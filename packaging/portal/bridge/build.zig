const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const c: @import("translate_c").Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("main.h"),
        .target = target,
        .optimize = optimize,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("c", c.mod);
    b.installArtifact(b.addExecutable(.{ .name = "aqueous-dms-portal-chooser", .root_module = module }));
}
