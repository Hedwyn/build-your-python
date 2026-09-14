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

pub const Edit = struct {
    needle: []const u8,
    replacement: []const u8,
};

pub const Patch = struct {
    /// cpython-root-relative path, e.g. "Modules/_winapi.c".
    file: []const u8,
    /// Applied in order, each against the result of the one before --
    /// almost always just one, but a file needing more than one independent
    /// exact-text change for the same reason (see `deepfreeze_fixups`) names
    /// them all here instead of contorting itself into two separate `Patch`
    /// entries racing to both claim the same `file`.
    edits: []const Edit,
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
        .edits = &.{.{
            .needle = "int previousTpSize = 0;",
            .replacement = "DWORD previousTpSize = 0;",
        }},
        .reason = "AdjustTokenPrivileges's ReturnLength out-param is PDWORD; " ++
            "MSVC accepts the int* mismatch silently (both are 32-bit on Windows), Clang doesn't",
    },
    .{
        .file = "Python/dynload_win.c",
        .edits = &.{.{
            .needle = "static int\n_Py_CheckPython3(void)",
            .replacement = "int\n_Py_CheckPython3(void)",
        }},
        .reason = "declared non-static (extern) in Include/pylifecycle.h, but its only " ++
            "caller is this same file -- MSVC doesn't cross-check declaration linkage, Clang does",
    },
    .{
        .file = "Programs/python.c",
        .edits = &.{.{
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
        }},
        .reason = "Zig's mingw-w64 integration (this Zig version) unconditionally links its " ++
            "own bundled ANSI crt2.o (expects `main`/`WinMain`) for every windows-gnu " ++
            "executable, with no exposed way to swap in the wide/`wmain` CRT startup variant " ++
            "or suppress the default one -- both attempted, see windows.md's Status section. " ++
            "Defining `main` and fetching wide argv via mingw's own `__wgetmainargs` (the " ++
            "standard technique real-world mingw programs use for exactly this) sidesteps the " ++
            "whole CRT-object-selection fight entirely, using Zig's already-working default.",
    },
};

/// CPython's own `Tools/build/deepfreeze.py` needs three independent fixes on
/// 3.13+ before this project can run it at all -- confirming what its own
/// upstream history already suggests (a "Remove accidentally added
/// Python/deepfreeze/deepfreeze.c" revert, and no Makefile rule invoking it
/// anywhere in the current tree): this tool has been unmaintained, dead code
/// as far as CPython's own build is concerned since well before 3.13, so
/// nothing upstream ever noticed it rotting. All three are absent on 3.12,
/// which is exactly why `applyIfPresent` (not `apply`) is used for this one:
/// whether the needles exist at all is itself CPython-version-dependent, not
/// something every build needs regardless of version the way mingw_fixups is.
///
/// 1. A mypy-driven cleanup (`cec0e13fd4aa96b188f04a45882d870556f80baa`,
///    cherry-picked to both the 3.13 and 3.14 branches) narrowed an
///    `isinstance` check from `(types.CodeType, umarshal.Code)` down to just
///    `types.CodeType`. Harmless for deepfreeze.py's *other* caller (compiling
///    raw `.py` source, which really does produce a `types.CodeType`) -- but
///    this project's own freeze step (`build.zig`'s `Utils.addDeepfreeze`)
///    always feeds it *already-frozen* headers (`Programs/_freeze_module.py`'s
///    own output, decoded back via `Tools/build/umarshal.py`'s hand-rolled
///    reader), which are never a real `types.CodeType` -- so every code
///    object it processes raises `TypeError: Cannot generate code for Code
///    object`.
/// 2. The folded-in `get_identifiers_and_strings` (previously the standalone
///    `Tools/build/generate_global_objects.py` helper 3.12 imports it from)
///    locates `Include/internal/pycore_global_strings.h` via `ROOT =
///    os.path.dirname(os.path.dirname(os.path.dirname(__file__)))` -- correct
///    only when `__file__` sits at its own original two-directories-deep
///    spot inside a real CPython checkout, which this project's patched copy
///    (a same-named file freshly written into its own build-cache directory
///    elsewhere, see `apply`) never does. Baking in the real, absolute
///    `cpython_dir_str` as a string literal instead makes it independent of
///    wherever the patched copy actually ends up.
/// 3. `generate_code` emits a call to `_PyStaticCode_Init`/`_PyStaticCode_Fini`
///    for every code object -- removed from CPython itself in `97ba910e47a`
///    ("gh-108716: Remove _PyStaticCode_Init/Fini", already gone by 3.13.0)
///    without deepfreeze.py's generator ever being updated to match, so the
///    generated `deepfreeze.c` calls two functions that plain don't exist
///    anywhere in the tree -- `error: call to undeclared function`. Neutered
///    into `pass` statements rather than generating a stub definition: CPython
///    itself runs every frozen module without ever calling either, so
///    whatever they once did is no longer needed at all, not just renamed.
///
/// A factory, not a `mingw_fixups`-style constant: edit 2's replacement bakes
/// in the caller's own `cpython_dir_str`, only known at `build()` runtime, as
/// a Python string literal -- `pyStringLiteral` handles the escaping.
pub fn deepfreezePatch(gpa: std.mem.Allocator, cpython_dir_str: []const u8) Patch {
    // Heap-allocated on purpose, not `&.{...}` taken inline: this function
    // returns a value containing that slice, and `&.{...}`'s storage
    // (a compound literal that isn't comptime-known throughout, since edit 2's
    // replacement is a runtime `allocPrint` result) only has this function's
    // own stack frame for a lifetime -- confirmed the hard way, as a real,
    // reproducible bug: the needle search below would intermittently fail
    // against already-overwritten stack contents despite reading the exact
    // right file correctly, byte for byte. `gpa.dupe` copies it somewhere
    // that outlives the call.
    const edits = gpa.dupe(Edit, &.{
        .{
            .needle = "if isinstance(obj, types.CodeType) :",
            .replacement = "if isinstance(obj, (types.CodeType, umarshal.Code)) :",
        },
        .{
            .needle = "ROOT = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))",
            .replacement = std.fmt.allocPrint(gpa, "ROOT = {s}", .{pyStringLiteral(gpa, cpython_dir_str)}) catch @panic("OOM"),
        },
        .{
            .needle = "self.finis.append(f\"_PyStaticCode_Fini({name_as_code});\")",
            .replacement = "pass  # _PyStaticCode_Fini removed upstream, gh-108716",
        },
        .{
            .needle = "self.inits.append(f\"_PyStaticCode_Init({name_as_code})\")",
            .replacement = "pass  # _PyStaticCode_Init removed upstream, gh-108716",
        },
    }) catch @panic("OOM");
    return .{
        .file = "Tools/build/deepfreeze.py",
        .edits = edits,
        .reason = "CPython 3.13/3.14's `deepfreeze.py` restructuring (gh-133403's mypy cleanup, " ++
            "folding generate_global_objects.py's get_identifiers_and_strings in, and calling " ++
            "since-removed _PyStaticCode_Init/Fini) assumes a real types.CodeType (this project " ++
            "only ever feeds it already-frozen headers), __file__ sitting at its original depth " ++
            "inside the CPython tree (this project always runs a patched copy elsewhere), and " ++
            "functions gh-108716 deleted years ago -- none of which hold here",
    };
}

/// `path` as a Python double-quoted string literal -- only `\` and `"` need
/// escaping for a plain filesystem path (no embedded newlines or control
/// characters to worry about).
fn pyStringLiteral(gpa: std.mem.Allocator, path: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(gpa, '"') catch @panic("OOM");
    for (path) |c| {
        if (c == '\\' or c == '"') out.append(gpa, '\\') catch @panic("OOM");
        out.append(gpa, c) catch @panic("OOM");
    }
    out.append(gpa, '"') catch @panic("OOM");
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

fn readFile(b: *std.Build, gpa: std.mem.Allocator, path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t}", .{ path, err });
}

/// Applies one `Patch`'s `edits`, in order, to `cpython_dir_str/patch.file`,
/// returning a LazyPath to the patched copy. Panics if an edit's `needle`
/// doesn't appear in the (partially-patched, by the time a later edit runs)
/// file, or appears more than once there (ambiguous -- the edit must name
/// enough context to be unique).
///
/// `siblings` are file names, relative to `patch.file`'s own directory,
/// copied unmodified alongside the patched copy in the same output
/// directory -- for a patched file that reaches for a same-directory file at
/// runtime (a Python script's `import` of a sibling module, resolved via
/// `sys.path[0]`) rather than through an include path a compiler already
/// searches. Empty for a patch that needs nothing else alongside it.
pub fn apply(
    b: *std.Build,
    gpa: std.mem.Allocator,
    cpython_dir_str: []const u8,
    patch: Patch,
    siblings: []const []const u8,
) std.Build.LazyPath {
    const path = b.pathJoin(&.{ cpython_dir_str, patch.file });
    var text = readFile(b, gpa, path);

    for (patch.edits) |edit| {
        const first = std.mem.indexOf(u8, text, edit.needle) orelse std.debug.panic(
            "sourcepatch target not found in {s} -- CPython version drift? ({s})",
            .{ path, patch.reason },
        );
        if (std.mem.indexOf(u8, text[first + edit.needle.len ..], edit.needle) != null) std.debug.panic(
            "sourcepatch target appears more than once in {s} -- needle needs more context ({s})",
            .{ path, patch.reason },
        );
        text = std.mem.concat(gpa, u8, &.{
            text[0..first],
            edit.replacement,
            text[first + edit.needle.len ..],
        }) catch @panic("OOM");
    }

    const wf = b.addWriteFiles();
    const out = wf.add(std.fs.path.basename(patch.file), text);
    const dir = std.fs.path.dirname(patch.file) orelse "";
    for (siblings) |sib| {
        const sib_path = b.pathJoin(&.{ cpython_dir_str, dir, sib });
        _ = wf.addCopyFile(b.graph.cwdRelativePath(sib_path), sib);
    }
    return out;
}

/// Finds and applies the one `Patch` in `patches` whose `file` matches --
/// panics if none does (caller error: check the list).
pub fn applyNamed(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patches: []const Patch, file: []const u8, siblings: []const []const u8) std.Build.LazyPath {
    for (patches) |p| {
        if (std.mem.eql(u8, p.file, file)) return apply(b, gpa, cpython_dir_str, p, siblings);
    }
    std.debug.panic("no sourcepatch registered for {s}", .{file});
}

/// Same as `apply`, but for a patch that only some CPython versions need
/// (the bug it fixes was introduced, or fixed, at some upstream release):
/// checks only the *first* edit's `needle`, and returns
/// `cpython_dir_str/patch.file` itself, unpatched, if that one isn't found,
/// instead of `apply`'s "loud panic on drift" -- for this kind of patch, a
/// missing needle usually just means this particular version predates the
/// regression, or a later one has already fixed it, not that something is
/// wrong. `siblings` is moot on that path: the file is still sitting in its
/// own original directory, real siblings and all.
pub fn applyIfPresent(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patch: Patch, siblings: []const []const u8) std.Build.LazyPath {
    const path = b.pathJoin(&.{ cpython_dir_str, patch.file });
    const original = readFile(b, gpa, path);
    if (std.mem.indexOf(u8, original, patch.edits[0].needle) == null) return b.graph.cwdRelativePath(path);
    return apply(b, gpa, cpython_dir_str, patch, siblings);
}

/// `applyIfPresent`, looking `patch` up by `file` the way `applyNamed` does.
pub fn applyNamedIfPresent(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patches: []const Patch, file: []const u8, siblings: []const []const u8) std.Build.LazyPath {
    for (patches) |p| {
        if (std.mem.eql(u8, p.file, file)) return applyIfPresent(b, gpa, cpython_dir_str, p, siblings);
    }
    std.debug.panic("no sourcepatch registered for {s}", .{file});
}
