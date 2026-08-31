// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Aqueous-specific extension of ext_foreign_toplevel_handle_v1.
//! Snapshot requests retain no Window pointer; layout control is output-scoped.

const WindowInfoManager = @This();

const std = @import("std");
const build_options = @import("build_options");
const wl = @import("wayland").server.wl;
const aqueous = @import("wayland").server.aqueous;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const Aqueous = @import("wm/Aqueous.zig");
const util = @import("util.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(manager: *WindowInfoManager) !void {
    manager.* = .{
        .global = try wl.Global.create(
            server.wl_server,
            aqueous.WindowInfoManagerV1,
            5,
            *WindowInfoManager,
            manager,
            bind,
        ),
    };
    server.wl_server.addDestroyListener(&manager.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const manager: *WindowInfoManager = @fieldParentPtr("server_destroy", listener);
    manager.global.destroy();
}

fn bind(client: *wl.Client, _: *WindowInfoManager, version: u32, id: u32) void {
    const resource = aqueous.WindowInfoManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(?*anyopaque, handleManagerRequest, null, null);
}

fn handleManagerRequest(
    resource: *aqueous.WindowInfoManagerV1,
    request: aqueous.WindowInfoManagerV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .get_window_info => |args| sendSnapshot(resource, args.id, args.toplevel),
        .get_scene_snapshot => |args| sendSceneSnapshot(resource, args.id),
        .get_overlay_plane_snapshot => |args| sendOverlayPlaneSnapshot(resource, args.id),
        .get_active_workspace_layout => |args| sendActiveWorkspaceLayout(resource, std.mem.span(args.output)),
        .set_active_workspace_layout => |args| {
            const output = std.mem.span(args.output);
            const status = server.aqueous.setActiveWorkspaceLayout(output, std.mem.span(args.layout));
            if (status == .success) {
                sendActiveWorkspaceLayout(resource, output);
            } else {
                resource.sendActiveWorkspaceLayout(
                    @enumFromInt(@intFromEnum(status)),
                    args.output,
                    0,
                    "",
                );
            }
        },
        .destroy => {},
    }
}

fn splitU64(value: u64) struct { u32, u32 } {
    return .{ @truncate(value >> 32), @truncate(value) };
}

fn sendOverlayPlaneSnapshot(manager: *aqueous.WindowInfoManagerV1, id: u32) void {
    const snapshot = aqueous.OverlayPlaneSnapshotV1.create(manager.getClient(), 1, id) catch {
        manager.getClient().postNoMemory();
        return;
    };
    snapshot.setHandler(?*anyopaque, handleOverlayPlaneSnapshotRequest, null, null);

    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        const wlr_output = output.wlr_output orelse continue;
        const state = output.overlaySnapshot();
        const candidate_hi, const candidate_lo = splitU64(state.candidate_id);
        const modifier_hi, const modifier_lo = splitU64(state.modifier);
        snapshot.sendOutputState(
            wlr_output.name,
            @intFromBool(state.enabled),
            @enumFromInt(@intFromEnum(state.capability)),
            @enumFromInt(@intFromEnum(state.phase)),
            @enumFromInt(@intFromEnum(state.reason)),
            candidate_hi,
            candidate_lo,
            state.destination.x,
            state.destination.y,
            state.destination.width,
            state.destination.height,
            state.format,
            modifier_hi,
            modifier_lo,
            state.backoff_remaining_ms,
        );
        const attempts_hi, const attempts_lo = splitU64(state.counters.attempts);
        const accepted_hi, const accepted_lo = splitU64(state.counters.accepted_tests);
        const rejected_hi, const rejected_lo = splitU64(state.counters.backend_rejections);
        const skips_hi, const skips_lo = splitU64(state.counters.backoff_skips);
        const fallback_hi, const fallback_lo = splitU64(state.counters.fallback_retries);
        const promotions_hi, const promotions_lo = splitU64(state.counters.promotions);
        const demotions_hi, const demotions_lo = splitU64(state.counters.demotions);
        snapshot.sendOutputCounters(
            wlr_output.name,
            attempts_hi,
            attempts_lo,
            accepted_hi,
            accepted_lo,
            rejected_hi,
            rejected_lo,
            skips_hi,
            skips_lo,
            fallback_hi,
            fallback_lo,
            promotions_hi,
            promotions_lo,
            demotions_hi,
            demotions_lo,
        );
    }
    snapshot.sendDone();
}

fn handleOverlayPlaneSnapshotRequest(
    _: *aqueous.OverlayPlaneSnapshotV1,
    request: aqueous.OverlayPlaneSnapshotV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => {},
    }
}

fn sendActiveWorkspaceLayout(manager: *aqueous.WindowInfoManagerV1, output: []const u8) void {
    const output_z = std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}", .{output}, 0) catch {
        manager.getClient().postNoMemory();
        return;
    };
    defer std.heap.c_allocator.free(output_z);
    const current = server.aqueous.activeWorkspaceLayout(output) orelse {
        manager.sendActiveWorkspaceLayout(.output_not_found, output_z.ptr, 0, "");
        return;
    };
    manager.sendActiveWorkspaceLayout(
        .success,
        output_z.ptr,
        current.workspace,
        Aqueous.layoutName(current.layout).ptr,
    );
}

fn sendSceneSnapshot(manager: *aqueous.WindowInfoManagerV1, id: u32) void {
    const snapshot = aqueous.SceneSnapshotV1.create(manager.getClient(), 1, id) catch {
        manager.getClient().postNoMemory();
        return;
    };
    snapshot.setHandler(?*anyopaque, handleSceneSnapshotRequest, null, null);

    var context: SceneSnapshotContext = .{ .snapshot = snapshot };
    sendSceneNode(&context, &server.scene.wlr_scene.tree.node, 0);
    snapshot.sendDone();
}

fn handleSceneSnapshotRequest(
    _: *aqueous.SceneSnapshotV1,
    request: aqueous.SceneSnapshotV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => {},
    }
}

const SceneSnapshotContext = struct {
    snapshot: *aqueous.SceneSnapshotV1,
    next_id: u32 = 1,
};

fn sendSceneNode(context: *SceneSnapshotContext, node: *wlr.SceneNode, parent_id: u32) void {
    const id = context.next_id;
    context.next_id +%= 1;
    if (context.next_id == 0) context.next_id = 1;

    var label_buffer: [512]u8 = undefined;
    const label = sceneNodeLabel(node, &label_buffer);
    const width, const height = sceneNodeDimensions(node);
    context.snapshot.sendNode(
        id,
        parent_id,
        label.ptr,
        switch (node.type) {
            .tree => .tree,
            .rect => .rect,
            .buffer => .buffer,
        },
        @intFromBool(node.enabled),
        node.x,
        node.y,
        width,
        height,
    );

    if (node.type == .tree) {
        const tree: *wlr.SceneTree = @fieldParentPtr("node", node);
        var it = tree.children.iterator(.forward);
        while (it.next()) |child| sendSceneNode(context, child, id);
    }
}

fn sceneNodeDimensions(node: *wlr.SceneNode) struct { i32, i32 } {
    return switch (node.type) {
        .tree => .{ 0, 0 },
        .rect => blk: {
            const rect = wlr.SceneRect.fromNode(node);
            break :blk .{ rect.width, rect.height };
        },
        .buffer => blk: {
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            if (scene_buffer.dst_width > 0 and scene_buffer.dst_height > 0) {
                break :blk .{ scene_buffer.dst_width, scene_buffer.dst_height };
            }
            if (scene_buffer.buffer) |buffer| break :blk .{ buffer.width, buffer.height };
            break :blk .{ 0, 0 };
        },
    };
}

fn sceneNodeLabel(node: *wlr.SceneNode, buffer: *[512]u8) [:0]const u8 {
    const scene = &server.scene;
    if (node == &scene.wlr_scene.tree.node) return "scene";
    if (node == &scene.interactive_tree.node) return "interactive";
    if (node == &scene.drag_icons.node) return "drag icons";
    if (node == &scene.hidden_tree.node) return "hidden staging";
    if (node == &scene.normal_tree.node) return "normal session";
    if (node == &scene.locked_tree.node) return "locked session";
    if (node == &scene.layers.background.node) return "layer: background";
    if (node == &scene.layers.bottom.node) return "layer: bottom";
    if (node == &scene.layers.wm.node) return "layer: windows";
    if (node == &scene.layers.top.node) return "layer: top";
    if (node == &scene.layers.fullscreen.node) return "layer: fullscreen";
    if (node == &scene.layers.overlay.node) return "layer: overlay";
    if (node == &scene.layers.popups.node) return "layer: popups";
    if (build_options.xwayland and node == &scene.layers.override_redirect.node) {
        return "layer: XWayland override-redirect";
    }
    if (server.overview.nodeLabel(node, buffer)) |label| return label;

    if (SceneNodeData.fromNode(node)) |owner| switch (owner.data) {
        .window => |window| return windowNodeLabel(window, node, buffer),
        .shell_surface => |surface| {
            if (node == &surface.tree.node) return "shell surface";
            if (node == &surface.popup_tree.node) return "shell surface popups";
        },
        .lock_surface => |surface| if (node == &surface.tree.node) return "lock surface",
        .layer_surface => |surface| {
            if (node == &surface.scene_layer_surface.tree.node) {
                return std.fmt.bufPrintZ(
                    buffer,
                    "layer surface: {s}",
                    .{surface.wlr_layer_surface.namespace},
                ) catch "layer surface";
            }
            if (node == &surface.blur_marker.node) {
                return "layer backdrop blur marker";
            }
            if (node == &surface.popup_tree.node) return "layer surface popups";
        },
        .override_redirect => |surface| if (build_options.xwayland) {
            if (surface.surface_tree) |tree| {
                if (node == &tree.node) return "XWayland override-redirect";
            }
        },
    };

    // Animation snapshots deliberately have no SceneNodeData so they remain
    // input-inert after being reparented into the normal window layer. Match
    // their persistent compositor-owned nodes by identity for diagnostics.
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        if (animationNodeLabel(window, node)) |label| return label;
    }

    var popups = server.layer_shell.popups.iterator();
    while (popups.next()) |popup| {
        if (popup.layer_owner == null or !popup.ownsNode(node)) continue;
        if (node == &popup.tree.node) return "layer XDG popup";
        if (node == &popup.blur_marker.node) {
            return "layer popup backdrop blur marker";
        }
    }

    return switch (node.type) {
        .tree => "tree",
        .rect => "rect",
        .buffer => if (wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node)) != null)
            "surface buffer"
        else
            "buffer",
    };
}

fn animationNodeLabel(
    window: *Window,
    node: *wlr.SceneNode,
) ?[:0]const u8 {
    if (node == &window.anim_tree.node) return "window animation snapshot";
    if (node == &window.anim_blur_marker.node) {
        return "animation backdrop blur marker";
    }
    if (node == &window.anim_surfaces_tree.node) return "animation surfaces";
    if (node == &window.anim_border_tree.node) return "animation border";
    if (node == &window.anim_border.rounded_outline.node) {
        return "animation border: rounded outline";
    }
    if (node == &window.anim_border.left.node) {
        return "animation border: left";
    }
    if (node == &window.anim_border.right.node) {
        return "animation border: right";
    }
    if (node == &window.anim_border.top.node) {
        return "animation border: top";
    }
    if (node == &window.anim_border.bottom.node) {
        return "animation border: bottom";
    }
    return null;
}

fn windowNodeLabel(window: *Window, node: *wlr.SceneNode, buffer: *[512]u8) [:0]const u8 {
    if (node == &window.tree.node) {
        const title = if (window.getTitle()) |title| std.mem.span(title) else "untitled";
        return std.fmt.bufPrintZ(buffer, "window: {s}", .{title}) catch "window";
    }
    if (node == &window.popup_tree.node) return "window popups";
    if (node == &window.anim_tree.node) return "window animation snapshot";
    if (node == &window.anim_blur_marker.node) return "animation backdrop blur marker";
    if (node == &window.fullscreen_background.node) return "fullscreen background";
    if (node == &window.blur_marker.node) return "backdrop blur marker";
    if (node == &window.decorations_below_tree.node) return "decorations below";
    if (node == &window.surfaces.tree.node) return "live surfaces";
    if (node == &window.surfaces.saved_tree.node) return "saved surfaces";
    if (node == &window.border.rounded_outline.node) return "border: rounded outline";
    if (node == &window.border.left.node) return "border: left";
    if (node == &window.border.right.node) return "border: right";
    if (node == &window.border.top.node) return "border: top";
    if (node == &window.border.bottom.node) return "border: bottom";
    if (node == &window.decorations_above_tree.node) return "decorations above";
    return switch (node.type) {
        .tree => "window subtree",
        .rect => "window rect",
        .buffer => "window surface buffer",
    };
}

fn sendSnapshot(
    manager: *aqueous.WindowInfoManagerV1,
    id: u32,
    foreign_resource: *@import("wayland").server.ext.ForeignToplevelHandleV1,
) void {
    const foreign = wlr.ExtForeignToplevelHandleV1.fromResource(@ptrCast(foreign_resource)) orelse {
        manager.postError(.invalid_toplevel, "foreign toplevel is not owned by Aqueous");
        return;
    };
    const window: *Window = @ptrCast(@alignCast(foreign.data orelse {
        manager.postError(.invalid_toplevel, "foreign toplevel is no longer mapped");
        return;
    }));

    const info = aqueous.WindowInfoV1.create(manager.getClient(), manager.getVersion(), id) catch {
        manager.getClient().postNoMemory();
        return;
    };
    info.setHandler(?*anyopaque, handleInfoRequest, null, null);

    const snapshot = window.infoSnapshot();
    info.sendBackend(switch (snapshot.backend) {
        .xdg => .xdg,
        .xwayland => .xwayland,
    });
    if (snapshot.app_id) |app_id| info.sendAppId(app_id);
    if (snapshot.class) |class| info.sendClass(class);
    if (snapshot.output) |output| info.sendOutput(output);
    if (snapshot.workspace != 0) info.sendWorkspace(snapshot.workspace);
    info.sendGeometry(
        snapshot.geometry.x,
        snapshot.geometry.y,
        snapshot.geometry.width,
        snapshot.geometry.height,
    );
    info.sendState(.{
        .focused = snapshot.focused,
        .floating = snapshot.floating,
        .fullscreen = snapshot.fullscreen,
        .maximized = snapshot.maximized,
        .minimized = snapshot.minimized,
        .visible = snapshot.visible,
    });
    info.sendLayout(snapshot.layout.ptr);
    // Content-type reporting was added with manager version 4; older clients
    // bind below that and must not receive the new event opcode.
    const supports_content_type = manager.getVersion() >= 4;
    if (supports_content_type and snapshot.content_type != .none) {
        info.sendContentType(@intCast(@intFromEnum(snapshot.content_type)));
    }

    const fingerprint = window.matchedRuleFingerprint();
    if (fingerprint != 0) {
        for (server.aqueous.rules.rules, 0..) |rule, index| {
            if (rule.matcherFingerprint() != fingerprint) continue;
            info.sendMatchedRule(@intCast(index + 1));
            if (rule.app_id) |pattern| sendRuleMatcher(info, .app_id, pattern);
            if (rule.class) |pattern| sendRuleMatcher(info, .class, pattern);
            if (rule.title) |pattern| sendRuleMatcher(info, .title, pattern);
            if (supports_content_type) if (rule.content_type) |content_type| {
                sendRuleMatcher(info, .content_type, @tagName(content_type));
            };
            break;
        }
    }
    info.sendDone();
}

fn handleInfoRequest(
    _: *aqueous.WindowInfoV1,
    request: aqueous.WindowInfoV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => {},
    }
}

fn sendRuleMatcher(
    info: *aqueous.WindowInfoV1,
    matcher: aqueous.WindowInfoV1.Matcher,
    pattern: []const u8,
) void {
    const terminated = util.gpa.dupeZ(u8, pattern) catch {
        log.err("out of memory while publishing rule matcher", .{});
        return;
    };
    defer util.gpa.free(terminated);
    info.sendRuleMatcher(matcher, terminated.ptr);
}
