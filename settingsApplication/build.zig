const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const process = b.createModule(.{ .root_source_file = b.path("src/services/process_client.zig"), .target = target, .optimize = optimize, .link_libc = true });
    process.addCSourceFile(.{ .file = b.path("src/services/theme/watch.c"), .flags = &.{"-std=c11"} });
    const backend = b.createModule(.{ .root_source_file = b.path("src/backend/root.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "process", .module = process }} });
    const backend_tests = b.addTest(.{ .root_module = backend });
    backend_tests.root_module.addCSourceFile(.{ .file = b.path("src/services/process.c"), .flags = &.{"-std=c11"} });
    const test_step = b.step("test", "Test models, backend and external commands without a display");
    test_step.dependOn(&b.addRunArtifact(backend_tests).step);
    const driver = b.addExecutable(.{ .name = "aqueous-backend-test", .root_module = b.createModule(.{ .root_source_file = b.path("tests/backend/driver.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "backend", .module = backend }} }) });
    // Regression adapter is installed only by an explicit test-driver build.
    const driver_install = b.addInstallArtifact(driver, .{});
    b.step("test-driver", "Build test-only backend regression adapter").dependOn(&driver_install.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .imports = &.{ .{ .name = "process", .module = process }, .{ .name = "backend", .module = backend } },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });

    test_step.dependOn(&b.addRunArtifact(tests).step);
    if (b.option(bool, "model-only", "Build only display-independent tests") orelse false) return;
    const dep = b.lazyDependency("quark", .{ .target = target, .optimize = optimize }) orelse return;
    const quark = dep.artifact("quark");
    const patched = b.addSystemCommand(&.{"python3"});
    patched.addFileArg(b.path("quark/prepare.py"));
    patched.addDirectoryArg(dep.path("src"));
    const source = patched.addOutputDirectoryArg("quark-src");
    patched.addFileArg(b.path("quark/redesign.py"));
    quark.root_module.root_source_file = source.path(b, "root.zig");
    const ui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "quark", .module = quark.root_module }},
    }) });
    b.step("test-ui-model", "Test widget restyling and ownership without a display").dependOn(&b.addRunArtifact(ui_tests).step);
    const exe = b.addExecutable(.{ .name = "aqueous-settings", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "quark", .module = quark.root_module }, .{ .name = "backend", .module = backend }, .{ .name = "process", .module = process } },
    }) });

    exe.root_module.addCSourceFile(.{ .file = b.path("src/vulkan_present_shim.c"), .flags = &.{"-std=c99"} });
    exe.root_module.linkSystemLibrary("dl", .{});
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Aqueous Settings").dependOn(&run.step);
}
