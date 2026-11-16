//! Helper functions shared by build.zig: driving `./configure`, turning
//! parsed Makefile data into Zig compile steps, and other mechanical bits
//! that aren't part of the top-level build orchestration.

const std = @import("std");
const Options = @import("options.zig");
const Makefile = @import("makefile.zig");

pub const BundledArchive = struct {
    path: []const u8,
    objs_var: []const u8,
    cflags_var: []const u8,
};

/// Extension modules that link a small vendored/static library (rather than
/// a system one) get that dependency spelled out as a literal ".a" path
/// baked into their link recipe, bypassing their own LDFLAGS variable. There
/// are only a handful of these in CPython; recognize them by the archive
/// path and compile their sources directly into the module instead of
/// building the intermediate archive make would have.
pub const bundled_archives = [_]BundledArchive{
    .{ .path = "Modules/_decimal/libmpdec/libmpdec.a", .objs_var = "LIBMPDEC_OBJS", .cflags_var = "LIBMPDEC_CFLAGS" },
    .{ .path = "Modules/expat/libexpat.a", .objs_var = "LIBEXPAT_OBJS", .cflags_var = "LIBEXPAT_CFLAGS" },
    .{ .path = "Modules/_hacl/libHacl_Hash_SHA2.a", .objs_var = "LIBHACL_SHA2_OBJS", .cflags_var = "LIBHACL_CFLAGS" },
};

pub fn findBundledArchive(path: []const u8) ?BundledArchive {
    for (bundled_archives) |a| {
        if (std.mem.eql(u8, a.path, path)) return a;
    }
    return null;
}

fn containsToken(list: []const []const u8, tok: []const u8) bool {
    for (list) |t| {
        if (std.mem.eql(u8, t, tok)) return true;
    }
    return false;
}

/// Modules that only exist to exercise CPython's own test suite / C API
/// internals -- never useful in a normal interpreter, so we don't build them.
pub const skip_modules = std.StaticStringMap(void).initComptime(.{
    .{"_testbuffer"},        .{"_testinternalcapi"},   .{"_testcapi"},
    .{"_testclinic"},        .{"_testimportmultiple"}, .{"_testmultiphase"},
    .{"_testsinglephase"},   .{"_ctypes_test"},        .{"xxlimited"},
    .{"xxlimited_35"},       .{"xxsubtype"},           .{"_xxtestfuzz"},
    .{"_xxsubinterpreters"}, .{"_xxinterpchannels"},
});

/// `objsToSources` assumes every object has a same-named `.c` source, which
/// holds for nearly everything -- except a couple of objects (e.g.
/// Python/asm_trampoline.o) that are actually built from a `.S` assembly
/// file. Swap those in place instead of guessing arch/config-specific rules.
pub fn fixupSourceExtensions(b: *std.Build, cpython_dir: []const u8, sources: [][]const u8) [][]const u8 {
    for (sources, 0..) |src, i| {
        const abs = b.pathJoin(&.{ cpython_dir, src });
        std.Io.Dir.cwd().access(b.graph.io, abs, .{}) catch {
            const alt = b.fmt("{s}S", .{src[0 .. src.len - 1]});
            const alt_abs = b.pathJoin(&.{ cpython_dir, alt });
            std.Io.Dir.cwd().access(b.graph.io, alt_abs, .{}) catch
                std.debug.panic("neither {s} nor {s} exist", .{ abs, alt_abs });
            sources[i] = alt;
        };
    }
    return sources;
}

/// Everything that changes what a (re)configure should produce -- the command line it
/// would be run with, plus the caller's own `pyconfig.h` if there is one: if any of
/// this differs from the last successful run recorded in the stamp file (see below), a
/// fresh `./configure` is needed. Hashing the command itself rather than the inputs it
/// was derived from means a change in *how* it is composed (a flag added for a class
/// of target, say) invalidates the stamp on its own, with nothing to remember to
/// update here. Deliberately content-hashed
/// rather than relying on `Makefile`/`pyconfig.h` file-existence (the
/// previous check): this function runs eagerly during `build()`, at
/// graph-construction time, before any `Step` exists -- CPython's module
/// list is only known once `Makefile` is parsed, so `build()` itself decides
/// what Steps to create from configure's output, and can't defer that
/// decision to a `Step.Run`/`addFileInput` the way an ordinary build-time
/// action would (those only run during the later execution phase). A plain
/// existence check is also just wrong on its own terms: it treats "Makefile
/// is present" as "configure inputs haven't changed since", which doesn't
/// hold across a target/optimize/pyconfig-header change once someone's
/// deleted stale files by hand expecting a fresh run.
fn configureFingerprint(
    b: *std.Build,
    argv: []const []const u8,
    pyconfig_header: ?[]const u8,
) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    for (argv) |arg| {
        hasher.update(arg);
        hasher.update(&.{0});
    }
    if (pyconfig_header) |src| {
        const content = std.Io.Dir.cwd().readFileAlloc(b.graph.io, src, b.allocator, .unlimited) catch |err|
            std.debug.panic("failed to read pyconfig-header {s}: {t}", .{ src, err });
        hasher.update(content);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

const Sha256 = std.crypto.hash.sha2.Sha256;

/// GNU-triple-shaped string `config.sub` accepts -- same spelling Zig's own
/// triples already use except for 32-bit x86 (`i686`, not `x86`).
fn gnuArchTriple(b: *std.Build, result: std.Target) []const u8 {
    return b.fmt("{s}-linux-{s}", .{
        if (result.cpu.arch == .x86) "i686" else @tagName(result.cpu.arch),
        @tagName(result.abi),
    });
}

/// Bare name `writeBuildPythonStub` writes the stub under, inside
/// `cpython_dir`. Its own doc comment explains why the function returns
/// `"./" ++ build_python_stub_name` rather than a `cpython_dir`-joined path.
const build_python_stub_name = ".metapython-build-python-stub.sh";

/// A stub good enough to satisfy `./configure --with-build-python=`'s own check
/// (a `command -v` lookup, then one `$path -c "import sys; print(...)"` call to
/// read back a version string) without an actual, working, host-native CPython
/// on hand at configure time. Safe here specifically because this project never
/// runs `make`/`makesetup` afterwards -- the `PYTHON_FOR_BUILD`/`PYTHON_FOR_FREEZE`
/// Make variables this option feeds are only read by Makefile recipes we never
/// invoke (see build.zig's own 3-stage bootstrap, which freezes modules through
/// its own host-native `freeze_module`/`_bootstrap_python` Zig steps instead).
/// Version is read out of `./configure` itself (`PACKAGE_VERSION='X.Y'`) rather
/// than hardcoded, so a submodule bump can't silently desync the two.
///
/// Returns `"./" ++ build_python_stub_name`, not the `cpython_dir`-joined
/// `stub_path` used for the write below: the `./configure` process this is
/// handed to (`--with-build-python=`) already runs with `cwd` set to
/// `cpython_dir` (see `runConfigure`), and `cpython_dir` is not reliably
/// absolute -- confirmed empirically for a `-Dcpython-version=` dependency
/// fetched into this pinned Zig's project-local `zig-pkg/` cache, which comes
/// back as a path relative to the build root rather than an absolute one
/// (see `cpython_source.zig`'s own doc comment on why that cache is
/// project-local at all). Joining that relative `cpython_dir` onto the stub
/// path and handing the result to a process whose `cwd` is *already*
/// `cpython_dir` looks `cpython_dir` up a second, nonexistent time on top of
/// itself -- `configure`'s `--with-build-python` check then reports the
/// binary "invalid or missing", since nothing exists at that doubled path.
/// The leading `"./"` matters too: `configure`'s check is a shell `command -v
/// $with_build_python`, and a name with no `/` in it is a `$PATH` lookup, not
/// a cwd-relative one -- it would never find a script sitting right next to
/// it otherwise.
fn writeBuildPythonStub(b: *std.Build, cpython_dir: []const u8) []const u8 {
    const gpa = b.allocator;
    const configure_path = b.pathJoin(&.{ cpython_dir, "configure" });
    const configure_text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, configure_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t}", .{ configure_path, err });
    const needle = "\nPACKAGE_VERSION='";
    const start = std.mem.indexOf(u8, configure_text, needle) orelse
        std.debug.panic("PACKAGE_VERSION not found in {s}", .{configure_path});
    const rest = configure_text[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\'') orelse
        std.debug.panic("malformed PACKAGE_VERSION in {s}", .{configure_path});
    const version = rest[0..end];

    const stub_path = b.pathJoin(&.{ cpython_dir, build_python_stub_name });
    std.Io.Dir.cwd().writeFile(b.graph.io, .{
        .sub_path = stub_path,
        .data = b.fmt("#!/bin/sh\necho {s}\n", .{version}),
    }) catch |err| std.debug.panic("failed to write {s}: {t}", .{ stub_path, err });
    std.Io.Dir.cwd().setFilePermissions(b.graph.io, stub_path, .executable_file, .{}) catch |err|
        std.debug.panic("failed to chmod {s}: {t}", .{ stub_path, err });
    return "./" ++ build_python_stub_name;
}

/// Bare name `writePkgConfigWrapper` writes its wrapper script under, inside
/// `cpython_dir` -- same as `writeBuildPythonStub` above, but returned as an
/// *absolute* path instead of that function's `"./"`-relative one: `PKG_CONFIG=`
/// is only honored as a direct override by `configure.ac` when it looks
/// absolute (`case $PKG_CONFIG in [\\/]* | ?:[\\/]*)`) -- a relative one falls
/// through to a `$PATH` search instead, which does not know what to do with a
/// literal `./` prefix (see `writePkgConfigWrapper`'s own doc).
const pkg_config_wrapper_name = ".metapython-pkg-config-wrapper.sh";

/// A `pkg-config`-compatible wrapper that answers "not found" for `libb2`
/// specifically and delegates everything else verbatim to the real `pkg-config`
/// on `$PATH` -- `_blake2`'s own optional `libb2` accelerator (see
/// `runConfigure`'s own doc on it below) is the *only* thing that needs pkg-config
/// kept from seeing a real system library it has no linkage option of its own to
/// gate on; openssl/bz2/sqlite3/lzma's own detection all still need pkg-config
/// answering *honestly* for anything else they ask it (their own `ac_cv_*` cache
/// seeds only short-circuit a later "does it actually link" check -- the earlier,
/// always-run include/lib-path composition upstream of that still consults
/// `$PKG_CONFIG` first and, on failure, falls through to a hardcoded host
/// `ssldirs`-style search that adds an explicit `-I` for whatever it finds --
/// disabling pkg-config outright (`--with-pkg-config=no`, tried first) broke
/// that path for a real, working system OpenSSL install, feeding its host
/// `/usr/include` into the cross target's own compile).
///
/// Set as `PKG_CONFIG=<this wrapper>` (an absolute-looking value, so both of
/// `configure.ac`'s independent `$PKG_CONFIG` resolutions -- see `runConfigure`'s
/// own doc -- take it directly, `case $PKG_CONFIG in [\\/]* | ?:[\\/]*)`, without
/// searching `$PATH` at all), not a cache variable: unlike `ac_cv_path_PKG_CONFIG`/
/// `ac_cv_prog_PKG_CONFIG`, this one is not cleared out from under a seed by
/// `configure`'s own `--with-pkg-config=yes|check` staleness guard.
fn writePkgConfigWrapper(b: *std.Build, cpython_dir: []const u8) []const u8 {
    const wrapper_path = b.pathJoin(&.{ cpython_dir, pkg_config_wrapper_name });
    std.Io.Dir.cwd().writeFile(b.graph.io, .{
        .sub_path = wrapper_path,
        .data =
        \\#!/bin/sh
        \\for arg in "$@"; do
        \\    case "$arg" in
        \\        libb2) exit 1 ;;
        \\    esac
        \\done
        \\exec pkg-config "$@"
        \\
        ,
    }) catch |err| std.debug.panic("failed to write {s}: {t}", .{ wrapper_path, err });
    std.Io.Dir.cwd().setFilePermissions(b.graph.io, wrapper_path, .executable_file, .{}) catch |err|
        std.debug.panic("failed to chmod {s}: {t}", .{ wrapper_path, err });
    // Absolute, not `wrapper_path` verbatim: `cpython_dir` (and so `wrapper_path`,
    // built from it) is itself potentially build-root-relative for a
    // `-Dcpython-version=` dependency fetched into this pinned Zig's
    // project-local `zig-pkg/` (see `writeBuildPythonStub`'s own doc on the same
    // gotcha, and `build/utils.zig`'s sqlite3 `LIBSQLITE3_CFLAGS` fix for another
    // instance of it) -- `PKG_CONFIG=`, unlike `--with-build-python=`, needs a
    // value `configure.ac` recognizes as absolute to take it as a direct
    // override at all (see this function's own doc), so a relative one has to
    // be resolved against the real build root here, not left as `wrapper_path`.
    if (std.fs.path.isAbsolute(wrapper_path)) return wrapper_path;
    const build_root = b.root.root_dir.path orelse
        std.debug.panic("expected absolute build root path", .{});
    return b.pathJoin(&.{ build_root, wrapper_path });
}

pub fn runConfigure(
    b: *std.Build,
    cpython_dir: []const u8,
    prefix: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: Options.BuildOptions,
) void {
    const pyconfig_header = options.pyconfig_header;
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const cc = b.fmt("{s} cc -target {s}", .{ b.graph.zig_exe, triple });
    const cxx = b.fmt("{s} c++ -target {s}", .{ b.graph.zig_exe, triple });
    const ar = b.fmt("{s} ar", .{b.graph.zig_exe});
    const ranlib = b.fmt("{s} ranlib", .{b.graph.zig_exe});

    const host_result = b.graph.host.result;
    // A different CPU architecture than the build machine's own is the one case
    // plain, `--host`-less `./configure` cannot paper over: `AC_PROG_CC`'s very
    // first sanity check compiles a trivial program and *executes* it to learn
    // whether it's cross-compiling -- which works by accident for a same-arch,
    // different-libc target (a musl binary still runs fine on a glibc kernel)
    // but is a hard "cannot run C compiled programs" abort for e.g. an aarch64
    // binary on an x86_64 host, before configure produces anything at all. Real
    // `--host=`/`--build=` cross mode is the only way past that -- see below for
    // what entering it then additionally requires.
    const cross_arch = target.result.cpu.arch != host_result.cpu.arch;

    // `--build` for a musl target, and only for the sake of one decision.
    // CPython's configure derives its platform triplet from a *preprocessor* test
    // -- which cannot tell musl from glibc, since musl deliberately defines no
    // macro of its own -- and then rewrites `linux-gnu` to `linux-musl` only if
    // `$build_os` says musl. `$build_os` is the machine autoconf thinks it is
    // running on (and, notably, still what this checks even under real `--host`
    // cross mode below -- config.sub's musl relabeling reads `$build_os`, never
    // `$host_os`), so without this a musl build is indistinguishable from a
    // native glibc one and comes out claiming `SOABI=cpython-3xx-<arch>-linux-gnu`.
    // That name is not cosmetic: it is the `EXT_SUFFIX` every extension module is
    // named after and the one the import system looks for, so a `musllinux` wheel
    // (whose `.so` is named `...-linux-musl.so`) would be invisible to the
    // interpreter. Spelled with the *host's* own arch, not the target's: this is
    // a lie about `$build_os`'s libc only -- its architecture is supposed to
    // describe the real build machine truthfully, cross_arch or not.
    //
    // Under real `--host` cross mode (`cross_arch`, below), `--build=` also
    // stops being optional for an unrelated reason: this configure.ac treats a
    // `--host` given without an explicit `--build` as ambiguous
    // (`cross_compiling=maybe`) and refuses outright ("Cross compiling required
    // --host=HOST-TUPLE and --build=ARCH") rather than falling back to
    // `config.guess`. A non-musl cross-arch target therefore still needs a
    // `--build=`, just an honest one (no libc lie needed).
    const build_triple: ?[]const u8 = if (target.result.abi.isMusl())
        b.fmt("--build={s}-linux-{s}", .{
            // `config.sub` speaks GNU architecture names, which are Zig's own but for
            // the 32-bit x86 spelling.
            if (host_result.cpu.arch == .x86) "i686" else @tagName(host_result.cpu.arch),
            @tagName(target.result.abi),
        })
    else if (cross_arch)
        b.fmt("--build={s}", .{gnuArchTriple(b, host_result)})
    else
        null;

    // Which optional modules exist at all is `configure`'s call, and it makes it by
    // probing *this* machine -- which is the wrong question for every library this
    // project vendors and builds from source for the target. OpenSSL is where it
    // shows: the probe link-tests the host's `libssl` with a target-targeting
    // compiler, fails for anything but a native build, and leaves `_ssl`/`_hashlib`
    // out of `MODSHARED_NAMES` entirely -- so no amount of `-Dopenssl-linkage=static`
    // downstream can bring them back, because the Makefile carries no rule to build
    // them. Pre-seeding autoconf's own cache variables is the documented way to answer
    // a question the build machine cannot: the answer here is "yes, and the library
    // comes from us".
    var cache_vars: std.ArrayList([]const u8) = .empty;
    if (options.openssl_linkage == .static) {
        cache_vars.appendSlice(b.allocator, &.{
            "ac_cv_working_openssl_ssl=yes",
            "ac_cv_working_openssl_hashlib=yes",
        }) catch @panic("OOM");
    }
    // bz2's detection chain (`PKG_CHECK_MODULES([BZIP2], [bzip2], [have_bzip2=yes],
    // [fallback])`) is fully cache-var-bypassable: both the header presence check
    // (`AC_CHECK_HEADERS([bzlib.h])`) and the symbol check
    // (`AC_CHECK_LIB([bz2], [BZ2_bzCompress])`) are ordinary `AC_CACHE_CHECK`-family
    // macros, so seeding their two cache variables is enough -- no real header or
    // library needs to exist yet. But the *outer* `PKG_CHECK_MODULES` only reaches
    // that fallback if pkg-config doesn't already claim success on its own account,
    // which it will on any host that happens to have a `bzip2.pc` installed (this
    // build host does) -- see the `ac_cv_path_PKG_CONFIG` seed below for why that
    // path is closed off unconditionally whenever either of these is vendored.
    if (options.bz2_linkage == .static) {
        cache_vars.appendSlice(b.allocator, &.{
            "ac_cv_header_bzlib_h=yes",
            "ac_cv_lib_bz2_BZ2_bzCompress=yes",
        }) catch @panic("OOM");
    }
    // sqlite3's chain has one link bz2's doesn't: the version-number check
    // (`#if SQLITE_VERSION_NUMBER < 3007015`) is a raw, uncached `AC_COMPILE_IFELSE`
    // inside `AC_CHECK_HEADER([sqlite3.h])`'s action -- there is no cache variable
    // for it, so unlike every other check here it cannot be bypassed and a real
    // `sqlite3.h` must be reachable when `./configure` runs. Fetching the same
    // amalgamation the `sqlite3` Zig package itself depends on (rather than
    // hardcoding a second copy of the URL/hash in this project's own
    // `build.zig.zon`) keeps the two in lockstep automatically. The nine
    // `PY_CHECK_SQLITE_FUNC`-driven `AC_CHECK_LIB` capability checks that follow
    // *are* ordinary cached checks, so those are bypassed the same way bz2's is --
    // a real link test would fail anyway, since no compiled `libsqlite3.a` exists
    // at `./configure` time (the Zig artifact is only built later, during the
    // actual `zig build` compile phase).
    if (options.sqlite_linkage == .static) {
        const sqlite3_dep = b.dependency("sqlite3", .{ .target = target, .optimize = optimize });
        const sqlite3_src = sqlite3_dep.builder.dependency("sqlite3", .{});
        const sqlite3_src_dir_raw = sqlite3_src.builder.root.root_dir.path orelse
            std.debug.panic("expected a sqlite3 dependency root path", .{});
        // This pinned Zig fetches dependencies into a project-local `zig-pkg/`
        // (see build/cpython_source.zig's own doc comment), and `root_dir.path`
        // for one comes back *relative to this project's own build root*, not
        // absolute -- fine as long as whatever consumes it also runs from that
        // same build root, but `./configure` (and every compiler invocation it
        // spawns) runs from `cpython_dir` instead (a sibling `zig-pkg/<hash>/`
        // directory, itself the very same kind of build-root-relative path).
        // A relative `-I` flag passed to it therefore resolves against the
        // *wrong* base (`<build-root>/zig-pkg/<cpython-hash>/zig-pkg/<sqlite3-
        // hash>`, which doesn't exist) instead of the intended
        // `<build-root>/zig-pkg/<sqlite3-hash>` -- silently, since a missing
        // `-I` directory is not itself an error, it just means `sqlite3.h`
        // isn't found there either, and `AC_CHECK_HEADER([sqlite3.h])`'s own
        // uncached version-number probe (see this block's own doc above) has
        // no cache variable to paper over that with, unlike every other check
        // here. Joining it onto the real build root (absolute; see `build.zig`'s
        // own `b.root.root_dir.path` at its own top level) makes the flag
        // correct regardless of which directory `./configure` actually runs in.
        const build_root = b.root.root_dir.path orelse
            std.debug.panic("expected absolute build root path", .{});
        const sqlite3_src_dir = if (std.fs.path.isAbsolute(sqlite3_src_dir_raw))
            sqlite3_src_dir_raw
        else
            b.pathJoin(&.{ build_root, sqlite3_src_dir_raw });
        cache_vars.appendSlice(b.allocator, &.{
            b.fmt("LIBSQLITE3_CFLAGS=-I{s}", .{sqlite3_src_dir}),
            "LIBSQLITE3_LIBS=-lsqlite3",
            "ac_cv_lib_sqlite3_sqlite3_bind_double=yes",
            "ac_cv_lib_sqlite3_sqlite3_column_decltype=yes",
            "ac_cv_lib_sqlite3_sqlite3_column_double=yes",
            "ac_cv_lib_sqlite3_sqlite3_complete=yes",
            "ac_cv_lib_sqlite3_sqlite3_progress_handler=yes",
            "ac_cv_lib_sqlite3_sqlite3_result_double=yes",
            "ac_cv_lib_sqlite3_sqlite3_set_authorizer=yes",
            "ac_cv_lib_sqlite3_sqlite3_trace_v2=yes",
            "ac_cv_lib_sqlite3_sqlite3_value_double=yes",
        }) catch @panic("OOM");
    }
    // liblzma's chain (`PKG_CHECK_MODULES([LIBLZMA], [liblzma], [have_liblzma=yes],
    // [fallback])`) is the same shape as bz2's -- `AC_CHECK_HEADERS([lzma.h])` and
    // `AC_CHECK_LIB([lzma], [lzma_easy_encoder])` are both ordinary cached checks,
    // no uncached compile step like sqlite3's version probe, so two cache variables
    // are enough here too.
    if (options.lzma_linkage == .static) {
        cache_vars.appendSlice(b.allocator, &.{
            "ac_cv_header_lzma_h=yes",
            "ac_cv_lib_lzma_lzma_easy_encoder=yes",
        }) catch @panic("OOM");
    }
    // `_blake2`'s own optional `libb2` accelerator has no linkage option of its
    // own to gate this on: even with CPython's bundled HACL* implementation
    // selected by default (`with_builtin_blake2=yes`), `configure.ac` *still*
    // separately probes for a system `libb2` via `PKG_CHECK_MODULES` and prefers
    // it if pkg-config reports one -- which it does on any build host that
    // happens to have a `libb2.pc` installed, regardless of target, making the
    // whole module unbuildable for a cross target (see `unprovidableLibrary`'s
    // own doc) purely because of what's installed *here*.
    //
    // Disabling pkg-config outright first (`--with-pkg-config=no`, or seeding
    // its own `ac_cv_path_PKG_CONFIG`/`ac_cv_prog_PKG_CONFIG` cache variables
    // empty) broke a *different*, previously-working case: `openssl_linkage`'s
    // own detection (`AC_ARG_WITH([openssl], ...)`'s `else` branch -- reached
    // whenever `--with-openssl=` itself isn't passed, which this project never
    // does, static or not) *also* asks `$PKG_CONFIG` first for a real system
    // OpenSSL, and only falls through to a hardcoded `ssldirs="... /usr"` search
    // if that fails -- a search whose explicit `-I$ssldir/include` (unlike
    // pkg-config's own `--cflags-only-I`, which omits a default search path
    // entirely) leaked this build host's own `/usr/include` into the target
    // compile once pkg-config could no longer answer that question at all
    // (confirmed: `_ssl.c`/`_hashlib` picking up host `pthread.h` and failing on
    // x86-only attributes for an `aarch64-linux-gnu` target -- `ac_cv_working_
    // openssl_ssl=yes`/`ac_cv_working_openssl_hashlib=yes` only short-circuit a
    // *later* "does it actually link" check, not this earlier include/lib-path
    // composition). Disabling pkg-config for everything is too broad a hammer:
    // `_blake2` is the only thing that needs pkg-config kept from seeing a real
    // system library it has no linkage knob for -- bz2/sqlite3/lzma/openssl all
    // still need it answering *honestly* for anything else they ask.
    //
    // `writePkgConfigWrapper` is the scoped fix: a `pkg-config`-compatible
    // wrapper that fails only for `libb2` and delegates every other query
    // (openssl, bz2, sqlite3, liblzma, ...) straight to the real `pkg-config` on
    // `$PATH`, unchanged from before this whole investigation started. Handed to
    // `configure` as `PKG_CONFIG=<wrapper>` (a plain variable override, not a
    // cache-variable seed): both of `configure.ac`'s independent `$PKG_CONFIG`
    // resolutions honor a pre-set, absolute-looking `$PKG_CONFIG` directly
    // (`case $PKG_CONFIG in [\\/]* | ?:[\\/]*)`) without searching `$PATH` at
    // all, so there is no `ac_pt`/`ac_ct` fallback pair left to fight (unlike
    // `--with-pkg-config=no`/a cache-variable seed, which `configure`'s own
    // `--with-pkg-config=yes|check` staleness guard silently discarded for
    // exactly that fallback pair -- confirmed directly in a real `--host=
    // aarch64-linux-gnu` config.log).
    //
    // (Two dead ends tried first, per vendored_libraries_plan.md's `_blake2`
    // section: `PKG_CONFIG=/bin/false` -- pkg.m4 rejects a tool that fails
    // `--version` and searches `$PATH` again -- and pre-setting `LIBB2_CFLAGS`/
    // `LIBB2_LIBS` directly -- pkg.m4 then assumes success, which is worse.
    // `--with-pkg-config=no` was tried next, working for `_blake2` alone but
    // regressing openssl as described above; a `PKG_CONFIG=` wrapper was not
    // tried in that doc.)
    cache_vars.append(
        b.allocator,
        b.fmt("PKG_CONFIG={s}", .{writePkgConfigWrapper(b, cpython_dir)}),
    ) catch @panic("OOM");

    // Real `--host` cross mode (see `cross_arch` above) makes CPython's own
    // configure.ac answer nearly every feature check from its own built-in,
    // documented cross-compiling defaults -- verified empirically for
    // `aarch64-linux-gnu`: only these three have no such default and abort
    // outright asking for a cache variable (or, for getaddrinfo, a
    // `--disable-ipv6` fallback this project doesn't want) instead:
    //  - `getaddrinfo bug`: an `AC_TRY_RUN` with no cross branch at all: this
    //    project targets modern glibc/musl, neither of which has the bug the
    //    check exists for.
    //  - `/dev/ptmx`, `/dev/ptc`: file-existence checks configure explicitly
    //    refuses to guess when cross-compiling. Linux always has the former,
    //    never the latter (a BSD/macOS-only pty device).
    if (cross_arch) {
        cache_vars.appendSlice(b.allocator, &.{
            "ac_cv_buggy_getaddrinfo=no",
            "ac_cv_file__dev_ptmx=yes",
            "ac_cv_file__dev_ptc=no",
        }) catch @panic("OOM");
    }

    var argv_list: std.ArrayList([]const u8) = .empty;
    argv_list.appendSlice(b.allocator, &.{
        "./configure",
        b.fmt("--prefix={s}", .{prefix}),
        b.fmt("CC={s}", .{cc}),
        b.fmt("CXX={s}", .{cxx}),
        b.fmt("AR={s}", .{ar}),
        b.fmt("RANLIB={s}", .{ranlib}),
        switch (optimize) {
            .Debug => "--with-pydebug",
            .ReleaseFast, .ReleaseSmall, .ReleaseSafe => "--enable-optimizations",
        },
    }) catch @panic("OOM");
    if (build_triple) |entry| argv_list.append(b.allocator, entry) catch @panic("OOM");
    if (cross_arch) {
        argv_list.appendSlice(b.allocator, &.{
            b.fmt("--host={s}", .{gnuArchTriple(b, target.result)}),
            b.fmt("--with-build-python={s}", .{writeBuildPythonStub(b, cpython_dir)}),
        }) catch @panic("OOM");
    }
    argv_list.appendSlice(b.allocator, cache_vars.items) catch @panic("OOM");
    const argv = argv_list.items;

    const stamp_path = b.pathJoin(&.{ cpython_dir, ".metapython-configure-stamp" });
    const fingerprint = configureFingerprint(b, argv, pyconfig_header);
    const makefile_path = b.pathJoin(&.{ cpython_dir, "Makefile" });
    const stale = stale: {
        const prev = std.Io.Dir.cwd().readFileAlloc(b.graph.io, stamp_path, b.allocator, .limited(Sha256.digest_length)) catch
            break :stale true; // no stamp (first run, or someone deleted it): treat as stale
        std.Io.Dir.cwd().access(b.graph.io, makefile_path, .{}) catch break :stale true; // stamp present but Makefile missing: also stale
        break :stale !std.mem.eql(u8, prev, &fingerprint);
    };

    if (stale) {
        const result = std.process.run(b.allocator, b.graph.io, .{
            .argv = argv,
            .cwd = .{ .path = cpython_dir },
        }) catch |err| std.debug.panic("failed to run ./configure: {t}", .{err});
        if (!result.term.success()) {
            std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
            std.debug.panic("./configure failed", .{});
        }

        // A user-supplied pyconfig.h always wins: overwrite whatever
        // autoconf produced. Bypasses autoconf's detection results without
        // needing to skip ./configure -- Makefile is still required for the
        // makesetup-derived module/object lists.
        if (pyconfig_header) |src| {
            std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), b.pathJoin(&.{ cpython_dir, "pyconfig.h" }), b.graph.io, .{}) catch |err|
                std.debug.panic("failed to copy pyconfig-header {s}: {t}", .{ src, err });
        }

        std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = stamp_path, .data = &fingerprint }) catch |err|
            std.debug.panic("failed to write configure stamp {s}: {t}", .{ stamp_path, err });
    }
}

pub const ExeOptions = struct {
    name: []const u8,
    core_sources: []const []const u8,
    core_cflags: []const []const u8,
    extra_sources: []const []const u8,
    extra_flags: []const []const u8,
    link_libs: []const u8,
    /// LazyPaths to generated `Python/frozen_modules/*.h` headers this exe's
    /// sources #include; each needs its own include path (every freeze Run
    /// step's output lives in its own cache directory).
    frozen_headers: []const std.Build.LazyPath,
    /// Flags for dynload_source (Python/dynload_shlib.c needs -DSOABI, which
    /// core_cflags lacks; Python/dynload_win.c needs none, but still takes
    /// core_cflags for its include paths).
    dynload_flags: []const []const u8,
    /// Platform-specific dynamic-loading source: `Python/dynload_shlib.c`
    /// (POSIX dlopen()) or `Python/dynload_win.c` (Windows LoadLibrary()) --
    /// a LazyPath (not just a cpython-root-relative string) so a caller can
    /// point it at a patched copy instead of the file on disk (see
    /// build/sourcepatch.zig, used for Windows' dynload_win.c). No default:
    /// every call site names it explicitly.
    dynload_source: std.Build.LazyPath,
    /// Whether the executable itself (and the libc it links) is statically
    /// or dynamically linked -- independent of the third-party dependency
    /// StaticOverrides above, which only affect extension `.so`s.
    linkage: std.builtin.LinkMode,
    /// See addCoreObjects' doc comment. `null` for every POSIX call site.
    primary_include: ?std.Build.LazyPath = null,
};

/// Shared setup between `addExe` and `addPythonLib`: include paths, core +
/// extra sources, `dynload_shlib.c`, and system link tokens. Everything a
/// "contains the CPython core" compile step needs, regardless of whether it
/// ends up as an executable, a static archive, or a shared object.
fn addCoreObjects(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    mod: *std.Build.Module,
    gpa: std.mem.Allocator,
    core_sources: []const []const u8,
    core_cflags: []const []const u8,
    extra_sources: []const []const u8,
    extra_flags: []const []const u8,
    frozen_headers: []const std.Build.LazyPath,
    dynload_flags: []const []const u8,
    dynload_source: std.Build.LazyPath,
    link_libs: []const u8,
    /// Searched (for `#include "..."` quote-form lookups, e.g. `pyconfig.h`)
    /// *before* `cpython_dir` itself. Windows needs this: its `pyconfig.h`
    /// lives in `PC/`, not the cpython root, and the root may separately
    /// hold an autoconf-generated `pyconfig.h` (from configuring the host
    /// toolchain for the bootstrap tools) that must not shadow it.
    /// `buildPosix`'s own stage 1/2 need it for the mirror-image reason on a
    /// CPU-arch cross build: `cpython_dir`'s `pyconfig.h` is the *target's*
    /// by the time they compile, and they're host-native tools -- see
    /// `native_pyconfig_dir` there. `null` everywhere else leaves lookup
    /// order exactly as before.
    primary_include: ?std.Build.LazyPath,
) void {
    if (primary_include) |p| mod.addIncludePath(p);
    mod.addIncludePath(cpython_dir);
    mod.addIncludePath(cpython_dir.path(b, "Include"));
    mod.addIncludePath(cpython_dir.path(b, "Include/internal"));
    // Each generated `Python/frozen_modules/x.h` is #include-d two different
    // ways: `Python/frozen.c` says `#include "frozen_modules/x.h"` (root at
    // .../Python), while `Programs/_bootstrap_python.c` says `#include
    // "Python/frozen_modules/x.h"` (root one level up). Add both depths.
    for (frozen_headers) |h| {
        mod.addIncludePath(h.dirname().dirname());
        mod.addIncludePath(h.dirname().dirname().dirname());
    }

    const core_flags = extractIncludePaths(mod, b, cpython_dir, gpa, core_cflags);
    const resolved_extra_flags = extractIncludePaths(mod, b, cpython_dir, gpa, extra_flags);
    const resolved_dynload_flags = extractIncludePaths(mod, b, cpython_dir, gpa, dynload_flags);
    mod.addCSourceFiles(.{ .root = cpython_dir, .files = core_sources, .flags = core_flags });
    mod.addCSourceFiles(.{ .root = cpython_dir, .files = extra_sources, .flags = resolved_extra_flags });
    mod.addCSourceFile(.{ .file = dynload_source, .flags = resolved_dynload_flags });
    applyLinkTokens(mod, link_libs, &.{});
}

pub fn addExe(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    gpa: std.mem.Allocator,
    opts: ExeOptions,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .strip = strip, .link_libc = true });
    addCoreObjects(
        b,
        cpython_dir,
        mod,
        gpa,
        opts.core_sources,
        opts.core_cflags,
        opts.extra_sources,
        opts.extra_flags,
        opts.frozen_headers,
        opts.dynload_flags,
        opts.dynload_source,
        opts.link_libs,
        opts.primary_include,
    );

    return b.addExecutable(.{ .name = opts.name, .root_module = mod, .linkage = opts.linkage });
}

pub const LibPythonOptions = struct {
    name: []const u8,
    core_sources: []const []const u8,
    core_cflags: []const []const u8,
    /// `Modules/getpath.c` and `Python/frozen.c` -- everything stage 3 used
    /// to compile straight into the executable that now belongs in the
    /// library instead. `Programs/python.c` is deliberately NOT here: it
    /// stays in the thin shim executable (see build.zig), same split
    /// upstream CPython uses for `--enable-shared` builds.
    extra_sources: []const []const u8,
    extra_flags: []const []const u8,
    link_libs: []const u8,
    frozen_headers: []const std.Build.LazyPath,
    dynload_flags: []const []const u8,
    dynload_source: std.Build.LazyPath,
    deepfreeze_c: std.Build.LazyPath,
    /// `.static` -> libpythonX.Y.a (still ends up fully absorbed into
    /// whatever links it -- a build-organization split, not a runtime one).
    /// `.dynamic` -> a real libpythonX.Y.so with its own `.dynsym`, so
    /// extension modules and the shim resolve Python C-API symbols via an
    /// ordinary build-time dependency instead of `-rdynamic`.
    linkage: std.builtin.LinkMode,
    /// See addCoreObjects' doc comment. `null` for every POSIX call site.
    primary_include: ?std.Build.LazyPath = null,
};

pub fn addPythonLib(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    gpa: std.mem.Allocator,
    opts: LibPythonOptions,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .strip = strip, .link_libc = true });
    addCoreObjects(
        b,
        cpython_dir,
        mod,
        gpa,
        opts.core_sources,
        opts.core_cflags,
        opts.extra_sources,
        opts.extra_flags,
        opts.frozen_headers,
        opts.dynload_flags,
        opts.dynload_source,
        opts.link_libs,
        opts.primary_include,
    );
    mod.addCSourceFile(.{ .file = opts.deepfreeze_c, .flags = opts.core_cflags });

    const lib = b.addLibrary(.{ .name = opts.name, .root_module = mod, .linkage = opts.linkage });
    return lib;
}

/// `-I<path>` tokens pulled from the Makefile are relative to `$(srcdir)`
/// (i.e. cpython_dir in an in-tree build), which only holds if the C
/// compiler subprocess's cwd happens to match -- not guaranteed here. Turn
/// each into a real (absolute) `addIncludePath` call instead of leaving it as
/// an opaque, cwd-dependent flag string; return the remaining flags.
pub fn extractIncludePaths(
    mod: *std.Build.Module,
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    gpa: std.mem.Allocator,
    raw: []const []const u8,
) [][]const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    for (raw) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            const path = tok[2..];
            if (std.mem.startsWith(u8, path, "/")) {
                mod.addIncludePath(.{ .cwd_relative = path });
            } else {
                mod.addIncludePath(cpython_dir.path(b, path));
            }
        } else {
            flags.append(gpa, tok) catch @panic("OOM");
        }
    }
    return flags.toOwnedSlice(gpa) catch @panic("OOM");
}

/// Maps a system library name (the `-l<name>` token CPython's own Makefile
/// would otherwise pass) to a Zig-built static artifact that should be baked
/// into the module instead of dynamically linking the host's `.so`.
pub const StaticOverride = struct {
    lib_name: []const u8,
    artifact: *std.Build.Step.Compile,
};

fn findOverride(overrides: []const StaticOverride, lib_name: []const u8) ?*std.Build.Step.Compile {
    for (overrides) |o| {
        if (std.mem.eql(u8, o.lib_name, lib_name)) return o.artifact;
    }
    return null;
}

pub fn applyLinkTokens(mod: *std.Build.Module, expanded: []const u8, overrides: []const StaticOverride) void {
    var it = std.mem.tokenizeAny(u8, expanded, " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-l")) {
            if (findOverride(overrides, tok[2..])) |artifact| {
                mod.linkLibrary(artifact);
            } else {
                mod.linkSystemLibrary(tok[2..], .{});
            }
        } else if (std.mem.startsWith(u8, tok, "-L")) {
            mod.addLibraryPath(.{ .cwd_relative = tok[2..] });
        }
    }
}

/// Copies an exe's binary next to a fresh copy of Lib/, in the relative
/// layout CPython's getpath.c landmark search expects, so it can run as a
/// real interpreter straight out of the build cache (see getpath_defines).
/// Returns the LazyPath of the copied executable.
pub fn packageExe(b: *std.Build, cpython_dir: std.Build.LazyPath, version: []const u8, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const wf = b.addNamedWriteFiles(exe.name);
    _ = wf.addCopyDirectory(cpython_dir.path(b, "Lib"), b.fmt("lib/python{s}", .{version}), .{});
    return wf.addCopyFile(exe.getEmittedBin(), b.fmt("bin/{s}", .{exe.out_filename}));
}

/// Invokes Tools/build/deepfreeze.py (a pure-Python script run by the stage-2
/// bootstrap interpreter) to combine all frozen module headers into a single
/// Python/deepfreeze/deepfreeze.c file, which embeds the entire frozen stdlib
/// bytecode into the final executable. Each frozen module header is passed as
/// a "path:name" argument. The path half is only known once the freeze Run
/// steps above actually execute, so the pairing can't be done in build.zig at
/// graph-construction time -- instead a small native helper
/// (build/tools/deepfreeze_runner.zig) does it at run time.
///
/// `deepfreeze_script` is `Tools/build/deepfreeze.py`, resolved by the caller
/// rather than derived from a bare `cpython_dir` here -- on 3.13+ it needs
/// `Sourcepatch.deepfreeze_fixups` applied first (see that patch's own doc
/// comment), which only the caller (already threading `cpython_dir_str`
/// through for its own patches) can do.
pub fn addDeepfreeze(
    b: *std.Build,
    deepfreeze_script: std.Build.LazyPath,
    bootstrap_packaged_exe: std.Build.LazyPath,
    headers: []const std.Build.LazyPath,
    names: []const []const u8,
) std.Build.LazyPath {
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("build/tools/deepfreeze_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const runner = b.addExecutable(.{ .name = "deepfreeze_runner", .root_module = runner_mod });

    const run = b.addRunArtifact(runner);
    run.addFileArg(bootstrap_packaged_exe);
    run.addFileArg(deepfreeze_script);
    const out = run.addOutputFileArg("deepfreeze.c");
    for (headers, names) |h, name| {
        run.addFileArg(h);
        run.addArg(name);
    }
    return out;
}

/// Libraries a target's own libc accounts for, so a `-l<name>` naming one needs
/// nothing from this project and nothing from the build host. This is musl's own
/// `EMPTY_LIB_NAMES` -- the archives it ships empty because the implementations live in
/// libc proper -- and glibc splits the same set into stub `.so`s that resolve just as
/// unconditionally.
const libc_provided_libraries = std.StaticStringMap(void).initComptime(.{
    .{"m"},    .{"rt"},   .{"pthread"}, .{"crypt"},
    .{"util"}, .{"xnet"}, .{"resolv"},  .{"dl"},
    .{"c"},    .{"gcc"},  .{"gcc_eh"},
});

/// The first system library in `link_tokens` that cannot be provided for `target`:
/// neither vendored by this project (`overrides`) nor part of the target's libc.
///
/// This is what decides whether a module is buildable *before* trying, and it exists
/// because `./configure` decides the module set by probing the build machine. For a
/// cross target its answers describe the wrong system: it offers `_bz2`, `_lzma`,
/// `readline`, `nis`, `_uuid` and `_blake2` on the strength of the host's headers, and
/// the link then fails ("unable to find dynamic system library 'bz2'") -- taking the
/// whole `install` step down with it, so modules that *would* have installed are
/// missing from the prefix too. Answering here instead turns each of those into one
/// skipped module and a complete build.
///
/// A native build keeps its old behaviour: the host's libraries *are* the target's, so
/// anything installed on it is fair game and gets bundled by the consumer afterwards.
/// Vendoring one of these (a `build.zig.zon` dependency plus a `static_overrides`
/// entry) is what turns its module back on for cross targets, one at a time.
pub fn unprovidableLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    link_tokens: []const u8,
    overrides: []const StaticOverride,
) ?[]const u8 {
    const host = b.graph.host.result;
    const native = target.result.cpu.arch == host.cpu.arch and
        target.result.os.tag == host.os.tag and
        target.result.abi == host.abi;
    if (native) return null;
    var it = std.mem.tokenizeAny(u8, link_tokens, " \t");
    while (it.next()) |tok| {
        if (!std.mem.startsWith(u8, tok, "-l")) continue;
        const lib_name = tok[2..];
        if (lib_name.len == 0) continue;
        if (libc_provided_libraries.has(lib_name)) continue;
        if (findOverride(overrides, lib_name) != null) continue;
        return lib_name;
    }
    return null;
}

pub fn addSharedModule(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    mk: Makefile,
    gpa: std.mem.Allocator,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    common_cflags: []const []const u8,
    name: []const u8,
    overrides: []const StaticOverride,
    /// When the core interpreter is built as a real libpythonX.Y.so
    /// (`python-linkage=dynamic`), every extension module links against it
    /// directly instead of relying on `-rdynamic` to resolve its Python
    /// C-API references against the main executable at runtime.
    python_lib: ?*std.Build.Step.Compile,
) ?*std.Build.Step.Compile {
    const rule = mk.findSharedModuleRule(gpa, name) orelse {
        std.debug.print("warning: no build rule found for module '{s}', skipping\n", .{name});
        return null;
    };
    const link_tokens = std.mem.join(gpa, " ", rule.recipe) catch @panic("OOM");
    if (unprovidableLibrary(b, target, link_tokens, overrides)) |lib_name| {
        std.debug.print(
            "skipping module '{s}': it needs the system library '{s}', which is " ++
                "neither built from source here nor part of {s}'s libc\n",
            .{ name, lib_name, target.query.zigTriple(gpa) catch @panic("OOM") },
        );
        return null;
    }

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .strip = strip, .link_libc = true });
    mod.addIncludePath(cpython_dir);
    mod.addIncludePath(cpython_dir.path(b, "Include"));
    mod.addIncludePath(cpython_dir.path(b, "Include/internal"));

    var upper_buf: [64]u8 = undefined;
    const upper_name = std.ascii.upperString(&upper_buf, name);
    const fallback_cflags_raw = std.mem.concat(
        gpa,
        []const u8,
        &.{ common_cflags, Makefile.tokens(gpa, mk.get(gpa, b.fmt("MODULE_{s}_CFLAGS", .{upper_name}))) },
    ) catch @panic("OOM");

    for (rule.prereqs) |tok| {
        if (!std.mem.endsWith(u8, tok, ".o")) continue;
        const src = b.fmt("{s}c", .{tok[0 .. tok.len - 1]});
        // Prefer the object's real recipe over the MODULE_<NAME>_CFLAGS naming
        // convention: not every module's own object follows it (sha3module.o
        // inlines its own -I flag directly, for instance).
        const flags_raw = if (mk.findObjectFlags(gpa, tok)) |f| Makefile.tokens(gpa, f) else fallback_cflags_raw;
        mod.addCSourceFile(.{
            .file = cpython_dir.path(b, src),
            .flags = extractIncludePaths(mod, b, cpython_dir, gpa, flags_raw),
        });
    }

    for (rule.recipe) |tok| {
        if (std.mem.endsWith(u8, tok, ".a")) {
            const archive = findBundledArchive(tok) orelse {
                std.debug.print("warning: module '{s}' needs unrecognized archive '{s}', skipping\n", .{ name, tok });
                return null;
            };
            mod.addCSourceFiles(.{
                .root = cpython_dir,
                .files = Makefile.objsToSources(gpa, mk.get(gpa, archive.objs_var)),
                .flags = extractIncludePaths(mod, b, cpython_dir, gpa, Makefile.tokens(gpa, mk.get(gpa, archive.cflags_var))),
            });
        } else if (std.mem.endsWith(u8, tok, ".o") and !containsToken(rule.prereqs, tok)) {
            // A bare object token in the *link* recipe, not a `.a` archive and
            // not already compiled via the `rule.prereqs` loop above (that
            // check matters: a simple module's own primary object -- e.g.
            // `_ssl.c`'s `Modules/_ssl.o` -- is both a prereq *and* one of
            // the tokens the recipe links, so without it every such module
            // would get its own source compiled twice, `ld.lld: duplicate
            // symbol: PyInit__ssl`). What this branch is actually for:
            // `_blake2`'s MODULE__BLAKE2_LDFLAGS is `$(LIBHACL_BLAKE2_OBJS)`
            // itself (new in CPython 3.14; every other bundled-C-library
            // module wraps its objects in an intermediate `.a` first) --
            // never a prereq, so silently missing from the link line
            // otherwise: the module still builds, `dlopen()` still succeeds,
            // but every symbol these objects would have defined is undefined
            // until first referenced, e.g. `Hacl_Hash_Blake2s_free`.
            const src = b.fmt("{s}c", .{tok[0 .. tok.len - 1]});
            const flags_raw = if (mk.findObjectFlags(gpa, tok)) |f| Makefile.tokens(gpa, f) else fallback_cflags_raw;
            mod.addCSourceFile(.{
                .file = cpython_dir.path(b, src),
                .flags = extractIncludePaths(mod, b, cpython_dir, gpa, flags_raw),
            });
        }
    }
    applyLinkTokens(mod, link_tokens, overrides);

    if (python_lib) |lib| {
        mod.linkLibrary(lib);
        // lib-dynload/foo.so -> ../.. reaches the prefix's lib/ dir, where
        // libpythonX.Y.so is installed (see build.zig's install step). Zig
        // also unconditionally emits an extra `-rpath <build-cache-dir>`
        // entry for same-build `linkLibrary` dynamic dependencies (no public
        // flag suppresses it) -- harmless: it's just a dead RUNPATH entry
        // once the tree is installed/moved elsewhere, and this $ORIGIN one
        // still resolves correctly (verified by relocating a built tree).
        mod.addRPathSpecial("$ORIGIN/../..");
    }

    return b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .dynamic });
}

/// The "builtin module" counterpart to `addSharedModule`: adds `name`'s
/// sources/flags directly onto `target_mod` (the main `python` executable's
/// own root module) instead of creating a separate shared-library artifact --
/// no `.so`, no `dlopen()`, no dynamic linking involved for this module at
/// all. Shares all of `addSharedModule`'s source/flag/static-override
/// resolution logic (same Makefile-derived build rule), just without the
/// separate-library wrapping or the `python_lib`/`addRPathSpecial` dance
/// (irrelevant here: a builtin module's Python C-API references resolve via
/// ordinary same-executable linking, not a runtime dependency on anything).
///
/// Returns `false` (after printing the same warning `addSharedModule` would)
/// if no build rule exists for `name`, or if it needs an unrecognized bundled
/// archive -- same not-buildable-here cases, not a builtin-vs-shared
/// distinction. Callers must skip registering the module in
/// `_PyImport_Inittab` when this returns `false` (see build.zig): a `false`
/// here means no object code for it was actually added, and declaring a
/// `PyInit_<name>` extern with nothing to define it is a link error.
pub fn addBuiltinModule(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    mk: Makefile,
    gpa: std.mem.Allocator,
    target_mod: *std.Build.Module,
    common_cflags: []const []const u8,
    name: []const u8,
    overrides: []const StaticOverride,
) bool {
    const rule = mk.findSharedModuleRule(gpa, name) orelse {
        std.debug.print("warning: no build rule found for module '{s}', skipping\n", .{name});
        return false;
    };

    var upper_buf: [64]u8 = undefined;
    const upper_name = std.ascii.upperString(&upper_buf, name);
    const fallback_cflags_raw = std.mem.concat(
        gpa,
        []const u8,
        &.{ common_cflags, Makefile.tokens(gpa, mk.get(gpa, b.fmt("MODULE_{s}_CFLAGS", .{upper_name}))) },
    ) catch @panic("OOM");

    for (rule.prereqs) |tok| {
        if (!std.mem.endsWith(u8, tok, ".o")) continue;
        const src = b.fmt("{s}c", .{tok[0 .. tok.len - 1]});
        const flags_raw = if (mk.findObjectFlags(gpa, tok)) |f| Makefile.tokens(gpa, f) else fallback_cflags_raw;
        target_mod.addCSourceFile(.{
            .file = cpython_dir.path(b, src),
            .flags = extractIncludePaths(target_mod, b, cpython_dir, gpa, flags_raw),
        });
    }

    for (rule.recipe) |tok| {
        if (!std.mem.endsWith(u8, tok, ".a")) continue;
        const archive = findBundledArchive(tok) orelse {
            std.debug.print("warning: module '{s}' needs unrecognized archive '{s}', skipping\n", .{ name, tok });
            return false;
        };
        target_mod.addCSourceFiles(.{
            .root = cpython_dir,
            .files = Makefile.objsToSources(gpa, mk.get(gpa, archive.objs_var)),
            .flags = extractIncludePaths(target_mod, b, cpython_dir, gpa, Makefile.tokens(gpa, mk.get(gpa, archive.cflags_var))),
        });
    }
    applyLinkTokens(target_mod, std.mem.join(gpa, " ", rule.recipe) catch @panic("OOM"), overrides);

    return true;
}

/// Patches `config_c_path`'s content (CPython's own generated
/// `Modules/config.c` -- produced by `./configure` itself, no `make`/
/// `makesetup` run needed; see build.zig's top comment), inserting an
/// `extern PyObject* PyInit_<name>(void);` declaration and a
/// `{"<name>", PyInit_<name>},` `_PyImport_Inittab` entry for each of
/// `module_names`, at the `/* -- ADDMODULE MARKER {1,2} -- */` comments
/// `makesetup` itself would use for exactly this purpose (present in the
/// file regardless of whether `makesetup` ever actually runs). Returns a
/// `LazyPath` to the patched copy, written via `b.addWriteFiles()` -- the
/// original file on disk is left untouched.
pub fn patchBuiltinModulesConfig(
    b: *std.Build,
    gpa: std.mem.Allocator,
    config_c_path: []const u8,
    module_names: []const []const u8,
) std.Build.LazyPath {
    const original = std.Io.Dir.cwd().readFileAlloc(b.graph.io, config_c_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t}", .{ config_c_path, err });

    var externs: std.ArrayList(u8) = .empty;
    var entries: std.ArrayList(u8) = .empty;
    for (module_names) |name| {
        externs.appendSlice(gpa, b.fmt("extern PyObject* PyInit_{s}(void);\n", .{name})) catch @panic("OOM");
        entries.appendSlice(gpa, b.fmt("    {{\"{s}\", PyInit_{s}}},\n", .{ name, name })) catch @panic("OOM");
    }

    const marker1 = "/* -- ADDMODULE MARKER 1 -- */";
    const marker2 = "/* -- ADDMODULE MARKER 2 -- */";
    const with_externs = replaceOnce(gpa, original, marker1, b.fmt("{s}\n{s}", .{ externs.items, marker1 })) orelse
        std.debug.panic("{s}: marker 1 not found -- CPython version drift?", .{config_c_path});
    const patched = replaceOnce(gpa, with_externs, marker2, b.fmt("{s}\n{s}", .{ entries.items, marker2 })) orelse
        std.debug.panic("{s}: marker 2 not found -- CPython version drift?", .{config_c_path});

    const wf = b.addWriteFiles();
    return wf.add("config.c", patched);
}

fn replaceOnce(gpa: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ?[]const u8 {
    const index = std.mem.indexOf(u8, haystack, needle) orelse return null;
    return std.mem.concat(gpa, u8, &.{ haystack[0..index], replacement, haystack[index + needle.len ..] }) catch @panic("OOM");
}
