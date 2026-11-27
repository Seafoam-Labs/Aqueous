// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Decoration = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const aqueous = @import("wayland").server.aqueous;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Scene = @import("Scene.zig");

const log = std.log.scoped(.wm);

const role: wlr.Surface.Role = .{
    .name = "aqueous_decoration_v1",
    .client_commit = clientCommit,
    .commit = commit,
    .unmap = unmap,
    .destroy = null,
};

object: ?*aqueous.DecorationV1,
/// Set instead of `object` for decorations created through
/// aqueous_shell_manager_v1.get_window_decoration.
shell_object: ?*aqueous.ShellDecorationV1 = null,
surface: *wlr.Surface,
tree: *wlr.SceneTree,
surfaces: Scene.SaveableSurfaces,
/// Window.decorations_above/below
link: wl.list.Link,
/// Created through aqueous_shell_manager_v1.get_window_decoration. Shell
/// decorations replace the compositor border while mapped and are owned by
/// `owner` for cleanup when the shell client disconnects.
shell: bool = false,
owner: ?*wl.Client = null,

rendering_requested: struct {
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    sync_next_commit: bool = false,
} = .{},

pub fn create(
    client: *wl.Client,
    version: u32,
    id: u32,
    surface: *wlr.Surface,
    parent: *wlr.SceneTree,
) !*Decoration {
    const decoration_v1 = try aqueous.DecorationV1.create(client, version, id);

    if (!surface.setRole(&role, @ptrCast(decoration_v1), @backingInt(aqueous.WindowManagerV1.Error.role))) {
        return error.AlreadyHasRole;
    }
    surface.setRoleObject(@ptrCast(decoration_v1));

    const decoration = try util.gpa.create(Decoration);
    errdefer util.gpa.destroy(decoration);

    const tree = try parent.createSceneTree();
    errdefer tree.node.destroy();

    const surfaces = try Scene.SaveableSurfaces.init(tree);
    _ = try surfaces.tree.createSceneSubsurfaceTree(surface);

    decoration.* = .{
        .object = decoration_v1,
        .surface = surface,
        .tree = tree,
        .surfaces = surfaces,
        .link = undefined,
    };

    decoration_v1.setHandler(*Decoration, handleRequest, handleDestroy, decoration);

    return decoration;
}

/// Shell-renderer constructor. The integrated policy has no external render
/// sequence, so requests are accepted at any time and applied in the next
/// rendering transaction.
pub fn createShell(
    client: *wl.Client,
    version: u32,
    id: u32,
    surface: *wlr.Surface,
    parent: *wlr.SceneTree,
) !*Decoration {
    const decoration_v1 = try aqueous.ShellDecorationV1.create(client, version, id);

    if (!surface.setRole(&role, @ptrCast(decoration_v1), @backingInt(aqueous.WindowManagerV1.Error.role))) {
        return error.AlreadyHasRole;
    }
    surface.setRoleObject(@ptrCast(decoration_v1));

    const decoration = try util.gpa.create(Decoration);
    errdefer util.gpa.destroy(decoration);

    const tree = try parent.createSceneTree();
    errdefer tree.node.destroy();

    const surfaces = try Scene.SaveableSurfaces.init(tree);
    _ = try surfaces.tree.createSceneSubsurfaceTree(surface);

    decoration.* = .{
        .object = null,
        .shell_object = decoration_v1,
        .surface = surface,
        .tree = tree,
        .surfaces = surfaces,
        .link = undefined,
        .shell = true,
        .owner = client,
    };

    decoration_v1.setHandler(*Decoration, handleShellRequest, handleShellDestroy, decoration);

    return decoration;
}

pub fn destroy(decoration: *Decoration) void {
    assert(decoration.object == null and decoration.shell_object == null);
    decoration.tree.node.destroy();
    decoration.link.remove();
    // Losing a shell decoration restores the compositor border fallback.
    if (decoration.shell) server.wm.dirtyWindowing();
    util.gpa.destroy(decoration);
}

pub fn makeInert(decoration: *Decoration) void {
    decoration.detach();
    decoration.surfaces.save();
}

/// Sever the protocol link without saving surfaces. Window teardown uses this
/// before destroy(): the shell client may still hold the decoration object and
/// only learns the window is gone from the next state batch, so its later
/// destroy request must land on an inert object instead of hitting the
/// live-object assert in destroy().
pub fn detach(decoration: *Decoration) void {
    if (decoration.object) |object| {
        object.setHandler(?*anyopaque, handleRequestInert, null, null);
        decoration.object = null;
    }
    if (decoration.shell_object) |object| {
        object.setHandler(?*anyopaque, handleShellRequestInert, null, null);
        decoration.shell_object = null;
    }
}

fn handleRequestInert(
    node_v1: *aqueous.DecorationV1,
    request: aqueous.DecorationV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) node_v1.destroy();
}

fn handleShellRequestInert(
    node_v1: *aqueous.ShellDecorationV1,
    request: aqueous.ShellDecorationV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) node_v1.destroy();
}

fn handleDestroy(_: *aqueous.DecorationV1, decoration: *Decoration) void {
    decoration.object = null;
    decoration.destroy();
}

fn handleShellDestroy(_: *aqueous.ShellDecorationV1, decoration: *Decoration) void {
    decoration.shell_object = null;
    decoration.destroy();
}

fn handleRequest(
    decoration_v1: *aqueous.DecorationV1,
    request: aqueous.DecorationV1.Request,
    decoration: *Decoration,
) void {
    assert(decoration.object == decoration_v1);
    switch (request) {
        .destroy => decoration_v1.destroy(),
        .set_offset => |args| {
            if (!server.wm.ensureRendering()) return;
            decoration.rendering_requested.offset_x = args.x;
            decoration.rendering_requested.offset_y = args.y;
        },
        .sync_next_commit => {
            if (!server.wm.ensureRendering()) return;
            decoration.rendering_requested.sync_next_commit = true;
        },
    }
}

fn handleShellRequest(
    decoration_v1: *aqueous.ShellDecorationV1,
    request: aqueous.ShellDecorationV1.Request,
    decoration: *Decoration,
) void {
    assert(decoration.shell_object == decoration_v1);
    switch (request) {
        .destroy => decoration_v1.destroy(),
        .set_offset => |args| {
            const changed = decoration.rendering_requested.offset_x != args.x or
                decoration.rendering_requested.offset_y != args.y;
            decoration.rendering_requested.offset_x = args.x;
            decoration.rendering_requested.offset_y = args.y;
            server.wm.dirtyRendering();
            // The offset defines the titlebar's outward extent, which tiling
            // reserves inside the tile cell. A change while mapped must re-run
            // windowing so the content box is re-inset (first map and unmap
            // already dirty windowing in the surface role hooks).
            if (changed and decoration.surface.mapped) server.wm.dirtyWindowing();
        },
        .sync_next_commit => {
            decoration.rendering_requested.sync_next_commit = true;
            server.wm.dirtyRendering();
        },
    }
}

fn clientCommit(wlr_surface: *wlr.Surface) callconv(.c) void {
    if (wlr_surface.role != &role) return;
    const resource = wlr_surface.role_resource orelse return;
    // Inert objects (detached or rejected decorations) carry no user data.
    const data = resource.getUserData() orelse return;
    const decoration: *Decoration = @ptrCast(@alignCast(data));
    if (decoration.rendering_requested.sync_next_commit) {
        decoration.surfaces.save();
    }
}

fn commit(wlr_surface: *wlr.Surface) callconv(.c) void {
    if (wlr_surface.hasBuffer()) {
        const was_mapped = wlr_surface.mapped;
        wlr_surface.map();
        // The first mapped shell decoration suppresses the compositor border;
        // re-run placement so the swap happens in one transaction.
        if (!was_mapped) {
            if (wlr_surface.role_resource) |resource| {
                if (resource.getUserData()) |data| {
                    const decoration: *Decoration = @ptrCast(@alignCast(data));
                    if (decoration.shell) server.wm.dirtyWindowing();
                }
            }
        }
    }
}

fn unmap(wlr_surface: *wlr.Surface) callconv(.c) void {
    // role_resource is cleared when the decoration object is destroyed, so a
    // null check here keeps client teardown safe. Inert objects (detached or
    // rejected decorations) also carry no user data: wlroots unmaps the
    // surface while destroying their resource, after the Decoration is gone.
    const resource = wlr_surface.role_resource orelse return;
    const data = resource.getUserData() orelse return;
    const decoration: *Decoration = @ptrCast(@alignCast(data));
    if (decoration.shell) server.wm.dirtyWindowing();
}

pub fn renderFinish(decoration: *Decoration, window_clip: *const wlr.Box) void {
    const rendering_requested = &decoration.rendering_requested;
    if (rendering_requested.sync_next_commit) {
        rendering_requested.sync_next_commit = false;

        if (!decoration.surfaces.saved) {
            if (decoration.object) |object| {
                object.postError(.no_commit,
                    \\no wl_surface.commit after sync_next_commit and before update_rendering_finish
                );
            }
            if (decoration.shell_object) |object| {
                object.postError(.no_commit,
                    \\no wl_surface.commit after sync_next_commit and before the compositor render
                );
            }
        }
    }

    decoration.surfaces.dropSaved();

    decoration.tree.node.setPosition(rendering_requested.offset_x, rendering_requested.offset_y);

    // wlroots asserts that a subsurface tree is present.
    if (!decoration.surfaces.tree.children.empty()) {
        var clip = window_clip.*;
        clip.x -= rendering_requested.offset_x;
        clip.y -= rendering_requested.offset_y;
        decoration.surfaces.tree.node.subsurfaceTreeSetClip(&clip);
    }
}
