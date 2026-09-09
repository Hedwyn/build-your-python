//! Builds musl's real `ld-musl-<arch>.so.1` -- ELF loader and libc in one file --
//! from musl's own sources, for a `*-linux-musl` target.
//!
//! Why this is here at all: Zig *links* musl dynamically fine, but it cannot supply
//! the runtime that linkage needs. Zig's bundled musl is stripped down to the parts
//! Zig does not implement itself (no `src/malloc`, most of `src/string` and
//! `src/math` missing -- a static musl binary gets those from Zig's own `c` and
//! `compiler_rt` modules) and, decisively, it has no `ldso/dynlink.c`: the loader.
//! What it ships as `libc.so` is a generated stub (`libc.S`, every symbol at one
//! dummy address) that exists to satisfy the linker and nothing else. Zig's model
//! is "the target machine has musl installed" -- fine for Alpine, useless for a
//! self-contained distribution, which has to carry its own copy.
//!
//! So: a `libc-linkage=dynamic` musl interpreter is only runnable next to the file
//! this module produces, and `install` puts it in the prefix's `lib/` for that
//! reason. Consumers that assemble a distribution out of the prefix (see smelt)
//! ship it alongside `libpythonX.Y.so` and start the interpreter through it.
//!
//! The alternative -- `libc-linkage=static`, no loader needed -- cannot `dlopen()`
//! anything at all with Zig's musl (see options.zig's `libc_linkage`), so it cannot
//! load extension modules that are not compiled into the interpreter.
//!
//! The sources are a pinned musl release declared in `build.zig.zon`, fetched by
//! Zig's package manager the first time a musl target is built (and only then -- the
//! dependency is lazy). The build mirrors musl's own Makefile rather than driving it:
//! same source selection (per-architecture files override their generic namesakes),
//! same compile flags, same `-shared -e _dlstart` link, but expressed as Zig build
//! steps, so it cross-compiles from any host with no `make`, `sed` or shell involved.

const std = @import("std");

pub const Loader = struct {
    lib: *std.Build.Step.Compile,
    /// The filename the loader has to be installed as: the basename of the
    /// `PT_INTERP` path Zig bakes into every dynamically-musl-linked binary it
    /// produces (e.g. `ld-musl-x86_64.so.1`). Taken from the resolved target rather
    /// than composed from an architecture table here, so the two cannot disagree.
    install_name: []const u8,
};

/// Compile musl's loader for `target`, or null when `target` is not a musl target
/// (nothing to build: a glibc target's loader belongs to the target machine) or the
/// musl source package has not been fetched yet (`lazyDependency`, see build.zig.zon
/// -- the build re-runs itself once Zig has fetched it).
pub fn addLoader(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    strip: ?bool,
) ?Loader {
    if (!target.result.abi.isMusl()) return null;
    const dep = b.lazyDependency("musl", .{}) orelse return null;
    const gpa = b.allocator;

    const arch = muslArch(target.result);
    const src_root = dep.builder.root.root_dir.path orelse
        @panic("expected an absolute path for the musl dependency");

    // musl's three generated headers. Its Makefile produces them with `sed` and
    // `printf`; the same transformations are done here in Zig, so the build needs no
    // POSIX tools (and works from a Windows host).
    const gen_include = b.addWriteFiles();
    _ = gen_include.add("bits/alltypes.h", allTypesHeader(b, src_root, arch));
    _ = gen_include.add("bits/syscall.h", syscallHeader(b, src_root, arch));
    const gen_internal = b.addWriteFiles();
    _ = gen_internal.add("version.h", b.fmt(
        "#define VERSION \"{s}\"\n",
        .{std.mem.trim(u8, readSource(b, src_root, "VERSION"), " \t\r\n")},
    ));

    // The compiler-runtime helpers musl takes from libgcc when a distribution builds
    // it (complex multiplication everywhere, soft-float long double where the
    // architecture has no hardware one). Zig's `compiler_rt` provides them, and its
    // sources ship with the compiler itself, next to the `zig` executable -- but it
    // has to be compiled *into this library* rather than linked in prebuilt. See
    // build/tools/musl_root.zig, which is what forces that.
    const zig_install_dir = std.fs.path.dirname(b.graph.zig_exe) orelse
        @panic("expected an absolute path for the zig executable");
    const compiler_rt = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ zig_install_dir, "lib", "compiler_rt.zig" }) },
        .target = target,
        .optimize = .ReleaseFast,
        .strip = strip,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("build/tools/musl_root.zig"),
        .target = target,
        // Deliberately not the caller's optimize mode. musl builds itself at a fixed
        // optimization level whatever its consumer does (`-Os` in its own configure),
        // and an unoptimized build of it needs compiler-runtime helpers -- 128-bit
        // division, soft-float conversions -- that an optimized one folds away, i.e.
        // exactly the symbols this build has no libgcc to get from. A libc compiled
        // for debugging is not something a distribution wants to carry either.
        .optimize = .ReleaseFast,
        .strip = strip,
        // A libc cannot be instrumented by the sanitizer runtime it would itself have
        // to provide (`__ubsan_handle_*` would end up undefined at link time).
        .sanitize_c = .off,
        // musl *is* libc: it must not be compiled against one, and the shared object
        // must not pick up Zig's CRT files either.
        .link_libc = false,
        .pic = true,
        // musl disables the stack protector for a specific handful of files (the
        // ones running before TLS exists); off everywhere is simpler and costs
        // nothing measurable in a libc whose callers set their own policy.
        .stack_protector = false,
    });

    mod.addImport("compiler_rt", compiler_rt);

    // Include order is musl's own, and it matters: the per-architecture `bits/`
    // headers have to shadow the generic ones.
    mod.addIncludePath(dep.path(b.fmt("arch/{s}", .{arch})));
    mod.addIncludePath(dep.path("arch/generic"));
    mod.addIncludePath(gen_internal.getDirectory());
    mod.addIncludePath(dep.path("src/include"));
    mod.addIncludePath(dep.path("src/internal"));
    mod.addIncludePath(gen_include.getDirectory());
    mod.addIncludePath(dep.path("include"));

    mod.addCSourceFiles(.{
        .root = dep.path("."),
        .files = sourceFiles(b, src_root, arch),
        .flags = &.{
            // musl's CFLAGS_C99FSE plus the flags its configure settles on for a
            // clang-like compiler. `-nostdinc` is what keeps Zig's own musl headers
            // out of a build of musl itself.
            "-std=c99",
            "-ffreestanding",
            "-nostdinc",
            "-D_XOPEN_SOURCE=700",
            "-fno-strict-aliasing",
            "-fexcess-precision=standard",
            "-frounding-math",
            "-fno-stack-protector",
            "-fno-unwind-tables",
            "-fno-asynchronous-unwind-tables",
            "-ffunction-sections",
            "-fdata-sections",
            "-fomit-frame-pointer",
            "-Wa,--noexecstack",
            // musl compiles with warnings off by default (`-w`): it is C99-freestanding
            // code that a modern compiler has opinions about, and none of them are
            // actionable from here. The `-Werror=` set is musl's own, and catches the
            // mistakes that would otherwise produce a subtly broken libc.
            "-w",
            "-Wno-pointer-to-int-cast",
            "-Werror=implicit-function-declaration",
            "-Werror=implicit-int",
            "-Werror=pointer-sign",
            "-Werror=pointer-arith",
            "-Werror=int-conversion",
            "-Werror=incompatible-pointer-types",
            // Assembly inputs share these flags; without this every C-only flag
            // produces a warning per assembly file.
            "-Qunused-arguments",
        },
    });
    const lib = b.addLibrary(.{ .name = "c", .linkage = .dynamic, .root_module = mod });
    // musl's own link line: the loader's entry point is its self-relocation stub,
    // not a C `main`, and an undefined symbol in a libc is a build error rather than
    // something to discover at runtime.
    lib.entry = .{ .symbol_name = "_dlstart" };
    lib.link_z_defs = true;
    lib.link_gc_sections = true;

    const interp = target.result.dynamic_linker.get() orelse
        std.debug.panic("no dynamic linker path known for target {s}", .{
            target.result.zigTriple(gpa) catch @panic("OOM"),
        });
    // Duplicated on purpose: `interp` points into `target`'s own copy of the
    // dynamic-linker buffer, which is this function's stack frame -- the name is read
    // by the caller's install step long after that is gone.
    return .{ .lib = lib, .install_name = b.dupe(std.fs.path.basename(interp)) };
}

/// musl's `$(ARCH)`: the name of its `arch/<...>` source directory for `target`.
/// Panics on a target musl has no port for -- a build option error, caught here with
/// the target spelled out rather than as a missing-header failure later.
fn muslArch(target: std.Target) []const u8 {
    if (target.abi == .muslx32) return "x32";
    return switch (target.cpu.arch) {
        .x86_64 => "x86_64",
        .x86 => "i386",
        .aarch64, .aarch64_be => "aarch64",
        .arm, .armeb, .thumb, .thumbeb => "arm",
        .riscv32 => "riscv32",
        .riscv64 => "riscv64",
        .loongarch64 => "loongarch64",
        .mips, .mipsel => if (target.abi == .muslabin32) "mipsn32" else "mips",
        .mips64, .mips64el => if (target.abi == .muslabin32) "mipsn32" else "mips64",
        .powerpc => "powerpc",
        .powerpc64, .powerpc64le => "powerpc64",
        .s390x => "s390x",
        .m68k => "m68k",
        else => std.debug.panic("musl has no port for {t}", .{target.cpu.arch}),
    };
}

fn readSource(b: *std.Build, src_root: []const u8, sub_path: []const u8) []u8 {
    const path = b.pathJoin(&.{ src_root, sub_path });
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch |err|
        std.debug.panic("failed to read musl source {s}: {t}", .{ path, err });
}

/// musl's `obj/include/bits/alltypes.h`, i.e. `tools/mkalltypes.sed` applied to the
/// architecture's `alltypes.h.in` followed by the generic one: every `TYPEDEF`,
/// `STRUCT` and `UNION` line becomes a definition guarded by the `__NEED_`/
/// `__DEFINED_` pair musl's public headers use to pull in only what they need.
fn allTypesHeader(b: *std.Build, src_root: []const u8, arch: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for ([_][]const u8{
        b.fmt("arch/{s}/bits/alltypes.h.in", .{arch}),
        "include/alltypes.h.in",
    }) |sub_path| {
        var lines = std.mem.splitScalar(u8, readSource(b, src_root, sub_path), '\n');
        while (lines.next()) |line| {
            // The empty segment a trailing newline leaves behind is not a line.
            if (line.len == 0 and lines.peek() == null) break;
            expandAllTypesLine(b, &out, line);
        }
    }
    return out.items;
}

fn expandAllTypesLine(b: *std.Build, out: *std.ArrayList(u8), line: []const u8) void {
    const gpa = b.allocator;
    const body = std.mem.trimEnd(u8, line, "\r");
    const guarded = for ([_]struct { prefix: []const u8, keyword: []const u8, tagged: bool }{
        .{ .prefix = "TYPEDEF ", .keyword = "typedef", .tagged = false },
        .{ .prefix = "STRUCT ", .keyword = "struct", .tagged = true },
        .{ .prefix = "UNION ", .keyword = "union", .tagged = true },
    }) |kind| {
        if (!std.mem.startsWith(u8, body, kind.prefix)) continue;
        const decl = std.mem.trim(u8, std.mem.trimEnd(u8, body[kind.prefix.len..], ";"), " \t");
        // What the `__NEED_`/`__DEFINED_` macros are named after: a typedef's own
        // name, which is its *last* word (`TYPEDEF unsigned long size_t;`), or a
        // struct's/union's tag, which is its *first* (`STRUCT timespec { ... };`).
        const guard = if (kind.tagged) b.fmt("{s}_{s}", .{
            kind.keyword,
            decl[0 .. std.mem.indexOfAny(u8, decl, " \t") orelse decl.len],
        }) else if (std.mem.lastIndexOfAny(u8, decl, " \t")) |at| decl[at + 1 ..] else decl;
        break b.fmt(
            \\#if defined(__NEED_{0s}) && !defined(__DEFINED_{0s})
            \\{1s} {2s};
            \\#define __DEFINED_{0s}
            \\#endif
            \\
        , .{ guard, kind.keyword, decl });
    } else null;
    out.appendSlice(gpa, guarded orelse body) catch @panic("OOM");
    out.append(gpa, '\n') catch @panic("OOM");
}

/// musl's `obj/include/bits/syscall.h`: the architecture's syscall table, plus the
/// same table again with musl's `__NR_` prefix rewritten to the public `SYS_` one.
fn syscallHeader(b: *std.Build, src_root: []const u8, arch: []const u8) []const u8 {
    const text = readSource(b, src_root, b.fmt("arch/{s}/bits/syscall.h.in", .{arch}));
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(b.allocator, text) catch @panic("OOM");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "__NR_") orelse continue;
        out.print(b.allocator, "{s}SYS_{s}\n", .{ line[0..at], line[at + "__NR_".len ..] }) catch @panic("OOM");
    }
    return out.items;
}

/// The source files musl's Makefile links into `libc.so`, i.e. everything under
/// `src/` (plus `ldso/`, and `compat/time32/` where the architecture needs it),
/// with one rule: a file under `<dir>/<arch>/` replaces the `<dir>/` file of the
/// same name. `crt/` is left out -- those objects are the startup files a *program*
/// links, not part of the library.
fn sourceFiles(b: *std.Build, src_root: []const u8, arch: []const u8) []const []const u8 {
    const gpa = b.allocator;
    var dirs: std.ArrayList([]const u8) = .empty;
    dirs.appendSlice(gpa, &.{ "ldso", "src/malloc/mallocng" }) catch @panic("OOM");
    // The 32-bit-time architectures need musl's compatibility shims; which ones do
    // is recorded in the architecture's own `arch.mak` fragment.
    if (readSourceIfPresent(b, src_root, b.fmt("arch/{s}/arch.mak", .{arch}))) |mak| {
        if (std.mem.indexOf(u8, mak, "compat/time32") != null)
            dirs.append(gpa, "compat/time32") catch @panic("OOM");
    }
    var src_it = iterate(b, src_root, "src");
    defer src_it.reader.dir.close(b.graph.io);
    while (nextEntry(b, &src_it)) |entry| {
        if (entry.kind == .directory) dirs.append(gpa, b.fmt("src/{s}", .{entry.name})) catch @panic("OOM");
    }

    var files: std.ArrayList([]const u8) = .empty;
    for (dirs.items) |dir| {
        // Per-architecture overrides first: their names are what the generic pass
        // below has to skip.
        var overridden: std.StringHashMapUnmanaged(void) = .empty;
        const arch_dir = b.fmt("{s}/{s}", .{ dir, arch });
        if (dirExists(b, src_root, arch_dir)) {
            var arch_it = iterate(b, src_root, arch_dir);
            defer arch_it.reader.dir.close(b.graph.io);
            while (nextEntry(b, &arch_it)) |entry| {
                if (!isSource(entry)) continue;
                overridden.put(gpa, std.fs.path.stem(b.dupe(entry.name)), {}) catch @panic("OOM");
                files.append(gpa, b.fmt("{s}/{s}", .{ arch_dir, entry.name })) catch @panic("OOM");
            }
        }
        var it = iterate(b, src_root, dir);
        defer it.reader.dir.close(b.graph.io);
        while (nextEntry(b, &it)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".c")) continue;
            if (overridden.contains(std.fs.path.stem(entry.name))) continue;
            files.append(gpa, b.fmt("{s}/{s}", .{ dir, entry.name })) catch @panic("OOM");
        }
    }
    // Sorted so the compile step's cache key does not depend on directory order.
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);
    return files.items;
}

fn isSource(entry: std.Io.Dir.Entry) bool {
    if (entry.kind != .file) return false;
    for ([_][]const u8{ ".c", ".s", ".S" }) |ext| {
        if (std.mem.endsWith(u8, entry.name, ext)) return true;
    }
    return false;
}

fn readSourceIfPresent(b: *std.Build, src_root: []const u8, sub_path: []const u8) ?[]u8 {
    const path = b.pathJoin(&.{ src_root, sub_path });
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch null;
}

fn dirExists(b: *std.Build, src_root: []const u8, sub_path: []const u8) bool {
    const path = b.pathJoin(&.{ src_root, sub_path });
    var dir = std.Io.Dir.cwd().openDir(b.graph.io, path, .{ .iterate = true }) catch return false;
    dir.close(b.graph.io);
    return true;
}

fn iterate(b: *std.Build, src_root: []const u8, sub_path: []const u8) std.Io.Dir.Iterator {
    const path = b.pathJoin(&.{ src_root, sub_path });
    const dir = std.Io.Dir.cwd().openDir(b.graph.io, path, .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open musl source directory {s}: {t}", .{ path, err });
    return dir.iterateAssumeFirstIteration();
}

fn nextEntry(b: *std.Build, it: *std.Io.Dir.Iterator) ?std.Io.Dir.Entry {
    return it.next(b.graph.io) catch |err|
        std.debug.panic("failed to read a musl source directory: {t}", .{err});
}
