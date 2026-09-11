//! Resolves which CPython source tree the rest of build.zig builds against.
//!
//! Two mutually-exclusive ways to pick one:
//!
//! - `-Dcpython-path=<dir>`: an already-extracted source tree on disk (e.g.
//!   the checked-in `cpython/` submodule, or a local patched checkout).
//!   Bypasses everything below.
//! - `-Dcpython-version=<name>` (default: `default_version`): a
//!   `build.zig.zon`-declared dependency, fetched lazily so picking one
//!   version never downloads the others. `<name>` isn't limited to the
//!   versions curated in build.zig.zon: `zig fetch --save=<name>
//!   <url-or-git-ref>` (Zig's own fetcher -- no system `git` needed, works
//!   for a tarball or a `git+https://` ref) adds any CPython source under a
//!   name of your choosing, which this option then picks up the same way.
//!
//! Both end up producing a real, writable, on-disk directory either way
//! (this pinned Zig fetches dependencies into a project-local, non-read-only
//! `zig-pkg/` -- confirmed empirically, unlike the historical read-only
//! global package cache older Zig versions used): `Utils.runConfigure`
//! genuinely runs `./configure` there and writes `Makefile`/`pyconfig.h`/its
//! own stamp file back into that same directory, exactly as it always has
//! for the submodule checkout.
const std = @import("std");
const ArchiveRoot = @import("archive_root.zig");

pub const default_version = "3.12.13";

pub const Source = struct {
    dir: std.Build.LazyPath,
    dir_str: []const u8,
};

/// Returns `null` when the selected `-Dcpython-version=` dependency hasn't
/// been fetched yet. The caller must bail out of the whole build immediately
/// in that case (no steps added this pass) so `zig build`'s "fetch pending
/// lazy dependencies, then rerun build.zig" flow can do its job: unlike a
/// dependency only consumed from inside a `Step.make` callback, this
/// project's `Utils.runConfigure` touches the resolved directory eagerly,
/// synchronously, while the build graph is still being constructed -- there
/// is no later point at which a missing directory would fail more
/// gracefully than right here.
pub fn resolve(b: *std.Build) ?Source {
    const build_root = b.root.root_dir.path orelse @panic("expected absolute build root path");

    if (b.option(
        []const u8,
        "cpython-path",
        "Use an already-extracted CPython source tree at this path (relative to the project root, or absolute) instead of a build.zig.zon dependency -- e.g. -Dcpython-path=cpython for the checked-in submodule. Bypasses -Dcpython-version entirely.",
    )) |path| {
        if (std.fs.path.isAbsolute(path))
            return .{ .dir = b.graph.cwdRelativePath(path), .dir_str = path };
        return .{ .dir = b.path(path), .dir_str = b.pathJoin(&.{ build_root, path }) };
    }

    const version = b.option(
        []const u8,
        "cpython-version",
        b.fmt(
            "CPython version to build, as a dependency name declared in build.zig.zon (default: {s}). `zig fetch --save=<name> <url-or-git-ref>` adds a custom one to pick here -- see build.zig.zon's own comment on this.",
            .{default_version},
        ),
    ) orelse default_version;

    const dep = b.lazyDependency(version, .{}) orelse return null;
    const fetched_dir_str = dep.builder.root.root_dir.path orelse
        std.debug.panic("expected absolute cpython dependency root path for '{s}'", .{version});
    // A release tarball (e.g. python.org's) wraps its whole tree in one
    // `Python-X.Y.Z/`-shaped directory. Whether this pinned Zig's fetcher strips
    // that wrapper turns out to be inconsistent -- confirmed empirically across
    // otherwise-identically-shaped python.org tarballs for different versions,
    // same wrapped-single-directory layout on disk before fetching, yet one
    // fetch left it in place and another stripped it (see `ArchiveRoot`).
    // Marker is `configure` specifically (not e.g. `setup.py`, which 3.14
    // dropped) since it's present at every supported version's true root and
    // it's the exact file `Utils.runConfigure` is about to invoke anyway.
    const sub_path = ArchiveRoot.resolve(b, fetched_dir_str, "configure");
    return .{ .dir = dep.path(sub_path), .dir_str = b.pathJoin(&.{ fetched_dir_str, sub_path }) };
}
