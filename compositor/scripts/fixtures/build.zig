const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const translator = b.dependency("translate_c", .{});
    const gpu_c: Translator = .init(translator, .{
        .c_source_file = b.path("gpu-observer.h"),
        .target = target,
        .optimize = optimize,
    });
    const observer_module = b.createModule(.{
        .root_source_file = b.path("gpu-observer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    observer_module.addImport("c", gpu_c.mod);
    observer_module.linkSystemLibrary("dl", .{});
    const observer = b.addLibrary(.{ .name = "gpu-observer", .root_module = observer_module, .linkage = .dynamic });
    const client_module = b.createModule(.{
        .root_source_file = b.path("gpu-observer-client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const client_c: Translator = .init(translator, .{
        .c_source_file = b.path("gpu-observer-client.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{.{ .name = "vulkan" }},
    });
    client_module.addImport("c", client_c.mod);
    const client = b.addExecutable(.{ .name = "gpu-observer-client", .root_module = client_module });
    const gpu_step = b.step("gpu-observer", "Build the Vulkan observer and its test client");
    gpu_step.dependOn(&b.addInstallArtifact(observer, .{}).step);
    gpu_step.dependOn(&b.addInstallArtifact(client, .{}).step);

    const dpi_c: Translator = .init(translator, .{
        .c_source_file = b.path("../../aqueous/xwayland_dpi.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{.{ .name = "xcb" }},
    });
    const dpi_module = b.createModule(.{
        .root_source_file = b.path("../../aqueous/xwayland_dpi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dpi_module.addImport("xwayland_c", dpi_c.mod);
    const dpi = b.addExecutable(.{ .name = "xwayland-dpi-test", .root_module = dpi_module, .use_llvm = true, .use_lld = true });
    b.step("dpi", "Build the isolated Xwayland DPI worker fixture").dependOn(&b.addInstallArtifact(dpi, .{}).step);
}
