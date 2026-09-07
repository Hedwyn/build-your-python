//! Reads `<ClCompile Include="...">` source lists out of a `PCbuild/*.vcxproj`
//! file (MSBuild XML), so build.zig can drive Windows compilation directly
//! instead of invoking MSBuild -- the Windows analog of what makefile.zig
//! does for the POSIX `./configure`-generated Makefile. Treated purely as
//! data: never executed, only parsed.
//!
//! No general XML parser: every `ClCompile` entry of interest is a single,
//! well-formed line (`<ClCompile Include="..\Foo\bar.c" />` or the same
//! opening tag followed by per-file overrides and a closing `</ClCompile>`),
//! so plain substring scanning suffices.

const std = @import("std");

const include_prefix = "<ClCompile Include=\"";

/// `"..\\Foo\\bar.c"` (a vcxproj path, relative to `PCbuild/`) -> `"Foo/bar.c"`
/// (cpython-root-relative, forward slashes) -- every vcxproj path used here
/// starts with `..\` since `PCbuild/` is one level below the cpython root.
fn normalize(gpa: std.mem.Allocator, path: []const u8) []const u8 {
    var rel = path;
    if (std.mem.startsWith(u8, rel, "..\\")) rel = rel["..\\".len..];
    const out = gpa.alloc(u8, rel.len) catch @panic("OOM");
    for (rel, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out;
}

/// Every `<ClCompile Include="...">` source path in `text`, in file order,
/// normalized to cpython-root-relative forward-slash paths. Skips entries
/// under an item-group `Condition=` (e.g. ARM-only or PGInstrument-only
/// sources) this parser doesn't evaluate -- callers only ever hand this the
/// small subset of `.vcxproj` files (`_freeze_module`, `pythoncore`) whose
/// unconditional `ClCompile` list is exactly what's wanted. Also skips any
/// entry whose path still contains an unexpanded `$(...)` MSBuild property
/// (e.g. `pythoncore.vcxproj`'s `$(zlibDir)`-rooted vendored-zlib sources,
/// gated behind `Condition="$(IncludeExternals)"`): never a real file this
/// parser can resolve, and always an optional vendored dependency this
/// project would instead provide its own way (see windows.md).
pub fn sources(gpa: std.mem.Allocator, text: []const u8) [][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, include_prefix)) continue;
        const rest = trimmed[include_prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        if (std.mem.indexOf(u8, rest[0..end], "$(") != null) continue;
        list.append(gpa, normalize(gpa, rest[0..end])) catch @panic("OOM");
    }
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}
