//! A small typed layer over pyconfig.h's `#define NAME value` / `/* #undef
//! NAME */` macro syntax: not a full parse-into-struct-and-reserialize model
//! (pyconfig.h interleaves ~350 macros with per-macro doc comments, guards,
//! and a handful of non-trivial constructs -- function-like macros, `#if
//! defined(...)` blocks -- that a "rebuild the whole file from a struct"
//! approach would have to either drop or faithfully reproduce for zero
//! benefit). Instead: name the macros you want overridden and what they
//! should become (`MacroPatch`), and `applyPatches` rewrites just those
//! lines in a single pass over an existing pyconfig.h's text, leaving
//! everything else -- including the comments -- byte-identical. That keeps
//! the result diffable against a fresh `./configure` run, and replaces
//! hand-editing a frozen, checked-in pyconfig.h copy or a one-off sed/python
//! script with an ordinary, reviewable Zig data list.

const std = @import("std");

/// What a patched macro should become.
pub const MacroState = union(enum) {
    /// `/* #undef NAME */` -- not defined.
    undef,
    /// `#define NAME` -- defined with no value (rare; feature-test markers).
    flag,
    /// `#define NAME <value>`, written verbatim -- caller already knows
    /// whether that's an integer, a quoted string, or a bare token; pyconfig.h
    /// mixes all three depending on the macro.
    value: []const u8,
};

pub const MacroPatch = struct {
    name: []const u8,
    state: MacroState,
};

/// Macros known to be misdetected by a native (non-cross-aware) `./configure`
/// run when `CC` is a musl-targeted `zig cc` (see build.zig's runConfigure
/// caller and roadmap.md's "musl `./configure` cross-detection" finding):
/// each is real on glibc but absent/broken on musl, regardless of what this
/// particular run's `AC_CHECK_*` actually detected (some already come out
/// right; forcing them again is a harmless no-op for those -- see
/// `applyPatches`' per-macro, not per-file, semantics).
pub const musl_fixups: []const MacroPatch = &.{
    .{ .name = "HAVE_CLOSE_RANGE", .state = .undef },
    .{ .name = "HAVE_SEM_CLOCKWAIT", .state = .undef },
    .{ .name = "HAVE_SYS_PIDFD_H", .state = .undef },
    // musl's <sched.h> lacks the glibc-only dynamic CPU_SET_S/CPU_ALLOC_SIZE family.
    .{ .name = "HAVE_SCHED_SETAFFINITY", .state = .undef },
    // musl never has this legacy SysV STREAMS header.
    .{ .name = "HAVE_STROPTS_H", .state = .undef },
    // AC_CHECK_DECLS spelling (0/1, not #define/#undef) for a glibc-only dlopen() flag.
    .{ .name = "HAVE_DECL_RTLD_DEEPBIND", .state = .{ .value = "0" } },
};

/// Rewrites every line in `text` that `#define`s or `/* #undef */`s one of
/// `patches`' macro names to that patch's `state`, leaving every other line
/// (doc comments, guards, macros not named in `patches`) byte-identical.
/// Panics if a named macro isn't found anywhere in `text` -- almost always a
/// typo, or a macro CPython's own `configure.ac` renamed/removed since the
/// patch list was written; silently no-op'ing that would be worse than
/// failing loudly (the whole point of naming macros explicitly is to know
/// they actually took effect).
pub fn applyPatches(gpa: std.mem.Allocator, text: []const u8, patches: []const MacroPatch) []const u8 {
    const found = gpa.alloc(bool, patches.len) catch @panic("OOM");
    defer gpa.free(found);
    @memset(found, false);

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) out.append(gpa, '\n') catch @panic("OOM");
        first = false;

        const name = matchMacroName(line);
        const patch_index: ?usize = if (name) |n|
            for (patches, 0..) |p, i| {
                if (std.mem.eql(u8, p.name, n)) break i;
            } else null
        else
            null;

        if (patch_index) |i| {
            found[i] = true;
            writeMacroLine(gpa, &out, patches[i]);
        } else {
            out.appendSlice(gpa, line) catch @panic("OOM");
        }
    }

    for (patches, found) |p, f| if (!f) std.debug.panic(
        "pyconfig patch target '{s}' not found in the given pyconfig.h -- macro renamed/removed upstream?",
        .{p.name},
    );

    return out.items;
}

fn writeMacroLine(gpa: std.mem.Allocator, out: *std.ArrayList(u8), patch: MacroPatch) void {
    const rendered = switch (patch.state) {
        .undef => std.fmt.allocPrint(gpa, "/* #undef {s} */", .{patch.name}),
        .flag => std.fmt.allocPrint(gpa, "#define {s}", .{patch.name}),
        .value => |v| std.fmt.allocPrint(gpa, "#define {s} {s}", .{ patch.name, v }),
    } catch @panic("OOM");
    out.appendSlice(gpa, rendered) catch @panic("OOM");
}

/// Recognizes both spellings pyconfig.h uses for a simple (non-function-like)
/// macro named `NAME`: `#define NAME` / `#define NAME <value>`, and
/// `/* #undef NAME */`. Returns the macro name, or null if `line` is neither
/// (including function-like macros, e.g. `#define FOO(x) ...` -- never a
/// patch target, and rewriting one would corrupt it).
fn matchMacroName(line: []const u8) ?[]const u8 {
    const define_prefix = "#define ";
    if (std.mem.startsWith(u8, line, define_prefix)) {
        const rest = line[define_prefix.len..];
        const name = takeIdent(rest) orelse return null;
        if (name.len < rest.len and rest[name.len] == '(') return null; // function-like
        return name;
    }
    const undef_prefix = "/* #undef ";
    const undef_suffix = " */";
    if (std.mem.startsWith(u8, line, undef_prefix) and std.mem.endsWith(u8, line, undef_suffix)) {
        return line[undef_prefix.len .. line.len - undef_suffix.len];
    }
    return null;
}

fn takeIdent(s: []const u8) ?[]const u8 {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return null;
    var end: usize = 1;
    while (end < s.len and (std.ascii.isAlphanumeric(s[end]) or s[end] == '_')) end += 1;
    return s[0..end];
}
