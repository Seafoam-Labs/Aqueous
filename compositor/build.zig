// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const assert = std.debug.assert;
const Build = std.Build;
const fs = std.fs;
const mem = std.mem;

const manifest = @import("build.zig.zon");
const version = manifest.version;

const Scanner = @import("wayland").Scanner;
const Translator = @import("translate_c").Translator;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;
    const use_llvm = b.option(bool, "llvm", "Force use of Zig's LLVM backend and the lld linker") orelse false;

    const omit_frame_pointer = switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        _ = b.findProgram(&.{"scdoc"}, &.{}) catch |err| switch (err) {
            error.FileNotFound => break :scdoc_found false,
        };
        break :scdoc_found true;
    };

    const xwayland = b.option(
        bool,
        "xwayland",
        "Set to true to enable xwayland support",
    ) orelse false;

    const wlroots_pkgconf = "wlroots-0.20";
    const vulkan_effects = b.option(
        bool,
        "vulkan-effects",
        "Enable Aqueous Vulkan effects on the wlroots Vulkan renderer. Defaults to true.",
    ) orelse true;

    const full_version = blk: {
        if (b.option([]const u8, "version-string", "Override `aqueous -version` output.")) |version_override| {
            break :blk version_override;
        } else if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.runAllowFail(
                &.{ "git", "-C", b.build_root.path orelse ".", "describe", "--long" },
                &ret,
                .ignore,
            ) catch break :blk version;

            var it = mem.splitSequence(u8, mem.trim(u8, git_describe_long, &std.ascii.whitespace), "-");
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            assert(it.next() == null);
            assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk b.fmt(version ++ ".{s}+{s}", .{ commit_count, commit_hash[1..] });
        } else {
            break :blk version;
        }
    };

    const animations = b.option(
        bool,
        "animations",
        "Enable compositor-side window position animations (smooth scrolling). Defaults to true.",
    ) orelse true;

    const external_policy = b.option(
        bool,
        "external-policy",
        "Enable the legacy river_window_manager_v1 external/compare policy modes. Defaults to false.",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(bool, "xwayland", xwayland);
    options.addOption(bool, "vulkan_effects", vulkan_effects);
    options.addOption(bool, "animations", animations);
    options.addOption(bool, "external_policy", external_policy);
    options.addOption([]const u8, "version", full_version);

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addSystemProtocol("staging/color-representation/color-representation-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml");
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xwayland-keyboard-grab/xwayland-keyboard-grab-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-foreign/xdg-foreign-unstable-v2.xml");

    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/aqueous-window-info-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-input-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-libinput-config-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-config-v1.xml"));

    scanner.addCustomProtocol(b.path("protocol/upstream/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/upstream/wlr-output-power-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/upstream/wlr-screencopy-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/upstream/virtual-keyboard-unstable-v1.xml"));
    // ext-workspace-v1: vendored pinned copy of the staging protocol merged upstream
    // (wayland-protocols MR !40). wlroots ships no implementation; bindings are generated
    // here for the hand-rolled WorkspaceManager.
    scanner.addCustomProtocol(b.path("protocol/upstream/ext-workspace-v1.xml"));

    // Some of these versions may be out of date with what wlroots implements.
    // This is not a problem in practice though as long as river successfully compiles.
    // These versions control Zig code generation and have no effect on anything internal
    // to wlroots. Therefore, the only thing that can happen due to a version being too
    // old is that river fails to compile.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);

    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("zwp_xwayland_keyboard_grab_manager_v1", 1);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("zxdg_importer_v2", 1);
    scanner.generate("zxdg_exporter_v2", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("ext_foreign_toplevel_list_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("wp_tearing_control_manager_v1", 1);
    scanner.generate("wp_color_manager_v1", 2);
    scanner.generate("wp_color_representation_manager_v1", 1);

    scanner.generate("river_window_manager_v1", 10);
    scanner.generate("aqueous_window_info_manager_v1", 3);
    scanner.generate("river_xkb_bindings_v1", 3);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("river_input_manager_v1", 2);
    scanner.generate("river_libinput_config_v1", 2);
    scanner.generate("river_xkb_config_v1", 2);

    scanner.generate("zwlr_output_power_manager_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
    scanner.generate("ext_workspace_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");

    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // We need to ensure the wlroots include path obtained from pkg-config is
    // exposed to the wlroots module for @cImport() to work. This seems to be
    // the best way to do so with the current std.Build API.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary(wlroots_pkgconf, .{});

    const flags = b.createModule(.{ .root_source_file = b.path("common/flags.zig") });
    const slotmap = b.createModule(.{ .root_source_file = b.path("common/slotmap.zig") });

    const translate_c: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "c",
        .c_source_file = b.path("aqueous/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("libevdev", .{});
    translate_c.linkSystemLibrary("libinput", .{});
    if (vulkan_effects) {
        translate_c.linkSystemLibrary(wlroots_pkgconf, .{});
        translate_c.linkSystemLibrary("vulkan", .{});
        translate_c.defineCMacro("RIVER_VULKAN_EFFECTS", null);
        translate_c.defineCMacro("WLR_USE_UNSTABLE", null);
    }

    {
        const river = b.addExecutable(.{
            .name = "aqueous",
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/main.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        river.build_id = .sha1;
        river.root_module.addOptions("build_options", options);

        river.root_module.linkSystemLibrary("libevdev", .{});
        river.root_module.linkSystemLibrary("libinput", .{});
        river.root_module.linkSystemLibrary("wayland-server", .{});
        river.root_module.linkSystemLibrary(wlroots_pkgconf, .{});
        if (vulkan_effects) {
            river.root_module.linkSystemLibrary("vulkan", .{});
            river.root_module.addRPathSpecial("$ORIGIN/../lib/aqueous");
        }
        river.root_module.linkSystemLibrary("xkbcommon", .{});
        river.root_module.linkSystemLibrary("pixman-1", .{});

        river.root_module.addImport("wayland", wayland);
        river.root_module.addImport("xkbcommon", xkbcommon);
        river.root_module.addImport("pixman", pixman);
        river.root_module.addImport("wlroots", wlroots);
        river.root_module.addImport("flags", flags);
        river.root_module.addImport("slotmap", slotmap);
        river.root_module.addImport("c", translate_c.mod);

        river.root_module.addCSourceFile(.{
            .file = b.path("aqueous/wlroots_log_wrapper.c"),
            .flags = &.{ "-std=c99", "-O2" },
        });

        river.pie = pie;
        river.root_module.omit_frame_pointer = omit_frame_pointer;

        b.installArtifact(river);
        if (vulkan_effects) {
            const library = b.option(
                []const u8,
                "wlroots-render-hook-library",
                "Path to the patched wlroots shared library installed with Aqueous.",
            ) orelse findWlrootsRenderHook(b) orelse std.process.fatal(
                "unable to locate libwlroots-0.20.so for the Vulkan effects install",
                .{},
            );
            b.getInstallStep().dependOn(&b.addInstallFile(
                .{ .cwd_relative = library },
                "lib/aqueous/libwlroots-0.20.so",
            ).step);
        }
    }

    {
        const aqueousctl = b.addExecutable(.{
            .name = "aqueousctl",
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueousctl/main.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        aqueousctl.root_module.addImport("wayland", wayland);
        aqueousctl.root_module.linkSystemLibrary("wayland-client", .{});
        aqueousctl.pie = pie;
        aqueousctl.root_module.omit_frame_pointer = omit_frame_pointer;
        b.installArtifact(aqueousctl);
    }

    {
        const wf = Build.Step.WriteFile.create(b);
        const pc_file = wf.add("aqueous-protocols.pc", b.fmt(
            \\prefix={s}
            \\datarootdir=${{prefix}}/share
            \\pkgdatadir=${{pc_sysrootdir}}${{datarootdir}}/aqueous-protocols
            \\
            \\Name: aqueous-protocols
            \\URL: https://github.com/Seafoam-Labs/Aqueous
            \\Description: Wayland protocol files provided by Aqueous
            \\Version: {s}
        , .{ b.install_prefix, full_version }));
        b.getInstallStep().dependOn(&b.addInstallFile(pc_file, "share/pkgconfig/aqueous-protocols.pc").step);
        inline for (&.{
            "river-window-management-v1.xml",
            "aqueous-window-info-v1.xml",
            "river-xkb-bindings-v1.xml",
            "river-layer-shell-v1.xml",
            "river-input-management-v1.xml",
            "river-libinput-config-v1.xml",
            "river-xkb-config-v1.xml",
        }) |protocol| {
            b.installFile("protocol/" ++ protocol, "share/aqueous-protocols/stable/" ++ protocol);
        }
    }

    if (man_pages) {
        inline for (.{ "aqueous", "aqueousctl" }) |page| {
            // Workaround for https://github.com/ziglang/zig/issues/16369
            // Even passing a buffer to std.Build.Step.Run appears to be racy and occasionally deadlocks.
            const scdoc = b.addSystemCommand(&.{ "/bin/sh", "-c", "scdoc < doc/" ++ page ++ ".1.scd" });
            // This makes the caching work for the Workaround, and the extra argument is ignored by /bin/sh.
            scdoc.addFileArg(b.path("doc/" ++ page ++ ".1.scd"));

            const stdout = scdoc.captureStdOut(.{});
            b.getInstallStep().dependOn(&b.addInstallFile(stdout, "share/man/man1/" ++ page ++ ".1").step);
        }
    }

    {
        const slotmap_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("common/slotmap.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_slotmap_test = b.addRunArtifact(slotmap_test);

        const effect_metadata_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/render/EffectMetadata.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        effect_metadata_test.root_module.addImport("wayland", wayland);
        effect_metadata_test.root_module.addImport("wlroots", wlroots);
        effect_metadata_test.root_module.addImport("slotmap", slotmap);
        const run_effect_metadata_test = b.addRunArtifact(effect_metadata_test);

        const output_hdr_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/output_hdr.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        output_hdr_test.root_module.addImport("wlroots", wlroots);
        const run_output_hdr_test = b.addRunArtifact(output_hdr_test);

        const global_filter_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/global_filter.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_global_filter_test = b.addRunArtifact(global_filter_test);

        const blur_cache_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/render/BlurCache.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_blur_cache_test = b.addRunArtifact(blur_cache_test);

        const scaling_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/scaling.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_scaling_test = b.addRunArtifact(scaling_test);

        const visual_state_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/visual_state.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_visual_state_test = b.addRunArtifact(visual_state_test);

        const cursor_lock_restore_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/cursor_lock_restore.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_cursor_lock_restore_test = b.addRunArtifact(cursor_lock_restore_test);

        const aqueous_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/Mode.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_aqueous_test = b.addRunArtifact(aqueous_test);

        const trace_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/Trace.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_trace_test = b.addRunArtifact(trace_test);

        const config_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/config_tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_config_test = b.addRunArtifact(config_test);

        const layout_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/layout/tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_layout_test = b.addRunArtifact(layout_test);

        const overview_model_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/overview_tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_overview_model_test = b.addRunArtifact(overview_model_test);

        const rules_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/rules/tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_rules_test = b.addRunArtifact(rules_test);

        const focus_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/focus/tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_focus_test = b.addRunArtifact(focus_test);

        const output_navigation_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/output/navigation.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_output_navigation_test = b.addRunArtifact(output_navigation_test);

        const input_drag_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/input_tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_input_drag_test = b.addRunArtifact(input_drag_test);

        const workspaces_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueous/wm/workspaces/coalescer.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        const run_workspaces_test = b.addRunArtifact(workspaces_test);

        const aqueousctl_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("aqueousctl/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        aqueousctl_test.root_module.addImport("wayland", wayland);
        aqueousctl_test.root_module.linkSystemLibrary("wayland-client", .{});
        const run_aqueousctl_test = b.addRunArtifact(aqueousctl_test);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&run_slotmap_test.step);
        test_step.dependOn(&run_effect_metadata_test.step);
        test_step.dependOn(&run_output_hdr_test.step);
        test_step.dependOn(&run_global_filter_test.step);
        test_step.dependOn(&run_blur_cache_test.step);
        test_step.dependOn(&run_scaling_test.step);
        test_step.dependOn(&run_visual_state_test.step);
        test_step.dependOn(&run_cursor_lock_restore_test.step);
        test_step.dependOn(&run_aqueous_test.step);
        test_step.dependOn(&run_trace_test.step);
        test_step.dependOn(&run_config_test.step);
        test_step.dependOn(&run_layout_test.step);
        test_step.dependOn(&run_overview_model_test.step);
        test_step.dependOn(&run_rules_test.step);
        test_step.dependOn(&run_focus_test.step);
        test_step.dependOn(&run_output_navigation_test.step);
        test_step.dependOn(&run_input_drag_test.step);
        test_step.dependOn(&run_workspaces_test.step);
        test_step.dependOn(&run_aqueousctl_test.step);
    }
}

fn findWlrootsRenderHook(b: *Build) ?[]const u8 {
    if (b.graph.environ_map.get("PKG_CONFIG_PATH")) |paths| {
        var it = mem.splitScalar(u8, paths, ':');
        while (it.next()) |pkgconfig_dir| {
            const pc_file = b.pathJoin(&.{ pkgconfig_dir, "wlroots-0.20.pc" });
            std.Io.Dir.cwd().access(b.graph.io, pc_file, .{}) catch continue;
            const libdir = fs.path.dirname(pkgconfig_dir) orelse continue;
            const library = b.pathJoin(&.{ libdir, "libwlroots-0.20.so" });
            std.Io.Dir.cwd().access(b.graph.io, library, .{}) catch continue;
            return library;
        }
    }

    var ret: u8 = 1;
    const output = b.runAllowFail(
        &.{ "pkg-config", "--variable=libdir", "wlroots-0.20" },
        &ret,
        .ignore,
    ) catch "";
    if (ret == 0) {
        const libdir = mem.trim(u8, output, &std.ascii.whitespace);
        const library = b.pathJoin(&.{ libdir, "libwlroots-0.20.so" });
        std.Io.Dir.cwd().access(b.graph.io, library, .{}) catch return null;
        return library;
    }

    const candidates = [_][]const u8{
        "/usr/local/lib/libwlroots-0.20.so",
        "/usr/lib/libwlroots-0.20.so",
    };
    for (candidates) |library| {
        std.Io.Dir.cwd().access(b.graph.io, library, .{}) catch continue;
        return library;
    }
    return null;
}
