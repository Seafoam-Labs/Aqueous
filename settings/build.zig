const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const quark = b.dependency("quark", .{}).artifact("quark");
    const exe = b.addExecutable(.{
        .name = "aqueous-settings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "quark", .module = quark.root_module },
            },
        }),
    });
    exe.root_module.linkLibrary(quark);
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/vulkan_present_shim.c"),
        .flags = &.{"-std=c99"},
    });
    exe.root_module.linkSystemLibrary("dl", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run Aqueous Settings");
    run_step.dependOn(&run.step);
}
