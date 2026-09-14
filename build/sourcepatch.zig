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

/// CPython's own `Tools/build/deepfreeze.py` needs several independent fixes
/// on 3.13+ before this project can run it at all -- confirming what its own
/// upstream history already suggests (a "Remove accidentally added
/// Python/deepfreeze/deepfreeze.c" revert, and no Makefile rule invoking it
/// anywhere in the current tree): this tool has been unmaintained, dead code
/// as far as CPython's own build is concerned since well before 3.13, so
/// nothing upstream ever noticed any of this rotting. `applyIfPresent` (not
/// `apply`) is used for this one because of it: whether the needles exist at
/// all is itself CPython-version-dependent, not something every build needs
/// regardless of version the way mingw_fixups is -- 1-3 are absent on 3.12,
/// 4-5 absent before 3.14 (both gated together by edit 1's presence, the
/// common case across every affected version; a 3.13 build ends up with
/// edit 5's harmless, never-instantiated `generate_slice` method too, cheaper
/// to accept than a second independently-gated patch object).
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
/// 4-5. CPython 3.14 added a new marshal type for `slice` objects
///    (`TYPE_SLICE`, see `umarshal_fixups`' own doc comment) -- some frozen
///    module's bytecode embeds one as a code-object constant (a slice
///    literal, e.g. `x[1:2]`, folded to a constant at compile time), and
///    `generate()`'s dispatch has no case for it at all, `types`-error or
///    not: `TypeError: Cannot generate code for slice object`. Modeled
///    directly on `generate_complex` (also a fixed-size, non-`PyVarObject`
///    struct): `PySliceObject` is `PyObject_HEAD` plus three `PyObject
///    *start, *stop, *step` fields (`Include/sliceobject.h`), each generated
///    recursively the way `generate_tuple`'s own items are.
/// 6. Every generated code object's `.co_framesize` initializer references
///    `FRAME_SPECIALS_SIZE` -- moved in 3.14 from `pycore_frame.h` (still
///    `#include`d, `deepfreeze.py`'s own hardcoded list never updated) into
///    a new `pycore_interpframe.h` that `pycore_frame.h` itself does not
///    transitively include -- `error: use of undeclared identifier`.
///
/// A factory, not a `mingw_fixups`-style constant: edit 2's replacement bakes
/// in the caller's own `cpython_dir_str`, only known at `build()` runtime, as
/// a Python string literal -- `pyStringLiteral` handles the escaping.
pub fn deepfreezePatch(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8) Patch {
    var edits: std.ArrayList(Edit) = .empty;
    edits.appendSlice(gpa, &.{
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
        .{
            .needle = "        elif isinstance(obj, frozenset):",
            .replacement =
            \\        elif isinstance(obj, slice):
            \\            val = self.generate_slice(name, obj)
            \\        elif isinstance(obj, frozenset):
            ,
        },
        .{
            .needle = "    def generate_file(self, module: str, code: object)-> None:",
            .replacement =
            \\    def generate_slice(self, name: str, s: slice) -> str:
            \\        start = self.generate(f"{name}_start", s.start)
            \\        stop = self.generate(f"{name}_stop", s.stop)
            \\        step = self.generate(f"{name}_step", s.step)
            \\        with self.block(f"static PySliceObject {name} =", ";"):
            \\            self.object_head("PySlice_Type")
            \\            self.write(f".start = {start},")
            \\            self.write(f".stop = {stop},")
            \\            self.write(f".step = {step},")
            \\        return f"(PyObject *)&{name}"
            \\
            \\    def generate_file(self, module: str, code: object)-> None:
            ,
        },
    }) catch @panic("OOM");
    // Unlike every edit above (Python-only changes, inert on a version that
    // never exercises them), this one adds an unconditional `#include` to
    // the *generated C file* -- wrong, not just dead, on a version that
    // doesn't have this header at all (3.13: verified absent). So this is
    // gated on the header genuinely existing on disk for this CPython
    // version, not lumped in with the others under edit 1's single gate.
    const interpframe_h = b.pathJoin(&.{ cpython_dir_str, "Include/internal/pycore_interpframe.h" });
    if (std.Io.Dir.cwd().access(b.graph.io, interpframe_h, .{})) |_| {
        edits.append(gpa, .{
            .needle = "self.write('#include \"internal/pycore_frame.h\"')",
            .replacement = "self.write('#include \"internal/pycore_frame.h\"')\n        self.write('#include \"internal/pycore_interpframe.h\"')",
        }) catch @panic("OOM");
    } else |_| {}
    return .{
        .file = "Tools/build/deepfreeze.py",
        .edits = edits.toOwnedSlice(gpa) catch @panic("OOM"),
        .reason = "CPython 3.13/3.14's `deepfreeze.py` restructuring (gh-133403's mypy cleanup, " ++
            "folding generate_global_objects.py's get_identifiers_and_strings in, and calling " ++
            "since-removed _PyStaticCode_Init/Fini) assumes a real types.CodeType (this project " ++
            "only ever feeds it already-frozen headers), __file__ sitting at its original depth " ++
            "inside the CPython tree (this project always runs a patched copy elsewhere), and " ++
            "functions gh-108716 deleted years ago; 3.14 also added a slice marshal type this " ++
            "generator's dispatch has no case for at all -- none of which hold/exist here",
    };
}

/// `deepfreezePatch`'s `import umarshal` sibling needs its own fix on 3.14+:
/// CPython 3.14 added a new marshal type, `TYPE_SLICE` (`':'`, see
/// `Python/marshal.c`'s real C reader/writer -- new because `slice` objects
/// can now end up as code-object constants there), that this hand-rolled
/// pure-Python reimplementation of the marshal format was never taught about
/// -- `AssertionError: Unknown type 58 ':'` decoding any frozen module whose
/// bytecode happens to embed one. Absent on 3.12/3.13 (no such marshal type
/// existed yet), so a plain `Patch`, not a factory: unlike `deepfreezePatch`,
/// every edit here is a comptime-known string, nothing this function needs to
/// compute at `build()` runtime.
pub const umarshal_fixups: []const Patch = &.{
    .{
        .file = "Tools/build/umarshal.py",
        .edits = &.{
            .{
                .needle = "    SHORT_ASCII_INTERNED = ord('Z')",
                .replacement = "    SHORT_ASCII_INTERNED = ord('Z')\n    SLICE               = ord(':')",
            },
            .{
                .needle = "        elif type == Type.FROZENSET:",
                .replacement =
                \\        elif type == Type.SLICE:
                \\            idx = self.r_ref_reserve(flag)
                \\            start = self.r_object()
                \\            stop = self.r_object()
                \\            step = self.r_object()
                \\            retval = slice(start, stop, step)
                \\            self.r_ref_insert(retval, idx, flag)
                \\            return retval
                \\        elif type == Type.FROZENSET:
                ,
            },
        },
        .reason = "CPython 3.14 added TYPE_SLICE to the real marshal format (Python/marshal.c) " ++
            "-- start, stop, step, each a sub-object, ref-reservable like a tuple -- without " ++
            "Tools/build/umarshal.py's hand-rolled reimplementation ever being taught the new type",
    },
};

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

/// Applies `edits`, in order, to `text` -- each against the result of the one
/// before. Panics if an edit's `needle` doesn't appear (or appears more than
/// once, ambiguously) in the text at the time it runs. `path`/`reason` are
/// only for that panic message.
fn applyEdits(gpa: std.mem.Allocator, text_in: []const u8, edits: []const Edit, path: []const u8, reason: []const u8) []const u8 {
    var text = text_in;
    for (edits) |edit| {
        const first = std.mem.indexOf(u8, text, edit.needle) orelse std.debug.panic(
            "sourcepatch target not found in {s} -- CPython version drift? ({s})",
            .{ path, reason },
        );
        if (std.mem.indexOf(u8, text[first + edit.needle.len ..], edit.needle) != null) std.debug.panic(
            "sourcepatch target appears more than once in {s} -- needle needs more context ({s})",
            .{ path, reason },
        );
        text = std.mem.concat(gpa, u8, &.{
            text[0..first],
            edit.replacement,
            text[first + edit.needle.len ..],
        }) catch @panic("OOM");
    }
    return text;
}

/// Applies one `Patch`'s `edits`, in order, to `cpython_dir_str/patch.file`,
/// returning a LazyPath to the patched copy.
///
/// `siblings` are additional `Patch`es -- cpython-root-relative, like
/// `patch.file` itself -- written into the *same* output directory as the
/// main patched file, under their own basename: for a patched file that
/// reaches for a same-directory file at runtime (a Python script's `import`
/// of a sibling module, resolved via `sys.path[0]`) rather than through an
/// include path a compiler already searches. Each is applied the tolerant
/// way (`applyIfPresent`'s own logic: skip if its first edit's needle isn't
/// there, since a sibling a `patch` needs edited on one CPython version may
/// need nothing at all on another) -- a sibling with no `edits` at all is
/// just copied through unmodified. Empty for a patch that needs nothing else
/// alongside it.
pub fn apply(
    b: *std.Build,
    gpa: std.mem.Allocator,
    cpython_dir_str: []const u8,
    patch: Patch,
    siblings: []const Patch,
) std.Build.LazyPath {
    const path = b.pathJoin(&.{ cpython_dir_str, patch.file });
    const text = applyEdits(gpa, readFile(b, gpa, path), patch.edits, path, patch.reason);

    const wf = b.addWriteFiles();
    const out = wf.add(std.fs.path.basename(patch.file), text);
    for (siblings) |sib| {
        const sib_path = b.pathJoin(&.{ cpython_dir_str, sib.file });
        const sib_original = readFile(b, gpa, sib_path);
        const sib_text = if (sib.edits.len > 0 and std.mem.indexOf(u8, sib_original, sib.edits[0].needle) != null)
            applyEdits(gpa, sib_original, sib.edits, sib_path, sib.reason)
        else
            sib_original;
        _ = wf.add(std.fs.path.basename(sib.file), sib_text);
    }
    return out;
}

/// Finds and applies the one `Patch` in `patches` whose `file` matches --
/// panics if none does (caller error: check the list).
pub fn applyNamed(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patches: []const Patch, file: []const u8, siblings: []const Patch) std.Build.LazyPath {
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
pub fn applyIfPresent(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patch: Patch, siblings: []const Patch) std.Build.LazyPath {
    const path = b.pathJoin(&.{ cpython_dir_str, patch.file });
    const original = readFile(b, gpa, path);
    if (std.mem.indexOf(u8, original, patch.edits[0].needle) == null) return b.graph.cwdRelativePath(path);
    return apply(b, gpa, cpython_dir_str, patch, siblings);
}

/// `applyIfPresent`, looking `patch` up by `file` the way `applyNamed` does.
pub fn applyNamedIfPresent(b: *std.Build, gpa: std.mem.Allocator, cpython_dir_str: []const u8, patches: []const Patch, file: []const u8, siblings: []const Patch) std.Build.LazyPath {
    for (patches) |p| {
        if (std.mem.eql(u8, p.file, file)) return applyIfPresent(b, gpa, cpython_dir_str, p, siblings);
    }
    std.debug.panic("no sourcepatch registered for {s}", .{file});
}
