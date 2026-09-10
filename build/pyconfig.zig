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
/// `patches` may name the same macro more than once; the last entry wins,
/// which is what lets callers append an override list after a built-in one.
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

        // Last patch naming a given macro wins, and *every* patch naming it
        // is marked found: build.zig concatenates several lists (musl,
        // cross, per-arch, caller-supplied `-Dpyconfig-define`/`-undef`) and
        // relies on a later one being able to override an earlier one --
        // without the shadowed entry then tripping the not-found panic below.
        const name = matchMacroName(line);
        var patch_index: ?usize = null;
        if (name) |n| for (patches, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, n)) {
                found[i] = true;
                patch_index = i;
            }
        };

        if (patch_index) |i| {
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

/// Macros CPython's own `configure.ac` gets wrong under *real* `--host`
/// cross-compilation (`build/utils.zig`'s `cross_arch` path), as opposed to
/// the musl-on-same-arch case `musl_fixups` covers. Each is decided by an
/// `AC_RUN_IFELSE` -- autoconf cannot execute a target-arch test binary on
/// the build machine, so it takes the macro's hardcoded cross fallback
/// instead of measuring anything.
///
/// Established empirically, not guessed: `./configure` was run out-of-tree
/// once per target with `CC="zig cc -target ..."` for `x86_64-linux-gnu`
/// (native, the control), `aarch64-linux-gnu`, `arm-linux-gnueabihf`,
/// `s390x-linux-gnu` and `i386-linux-gnu`, and the five `pyconfig.h`s
/// diffed. Exactly six macros moved, and only these four moved *wrongly*
/// (`HAVE_GCC_ASM_FOR_X87`/`HAVE_GCC_ASM_FOR_X64` also moved, correctly:
/// they really are x86-only, and cross mode already turns them off for the
/// non-x86 targets by an ordinary compile test).
///
/// The same diff is also why there is no per-CPU macro *table* here: every
/// genuinely CPU-tied macro in `pyconfig.h` -- `SIZEOF_*`, `ALIGNOF_*`,
/// `DOUBLE_IS_{LITTLE,BIG}_ENDIAN_IEEE754`, `HAVE_GCC_UINT128_T`,
/// `HAVE_GCC_ASM_FOR_X87` -- comes out *correct* under `--host`, because
/// autoconf measures those with compile-time (not run-time) probes, which
/// cross fine. Verified across all four cross targets above, including the
/// 32-bit (`arm`, `i386`) and big-endian (`s390x`) ones, whose values differ
/// from the host's in every one of those macros. `ArchProfile` below covers
/// the single exception.
pub const cross_fixups: []const MacroPatch = &.{
    // `AC_RUN_IFELSE`'s cross fallback is "no", but the check is about the
    // *compiler*, not the target: `zig cc` is Clang, which supports GCC's
    // `&&label`/computed-goto extension on every architecture this project
    // can target. Leaving it off silently drops CPython's threaded-code
    // interpreter dispatch (`USE_COMPUTED_GOTOS`) -- a large, purely
    // gratuitous interpreter slowdown on every cross-built binary.
    .{ .name = "HAVE_COMPUTED_GOTOS", .state = .{ .value = "1" } },
    // Cross fallback "no". True on both glibc and musl: the check exists for
    // historical Unixes whose `tzset()` ignored `TZ` changes.
    .{ .name = "HAVE_WORKING_TZSET", .state = .{ .value = "1" } },
    // Cross fallback "no". Linux/NPTL has supported `PTHREAD_SCOPE_SYSTEM`
    // (in fact supports *only* it) since it replaced LinuxThreads.
    .{ .name = "PTHREAD_SYSTEM_SCHED_SUPPORTED", .state = .{ .value = "1" } },
    // Inverted sense, so the cross fallback lands on "broken": defined means
    // `sem_getvalue()` doesn't work (a macOS trait). Both Linux libcs
    // implement it; leaving this defined disables `multiprocessing`'s
    // bounded-semaphore value reporting for no reason.
    .{ .name = "HAVE_BROKEN_SEM_GETVALUE", .state = .undef },
};

/// The CPU/ABI-determined part of `pyconfig.h` that a `--host` cross
/// `./configure` still gets wrong -- i.e. what `cross_fixups` can't state as
/// one fixed answer because the right answer genuinely depends on which
/// architecture is being built for.
///
/// Deliberately tiny, and that is the finding rather than an omission: see
/// `cross_fixups`' doc comment for the four-target `pyconfig.h` diff showing
/// that every other CPU-tied macro is already correct under `--host`. Kept
/// as a struct anyway (rather than folding its one field into an `if` at the
/// call site) so that the next such macro is a field, not a new mechanism.
pub const ArchProfile = struct {
    /// Whether the target's `wchar_t` is a *signed* type.
    ///
    /// `configure.ac`'s `ac_cv_wchar_t_signed` is an `AC_RUN_IFELSE` whose
    /// cross fallback is the conservative "yes"; `HAVE_USABLE_WCHAR_T` is
    /// then defined only when `wchar_t` is at least 2 bytes *and* unsigned
    /// (CPython reads it directly as a code point in that case, and refuses
    /// to when it might be negative). So a cross build for a target whose
    /// `wchar_t` is unsigned silently loses that fast path.
    ///
    /// Signedness is fixed by the psABI, not the libc, and was checked per
    /// target with a `_Static_assert(((wchar_t)-1) < 0)` compiled by
    /// `zig cc`: unsigned on the ARM family (AArch64 and 32-bit ARM alike,
    /// both endiannesses), signed on x86, x86_64, s390x, powerpc64le,
    /// riscv64, mips and loongarch64.
    wchar_t_signed: bool,
    /// Size of the target's `wchar_t`, in bytes. Not available from
    /// `std.Target`'s C-type table (which stops at `long double`), so it is
    /// spelled out here: 2 on Windows (UTF-16 `wchar_t`), 4 everywhere else
    /// this project builds for.
    wchar_t_size: u8,

    pub fn of(target: std.Target) ArchProfile {
        return .{
            .wchar_t_signed = switch (target.cpu.arch) {
                .aarch64, .aarch64_be, .arm, .armeb, .thumb, .thumbeb => false,
                else => true,
            },
            .wchar_t_size = if (target.os.tag == .windows) 2 else 4,
        };
    }

    /// Appends this profile's macros to `out` in `applyPatches` form.
    pub fn appendPatches(self: ArchProfile, gpa: std.mem.Allocator, out: *std.ArrayList(MacroPatch)) void {
        const usable = self.wchar_t_size >= 2 and !self.wchar_t_signed;
        out.append(gpa, .{
            .name = "HAVE_USABLE_WCHAR_T",
            .state = if (usable) .{ .value = "1" } else .undef,
        }) catch @panic("OOM");
    }
};

/// Parses one `-Dpyconfig-define=` value: `NAME=VALUE` -> `.value`, bare
/// `NAME` -> `.flag` (`#define NAME`, no value -- what `AC_DEFINE` with no
/// second argument produces). Same shape as `cc`'s own `-D`, deliberately.
/// Panics on a malformed name: a build-option typo is a developer error.
pub fn parseDefine(spec: []const u8) MacroPatch {
    const eq = std.mem.indexOfScalar(u8, spec, '=');
    const name = if (eq) |i| spec[0..i] else spec;
    validateName(name, spec);
    return .{
        .name = name,
        .state = if (eq) |i| .{ .value = spec[i + 1 ..] } else .flag,
    };
}

/// Parses one `-Dpyconfig-undef=` value: a bare macro name, turned into
/// `/* #undef NAME */`. The counterpart of `parseDefine`, kept a separate
/// option rather than a `NAME=` spelling so that "undefine it" can never be
/// confused with "define it to the empty string".
pub fn parseUndef(spec: []const u8) MacroPatch {
    validateName(spec, spec);
    return .{ .name = spec, .state = .undef };
}

fn validateName(name: []const u8, spec: []const u8) void {
    const ident = takeIdent(name) orelse std.debug.panic(
        "invalid pyconfig macro '{s}': expected a C identifier",
        .{spec},
    );
    if (ident.len != name.len) std.debug.panic(
        "invalid pyconfig macro '{s}': '{s}' is not a C identifier",
        .{ spec, name },
    );
}
