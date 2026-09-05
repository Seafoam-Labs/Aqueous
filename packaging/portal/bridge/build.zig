const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    b.installArtifact(b.addExecutable(.{ .name = "aqueous-dms-portal-chooser", .root_module = module }));
}
