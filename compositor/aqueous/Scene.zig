// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Scene = @This();

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;

const SceneNodeData = @import("SceneNodeData.zig");
const fx = @import("fx.zig");
const util = @import("util.zig");

wlr_scene: *wlr.Scene,
/// All windows, status bars, drowdown menus, etc. that can recieve pointer events and similar.
interactive_tree: *wlr.SceneTree,
/// Drag icons, which cannot recieve e.g. pointer events and are therefore kept
/// in a separate tree from the interactive tree.
drag_icons: *wlr.SceneTree,
/// Always disabled, used for staging changes
/// TODO can this be refactored away?
hidden_tree: *wlr.SceneTree,
/// Direct child of interactive_tree, disabled when the session is locked
normal_tree: *wlr.SceneTree,
/// Direct child of interactive_tree, enabled when the session is locked
locked_tree: *wlr.SceneTree,

/// All direct children of the normal_tree scene node
layers: struct {
    /// Background layer shell layer
    background: *wlr.SceneTree,
    /// Bottom layer shell layer
    bottom: *wlr.SceneTree,
    /// Windows and shell surfaces of the window manager
    wm: *wlr.SceneTree,
    /// Top layer shell layer
    top: *wlr.SceneTree,
    /// Fullscreen windows and river shell surfaces placed above them.
    fullscreen: *wlr.SceneTree,
    /// Overlay layer shell layer
    overlay: *wlr.SceneTree,
    /// Popups from xdg-shell and input-method-v2 clients
    popups: *wlr.SceneTree,
    /// Xwayland override redirect windows are a legacy wart that decide where
    /// to place themselves in layout coordinates. Unfortunately this is how
    /// X11 decided to make dropdown menus and the like possible.
    override_redirect: if (build_options.xwayland) *wlr.SceneTree else void,
},

pub fn init(scene: *Scene) !void {
    const wlr_scene = try wlr.Scene.create();
    errdefer wlr_scene.tree.node.destroy();

    if (server.linux_dmabuf) |linux_dmabuf| wlr_scene.setLinuxDmabufV1(linux_dmabuf);
    if (server.color_manager) |color_manager| wlr_scene.setColorManagerV1(color_manager);

    const interactive_tree = try wlr_scene.tree.createSceneTree();
    const drag_icons = try wlr_scene.tree.createSceneTree();
    const hidden_tree = try wlr_scene.tree.createSceneTree();
    hidden_tree.node.setEnabled(false);

    const normal_tree = try interactive_tree.createSceneTree();
    const locked_tree = try interactive_tree.createSceneTree();
    locked_tree.node.setEnabled(false);

    scene.* = .{
        .wlr_scene = wlr_scene,
        .interactive_tree = interactive_tree,
        .drag_icons = drag_icons,
        .hidden_tree = hidden_tree,
        .normal_tree = normal_tree,
        .locked_tree = locked_tree,
        .layers = .{
            .background = try normal_tree.createSceneTree(),
            .bottom = try normal_tree.createSceneTree(),
            .wm = try normal_tree.createSceneTree(),
            .top = try normal_tree.createSceneTree(),
            .fullscreen = try normal_tree.createSceneTree(),
            .overlay = try normal_tree.createSceneTree(),
            .popups = try normal_tree.createSceneTree(),
            .override_redirect = if (build_options.xwayland) try normal_tree.createSceneTree(),
        },
    };
}

pub const AtResult = struct {
    node: *wlr.SceneNode,
    surface: ?*wlr.Surface,
    sx: f64,
    sy: f64,
    data: SceneNodeData.Data,
};

/// Return information about what is currently rendered in the interactive_tree
/// tree at the given layout coordinates, taking surface input regions into account.
pub fn at(scene: *const Scene, lx: f64, ly: f64) ?AtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node = scene.interactive_tree.node.at(lx, ly, &sx, &sy) orelse return null;

    const surface: ?*wlr.Surface = blk: {
        if (node.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            if (CanvasBufferData.fromBuffer(scene_buffer)) |canvas| {
                return .{
                    .node = node,
                    .surface = canvas.surface,
                    .sx = sx,
                    .sy = sy,
                    .data = canvas.data,
                };
            }
            if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface| {
                break :blk scene_surface.surface;
            }
        }
        break :blk null;
    };

    if (SceneNodeData.fromNode(node)) |scene_node_data| {
        return .{
            .node = node,
            .surface = surface,
            .sx = sx,
            .sy = sy,
            .data = scene_node_data.data,
        };
    } else {
        return null;
    }
}

/// Input and frame-callback bridge attached to a scaled presentation buffer.
/// The clone renders an existing scene buffer while pointer coordinates and
/// frame events continue to target the original wl_surface.
pub const CanvasBufferData = struct {
    buffer: *wlr.SceneBuffer,
    source: *wlr.SceneBuffer,
    surface: *wlr.Surface,
    scale: f64,
    data: SceneNodeData.Data,
    destroy: wl.Listener(void) = .init(handleDestroy),
    outputs_update: wl.Listener(*wlr.SceneBuffer.event.OutputsUpdate) = .init(handleOutputsUpdate),
    output_sample: wl.Listener(*wlr.SceneBuffer.event.OutputSample) = .init(handleOutputSample),
    frame_done: wl.Listener(*wlr.SceneBuffer.event.FrameDone) = .init(handleFrameDone),

    pub fn attach(buffer: *wlr.SceneBuffer, source: *wlr.SceneBuffer, surface: *wlr.Surface, scale: f64, data: SceneNodeData.Data) !void {
        const mapping = try util.gpa.create(CanvasBufferData);
        mapping.* = .{
            .buffer = buffer,
            .source = source,
            .surface = surface,
            .scale = scale,
            .data = data,
        };
        buffer.node.data = mapping;
        buffer.point_accepts_input = pointAcceptsInput;
        buffer.node.events.destroy.add(&mapping.destroy);
        buffer.events.outputs_update.add(&mapping.outputs_update);
        buffer.events.output_sample.add(&mapping.output_sample);
        buffer.events.frame_done.add(&mapping.frame_done);
    }

    pub fn fromBuffer(buffer: *wlr.SceneBuffer) ?*CanvasBufferData {
        return @ptrCast(@alignCast(buffer.node.data));
    }

    fn pointAcceptsInput(buffer: *wlr.SceneBuffer, sx: *f64, sy: *f64) callconv(.c) bool {
        const mapping = fromBuffer(buffer) orelse return false;
        var source_x = sx.* / mapping.scale;
        var source_y = sy.* / mapping.scale;
        const accepts = if (mapping.source.point_accepts_input) |callback|
            callback(mapping.source, &source_x, &source_y)
        else
            mapping.surface.pointAcceptsInput(source_x, source_y);
        sx.* = source_x;
        sy.* = source_y;
        return accepts;
    }

    fn handleFrameDone(listener: *wl.Listener(*wlr.SceneBuffer.event.FrameDone), event: *wlr.SceneBuffer.event.FrameDone) void {
        const mapping: *CanvasBufferData = @fieldParentPtr("frame_done", listener);
        if (wlr.SceneSurface.tryFromBuffer(mapping.source)) |scene_surface| scene_surface.sendFrameDone(&event.when);
    }

    fn handleOutputsUpdate(listener: *wl.Listener(*wlr.SceneBuffer.event.OutputsUpdate), event: *wlr.SceneBuffer.event.OutputsUpdate) void {
        const mapping: *CanvasBufferData = @fieldParentPtr("outputs_update", listener);
        mapping.source.events.outputs_update.emit(event);
    }

    fn handleOutputSample(listener: *wl.Listener(*wlr.SceneBuffer.event.OutputSample), event: *wlr.SceneBuffer.event.OutputSample) void {
        const mapping: *CanvasBufferData = @fieldParentPtr("output_sample", listener);
        mapping.source.events.output_sample.emit(event);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const mapping: *CanvasBufferData = @fieldParentPtr("destroy", listener);
        mapping.destroy.link.remove();
        mapping.outputs_update.link.remove();
        mapping.output_sample.link.remove();
        mapping.frame_done.link.remove();
        mapping.buffer.node.data = null;
        util.gpa.destroy(mapping);
    }
};

const CanvasCloneContext = struct {
    target: *wlr.SceneTree,
    scale: f64,
    data: SceneNodeData.Data,
};

pub fn cloneNodeScaledInto(source: *wlr.SceneNode, target: *wlr.SceneTree, scale: f64, data: SceneNodeData.Data) void {
    var context: CanvasCloneContext = .{ .target = target, .scale = scale, .data = data };
    source.forEachBuffer(*CanvasCloneContext, cloneScaledSurfaceIter, &context);
}

fn cloneScaledSurfaceIter(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, context: *CanvasCloneContext) void {
    const scene_surface = wlr.SceneSurface.tryFromBuffer(buffer) orelse return;
    const clone = context.target.createSceneBuffer(buffer.buffer) catch {
        std.log.err("out of memory creating canvas presentation buffer", .{});
        return;
    };
    clone.node.setPosition(scaleInt(sx, context.scale), scaleInt(sy, context.scale));
    clone.setDestSize(@max(1, scaleInt(buffer.dst_width, context.scale)), @max(1, scaleInt(buffer.dst_height, context.scale)));
    clone.setSourceBox(&buffer.src_box);
    clone.setTransform(buffer.transform);
    clone.setOpacity(buffer.opacity);
    clone.setFilterMode(.bilinear);
    fx.copyBufferFx(clone, buffer);
    CanvasBufferData.attach(clone, buffer, scene_surface.surface, context.scale, context.data) catch {
        clone.node.destroy();
    };
}

fn scaleInt(value: c_int, scale: f64) c_int {
    return @intFromFloat(@round(@as(f64, @floatFromInt(value)) * scale));
}

pub fn layerSurfaceTree(scene: *Scene, layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    return switch (layer) {
        .background => scene.layers.background,
        .bottom => scene.layers.bottom,
        .top => scene.layers.top,
        .overlay => scene.layers.overlay,
        _ => unreachable,
    };
}

pub const SaveableSurfaces = struct {
    enabled: bool,
    saved: bool,
    tree: *wlr.SceneTree,
    saved_tree: *wlr.SceneTree,

    pub fn init(parent: *wlr.SceneTree) !SaveableSurfaces {
        const surfaces: SaveableSurfaces = .{
            .enabled = true,
            .saved = false,
            .tree = try parent.createSceneTree(),
            .saved_tree = try parent.createSceneTree(),
        };
        surfaces.syncEnabled();
        return surfaces;
    }

    fn syncEnabled(surfaces: *const SaveableSurfaces) void {
        surfaces.tree.node.setEnabled(surfaces.enabled and !surfaces.saved);
        surfaces.saved_tree.node.setEnabled(surfaces.enabled and surfaces.saved);
    }

    pub fn setEnabled(surfaces: *SaveableSurfaces, enabled: bool) void {
        if (enabled == surfaces.enabled) return;
        surfaces.enabled = enabled;
        surfaces.syncEnabled();
    }

    pub fn save(surfaces: *SaveableSurfaces) void {
        if (surfaces.saved) return;
        assert(surfaces.tree.node.enabled == surfaces.enabled);
        assert(!surfaces.saved_tree.node.enabled);
        assert(surfaces.saved_tree.children.empty());
        surfaces.tree.node.forEachBuffer(*wlr.SceneTree, saveSurfaceTreeIter, surfaces.saved_tree);
        surfaces.saved = true;
        surfaces.syncEnabled();
    }

    fn saveSurfaceTreeIter(
        buffer: *wlr.SceneBuffer,
        sx: c_int,
        sy: c_int,
        saved_tree: *wlr.SceneTree,
    ) void {
        const scene_buffer = saved_tree.createSceneBuffer(buffer.buffer) catch {
            std.log.err("out of memory", .{});
            return;
        };
        scene_buffer.node.setPosition(sx, sy);
        scene_buffer.setDestSize(buffer.dst_width, buffer.dst_height);
        scene_buffer.setSourceBox(&buffer.src_box);
        scene_buffer.setTransform(buffer.transform);
        scene_buffer.setOpacity(buffer.opacity);
        fx.copyBufferFx(scene_buffer, buffer);
    }

    /// Clone the current live surface buffers into an arbitrary target tree,
    /// reusing the same per-buffer copy (including SceneFX attributes) as `save`.
    /// Unlike `save`, this neither toggles `saved` nor disables the live tree, so
    /// the clones can be displayed simultaneously with the live surfaces (used by
    /// the cosmetic position-animation overlay).
    pub fn cloneInto(surfaces: *const SaveableSurfaces, target: *wlr.SceneTree) void {
        surfaces.tree.node.forEachBuffer(*wlr.SceneTree, saveSurfaceTreeIter, target);
    }

    pub fn cloneScaledInto(surfaces: *const SaveableSurfaces, target: *wlr.SceneTree, scale: f64, data: SceneNodeData.Data) void {
        cloneNodeScaledInto(&surfaces.tree.node, target, scale, data);
    }

    pub fn dropSaved(surfaces: *SaveableSurfaces) void {
        if (!surfaces.saved) return;
        assert(!surfaces.tree.node.enabled);
        assert(surfaces.saved_tree.node.enabled == surfaces.enabled);
        {
            var it = surfaces.saved_tree.children.safeIterator(.forward);
            while (it.next()) |node| node.destroy();
        }
        surfaces.saved = false;
        surfaces.syncEnabled();
    }
};
