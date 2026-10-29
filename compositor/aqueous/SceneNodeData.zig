// SPDX-FileCopyrightText: © 2023 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const SceneNodeData = @This();

const assert = @import("std").debug.assert;
const build_options = @import("build_options");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const LockSurface = @import("LockSurface.zig");
const LayerSurface = @import("LayerSurface.zig");
const DragIcon = @import("DragIcon.zig");
const Window = @import("Window.zig");
const ShellSurface = @import("ShellSurface.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

pub const Data = union(enum) {
    drag_icon: *DragIcon,
    window: *Window,
    shell_surface: *ShellSurface,
    lock_surface: *LockSurface,
    layer_surface: *LayerSurface,
    override_redirect: if (build_options.xwayland) *XwaylandOverrideRedirect else noreturn,
};

node: *wlr.SceneNode,
data: Data,
destroy: wl.Listener(void) = .init(handleDestroy),

/// Non-null compositor scene-node data must always point to this wrapper,
/// including nodes outside the interactive tree: render hooks visit them too.
pub fn attach(node: *wlr.SceneNode, data: Data) error{OutOfMemory}!void {
    assert(node.data == null);
    const scene_node_data = try util.gpa.create(SceneNodeData);

    scene_node_data.* = .{
        .node = node,
        .data = data,
    };
    node.data = scene_node_data;

    node.events.destroy.add(&scene_node_data.destroy);
}

pub fn fromNode(node: *wlr.SceneNode) ?*SceneNodeData {
    var n = node;
    while (true) {
        if (@as(?*SceneNodeData, @ptrCast(@alignCast(n.data)))) |scene_node_data| {
            return scene_node_data;
        }
        if (n.parent) |parent_tree| {
            n = &parent_tree.node;
        } else {
            return null;
        }
    }
}

pub fn fromSurface(surface: *wlr.Surface) ?*SceneNodeData {
    if (@as(?*wlr.SceneNode, @ptrCast(@alignCast(surface.getRootSurface().data)))) |node| {
        return fromNode(node);
    }
    return null;
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const scene_node_data: *SceneNodeData = @fieldParentPtr("destroy", listener);

    scene_node_data.destroy.link.remove();
    scene_node_data.node.data = null;

    util.gpa.destroy(scene_node_data);
}
