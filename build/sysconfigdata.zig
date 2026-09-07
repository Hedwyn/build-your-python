//! Synthesizes the `_sysconfigdata_<abiflags>_<platform>_<multiarch>.py`
//! module that CPython's own `sysconfig.py` (`_get_sysconfigdata_name` /
//! `_init_posix`) `__import__`s at runtime for `get_config_vars()`,
//! `get_paths()`, `get_platform()`, etc. Upstream generates this file by
//! running the freshly built interpreter (`python -S -m sysconfig
//! --generate-posix-vars`, see `Makefile.pre.in`'s `pybuilddir.txt` rule) --
//! we instead derive it directly from data build.zig already has on hand
//! (the parsed Makefile, plus pyconfig.h), mirroring
//! `sysconfig._parse_makefile` / `parse_config_h` closely enough to produce
//! the same keys. Without this file, any `sysconfig.get_*` call -- and
//! everything built on it (`pydoc`, `site.getsitepackages()`, `ensurepip`,
//! `venv`) -- fails with `ModuleNotFoundError` at runtime.

const std = @import("std");
const Makefile = @import("makefile.zig");

const Value = union(enum) {
    int: i64,
    str: []const u8,
};

pub const Vars = std.StringHashMap(Value);

/// Every top-level "NAME = value" assignment in `mk`, expanded and
/// classified str/int exactly like `sysconfig._parse_makefile`'s `int(v)`
/// fallback. Deliberately excludes "NAME := value" assignments -- CPython's
/// own `_variable_rx` (`([a-zA-Z][a-zA-Z0-9_]+)\s*=\s*(.*)`) requires a
/// literal `=` right after the name, so those are invisible to it too (e.g.
/// this Makefile's BOLT_* vars).
pub fn fromMakefile(gpa: std.mem.Allocator, mk: Makefile) Vars {
    var vars = Vars.init(gpa);
    var lines = std.mem.splitScalar(u8, mk.text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const name = matchAssignName(line) orelse continue;
        if (vars.contains(name)) continue; // first occurrence wins, as Makefile.getRaw does
        const value = std.mem.trim(u8, mk.expand(gpa, mk.getRaw(gpa, name)), " \t");
        vars.put(name, classify(value)) catch @panic("OOM");
    }
    return vars;
}

/// Merges `#define NAME value` / `/* #undef NAME */` lines from a
/// pyconfig.h-style file into `vars`, overwriting on key collision --
/// mirrors `parse_config_h(fp, vars)` being called with the Makefile vars
/// already in `vars`.
pub fn mergeConfigH(vars: *Vars, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (matchDefine(line)) |kv| {
            vars.put(kv.name, classify(kv.value)) catch @panic("OOM");
        } else if (matchUndef(line)) |name| {
            vars.put(name, .{ .int = 0 }) catch @panic("OOM");
        }
    }
}

pub fn moduleName(gpa: std.mem.Allocator, abiflags: []const u8, platform: []const u8, multiarch: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "_sysconfigdata_{s}_{s}_{s}", .{ abiflags, platform, multiarch }) catch @panic("OOM");
}

/// Renders `vars` as the `.py` source `sysconfig._init_posix` expects:
/// a `build_time_vars = {...}` dict literal.
pub fn render(gpa: std.mem.Allocator, vars: Vars) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(gpa, "# system configuration generated and used by the sysconfig module\n") catch @panic("OOM");
    out.appendSlice(gpa, "build_time_vars = {\n") catch @panic("OOM");
    var it = vars.iterator();
    while (it.next()) |entry| {
        out.appendSlice(gpa, "    ") catch @panic("OOM");
        writePyStr(gpa, &out, entry.key_ptr.*);
        out.appendSlice(gpa, ": ") catch @panic("OOM");
        switch (entry.value_ptr.*) {
            .int => |n| out.appendSlice(gpa, std.fmt.allocPrint(gpa, "{d}", .{n}) catch @panic("OOM")) catch @panic("OOM"),
            .str => |s| writePyStr(gpa, &out, s),
        }
        out.appendSlice(gpa, ",\n") catch @panic("OOM");
    }
    out.appendSlice(gpa, "}\n") catch @panic("OOM");
    return out.items;
}

fn matchAssignName(line: []const u8) ?[]const u8 {
    if (!std.ascii.isAlphabetic(line[0])) return null;
    var end: usize = 1;
    while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
    if (end < 2) return null;
    const rest = std.mem.trimStart(u8, line[end..], " \t");
    if (rest.len == 0 or rest[0] != '=') return null; // excludes ":=" -- see doc comment above
    return line[0..end];
}

const NameValue = struct { name: []const u8, value: []const u8 };

fn matchDefine(line: []const u8) ?NameValue {
    const prefix = "#define ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    if (rest.len == 0 or rest[0] < 'A' or rest[0] > 'Z') return null;
    var end: usize = 1;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
    if (end < 2) return null;
    if (end >= rest.len or rest[end] != ' ') return null; // excludes function-like macros, e.g. "FOO(x)"
    return .{ .name = rest[0..end], .value = rest[end + 1 ..] };
}

fn matchUndef(line: []const u8) ?[]const u8 {
    const prefix = "/* #undef ";
    const suffix = " */";
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, suffix)) return null;
    const name = line[prefix.len .. line.len - suffix.len];
    if (name.len < 2 or name[0] < 'A' or name[0] > 'Z') return null;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return name;
}

fn classify(value: []const u8) Value {
    if (value.len > 0) {
        if (std.fmt.parseInt(i64, value, 10) catch null) |n| return .{ .int = n };
    }
    return .{ .str = value };
}

fn writePyStr(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.append(gpa, '\'') catch @panic("OOM");
    for (s) |c| {
        switch (c) {
            '\\' => out.appendSlice(gpa, "\\\\") catch @panic("OOM"),
            '\'' => out.appendSlice(gpa, "\\'") catch @panic("OOM"),
            '\n' => out.appendSlice(gpa, "\\n") catch @panic("OOM"),
            '\r' => out.appendSlice(gpa, "\\r") catch @panic("OOM"),
            '\t' => out.appendSlice(gpa, "\\t") catch @panic("OOM"),
            else => out.append(gpa, c) catch @panic("OOM"),
        }
    }
    out.append(gpa, '\'') catch @panic("OOM");
}
