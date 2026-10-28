const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gobject = b.dependency("gobject", .{ .target = target, .optimize = optimize });
    const picker = b.addExecutable(.{
        .name = "aqueous-portal-picker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    inline for (.{ "gtk4", "gdk4", "gdkwayland4", "glib2", "gio2", "gobject2" }) |name|
        picker.root_module.addImport(name, gobject.module(name));
    picker.root_module.linkSystemLibrary("gtk4", .{});
    const options = b.addOptions();
    options.addOption([]const u8, "instance_name", b.option([]const u8, "instance-name", "Desktop package identity") orelse "aqueous");
    options.addOption(bool, "test_hooks", b.option(bool, "test-hooks", "Enable isolated GUI smoke-test hooks") orelse false);
    picker.root_module.addOptions("build_options", options);
    const install = b.addInstallArtifact(picker, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("picker", "Build and install the screen-sharing source picker").dependOn(&install.step);
}
