const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const scaling = b.createModule(.{ .root_source_file = b.path("../compositor/aqueous/scaling.zig"), .target = target, .optimize = optimize });
    const tablet = b.createModule(.{ .root_source_file = b.path("../compositor/common/tablet.zig"), .target = target, .optimize = optimize });
    const display_config = b.createModule(.{ .root_source_file = b.path("../compositor/aqueous/DisplayConfig.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "scaling", .module = scaling }, .{ .name = "tablet", .module = tablet } } });
    const process = b.createModule(.{ .root_source_file = b.path("src/services/process_client.zig"), .target = target, .optimize = optimize, .link_libc = true });
    process.addCSourceFile(.{ .file = b.path("src/services/process.c"), .flags = &.{"-std=c11"} });
    const backend = b.createModule(.{ .root_source_file = b.path("src/backend/root.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "process", .module = process }} });
    backend.addImport("display_config", display_config);
    const backend_tests = b.addTest(.{ .root_module = backend });
    const test_step = b.step("test", "Test the canonical backend and subprocess runtime");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = display_config })).step);
    test_step.dependOn(&b.addRunArtifact(backend_tests).step);
    const config_cli = b.createModule(.{ .root_source_file = b.path("src/config_main.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "backend", .module = backend }} });
    const production_options = b.addOptions();
    production_options.addOption(bool, "fault_injection", false);
    config_cli.addOptions("build_options", production_options);
    const driver_cli = b.createModule(.{ .root_source_file = b.path("src/config_main.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "backend", .module = backend }} });
    const driver_options = b.addOptions();
    driver_options.addOption(bool, "fault_injection", true);
    driver_cli.addOptions("build_options", driver_options);
    const helper = b.addExecutable(.{ .name = "aqueous-config", .root_module = config_cli });
    const helper_install = b.addInstallArtifact(helper, .{});
    b.getInstallStep().dependOn(&helper_install.step);
    b.step("config", "Build the canonical aqueous-config helper").dependOn(&helper_install.step);
    const driver = b.addExecutable(.{ .name = "aqueous-backend-test", .root_module = driver_cli });
    // Regression adapter is installed only by an explicit test-driver build.
    const driver_install = b.addInstallArtifact(driver, .{});
    b.step("test-driver", "Build test-only backend regression adapter").dependOn(&driver_install.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = process })).step);
    // Accept existing build invocations; every build is now helper-only.
    _ = b.option(bool, "helper-only", "Compatibility option: the GUI has been retired");
    _ = b.option(bool, "model-only", "Compatibility option: all tests are display-independent");
}
