//! Exact-text source patches applied to a *copy* of a CPython file at build
//! time (via `b.addWriteFiles()`), never to the file on disk -- the `cpython`
//! submodule stays byte-identical to upstream. Same spirit as
//! build/pyconfig.zig's macro patcher, generalized to arbitrary source lines:
//! name the exact text you want replaced, and why; panics loudly if it isn't
//! found (typo, or upstream changed the line since this patch was written)
//! rather than silently no-op'ing.
//!
//! Reserved for cases with no equivalent-effort alternative -- a missing
//! define, an unavailable library, a compiler flag -- see build.zig and
//! windows.md for what actually lands here and why.

const std = @import("std");

pub const Patch = struct {
    /// cpython-root-relative path, e.g. "Modules/_winapi.c".
    file: []const u8,
    needle: []const u8,
    replacement: []const u8,
    /// Why this exact text needs to change -- shown in the panic message
    /// too, so a future CPython version bump that moves/rewords the line
    /// points straight at the reasoning instead of just a dead string match.
    reason: []const u8,
};

/// mingw-w64 (Clang) is stricter than MSVC about a couple of narrow, harmless
/// spots in CPython's own Windows-only sources -- see windows.md's "Status"
/// section for the full investigation (each of these was confirmed to be a
/// real compile-time-only, MSVC-tolerated inconsistency, not a functional bug:
/// the `_winapi.c` one is a same-width nominal-type mismatch with identical
/// codegen either way on Windows' LLP64 model, and the `dynload_win.c` one is
/// a linkage mismatch whose only caller is in the same file, so it's inert
/// under either linkage).
pub const mingw_fixups: []const Patch = &.{
    .{
        .file = "Modules/_winapi.c",
        .needle = "int previousTpSize = 0;",
        .replacement = "DWORD previousTpSize = 0;",
        .reason = "AdjustTokenPrivileges's ReturnLength out-param is PDWORD; " ++
            "MSVC accepts the int* mismatch silently (both are 32-bit on Windows), Clang doesn't",
    },
    .{
        .file = "Python/dynload_win.c",
        .needle = "static int\n_Py_CheckPython3(void)",
        .replacement = "int\n_Py_CheckPython3(void)",
        .reason = "declared non-static (extern) in Include/pylifecycle.h, but its only " ++
            "caller is this same file -- MSVC doesn't cross-check declaration linkage, Clang does",
    },
    .{
        .file = "Programs/python.c",
        .needle = "int\nwmain(int argc, wchar_t **argv)\n{\n    return Py_Main(argc, argv);\n}",
        .replacement =
        \\extern int __wgetmainargs(int *argc, wchar_t ***wargv, wchar_t ***wenv, int expand_wildcards, int *startupinfo);
        \\int
        \\main(int argc, char **argv)
        \\{
        \\    (void)argc; (void)argv;
        \\    int wargc, si = 0;
        \\    wchar_t **wargv, **wenviron;
        \\    __wgetmainargs(&wargc, &wargv, &wenviron, 0, &si);
        \\    return Py_Main(wargc, wargv);
        \\}
        ,
        .reason = "Zig's mingw-w64 integration (this Zig version) unconditionally links its " ++
            "own bundled ANSI crt2.o (expects `main`/`WinMain`) for every windows-gnu " ++
            "executable, with no exposed way to swap in the wide/`wmain` CRT startup variant " ++
            "or suppress the default one -- both attempted, see windows.md's Status section. " ++
            "Defining `main` and fetching wide argv via mingw's own `__wgetmainargs` (the " ++
            "standard technique real-world mingw programs use for exactly this) sidesteps the " ++
            "whole CRT-object-selection fight entirely, using Zig's already-working default.",
    },
};

/// Applies one `Patch` to `cpython_dir_str/patch.file`, returning a LazyPath
/// to the patched copy. Panics if `needle` doesn't appear in the file, or
/// appears more than once (ambiguous -- the patch must name enough context
/// to be unique).
pub fn apply(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patch: Patch) std.Build.LazyPath {
    const path = b.pathJoin(&.{ cpython_dir_str, patch.file });
    const original = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t}", .{ path, err });

    const first = std.mem.indexOf(u8, original, patch.needle) orelse std.debug.panic(
        "sourcepatch target not found in {s} -- CPython version drift? ({s})",
        .{ path, patch.reason },
    );
    if (std.mem.indexOf(u8, original[first + patch.needle.len ..], patch.needle) != null) std.debug.panic(
        "sourcepatch target appears more than once in {s} -- needle needs more context ({s})",
        .{ path, patch.reason },
    );

    const patched = std.mem.concat(gpa, u8, &.{
        original[0..first],
        patch.replacement,
        original[first + patch.needle.len ..],
    }) catch @panic("OOM");

    const wf = b.addWriteFiles();
    return wf.add(std.fs.path.basename(patch.file), patched);
}

/// Finds and applies the one `Patch` in `patches` whose `file` matches --
/// panics if none does (caller error: check the list).
pub fn applyNamed(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patches: []const Patch, file: []const u8) std.Build.LazyPath {
    for (patches) |p| {
        if (std.mem.eql(u8, p.file, file)) return apply(b, gpa, cpython_dir_str, p);
    }
    std.debug.panic("no sourcepatch registered for {s}", .{file});
}
