//! Builds CPython "the normal way" (dynamic linking of extension modules and
//! system libraries), driving compilation directly through Zig's build
//! system instead of `make`.
//!
//! `./configure` is still used (POSIX only) to detect available system
//! libraries and to expand CPython's own Makefile.pre.in into a concrete
//! Makefile via its internal `makesetup` pass. We never execute that
//! Makefile with `make` -- see build/makefile.zig, which reads it purely as
//! data (object lists, per-module CFLAGS/LDFLAGS, frozen-module recipes) so
//! we can add the equivalent Zig compile steps ourselves (see build/utils.zig).
//!
//! `./configure` also generates `pyconfig.h`; pass `-Dpyconfig-header=<path>`
//! to overwrite it with your own afterward (see build/utils.zig's
//! runConfigure) -- useful when cross-compiling, since autoconf's detection
//! can't execute target-arch test programs.

const std = @import("std");
const Makefile = @import("build/makefile.zig");
const Utils = @import("build/utils.zig");
const Options = @import("build/options.zig");
const Sysconfigdata = @import("build/sysconfigdata.zig");
const Pyconfig = @import("build/pyconfig.zig");
const Vcxproj = @import("build/vcxproj.zig");
const Sourcepatch = @import("build/sourcepatch.zig");
const Musl = @import("build/musl.zig");
const CpythonSource = @import("build/cpython_source.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = Options.parseOptions(b);

    // `null` means the `-Dcpython-version=` dependency was just queued for
    // fetching (see CpythonSource.resolve's own doc comment) -- bail with no
    // steps added; `zig build` fetches it and reruns this function.
    const cpython = CpythonSource.resolve(b) orelse return;

    switch (target.result.os.tag) {
        .windows => buildWindows(b, target, optimize, options, cpython),
        else => buildPosix(b, target, optimize, options, cpython),
    }
}

// Windows build. CPython's own Windows build has no `./configure`/`Makefile`
// at all -- it's driven by `PCbuild/*.vcxproj` (MSBuild) plus a static,
// checked-in `PC/pyconfig.h`. See windows.md for the full design writeup;
// summary of what's different from `buildPosix` below:
//
// - No `./configure` for the *target*: `PC/pyconfig.h` is used as-is.
// - Stage 1/2 (freeze_module, _bootstrap_python) are host-native tools
//   regardless of target (see buildPosix's own comments -- true there
//   already for musl cross-builds). For Windows they need a *real* POSIX
//   pyconfig.h/Makefile pair to compile for the (Linux) build host, entirely
//   independent of the Windows target -- so `./configure` still runs here,
//   just targeting `b.graph.host`, not `target`.
// - Stage 3's source list comes from `PCbuild/pythoncore.vcxproj` (parsed by
//   build/vcxproj.zig), not a Makefile: Windows statically links most stdlib
//   C extensions straight into `pythonXY.dll` rather than building each as a
//   separate shared object the way POSIX does (that's `PC/config.c`'s
//   inittab, used verbatim -- entries needing an unavailable optional
//   dependency, e.g. zlib, are already `#ifdef`-guarded out in that file).
// - The split-lib shape (`pythonXY.dll` + a thin `python.exe` shim) is
//   mandatory here, not a `python-linkage=dynamic` opt-in like on POSIX:
//   there's no `-rdynamic` equivalent for a plain `.exe`, so extension
//   `.pyd`s (once added) need a real import library to link against.
// - Target triple is mingw-w64 (`*-windows-gnu`), not MSVC ABI: MSVC needs
//   Microsoft's own SDK/CRT, which Zig doesn't (can't -- proprietary,
//   non-redistributable) bundle, breaking this project's standalone-toolchain
//   constraint. Confirmed empirically: `zig cc -target x86_64-windows-msvc`
//   fails to link libc at all, `x86_64-windows-gnu` works with zero extra
//   setup. Tradeoff: no ABI compat with official PyPI Windows wheels.
fn buildWindows(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options.BuildOptions, cpython: CpythonSource.Source) void {
    const gpa = b.allocator;
    const build_root = b.root.root_dir.path orelse @panic("expected absolute build root path");
    const cpython_dir_str = cpython.dir_str;
    const cpython_dir = cpython.dir;
    const prefix = b.pathJoin(&.{ build_root, "zig-out" });

    // ---- host side: configure+build the bootstrap tools natively (Linux),
    // completely independent of the Windows `target` below.
    Utils.runConfigure(b, cpython_dir_str, prefix, b.graph.host, .Debug, options);

    const makefile_path = b.pathJoin(&.{ cpython_dir_str, "Makefile" });
    const makefile_text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, makefile_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t} (did ./configure run?)", .{ makefile_path, err });
    const mk: Makefile = .{ .text = makefile_text };

    const version = mk.get(gpa, "VERSION"); // e.g. "3.12"

    const host_core_cflags = std.mem.concat(gpa, []const u8, &.{
        Makefile.tokens(gpa, mk.get(gpa, "PY_CORE_CFLAGS")),
        &[_][]const u8{"-Wno-error=date-time"}, // see buildPosix's own comment on this flag
    }) catch @panic("OOM");
    const host_all_core_sources = Utils.fixupSourceExtensions(b, cpython_dir_str, Makefile.objsToSources(gpa, mk.get(gpa, "LIBRARY_OBJS_OMIT_FROZEN")));
    const host_link_libs = std.mem.concat(gpa, u8, &.{
        mk.get(gpa, "LIBS"), " ", mk.get(gpa, "MODLIBS"), " ", mk.get(gpa, "SYSLIBS"),
    }) catch @panic("OOM");
    const host_dynload_flags = std.mem.concat(gpa, []const u8, &.{
        host_core_cflags,
        &[_][]const u8{b.fmt("-DSOABI=\"{s}\"", .{mk.get(gpa, "SOABI")})},
    }) catch @panic("OOM");
    var host_core_sources: std.ArrayList([]const u8) = .empty;
    for (host_all_core_sources) |s| {
        if (!std.mem.eql(u8, s, "Python/dynload_shlib.c")) host_core_sources.append(gpa, s) catch @panic("OOM");
    }

    const freeze_module_exe = Utils.addExe(b, cpython_dir, b.graph.host, .Debug, false, gpa, .{
        .name = "freeze_module",
        .core_sources = host_core_sources.items,
        .core_cflags = host_core_cflags,
        .extra_sources = &.{ "Programs/_freeze_module.c", "Modules/getpath_noop.c" },
        .extra_flags = host_core_cflags,
        .link_libs = host_link_libs,
        .frozen_headers = &.{},
        .dynload_flags = host_dynload_flags,
        .dynload_source = cpython_dir.path(b, "Python/dynload_shlib.c"),
        .linkage = .dynamic,
    });

    const freeze_entries = mk.freezeEntries(gpa);
    var early_headers = std.StringHashMap(std.Build.LazyPath).init(gpa);
    var early_headers_list: std.ArrayList(std.Build.LazyPath) = .empty;
    for (freeze_entries) |f| {
        if (!f.bootstrap) continue;
        const run = b.addRunArtifact(freeze_module_exe);
        run.addArg(f.name);
        run.addFileArg(cpython_dir.path(b, f.src));
        const out = run.addOutputFileArg(f.out);
        early_headers.put(f.name, out) catch @panic("OOM");
        early_headers_list.append(gpa, out) catch @panic("OOM");
    }

    const host_getpath_flags = std.mem.concat(gpa, []const u8, &.{
        host_core_cflags,
        &[_][]const u8{
            "-DPREFIX=\"\"",
            "-DEXEC_PREFIX=\"\"",
            b.fmt("-DVERSION=\"{s}\"", .{version}),
            "-DPLATLIBDIR=\"lib\"",
            "-DVPATH=\"\"",
        },
    }) catch @panic("OOM");

    const bootstrap_exe = Utils.addExe(b, cpython_dir, b.graph.host, .Debug, false, gpa, .{
        .name = "_bootstrap_python",
        .core_sources = host_core_sources.items,
        .core_cflags = host_core_cflags,
        .extra_sources = &.{ "Programs/_bootstrap_python.c", "Modules/getpath.c" },
        .extra_flags = host_getpath_flags,
        .link_libs = host_link_libs,
        .frozen_headers = early_headers_list.items,
        .dynload_flags = host_dynload_flags,
        .dynload_source = cpython_dir.path(b, "Python/dynload_shlib.c"),
        .linkage = .dynamic,
    });
    const bootstrap_packaged_exe = Utils.packageExe(b, cpython_dir, version, bootstrap_exe);

    var frozen_headers: std.ArrayList(std.Build.LazyPath) = .empty;
    var deepfreeze_headers: std.ArrayList(std.Build.LazyPath) = .empty;
    var deepfreeze_names: std.ArrayList([]const u8) = .empty;
    for (freeze_entries) |f| {
        const out = if (f.bootstrap) early_headers.get(f.name).? else blk: {
            const run = std.Build.Step.Run.create(b, b.fmt("freeze {s}", .{f.name}));
            run.addFileArg(bootstrap_packaged_exe);
            run.addFileArg(cpython_dir.path(b, "Programs/_freeze_module.py"));
            run.addArg(f.name);
            run.addFileArg(cpython_dir.path(b, f.src));
            break :blk run.addOutputFileArg(f.out);
        };
        frozen_headers.append(gpa, out) catch @panic("OOM");
        if (!std.mem.eql(u8, f.name, "getpath")) {
            deepfreeze_headers.append(gpa, out) catch @panic("OOM");
            deepfreeze_names.append(gpa, f.name) catch @panic("OOM");
        }
    }
    const deepfreeze_script = Sourcepatch.applyIfPresent(
        b,
        gpa,
        cpython_dir_str,
        Sourcepatch.deepfreezePatch(b, gpa, cpython_dir_str),
        Sourcepatch.deepfreezeSiblings(gpa, cpython_dir_str),
    );
    const deepfreeze_c = Utils.addDeepfreeze(b, deepfreeze_script, bootstrap_packaged_exe, deepfreeze_headers.items, deepfreeze_names.items);

    // ---- target side: the real Windows build, sourced from pythoncore.vcxproj.
    const pythoncore_vcxproj_path = b.pathJoin(&.{ cpython_dir_str, "PCbuild", "pythoncore.vcxproj" });
    const pythoncore_vcxproj_text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, pythoncore_vcxproj_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t}", .{ pythoncore_vcxproj_path, err });
    // Python/dynload_win.c is pulled out and added back via `dynload_source`
    // below, same reason buildPosix pulls Python/dynload_shlib.c out of its
    // own core_sources (see its comment on `dynload_src`). Modules/zlibmodule.c
    // is excluded too: its own vendored zlib sources were already dropped by
    // Vcxproj.sources' `$(zlibDir)` filter, so it'd otherwise be a module with
    // no zlib to link against -- zlib support is optional/deferred (windows.md).
    // Modules/_winapi.c is pulled out for the same reason as dynload_win.c:
    // it needs a build/sourcepatch.zig fixup too (see mingw_fixups), added
    // back individually below instead of through the bulk core_sources list.
    // Python/deepfreeze/deepfreeze.c is pythoncore.vcxproj's reference to
    // CPython's own checked-in, pre-generated copy (for MSVC builds, which
    // never run our freeze pipeline) -- excluded in favor of the one this
    // build freshly generates (`deepfreeze_c` below, from *this* build's
    // actual frozen-module set), same symbols either way so keeping both
    // is a straight duplicate-symbol link error, not just redundant work.
    var win_core_sources: std.ArrayList([]const u8) = .empty;
    for (Vcxproj.sources(gpa, pythoncore_vcxproj_text)) |src| {
        if (std.mem.eql(u8, src, "Python/dynload_win.c")) continue;
        if (std.mem.eql(u8, src, "Modules/zlibmodule.c")) continue;
        if (std.mem.eql(u8, src, "Modules/_winapi.c")) continue;
        if (std.mem.eql(u8, src, "Python/deepfreeze/deepfreeze.c")) continue;
        win_core_sources.append(gpa, src) catch @panic("OOM");
    }

    // Mirrors pythoncore.vcxproj's own `<PreprocessorDefinitions>` (project-wide,
    // plus getpath.c's per-file block folded in globally -- Python/sysmodule.c
    // also reads VPATH directly, so it can't be getpath.c-only the way
    // buildPosix's getpath_flags split assumes). `PLATLIBDIR="DLLs"` and
    // `PREFIX`/`EXEC_PREFIX`/`VERSION` all `NULL` (not `""`): the literal
    // values CPython's own Windows build passes for the same relocatable,
    // argv0-relative landmark-search behavior buildPosix's blank-string
    // getpath_defines achieve on POSIX.
    const win_core_cflags = [_][]const u8{
        "-DPy_BUILD_CORE",
        "-DPy_BUILD_CORE_BUILTIN",
        "-DPy_ENABLE_SHARED",
        "-D_USRDLL",
        "-DPREFIX=NULL",
        "-DEXEC_PREFIX=NULL",
        "-DVERSION=NULL",
        "-DVPATH=\"\"",
        "-DPLATLIBDIR=\"DLLs\"",
        "-Wno-error=date-time",
        // See core_cflags' own comment on this one below -- same reason,
        // same fix, same generated deepfreeze.c triggering it either way.
        "-Wno-unterminated-string-initialization",
        // MSBuild-property-only placeholder (see pythoncore.vcxproj's
        // `MS_DLL_ID="$(SysWinVer)"`) that PC/dl_nt.c also reads directly as
        // code, not just from the .rc resource we don't compile. Just a
        // version-stamp string; blank is harmless.
        "-DMS_DLL_ID=\"\"",
        // Normally comes from PCbuild/pyproject.props (shared across every
        // vcxproj, pythoncore.vcxproj included) as `PY3_DLLNAME=L"$(Py3DllName)"`
        // -- the stable-ABI forwarder DLL name Python/dynload_win.c looks for
        // at runtime so it doesn't mistake it for a real Python DLL.
        "-DPY3_DLLNAME=L\"python3.dll\"",
        // posixmodule.c compares a `DWORD` (32-bit) against `PY_SSIZE_T_MAX`
        // (64-bit on this target): always-true, but intentionally so (an
        // overflow guard that degrades to a no-op on narrower `DWORD`
        // platforms) -- not a real bug.
        "-Wno-error=tautological-constant-out-of-range-compare",
        // posixmodule.c has a couple of `label: int x;`-shaped declarations
        // immediately after a `case`/goto label -- valid C23, and long-accepted
        // as a GNU extension on earlier standards; only an error under Clang's
        // strict pre-C23 pedantic mode.
        "-Wno-error=c23-extensions",
        // The next four are all real, benign warnings under Clang (verified
        // against plain `zig cc`, independent of anything this build adds)
        // that MSVC simply never flags at all: CPython's Windows sources were
        // only ever compiled by MSVC, so nothing here forced these to be
        // written the stricter way. None of them are silencing a mingw-only
        // problem -- they're generic C laxness MSVC doesn't enforce.
        "-Wno-error=inconsistent-dllimport", // posixmodule.c's plain `extern char **environ;` vs mingw's dllimport-attributed one
        // `-Wno-error=` alone doesn't downgrade this one back to a warning in
        // dynload_win.c's real header-inclusion context (unclear why --
        // possibly a stricter re-declaration reached through <windows.h>'s
        // own headers -- verified `-Wno-pointer-sign` outright does), so
        // disable the warning itself rather than just its error-promotion.
        "-Wno-pointer-sign", // dynload_win.c's `unsigned char *import_name` passed to str*() (const char *)
        "-Wno-error=incompatible-pointer-types-discards-qualifiers", // posixmodule.c: wchar_t** where PathCchSkipRoot wants a const-qualified PCWSTR*
        "-Wno-error=implicit-function-declaration", // posixmodule.c's bare getpid() -- mingw provides it, just not declared in scope here
        b.fmt("-I{s}", .{b.pathJoin(&.{ cpython_dir_str, "Modules", "_hacl", "include" })}),
        b.fmt("-I{s}", .{b.pathJoin(&.{ cpython_dir_str, "Modules", "_hacl", "internal" })}),
        b.fmt("-I{s}", .{b.pathJoin(&.{ cpython_dir_str, "Python" })}),
    };
    const pc_dir = cpython_dir.path(b, "PC");

    // build/sourcepatch.zig's mingw_fixups: two narrow, MSVC-tolerated-but-
    // Clang-rejected lines in CPython's own Windows sources (see windows.md's
    // "Status" section for the full investigation of each). Applied to
    // build-time copies only -- the cpython submodule itself is untouched.
    const dynload_win_patched = Sourcepatch.applyNamed(b, gpa, cpython_dir_str, Sourcepatch.mingw_fixups, "Python/dynload_win.c", &.{});
    const winapi_patched = Sourcepatch.applyNamed(b, gpa, cpython_dir_str, Sourcepatch.mingw_fixups, "Modules/_winapi.c", &.{});

    const libpython_lib = Utils.addPythonLib(b, cpython_dir, target, optimize, options.strip, gpa, .{
        .name = b.fmt("python{s}", .{version}),
        .core_sources = win_core_sources.items,
        .core_cflags = &win_core_cflags,
        .extra_sources = &.{},
        .extra_flags = &win_core_cflags,
        // PathCch* (pathcch.lib on MSVC) ships from an API-set DLL, not a
        // conventionally-named one; mingw-w64 only provides its import lib
        // under that API-set name.
        .link_libs = "-lversion -lws2_32 -lapi-ms-win-core-path-l1-1-0 -lbcrypt",
        .frozen_headers = frozen_headers.items,
        .dynload_flags = &win_core_cflags,
        .dynload_source = dynload_win_patched,
        .deepfreeze_c = deepfreeze_c,
        .linkage = .dynamic,
        .primary_include = pc_dir,
    });
    const winapi_flags = std.mem.concat(gpa, []const u8, &.{
        &win_core_cflags,
        // The patched copy lives in a different directory than the original
        // (build/sourcepatch.zig writes it under a WriteFiles cache dir), so
        // its `#include "winreparse.h"` -- a sibling-file quote-include that
        // resolved fine in-place -- needs Modules/ added back explicitly.
        &[_][]const u8{b.fmt("-I{s}", .{b.pathJoin(&.{ cpython_dir_str, "Modules" })})},
    }) catch @panic("OOM");
    libpython_lib.root_module.addCSourceFile(.{ .file = winapi_patched, .flags = winapi_flags });

    const shim_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    shim_mod.addIncludePath(pc_dir);
    shim_mod.addIncludePath(cpython_dir);
    shim_mod.addIncludePath(cpython_dir.path(b, "Include"));
    shim_mod.addIncludePath(cpython_dir.path(b, "Include/internal"));
    // Patched (see mingw_fixups) to define `main` instead of `wmain`: this
    // Zig version's mingw-w64 integration unconditionally links its own
    // bundled ANSI crt2.o (expects `main`/`WinMain`) for a windows-gnu exe,
    // with no exposed way to request the wide-entry CRT variant instead.
    const python_c_patched = Sourcepatch.applyNamed(b, gpa, cpython_dir_str, Sourcepatch.mingw_fixups, "Programs/python.c", &.{});
    shim_mod.addCSourceFile(.{
        .file = python_c_patched,
        .flags = &.{ "-DPy_BUILD_CORE", "-D_CONSOLE" },
    });
    shim_mod.linkLibrary(libpython_lib);
    const final_exe = b.addExecutable(.{ .name = "python", .root_module = shim_mod, .linkage = options.libc_linkage });
    final_exe.subsystem = .console;

    // ---- install: exe + DLL next to each other (Windows DLL search order --
    // no RPATH/$ORIGIN equivalent), plus Lib/. No lib-dynload/sysconfigdata
    // step yet: no extension modules, and Windows' sysconfig doesn't read an
    // imported _sysconfigdata module in the first place (see windows.md).
    b.getInstallStep().dependOn(&b.addInstallArtifact(final_exe, .{}).step);
    b.getInstallStep().dependOn(&b.addInstallArtifact(libpython_lib, .{}).step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = cpython_dir.path(b, "Lib"),
        .install_dir = .prefix,
        .install_subdir = "Lib",
    }).step);
}

fn buildPosix(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options.BuildOptions, cpython: CpythonSource.Source) void {
    const gpa = b.allocator;
    const build_root = b.root.root_dir.path orelse @panic("expected absolute build root path");
    const cpython_dir_str = cpython.dir_str;
    const cpython_dir = cpython.dir;
    const prefix = b.pathJoin(&.{ build_root, "zig-out" });

    // sqlite3 static linking used not to work for a genuinely different CPU
    // architecture than the build machine's own (same-arch targets -- native,
    // or musl-on-glibc -- were unaffected): `./configure`'s uncached
    // `AC_CHECK_HEADER([sqlite3.h])` probe (see build/utils.zig's sqlite3
    // `LIBSQLITE3_CFLAGS=-I...` cache-var seed) failed to find the header under
    // real `--host` cross mode. Root cause: this pinned Zig fetches
    // dependencies into a project-local `zig-pkg/` (build/cpython_source.zig's
    // own doc comment), and a fetched dependency's `root_dir.path` comes back
    // relative to this project's own build root, not absolute -- but
    // `./configure` (and everything it spawns) runs from `cpython_dir` instead,
    // itself another such build-root-relative `zig-pkg/<hash>/` directory, so
    // the relative `-I` flag resolved against the wrong base entirely. Fixed by
    // joining it onto the real (absolute) build root before use -- see
    // build/utils.zig's own doc comment on that fix. Verified end to end for
    // `-Dtarget=aarch64-linux-gnu` (a genuine x86_64-host cross build, not just
    // same-arch): `_sqlite3.cpython-312-aarch64-linux-gnu.so` built, links no
    // `libsqlite3.so` (`readelf -d`), and a real `sqlite3.connect(':memory:')`
    // create/insert/select round-trip ran correctly under `qemu-aarch64-static`.
    //
    // openssl used to have the same restriction for an unrelated reason (the old
    // `allyourcodebase/openssl` package's build.zig unconditionally built
    // x86_64 inline-asm sources with no ARM/etc. equivalent) -- fixed by
    // vendoring OpenSSL from scratch with assembly optimizations off, which
    // is arch-agnostic by construction (see vendoring/openssl/build.zig).
    const cross_arch = target.result.cpu.arch != b.graph.host.result.cpu.arch;

    // Stage 1/2 below (freeze_module_exe, bootstrap_exe) are host-native tools,
    // same as buildWindows' own bootstrap stage -- but unlike buildWindows (which
    // never runs `./configure` for anything but the host, and derives its whole
    // `host_*` compile input set -- cflags, sources, link libs -- from that native
    // configure alone), the `runConfigure` call right after this one reconfigures
    // this checkout's *single* `cpython/Makefile`+`pyconfig.h` for `target`, and
    // stage 1/2 below were, until this block existed, compiled from *that* target
    // Makefile's sources/cflags while still targeting the host. For a genuinely
    // different CPU architecture than the host's this is doubly wrong, not just in
    // pyconfig.h's word-size macros (verified: `Include/pyport.h`'s own
    // self-consistency check, "LONG_BIT definition appears wrong for platform",
    // aborts compiling arm-linux-gnueabihf's stage 1 on an x86_64 host) but in the
    // *source list* too: `PY_HAVE_PERF_TRAMPOLINE` is undefined in an armv7
    // pyconfig.h (real, target-correct -- perf trampolines need an arch-specific
    // assembly file this project has no armv7 source for), yet a native pyconfig.h
    // swapped in by primary_include alone defines it (x86_64 has real trampoline
    // support) while `core_sources` still comes from the *target* Makefile, which
    // never lists `Python/asm_trampoline.o` for the same reason -- so
    // `perf_trampoline.c` compiles as if it needs `_Py_trampoline_func_start`/`_end`
    // and nothing supplies them: an "undefined symbol" link failure, not a compile
    // error, so the mismatch is silent until the very last step. Same-arch targets
    // (native, or musl-on-glibc) don't need any of this: `cpython/Makefile` and
    // `cpython/pyconfig.h` already describe the host correctly, self-consistently,
    // by construction.
    //
    // Fixed by fully mirroring buildWindows' own separation: configure the host
    // natively first (into the same shared `cpython/` -- see `native_pyconfig_dir`'s
    // own note on why `options.pyconfig_header` is cleared for this call only),
    // snapshot pyconfig.h for `primary_include` to shadow with (same reasoning as
    // buildWindows avoiding the mirror-image shadowing problem), and additionally
    // snapshot the Makefile text so `host_core_cflags`/`host_core_sources.items`/
    // `host_link_libs`/`host_dynload_flags`/`host_getpath_flags` below can be
    // derived from *it*, exactly the way buildWindows derives its own `host_*` set
    // -- instead of reusing `core_cflags`/`core_sources`/`link_libs`/`dynload_flags`/
    // `getpath_flags`, which stay target-derived for stage 3 below. `.Debug`
    // optimize, not `optimize`: stage 1/2 are always built `.Debug` (matching
    // buildWindows), regardless of what `-Doptimize=` the real target build asked
    // for, and `--with-pydebug` vs `--enable-optimizations` changes ABI-affecting
    // macros (`Py_DEBUG`, ...) that this snapshot has to match.
    var native_pyconfig_dir: ?std.Build.LazyPath = null;
    var host_makefile_text: ?[]const u8 = null;
    if (cross_arch) {
        // `options.pyconfig_header` (a caller-supplied override, e.g. smelt's own
        // `_resolve_pyconfig_header`) is *target*-shaped -- `runConfigure` copies it
        // over whatever `./configure` just produced, for *any* target it's given,
        // native included. Left as-is, this native pass would snapshot the same
        // target header all over again instead of a real native one. Clear it for
        // this call only: the native snapshot must be real `./configure` cross
        // detection run natively, never the caller's target override.
        var native_options = options;
        native_options.pyconfig_header = null;
        Utils.runConfigure(b, cpython_dir_str, prefix, b.graph.host, .Debug, native_options);

        const snapshot_dir = b.pathJoin(&.{ build_root, ".zig-cache", "byp-native-pyconfig" });
        std.Io.Dir.cwd().createDirPath(b.graph.io, snapshot_dir) catch |err|
            std.debug.panic("failed to create {s}: {t}", .{ snapshot_dir, err });
        const native_pyconfig_h_path = b.pathJoin(&.{ cpython_dir_str, "pyconfig.h" });
        const native_pyconfig_text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, native_pyconfig_h_path, gpa, .unlimited) catch |err|
            std.debug.panic("failed to read {s}: {t}", .{ native_pyconfig_h_path, err });
        std.Io.Dir.cwd().writeFile(b.graph.io, .{
            .sub_path = b.pathJoin(&.{ snapshot_dir, "pyconfig.h" }),
            .data = native_pyconfig_text,
        }) catch |err| std.debug.panic("failed to write {s}/pyconfig.h: {t}", .{ snapshot_dir, err });
        native_pyconfig_dir = .{ .cwd_relative = snapshot_dir };

        const native_makefile_path = b.pathJoin(&.{ cpython_dir_str, "Makefile" });
        host_makefile_text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, native_makefile_path, gpa, .unlimited) catch |err|
            std.debug.panic("failed to read {s}: {t}", .{ native_makefile_path, err });
    }

    Utils.runConfigure(b, cpython_dir_str, prefix, target, optimize, options);

    // `./configure` gets `pyconfig.h` wrong in two different, independent
    // ways this project has to correct (see build/pyconfig.zig for the
    // evidence behind each list, and build/utils.zig's runConfigure for the
    // two configure modes they correspond to):
    //  - a musl target on a glibc host is *not* run through `--host` cross
    //    mode at all (same CPU, so autoconf's own test binaries run fine) --
    //    which means every libc feature check answers for the host's glibc.
    //  - a different-CPU target *is*, and then every `AC_RUN_IFELSE` check
    //    falls back to a hardcoded guess instead of measuring anything.
    // Patch just the affected macros in whatever pyconfig.h is now on disk
    // (freshly autoconf-generated, or the caller's own `-Dpyconfig-header=`),
    // then let `-Dpyconfig-define=`/`-Dpyconfig-undef=` override any of it,
    // rather than requiring the caller to know CPython's internals well
    // enough to hand-patch a header themselves. Unconditional on every
    // `build()` call, regardless of whether `runConfigure` actually
    // reconfigured this time: cheap, and idempotent -- re-patching an
    // already-patched file converges to the same bytes.
    {
        var patches: std.ArrayList(Pyconfig.MacroPatch) = .empty;
        if (target.result.abi.isMusl())
            patches.appendSlice(gpa, Pyconfig.musl_fixups) catch @panic("OOM");
        if (cross_arch) {
            patches.appendSlice(gpa, Pyconfig.cross_fixups) catch @panic("OOM");
            Pyconfig.ArchProfile.of(target.result).appendPatches(gpa, &patches);
        }
        // Last, so a caller's explicit request beats this project's defaults
        // (applyPatches is last-wins on duplicate macro names).
        patches.appendSlice(gpa, options.pyconfig_macros) catch @panic("OOM");

        if (patches.items.len > 0) {
            const pyconfig_h_path = b.pathJoin(&.{ cpython_dir_str, "pyconfig.h" });
            const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, pyconfig_h_path, gpa, .unlimited) catch |err|
                std.debug.panic("failed to read {s}: {t} (did ./configure run?)", .{ pyconfig_h_path, err });
            const patched = Pyconfig.applyPatches(gpa, text, patches.items);
            std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = pyconfig_h_path, .data = patched }) catch |err|
                std.debug.panic("failed to write patched {s}: {t}", .{ pyconfig_h_path, err });
        }
    }

    // A step with nothing to depend on: `./configure` and the pyconfig.h patches above already
    // ran unconditionally, as plain Zig code, before this point is even reached --
    // regardless of which step ends up actually being requested (every `zig build
    // <anything>` call runs this whole function to build the step graph first). So
    // `zig build configure` needs no work of its own to schedule; it exists so a
    // caller can stop *here*, before any of the compile steps below get constructed
    // into the graph, for the cost of `./configure` alone (seconds) rather than a
    // real build (minutes) -- see `BuildOptions.pyconfig_header`'s docs for why a
    // caller (smelt) wants exactly that: a correctly target-detected pyconfig.h,
    // without paying for a full compile just to get one.
    _ = b.step("configure", "Runs ./configure (and the pyconfig.h patches above) only -- no compiling.");

    const makefile_path = b.pathJoin(&.{ cpython_dir_str, "Makefile" });
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, makefile_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t} (did ./configure run?)", .{ makefile_path, err });
    const mk: Makefile = .{ .text = text };

    const version = mk.get(gpa, "VERSION"); // e.g. "3.12"
    const ext_suffix = mk.get(gpa, "EXT_SUFFIX"); // e.g. ".cpython-312d-x86_64-linux-gnu.so"

    // `_sysconfigdata_<abiflags>_<platform>_<multiarch>.py`: the module
    // `sysconfig.get_config_vars()`/`get_paths()`/etc. `__import__` at
    // runtime (see build/sysconfigdata.zig). Derived here from the same
    // Makefile plus pyconfig.h, instead of shelling out to the built
    // interpreter, to keep this build's only external dependency Zig itself.
    const pyconfig_h_path = b.pathJoin(&.{ cpython_dir_str, "pyconfig.h" });
    const pyconfig_h_text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, pyconfig_h_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t}", .{ pyconfig_h_path, err });
    var posix_vars = Sysconfigdata.fromMakefile(gpa, mk);
    Sysconfigdata.mergeConfigH(&posix_vars, pyconfig_h_text);
    const sysconfigdata_name = Sysconfigdata.moduleName(gpa, mk.get(gpa, "ABIFLAGS"), mk.get(gpa, "MACHDEP"), mk.get(gpa, "MULTIARCH"));
    const sysconfigdata_file = b.addWriteFiles().add(
        b.fmt("{s}.py", .{sysconfigdata_name}),
        Sysconfigdata.render(gpa, posix_vars),
    );
    // `-Wno-error=date-time`: Zig hands clang `-Werror=date-time` for every optimize
    // mode but Debug, in the name of reproducible builds. CPython's
    // `Modules/getbuildinfo.c` expands `__DATE__`/`__TIME__` on purpose -- that is
    // exactly where `sys.version`'s build timestamp comes from -- so under any release
    // mode the core library fails to compile at all. Demote it back to a warning
    // rather than stripping the timestamp: a `python` that can't report when it was
    // built is a worse artifact than a non-bit-reproducible one.
    // `-DPLATFORM`/`-DABIFLAGS`/`-DMULTIARCH`: CPython's Makefile gives `Python/getplatform.c`
    // and `Python/sysmodule.c` their own compile recipes carrying just these defines
    // (see the `Python/getplatform.o:` and `Python/sysmodule.o:` rules). Compiling them
    // with the bulk `PY_CORE_CFLAGS` instead loses all three *silently*: `getplatform.c`
    // falls back to its own `#define PLATFORM "unknown"`, so `sys.platform` reads
    // `"unknown"` and every `sys.platform`-dispatching library (psutil, and much of
    // the stdlib) refuses to run; `sysmodule.c`'s `#ifdef ABIFLAGS`/`#ifdef MULTIARCH`
    // blocks just drop out, leaving `sys.abiflags` undefined and
    // `sys.implementation._multiarch` missing -- the latter is what
    // `sysconfig._get_sysconfigdata_name()` (see build/sysconfigdata.zig) uses to name
    // the module it imports, so a mismatch there reintroduces the same
    // `ModuleNotFoundError` this build otherwise fixes. Added to the shared flags rather
    // than given per-file recipes: no other core source reads any of the three macros
    // (verified by grep across `Python/`, `Modules/`, `Objects/` and the public headers),
    // so the bulk compile stays a single step.
    // `-Wno-unterminated-string-initialization`: CPython 3.13+'s deepfreeze.py
    // (see Sourcepatch.deepfreezePatch) emits each frozen code object's bytecode
    // as a plain C string literal sized to fit exactly, deliberately with no
    // room for a NUL terminator -- valid C (an array need not be
    // NUL-terminated if the initializer already fills it), but this pinned
    // Zig's Clang treats it as a hard error by default, suggesting the GNU
    // `nonstring` attribute CPython's own generated struct fields don't carry.
    // Demoted back to (a silenced) warning rather than patching every such
    // literal deepfreeze.py emits.
    const core_cflags = std.mem.concat(gpa, []const u8, &.{
        Makefile.tokens(gpa, mk.get(gpa, "PY_CORE_CFLAGS")),
        &[_][]const u8{
            "-Wno-error=date-time",
            "-Wno-unterminated-string-initialization",
            b.fmt("-DPLATFORM=\"{s}\"", .{mk.get(gpa, "MACHDEP")}),
            b.fmt("-DABIFLAGS=\"{s}\"", .{mk.get(gpa, "ABIFLAGS")}),
            b.fmt("-DMULTIARCH=\"{s}\"", .{mk.get(gpa, "MULTIARCH")}),
        },
    }) catch @panic("OOM");
    const all_core_sources = Utils.fixupSourceExtensions(b, cpython_dir_str, Makefile.objsToSources(gpa, mk.get(gpa, "LIBRARY_OBJS_OMIT_FROZEN")));
    const link_libs = std.mem.concat(gpa, u8, &.{
        mk.get(gpa, "LIBS"), " ", mk.get(gpa, "MODLIBS"), " ", mk.get(gpa, "SYSLIBS"),
    }) catch @panic("OOM");

    // Python/dynload_shlib.c needs -DSOABI, which (unlike most core sources)
    // isn't part of the common PY_CORE_CFLAGS -- pull its real recipe instead
    // of bulk-compiling it with the wrong flags.
    const dynload_src = "Python/dynload_shlib.c";
    var core_sources: std.ArrayList([]const u8) = .empty;
    for (all_core_sources) |s| {
        if (!std.mem.eql(u8, s, dynload_src)) core_sources.append(gpa, s) catch @panic("OOM");
    }
    const dynload_flags = std.mem.concat(gpa, []const u8, &.{
        core_cflags,
        &[_][]const u8{b.fmt("-DSOABI=\"{s}\"", .{mk.get(gpa, "SOABI")})},
    }) catch @panic("OOM");

    // `-Dstatic-modules=...` (see build/options.zig): confirm each requested name
    // actually has a build rule *before* generating the `Modules/config.c` patch --
    // a `PyInit_<name>` extern declared there with nothing compiled to define it is
    // a link error, not a graceful skip, so the module list going into that patch
    // must already be pruned to what `Utils.addBuiltinModule` will actually add below.
    var confirmed_static_modules: std.ArrayList([]const u8) = .empty;
    for (options.static_modules) |name| {
        if (mk.findSharedModuleRule(gpa, name) != null) {
            confirmed_static_modules.append(gpa, name) catch @panic("OOM");
        } else {
            std.debug.print("warning: no build rule found for module '{s}' (static-modules), skipping\n", .{name});
        }
    }
    // Only meaningful for `python-linkage=off` (see options.zig's `static_modules`
    // doc comment): that's the only shape where the final exe's own compilation unit
    // has the core Python symbols these modules' `PyInit_*` functions need.
    const use_static_modules = confirmed_static_modules.items.len > 0 and options.python_linkage == null;

    // `Modules/config.c` (CPython's own generated builtin-module table -- produced
    // by `./configure` alone, not `make`/`makesetup`) is normally part of
    // `core_sources` verbatim; when using static modules, patch in their
    // `PyInit_*` externs/inittab entries and compile *that* copy instead, for the
    // final exe only (freeze_module_exe/bootstrap_exe below are internal build
    // tools -- the unpatched original is exactly right for them).
    const config_c_src = "Modules/config.c";
    var final_core_sources: std.ArrayList([]const u8) = .empty;
    const patched_config_c: std.Build.LazyPath = if (use_static_modules) blk: {
        for (all_core_sources) |s| {
            if (!std.mem.eql(u8, s, config_c_src) and !std.mem.eql(u8, s, dynload_src))
                final_core_sources.append(gpa, s) catch @panic("OOM");
        }
        break :blk Utils.patchBuiltinModulesConfig(
            b,
            gpa,
            b.pathJoin(&.{ cpython_dir_str, config_c_src }),
            confirmed_static_modules.items,
        );
    } else undefined;

    // getpath.c is compiled with a blank install prefix everywhere (bootstrap
    // *and* final exe): it makes sys.path discovery relative to argv[0]
    // instead of an absolute path baked in at build time. That's what lets
    // the bootstrap interpreter below run straight out of the build cache
    // (see Utils.packageExe), and it's a step toward this project's
    // relocatability goal (see research.md) rather than a bootstrap-only hack.
    const getpath_defines = [_][]const u8{
        "-DPREFIX=\"\"",
        "-DEXEC_PREFIX=\"\"",
        b.fmt("-DVERSION=\"{s}\"", .{version}),
        "-DPLATLIBDIR=\"lib\"",
        "-DVPATH=\"\"",
    };
    const getpath_flags = std.mem.concat(gpa, []const u8, &.{ core_cflags, &getpath_defines }) catch @panic("OOM");

    // Stage 1/2's own compile inputs -- see `native_pyconfig_dir`'s note above for
    // why these have to be *host*-derived rather than reusing `core_cflags`/
    // `core_sources`/`link_libs`/`dynload_flags`/`getpath_flags` above (target-
    // derived, correct for stage 3 below). Mirrors buildWindows' own `host_core_cflags`/
    // `host_all_core_sources`/`host_link_libs`/`host_dynload_flags`/`host_getpath_flags`
    // derivation exactly, just from the native Makefile snapshotted alongside
    // `native_pyconfig_dir` instead of buildWindows' always-native one. `host_makefile_text`
    // is only set when `cross_arch` (see above) -- same-arch targets reuse the target
    // variables outright, since target and host already agree.
    var host_core_cflags = core_cflags;
    var host_core_sources: std.ArrayList([]const u8) = .empty;
    host_core_sources.appendSlice(gpa, core_sources.items) catch @panic("OOM");
    var host_link_libs = link_libs;
    var host_dynload_flags = dynload_flags;
    var host_getpath_flags = getpath_flags;
    if (host_makefile_text) |host_text| {
        const host_mk: Makefile = .{ .text = host_text };
        host_core_cflags = std.mem.concat(gpa, []const u8, &.{
            Makefile.tokens(gpa, host_mk.get(gpa, "PY_CORE_CFLAGS")),
            &[_][]const u8{"-Wno-error=date-time"},
        }) catch @panic("OOM");
        const host_all_core_sources = Utils.fixupSourceExtensions(
            b,
            cpython_dir_str,
            Makefile.objsToSources(gpa, host_mk.get(gpa, "LIBRARY_OBJS_OMIT_FROZEN")),
        );
        host_core_sources = .empty;
        for (host_all_core_sources) |s| {
            if (!std.mem.eql(u8, s, dynload_src)) host_core_sources.append(gpa, s) catch @panic("OOM");
        }
        host_link_libs = std.mem.concat(gpa, u8, &.{
            host_mk.get(gpa, "LIBS"), " ", host_mk.get(gpa, "MODLIBS"), " ", host_mk.get(gpa, "SYSLIBS"),
        }) catch @panic("OOM");
        host_dynload_flags = std.mem.concat(gpa, []const u8, &.{
            host_core_cflags,
            &[_][]const u8{b.fmt("-DSOABI=\"{s}\"", .{host_mk.get(gpa, "SOABI")})},
        }) catch @panic("OOM");
        host_getpath_flags = std.mem.concat(gpa, []const u8, &.{ host_core_cflags, &getpath_defines }) catch @panic("OOM");
    }

    const freeze_entries = mk.freezeEntries(gpa);

    // ---- stage 1: freeze_module (a compiled tool, not a real interpreter)
    // A minimal C program that embeds the CPython interpreter but only enough
    // to run Programs/_freeze_module.c's frozen-module compilation logic. Used
    // to freeze the first 4 bootstrap modules (importlib._bootstrap, etc.) whose
    // headers are required to compile stage 2. Uses getpath_noop.c (a stub) since
    // it doesn't need to discover sys.path -- it just freezes files passed as args.
    const freeze_module_exe = Utils.addExe(b, cpython_dir, b.graph.host, .Debug, false, gpa, .{
        .name = "freeze_module",
        .core_sources = host_core_sources.items,
        .core_cflags = host_core_cflags,
        .extra_sources = &.{ "Programs/_freeze_module.c", "Modules/getpath_noop.c" },
        .extra_flags = host_core_cflags,
        .link_libs = host_link_libs,
        .frozen_headers = &.{},
        .dynload_flags = host_dynload_flags,
        .dynload_source = cpython_dir.path(b, "Python/dynload_shlib.c"),
        .linkage = options.libc_linkage,
        .primary_include = native_pyconfig_dir,
    });

    var early_headers = std.StringHashMap(std.Build.LazyPath).init(gpa);
    var early_headers_list: std.ArrayList(std.Build.LazyPath) = .empty;
    for (freeze_entries) |f| {
        if (!f.bootstrap) continue;
        const run = b.addRunArtifact(freeze_module_exe);
        run.addArg(f.name);
        run.addFileArg(cpython_dir.path(b, f.src));
        const out = run.addOutputFileArg(f.out);
        early_headers.put(f.name, out) catch @panic("OOM");
        early_headers_list.append(gpa, out) catch @panic("OOM");
    }

    // ---- stage 2: _bootstrap_python (a real interpreter, not just a tool)
    // Has the 4 bootstrap frozen modules baked in and uses real getpath.c
    // (discovers Lib/ relative to argv[0]). Packaged together with Lib/ so it can
    // run pure-Python build scripts like Programs/_freeze_module.py (which freezes
    // the remaining ~20 stdlib modules). Not exposed to end users; only exists to
    // bootstrap stage 3.
    const bootstrap_exe = Utils.addExe(b, cpython_dir, b.graph.host, .Debug, false, gpa, .{
        .name = "_bootstrap_python",
        .core_sources = host_core_sources.items,
        .core_cflags = host_core_cflags,
        .extra_sources = &.{ "Programs/_bootstrap_python.c", "Modules/getpath.c" },
        .extra_flags = host_getpath_flags,
        .link_libs = host_link_libs,
        .frozen_headers = early_headers_list.items,
        .dynload_flags = host_dynload_flags,
        .dynload_source = cpython_dir.path(b, "Python/dynload_shlib.c"),
        .linkage = options.libc_linkage,
        .primary_include = native_pyconfig_dir,
    });

    // _bootstrap_python needs Lib/ sitting next to it (in the layout getpath.c's
    // relative landmark search expects) before it can run any Python at all.
    const bootstrap_packaged_exe = Utils.packageExe(b, cpython_dir, version, bootstrap_exe);

    var frozen_headers: std.ArrayList(std.Build.LazyPath) = .empty;
    var deepfreeze_headers: std.ArrayList(std.Build.LazyPath) = .empty;
    var deepfreeze_names: std.ArrayList([]const u8) = .empty;

    // The remaining (non-bootstrap) frozen modules are frozen by running the
    // *packaged* bootstrap interpreter directly on Programs/_freeze_module.py
    // (a pure-Python re-implementation), exactly as the real Makefile does.
    for (freeze_entries) |f| {
        const out = if (f.bootstrap) early_headers.get(f.name).? else blk: {
            const run = std.Build.Step.Run.create(b, b.fmt("freeze {s}", .{f.name}));
            run.addFileArg(bootstrap_packaged_exe);
            run.addFileArg(cpython_dir.path(b, "Programs/_freeze_module.py"));
            run.addArg(f.name);
            run.addFileArg(cpython_dir.path(b, f.src));
            break :blk run.addOutputFileArg(f.out);
        };
        frozen_headers.append(gpa, out) catch @panic("OOM");
        if (!std.mem.eql(u8, f.name, "getpath")) {
            deepfreeze_headers.append(gpa, out) catch @panic("OOM");
            deepfreeze_names.append(gpa, f.name) catch @panic("OOM");
        }
    }

    const deepfreeze_script = Sourcepatch.applyIfPresent(
        b,
        gpa,
        cpython_dir_str,
        Sourcepatch.deepfreezePatch(b, gpa, cpython_dir_str),
        Sourcepatch.deepfreezeSiblings(gpa, cpython_dir_str),
    );
    const deepfreeze_c = Utils.addDeepfreeze(b, deepfreeze_script, bootstrap_packaged_exe, deepfreeze_headers.items, deepfreeze_names.items);

    // ---- stage 3: the final "python" executable (the one users run).
    // Built with the target optimization level (not Debug like stages 1-2).
    // Includes all ~24 frozen modules (4 bootstrap + 20 regular), deepfroze stdlib
    // bytecode, and core interpreter. Extension modules are NOT linked in statically
    // -- they're built as standalone .so files below and dlopen()'d at import time,
    // same as CPython normally does. This enables dynamic linking and relocatability.
    //
    // `python-linkage` picks between two shapes for this stage:
    //   off (default): one monolithic executable, as above -- extension .so's
    //     resolve Python C-API symbols against it via `-rdynamic`.
    //   static/dynamic: the core interpreter is split into a standalone
    //     libpythonX.Y (an archive or a real .so) plus a thin shim exe that's
    //     just Programs/python.c linked against it, matching upstream
    //     CPython's own `--enable-shared` layout. "dynamic" is the one that
    //     matters: extension modules then link against the real libpythonX.Y.so
    //     the ordinary way instead of depending on `-rdynamic` -- which is what
    //     actually lets dlopen()'d extensions work under `libc-linkage=static`
    //     (see build/options.zig's python_linkage doc comment for why).
    const final_exe, const libpython_lib = if (options.python_linkage) |python_linkage| blk: {
        const lib = Utils.addPythonLib(b, cpython_dir, target, optimize, options.strip, gpa, .{
            .name = b.fmt("python{s}", .{version}),
            .core_sources = core_sources.items,
            .core_cflags = core_cflags,
            .extra_sources = &.{ "Modules/getpath.c", "Python/frozen.c" },
            .extra_flags = getpath_flags,
            .link_libs = link_libs,
            .frozen_headers = frozen_headers.items,
            .dynload_flags = dynload_flags,
            .dynload_source = cpython_dir.path(b, "Python/dynload_shlib.c"),
            .deepfreeze_c = deepfreeze_c,
            .linkage = python_linkage,
        });

        const shim_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        shim_mod.addIncludePath(cpython_dir);
        shim_mod.addIncludePath(cpython_dir.path(b, "Include"));
        shim_mod.addIncludePath(cpython_dir.path(b, "Include/internal"));
        shim_mod.addCSourceFile(.{
            .file = cpython_dir.path(b, "Programs/python.c"),
            .flags = Utils.extractIncludePaths(shim_mod, b, cpython_dir, gpa, core_cflags),
        });
        shim_mod.linkLibrary(lib);

        const exe = b.addExecutable(.{ .name = "python", .root_module = shim_mod, .linkage = options.libc_linkage });
        if (python_linkage == .dynamic) {
            // Real .so: extensions and the shim resolve against it via an
            // ordinary dependency, not `-rdynamic`. See addSharedModule's
            // matching addRPathSpecial for why the extra absolute rpath Zig
            // also emits here is harmless.
            shim_mod.addRPathSpecial("$ORIGIN/../lib");
        } else {
            // Static: the archive still ends up fully absorbed into this
            // one exe at link time -- functionally the same monolithic
            // blob as `off`, so extensions still need `-rdynamic` to reach it.
            exe.rdynamic = true;
        }
        break :blk .{ exe, @as(?*std.Build.Step.Compile, lib) };
    } else blk: {
        const exe = Utils.addExe(b, cpython_dir, target, optimize, options.strip, gpa, .{
            .name = "python",
            .core_sources = if (use_static_modules) final_core_sources.items else core_sources.items,
            .core_cflags = core_cflags,
            .extra_sources = &.{ "Programs/python.c", "Modules/getpath.c", "Python/frozen.c" },
            .extra_flags = getpath_flags,
            .link_libs = link_libs,
            .frozen_headers = frozen_headers.items,
            .dynload_flags = dynload_flags,
            .dynload_source = cpython_dir.path(b, "Python/dynload_shlib.c"),
            .linkage = options.libc_linkage,
        });
        exe.root_module.addCSourceFile(.{ .file = deepfreeze_c, .flags = core_cflags });
        // Patched `Modules/config.c` (extra `PyInit_*`/inittab entries for
        // `-Dstatic-modules=...`) in place of the one `core_sources` would
        // otherwise carry -- see the `use_static_modules` block above.
        if (use_static_modules) {
            exe.root_module.addCSourceFile(.{ .file = patched_config_c, .flags = core_cflags });
        }
        exe.rdynamic = true; // -export-dynamic: extension .so's resolve Python C API symbols against us
        // `exe.pie = true` was originally set here on the hypothesis that musl's
        // static-linked-program `dlopen()` failure ("Dynamic loading not supported",
        // musl's own `dlerror()` text -- confirmed absent from CPython's own source
        // entirely, so it's musl's libc talking, not ours) was a self-relocation
        // problem plain static/ET_EXEC couldn't solve but static-PIE could. Confirmed
        // false by direct investigation: Zig's bundled musl port never ships musl's
        // real ELF loader (`ldso/dynlink.c`) in its static `libc.a` at all --
        // `ldso/dlopen.c` there is a ~5-line stub that unconditionally calls
        // `__dl_seterr("Dynamic loading not supported")`, regardless of ET_EXEC vs.
        // ET_DYN/PIE-ness. A standalone `dlopen()` repro (no CPython involved) hits
        // the identical stub under `-static`, `-static-pie`, and Zig's own
        // link-mode-unspecified default alike -- `-static-pie` isn't even honored by
        // `zig cc`'s driver as a distinct linkage ("argument unused during
        // compilation"). `libc-linkage=static` therefore can never support `dlopen()`
        // of a loose `.so`, under any PIE setting: every native module needs to be
        // either compiled straight in (`-Dstatic-modules=`) or, from the caller's
        // side, inittab-linked. `exe.pie = true` is kept regardless -- still harmless,
        // and still what a caller relinking against `libpythonX.Y.a` needs to match
        // (see build.zig's `off`-branch archive below) -- just no longer believed to
        // fix dlopen. Keeping `dlopen()` means `libc-linkage=dynamic` instead, which
        // for a musl target needs a musl runtime to exist on the target machine --
        // built from musl's own sources and installed into the prefix by
        // build/musl.zig.
        exe.pie = true;

        // `final_exe` above is self-contained and never needs this -- it's built
        // fresh here, straight from source, every time. It exists purely so a
        // downstream caller (smelt's own inittab relink, see roadmap.md's "Known
        // gaps" #5) can link *additional* object files (its own compiled
        // extensions) against the same core Python symbols this exe just got,
        // instead of only being able to do that against a real libpythonX.Y.so --
        // which `python-linkage=off` never produces. Same translation units as
        // `final_exe` (core sources, deepfreeze, the patched inittab when
        // `use_static_modules`), minus `Programs/python.c`'s `main()`, packaged as
        // an archive instead of linked straight into one binary.
        const archive = Utils.addPythonLib(b, cpython_dir, target, optimize, options.strip, gpa, .{
            .name = b.fmt("python{s}", .{version}),
            .core_sources = if (use_static_modules) final_core_sources.items else core_sources.items,
            .core_cflags = core_cflags,
            .extra_sources = &.{ "Modules/getpath.c", "Python/frozen.c" },
            .extra_flags = getpath_flags,
            .link_libs = link_libs,
            .frozen_headers = frozen_headers.items,
            .dynload_flags = dynload_flags,
            .dynload_source = cpython_dir.path(b, "Python/dynload_shlib.c"),
            .deepfreeze_c = deepfreeze_c,
            .linkage = .static,
        });
        if (use_static_modules) {
            archive.root_module.addCSourceFile(.{ .file = patched_config_c, .flags = core_cflags });
        }
        // Whatever links this archive back in (smelt's relink step) produces
        // another static-PIE exe the same way `final_exe` does -- needs the same
        // PIC object code `final_exe`'s own compile units get from `exe.pie`.
        // Zig's default PIC-ness for a plain static-library compile step is
        // target-dependent (PIC-by-default for `*-linux-gnu`, not for
        // `*-linux-musl` -- see the `zlib_linkage == .static` comment below for the
        // same gotcha hit the same way), so this is requested explicitly rather
        // than relying on the default; harmless where the default already agrees.
        archive.root_module.pic = true;
        break :blk .{ exe, @as(?*std.Build.Step.Compile, archive) };
    };
    // Only a real libpythonX.Y.so (not the .a, and not "off") gives extension
    // modules something to link against instead of `-rdynamic`.
    const dynamic_python_lib: ?*std.Build.Step.Compile = if (options.python_linkage == .dynamic) libpython_lib else null;

    // ---- optional extension modules, one shared object each, dynamically linked.
    const common_module_cflags = Makefile.tokens(
        gpa,
        std.mem.concat(gpa, u8, &.{ mk.get(gpa, "PY_STDMODULE_CFLAGS"), " ", mk.get(gpa, "CCSHARED") }) catch @panic("OOM"),
    );
    const shared_names = Makefile.tokens(gpa, mk.get(gpa, "MODSHARED_NAMES"));

    // Third-party libs requested as `static`: built from source via their
    // allyourcodebase Zig package and baked into the extension module that
    // needs them, instead of dynamically linking the host's system `.so`.
    var static_overrides: std.ArrayList(Utils.StaticOverride) = .empty;
    if (options.zlib_linkage == .static) {
        // `pie` (really: PIC) explicitly requested -- needed because this static
        // archive gets baked into *shared* extension modules (`static_overrides`
        // below), and Zig's default PIC-ness for a plain static-library compile step
        // is target-dependent: it works out (PIC-by-default) for `*-linux-gnu`, but
        // not for `*-linux-musl`, where the resulting object code fails to link into
        // a `.so` at all ("relocation R_X86_64_64 cannot be used against local
        // symbol; recompile with -fPIC") -- verified empirically building for
        // x86_64-linux-musl. Requesting PIC unconditionally is a no-op for targets
        // that already default to it.
        const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize, .pie = true });
        static_overrides.append(gpa, .{ .lib_name = "z", .artifact = zlib_dep.artifact("z") }) catch @panic("OOM");
    }
    if (options.openssl_linkage == .static) {
        const openssl_dep = b.dependency("openssl", .{ .target = target, .optimize = optimize });
        const openssl_lib = openssl_dep.artifact("openssl");
        // PIC, for the same reason as zlib and libffi: `_ssl` and `_hashlib` are shared
        // modules, and a non-PIC archive cannot be linked into one.
        openssl_lib.root_module.pic = true;
        static_overrides.append(gpa, .{ .lib_name = "ssl", .artifact = openssl_lib }) catch @panic("OOM");
        static_overrides.append(gpa, .{ .lib_name = "crypto", .artifact = openssl_lib }) catch @panic("OOM");
    }
    if (options.libffi_linkage == .static) {
        const libffi_dep = b.dependency("libffi", .{ .target = target, .optimize = optimize });
        const libffi_lib = libffi_dep.artifact("ffi");
        // Same requirement as zlib's `.pie = true` above, asked for differently because
        // this package exposes no option for it: `_ctypes` is a *shared* module, and a
        // static archive built without PIC cannot be linked into one -- lld rejects it
        // with "relocation R_X86_64_64 cannot be used against local symbol; recompile
        // with -fPIC", once per relocation, which is what `_ctypes`' several hundred
        // errors on a musl target actually are. Setting it on the dependency's own
        // module reaches inside that package, which is not lovely, but the alternative
        // is shipping no `ctypes` at all.
        libffi_lib.root_module.pic = true;
        static_overrides.append(gpa, .{ .lib_name = "ffi", .artifact = libffi_lib }) catch @panic("OOM");
    }
    if (options.sqlite_linkage == .static) {
        const sqlite3_dep = b.dependency("sqlite3", .{ .target = target, .optimize = optimize });
        const sqlite3_lib = sqlite3_dep.artifact("sqlite3");
        // Same PIC requirement as libffi/openssl above: `_sqlite3` is a shared
        // module, and this package's own build.zig sets no PIC option of its own.
        sqlite3_lib.root_module.pic = true;
        static_overrides.append(gpa, .{ .lib_name = "sqlite3", .artifact = sqlite3_lib }) catch @panic("OOM");
    }
    if (options.bz2_linkage == .static) {
        const bz2_dep = b.dependency("bzip2", .{ .target = target, .optimize = optimize });
        const bz2_lib = bz2_dep.artifact("bz"); // package's own artifact name, not "bz2"
        // Same PIC requirement as libffi/openssl/sqlite3 above.
        bz2_lib.root_module.pic = true;
        static_overrides.append(gpa, .{ .lib_name = "bz2", .artifact = bz2_lib }) catch @panic("OOM");
    }
    if (options.lzma_linkage == .static) {
        const lzma_dep = b.dependency("lzma", .{ .target = target, .optimize = optimize });
        const lzma_lib = lzma_dep.artifact("lzma");
        // Same PIC requirement as the other static overrides above.
        lzma_lib.root_module.pic = true;
        static_overrides.append(gpa, .{ .lib_name = "lzma", .artifact = lzma_lib }) catch @panic("OOM");
    }

    var shared_libs: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for (shared_names) |name| {
        if (Utils.skip_modules.has(name)) continue;
        if (Options.isModuleDisabled(options, name)) {
            std.debug.print("skipping module '{s}': dependency linkage is off, or explicitly disabled\n", .{name});
            continue;
        }
        if (use_static_modules and Options.isModuleForcedStatic(options, name)) {
            // Compiled straight into `final_exe` above (`patched_config_c` already
            // declares/registers it) instead of as a separate shared module --
            // `confirmed_static_modules` already guarantees a build rule exists, so
            // this shouldn't fail, but a `false` here would mean a dangling extern
            // with nothing defining it, so surface it loudly rather than silently
            // producing a broken link.
            if (!Utils.addBuiltinModule(b, cpython_dir, mk, gpa, final_exe.root_module, common_module_cflags, name, static_overrides.items))
                std.debug.panic("static module '{s}' passed the pre-check but addBuiltinModule failed", .{name});
            continue;
        }
        const lib = Utils.addSharedModule(b, cpython_dir, mk, gpa, target, optimize, options.strip, common_module_cflags, name, static_overrides.items, dynamic_python_lib) orelse continue;
        shared_libs.append(gpa, lib) catch @panic("OOM");
    }

    // ---- install.
    const lib_dir = b.fmt("lib/python{s}", .{version});
    b.getInstallStep().dependOn(&b.addInstallArtifact(final_exe, .{}).step);
    if (libpython_lib) |lib| b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = cpython_dir.path(b, "Lib"),
        .install_dir = .prefix,
        .install_subdir = lib_dir,
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        sysconfigdata_file,
        .prefix,
        b.fmt("{s}/{s}.py", .{ lib_dir, sysconfigdata_name }),
    ).step);
    for (shared_libs.items) |lib| {
        const dest = b.fmt("{s}/lib-dynload/{s}{s}", .{ lib_dir, lib.name, ext_suffix });
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(lib.getEmittedBin(), .prefix, dest).step);
    }

    // A musl interpreter linked against libc dynamically has nowhere to get a libc
    // from: Zig links musl but cannot provide its runtime (see build/musl.zig), and
    // the target machine is not assumed to have musl installed -- that assumption is
    // the whole reason to target musl in the first place. So the loader is built from
    // musl's own sources and installed next to `libpythonX.Y.so`; the interpreter is
    // only runnable through it. Built for a static-libc build too would be pointless:
    // there is no dynamic section to satisfy.
    if (options.libc_linkage == .dynamic) {
        if (Musl.addLoader(b, target, options.strip)) |loader| {
            const install = b.addInstallFileWithDir(loader.lib.getEmittedBin(), .lib, loader.install_name);
            b.getInstallStep().dependOn(&install.step);
            // Also reachable on its own: the loader is what a consumer needs to ship,
            // and it is independent of everything else here.
            b.step(
                "musl-loader",
                "Builds musl's ld-musl-<arch>.so.1 (loader + libc) for the musl target only.",
            ).dependOn(&install.step);
        }
    }
}
