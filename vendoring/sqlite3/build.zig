//! Minimal local stand-in for `allyourcodebase/sqlite3`: same amalgamation
//! source, same shape of `build.zig` (just the library, no shell/run demo --
//! see this project's `vendored_libraries_plan.md`, "starting with the ones
//! in allyourcodebase" thread, for why upstream's own build.zig can't be
//! used as-is against this project's pinned Zig version).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const src = b.dependency("sqlite3", .{});

    const lib = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addCSourceFile(.{ .file = src.path("sqlite3.c") });
    lib.installHeader(src.path("sqlite3.h"), "sqlite3.h");
    lib.installHeader(src.path("sqlite3ext.h"), "sqlite3ext.h");
    b.installArtifact(lib);
}
