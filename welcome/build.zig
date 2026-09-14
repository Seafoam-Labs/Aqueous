const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gobject = b.dependency("gobject", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "aqueous-welcome",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    inline for (.{ "gtk4", "glib2", "gio2", "gobject2" }) |name|
        exe.root_module.addImport(name, gobject.module(name));
    exe.root_module.linkSystemLibrary("gtk4", .{});
    const options = b.addOptions();
    const instance_name = b.option([]const u8, "instance-name", "Desktop package identity") orelse "aqueous";
    const test_hooks = b.option(bool, "test-hooks", "Enable isolated GUI smoke-test hooks") orelse false;
    options.addOption([]const u8, "instance_name", instance_name);
    options.addOption(bool, "test_hooks", test_hooks);
    const metadata = b.addWriteFiles().add("build-instance.json", b.fmt("{{\"schema\":1,\"instance\":\"{s}\",\"test_hooks\":{s}}}\n", .{ instance_name, if (test_hooks) "true" else "false" }));
    b.getInstallStep().dependOn(&b.addInstallFile(metadata, "share/aqueous/build-instance.json").step);
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run Welcome to Aqueous");
    run_step.dependOn(&run.step);

    const settings_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_settings_tests = b.addRunArtifact(settings_tests);
    const test_step = b.step("test", "Run Aqueous welcome tests");
    test_step.dependOn(&run_settings_tests.step);
    const backend_tests = b.addSystemCommand(&.{"bash"});
    backend_tests.addFileArg(b.path("tests/test-worker.sh"));
    backend_tests.addArtifactArg(exe);
    test_step.dependOn(&backend_tests.step);
}
