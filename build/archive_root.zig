//! Finds the real source root inside a fetched dependency whose upstream
//! archive may or may not wrap its contents in one top-level directory --
//! this pinned Zig's fetcher is inconsistent about stripping that wrapper
//! (confirmed empirically: CPython's python.org release tarball keeps it,
//! OpenSSL's GitHub release tarball doesn't, for the same Zig binary), so
//! every vendored dependency that fetches a real upstream archive needs
//! this rather than assuming either shape.

const std = @import("std");

/// `dir_str` is a fetched dependency's root, as an absolute path. `marker`
/// is a file known to sit at the real source root (CPython's `configure`,
/// OpenSSL's `Configure`, ...). Returns `""` if `dir_str` already holds
/// `marker` directly, or the name of the single wrapper directory to
/// descend into.
pub fn resolve(b: *std.Build, dir_str: []const u8, marker: []const u8) []const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, b.pathJoin(&.{ dir_str, marker }), .{}) catch {
        var dir = cwd.openDir(io, dir_str, .{ .iterate = true }) catch |err|
            std.debug.panic("failed to open fetched source dir {s}: {t}", .{ dir_str, err });
        defer dir.close(io);
        var it = dir.iterate();
        const first = (it.next(io) catch |err|
            std.debug.panic("failed to read {s}: {t}", .{ dir_str, err })) orelse
            std.debug.panic("fetched source dir {s} is empty", .{dir_str});
        const second = it.next(io) catch |err|
            std.debug.panic("failed to read {s}: {t}", .{ dir_str, err });
        if (first.kind != .directory or second != null)
            std.debug.panic(
                "fetched source dir {s} has no {s} at its root and isn't a single wrapping directory either -- unexpected archive layout",
                .{ dir_str, marker },
            );
        return b.dupe(first.name);
    };
    return "";
}
