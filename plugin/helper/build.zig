const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config_document.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const toolkit_sync_module = b.createModule(.{
        .root_source_file = b.path("src/toolkit_sync.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "aqueous_config_document", .module = config_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "aqueous-config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "aqueous_config_document", .module = config_module },
                .{ .name = "aqueous_toolkit_sync", .module = toolkit_sync_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run aqueous-config").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "aqueous_config_document", .module = config_module },
                .{ .name = "aqueous_toolkit_sync", .module = toolkit_sync_module },
            },
        }),
    });
    b.step("test", "Run aqueous-config tests").dependOn(&b.addRunArtifact(tests).step);
}
