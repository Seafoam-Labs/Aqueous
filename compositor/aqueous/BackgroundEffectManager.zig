// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const BackgroundEffectManager = @This();
const std = @import("std");
const wl = @import("wayland").server.wl;
const ext = @import("wayland").server.ext;
const wlr = @import("wlroots");
const pixman = @import("pixman");
const fx = @import("fx.zig");
const util = @import("util.zig");
const server = &@import("main.zig").server;
const SceneNodeData = @import("SceneNodeData.zig");

extern fn wlr_region_from_resource(resource: *wl.Region) *pixman.Region32;

global: ?*wl.Global = null,
managers: wl.list.Head(Manager, .link) = undefined,
surfaces: std.AutoHashMapUnmanaged(*wlr.Surface, *Surface) = .empty,
attachments: std.ArrayList(*Attachment) = .empty,
idle: ?*wl.EventSource = null,
capability: bool = false,

const Manager = struct {
    link: wl.list.Link = undefined,
    resource: *ext.BackgroundEffectManagerV1,
};
const Effect = struct {
    resource: *ext.BackgroundEffectSurfaceV1,
    surface: ?*Surface,
};

// Immutable, shared state avoids allocations in wlroots' infallible state moves.
const Mask = struct {
    refs: usize = 1,
    region: pixman.Region32,

    fn create(region: ?*pixman.Region32) !*Mask {
        const mask = try util.gpa.create(Mask);
        mask.* = .{ .region = undefined };
        mask.region.init();
        if (region) |r| if (!mask.region.copy(r)) {
            mask.unref();
            return error.OutOfMemory;
        };
        return mask;
    }
    fn unref(mask: *Mask) void {
        mask.refs -= 1;
        if (mask.refs != 0) return;
        mask.region.deinit();
        util.gpa.destroy(mask);
    }
};
const State = struct {
    active: bool = false,
    mask: ?*Mask = null,

    fn init(raw: *anyopaque) callconv(.c) void {
        const state: *State = @ptrCast(@alignCast(raw));
        state.* = .{};
    }
    fn finish(raw: *anyopaque) callconv(.c) void {
        const state: *State = @ptrCast(@alignCast(raw));
        if (state.mask) |mask| mask.unref();
        state.* = .{};
    }
    fn move(dst_raw: *anyopaque, src_raw: *anyopaque) callconv(.c) void {
        const dst: *State = @ptrCast(@alignCast(dst_raw));
        const src: *State = @ptrCast(@alignCast(src_raw));
        if (src.mask) |mask| mask.refs += 1;
        finish(dst);
        dst.* = src.*;
    }
};
const synced_impl: wlr.Surface.Synced.Impl = .{
    .state_size = @sizeOf(State),
    .init_state = State.init,
    .finish_state = State.finish,
    .move_state = State.move,
};

const Surface = struct {
    surface: *wlr.Surface,
    effect: ?*Effect = null,
    synced: wlr.Surface.Synced = undefined,
    pending: State = .{},
    current: State = .{},
    commit: wl.Listener(*wlr.Surface) = .init(committed),
    destroy: wl.Listener(*wlr.Surface) = .init(destroyed),

    fn committed(_: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        server.background_effect_manager.schedule();
    }
    fn destroyed(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const surface: *Surface = @fieldParentPtr("destroy", listener);
        if (surface.effect) |effect| effect.surface = null;
        surface.commit.link.remove();
        surface.destroy.link.remove();
        surface.synced.deinit();
        _ = server.background_effect_manager.surfaces.remove(surface.surface);
        util.gpa.destroy(surface);
        server.background_effect_manager.schedule();
    }
};

pub fn init(manager: *BackgroundEffectManager) !void {
    if (comptime !fx.blur_available) return;
    manager.managers.init();
    manager.global = try wl.Global.create(server.wl_server, ext.BackgroundEffectManagerV1, 1, *BackgroundEffectManager, manager, bind);
}

pub fn deinit(manager: *BackgroundEffectManager) void {
    if (manager.idle) |idle| idle.remove();
    manager.idle = null;
    while (manager.attachments.items.len > 0) manager.attachments.items[manager.attachments.items.len - 1].destroy();
    manager.attachments.deinit(util.gpa);
    manager.attachments = .empty;
    manager.surfaces.deinit(util.gpa);
    manager.surfaces = .empty;
    if (manager.global) |global| global.destroy();
    manager.global = null;
}

fn bind(client: *wl.Client, owner: *BackgroundEffectManager, version: u32, id: u32) void {
    const resource = ext.BackgroundEffectManagerV1.create(client, version, id) catch return client.postNoMemory();
    const manager = util.gpa.create(Manager) catch {
        resource.destroy();
        return client.postNoMemory();
    };
    manager.* = .{ .resource = resource };
    owner.managers.append(manager);
    resource.setHandler(*Manager, managerRequest, managerDestroy, manager);
    resource.sendCapabilities(.{ .blur = owner.capability });
}
fn managerDestroy(_: *ext.BackgroundEffectManagerV1, manager: *Manager) void {
    manager.link.remove();
    util.gpa.destroy(manager);
}
fn managerRequest(resource: *ext.BackgroundEffectManagerV1, request: ext.BackgroundEffectManagerV1.Request, _: *Manager) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_background_effect => |args| {
            const owner = &server.background_effect_manager;
            const wlr_surface = wlr.Surface.fromWlSurface(args.surface);
            const entry = owner.surfaces.getOrPut(util.gpa, wlr_surface) catch return resource.postNoMemory();
            if (!entry.found_existing) {
                const surface = util.gpa.create(Surface) catch {
                    _ = owner.surfaces.remove(wlr_surface);
                    return resource.postNoMemory();
                };
                surface.* = .{ .surface = wlr_surface };
                surface.synced.init(wlr_surface, &synced_impl, &surface.pending, &surface.current) catch {
                    util.gpa.destroy(surface);
                    _ = owner.surfaces.remove(wlr_surface);
                    return resource.postNoMemory();
                };
                wlr_surface.events.commit.add(&surface.commit);
                wlr_surface.events.destroy.add(&surface.destroy);
                entry.value_ptr.* = surface;
            }
            const surface = entry.value_ptr.*;
            if (surface.effect != null) {
                resource.postError(.background_effect_exists, "surface already has a background effect");
                return;
            }
            const effect_resource = ext.BackgroundEffectSurfaceV1.create(resource.getClient(), 1, args.id) catch return resource.postNoMemory();
            const effect = util.gpa.create(Effect) catch {
                effect_resource.destroy();
                return resource.postNoMemory();
            };
            effect.* = .{ .resource = effect_resource, .surface = surface };
            surface.effect = effect;
            State.finish(&surface.pending);
            surface.pending.active = true;
            effect_resource.setHandler(*Effect, effectRequest, effectDestroy, effect);
        },
    }
}
fn effectDestroy(_: *ext.BackgroundEffectSurfaceV1, effect: *Effect) void {
    if (effect.surface) |surface| {
        surface.effect = null;
        State.finish(&surface.pending);
    }
    util.gpa.destroy(effect);
}
fn effectRequest(resource: *ext.BackgroundEffectSurfaceV1, request: ext.BackgroundEffectSurfaceV1.Request, effect: *Effect) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_blur_region => |args| {
            const surface = effect.surface orelse {
                resource.postError(.surface_destroyed, "surface has been destroyed");
                return;
            };
            const mask = Mask.create(if (args.region) |region| wlr_region_from_resource(region) else null) catch return resource.postNoMemory();
            State.finish(&surface.pending);
            surface.pending = .{ .active = true, .mask = mask };
        },
    }
}

pub fn controls(manager: *BackgroundEffectManager, surface: *wlr.Surface) bool {
    const record = manager.surfaces.get(surface) orelse return false;
    return record.current.active;
}

pub fn schedule(manager: *BackgroundEffectManager) void {
    if (comptime !fx.blur_available) return;
    if (manager.idle != null) return;
    manager.idle = server.wl_server.getEventLoop().addIdle(*BackgroundEffectManager, refresh, manager) catch {
        std.log.err("could not schedule background effect update", .{});
        return;
    };
}
fn refresh(manager: *BackgroundEffectManager) void {
    manager.idle = null;
    manager.sync();
    var layers = server.layer_shell.surfaces.iterator();
    while (layers.next()) |layer| layer.syncBlurEffects();
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| window.refreshBackdropBlur();
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| output.markBlurDirty();
}
pub fn sync(manager: *BackgroundEffectManager) void {
    if (comptime !fx.blur_available) return;
    const capability = server.wm.blur.enabled and server.wm.blur.radius > 0 and server.wm.blur.passes > 0;
    if (manager.capability != capability) {
        manager.capability = capability;
        var it = manager.managers.iterator(.forward);
        while (it.next()) |resource| resource.resource.sendCapabilities(.{ .blur = capability });
    }
    if (manager.surfaces.count() != 0) manager.walk(&server.scene.wlr_scene.tree);
    for (manager.attachments.items) |attachment| attachment.sync();
}
fn walk(manager: *BackgroundEffectManager, tree: *wlr.SceneTree) void {
    var it = tree.children.safeIterator(.forward);
    while (it.next()) |node| switch (node.type) {
        .tree => manager.walk(@fieldParentPtr("node", node)),
        .buffer => {
            const buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(buffer) orelse continue;
            if (!manager.controls(scene_surface.surface) or manager.forBuffer(buffer) != null) continue;
            _ = Attachment.create(buffer) catch {
                scene_surface.surface.resource.postNoMemory();
                continue;
            };
        },
        .rect => {},
    };
}
pub fn forBuffer(manager: *BackgroundEffectManager, buffer: *wlr.SceneBuffer) ?*Attachment {
    for (manager.attachments.items) |attachment| if (attachment.buffer == buffer) return attachment;
    return null;
}
pub fn forNode(manager: *BackgroundEffectManager, node: *wlr.SceneNode) ?*Attachment {
    for (manager.attachments.items) |attachment| {
        if (attachment.tree == null) continue;
        if (node == &attachment.marker.?.node or node == &attachment.buffer.node) return attachment;
    }
    return null;
}

pub const Attachment = struct {
    buffer: *wlr.SceneBuffer,
    tree: ?*wlr.SceneTree,
    marker: ?*wlr.SceneRect,
    blur: ?fx.WindowBlur,
    region: pixman.Region32,
    frozen: bool = false,
    frozen_region: pixman.Region32 = undefined,
    frozen_crop: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    frozen_allowed: bool = true,
    buffer_destroy: wl.Listener(void) = .init(bufferDestroyed),
    tree_destroy: wl.Listener(void) = .init(treeDestroyed),

    fn create(buffer: *wlr.SceneBuffer) !*Attachment {
        const attachment = try util.gpa.create(Attachment);
        errdefer util.gpa.destroy(attachment);
        const tree = try buffer.node.parent.?.createSceneTree();
        errdefer tree.node.destroy();
        const marker = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1.0 / 255.0 });
        marker.node.setEnabled(false);
        fx.setRectInputEnabled(marker, false);
        const blur = fx.createWindowBlur(tree) orelse return error.OutOfMemory;
        errdefer fx.destroyWindowBlur(blur);
        try server.background_effect_manager.attachments.append(util.gpa, attachment);
        attachment.* = .{ .buffer = buffer, .tree = tree, .marker = marker, .blur = blur, .region = undefined };
        attachment.region.init();
        buffer.node.events.destroy.add(&attachment.buffer_destroy);
        tree.node.events.destroy.add(&attachment.tree_destroy);
        return attachment;
    }
    fn destroy(attachment: *Attachment) void {
        attachment.buffer_destroy.link.remove();
        if (attachment.tree) |tree| {
            attachment.tree_destroy.link.remove();
            if (attachment.blur) |blur| fx.destroyWindowBlur(blur);
            tree.node.destroy();
        }
        attachment.region.deinit();
        if (attachment.frozen) attachment.frozen_region.deinit();
        const list = &server.background_effect_manager.attachments;
        for (list.items, 0..) |item, i| if (item == attachment) {
            _ = list.swapRemove(i);
            break;
        };
        util.gpa.destroy(attachment);
    }
    fn bufferDestroyed(listener: *wl.Listener(void)) void {
        const attachment: *Attachment = @fieldParentPtr("buffer_destroy", listener);
        attachment.destroy();
    }
    fn treeDestroyed(listener: *wl.Listener(void)) void {
        const attachment: *Attachment = @fieldParentPtr("tree_destroy", listener);
        attachment.tree_destroy.link.remove();
        attachment.tree = null;
        attachment.marker = null;
        attachment.blur = null;
    }
    fn allowed(attachment: *Attachment) bool {
        if (attachment.frozen) return attachment.frozen_allowed;
        const owner = SceneNodeData.fromNode(&attachment.buffer.node) orelse return true;
        return switch (owner.data) {
            .window => |window| window.rendering_requested.blur_enabled,
            .layer_surface => |layer| blk: {
                const surface = wlr.SceneSurface.tryFromBuffer(attachment.buffer) orelse break :blk true;
                break :blk server.aqueous.layerNativeBlurAllowed(
                    std.mem.span(layer.wlr_layer_surface.namespace),
                    surface.surface.getRootSurface() != layer.wlr_layer_surface.surface,
                );
            },
            else => true,
        };
    }
    fn sync(attachment: *Attachment) void {
        const tree = attachment.tree orelse return;
        const marker = attachment.marker.?;
        const blur = attachment.blur.?;
        const buffer = attachment.buffer;
        var region: pixman.Region32 = undefined;
        region.init();
        defer region.deinit();
        if (attachment.frozen) {
            if (!region.copy(&attachment.frozen_region)) return;
            const crop = attachment.frozen_crop;
            if (!crop.empty()) {
                if (!region.intersectRect(&region, crop.x, crop.y, @intCast(crop.width), @intCast(crop.height))) return;
                region.translate(-crop.x, -crop.y);
            }
        } else if (wlr.SceneSurface.tryFromBuffer(buffer)) |scene_surface| {
            const surface = scene_surface.surface;
            if (server.background_effect_manager.surfaces.get(surface)) |record| {
                if (record.current.active) if (record.current.mask) |mask| {
                    if (!region.intersectRect(&mask.region, 0, 0, @intCast(@max(0, surface.current.width)), @intCast(@max(0, surface.current.height)))) return;
                    const clip = scene_surface.private.clip;
                    if (!clip.empty()) {
                        if (!region.intersectRect(&region, clip.x, clip.y, @intCast(clip.width), @intCast(clip.height))) return;
                        region.translate(-clip.x, -clip.y);
                    }
                };
            }
        }
        if (!attachment.region.equal(&region)) {
            std.mem.swap(pixman.Region32, &attachment.region, &region);
            server.effect_metadata.invalidateWindowBlur(blur);
            var outputs = server.om.outputs.iterator(.forward);
            while (outputs.next()) |output| {
                output.damageBlurAppearance();
                output.markBlurDirty();
            }
        }
        if (tree.node.parent != buffer.node.parent) tree.node.reparent(buffer.node.parent.?);
        tree.node.setPosition(buffer.node.x, buffer.node.y);
        // wlroots can reorder subsurfaces independently of their parent surface.
        if (tree.node.link.next != &buffer.node.link) tree.node.placeBelow(&buffer.node);
        const box = attachment.region.extents;
        const enabled = server.background_effect_manager.capability and buffer.node.enabled and buffer.buffer != null and buffer.opacity > 0 and attachment.region.notEmpty() and attachment.allowed();
        @import("c").aqueous_scene_node_set_enabled(@ptrCast(&marker.node), @intFromBool(enabled));
        marker.node.setPosition(box.x1, box.y1);
        marker.setSize(box.x2 - box.x1, box.y2 - box.y1);
        fx.configureWindowBlur(blur, .{ .x = box.x1, .y = box.y1, .width = box.x2 - box.x1, .height = box.y2 - box.y1 }, 0, enabled);
    }
};

pub fn clone(manager: *BackgroundEffectManager, source: *wlr.SceneBuffer, target: *wlr.SceneBuffer) !void {
    if (comptime !fx.blur_available) return;
    if (manager.forBuffer(source) == null) {
        const scene_surface = wlr.SceneSurface.tryFromBuffer(source) orelse return;
        if (!manager.controls(scene_surface.surface)) return;
        _ = try Attachment.create(source);
    }
    const original = manager.forBuffer(source).?;
    original.sync();
    const attachment = try Attachment.create(target);
    attachment.frozen = true;
    attachment.frozen_allowed = original.allowed();
    attachment.frozen_region.init();
    if (!attachment.frozen_region.copy(&original.region)) {
        attachment.destroy();
        return error.OutOfMemory;
    }
    attachment.sync();
}

pub fn cropSnapshot(manager: *BackgroundEffectManager, buffer: *wlr.SceneBuffer, crop: wlr.Box) void {
    if (comptime !fx.blur_available) return;
    const attachment = manager.forBuffer(buffer) orelse return;
    std.debug.assert(attachment.frozen);
    attachment.frozen_crop = crop;
}

pub fn dropSnapshot(manager: *BackgroundEffectManager, buffer: *wlr.SceneBuffer) void {
    if (manager.forBuffer(buffer)) |attachment| attachment.destroy();
}

pub fn hasFrozenIn(manager: *BackgroundEffectManager, tree: *wlr.SceneTree) bool {
    for (manager.attachments.items) |attachment| {
        if (!attachment.frozen) continue;
        var parent = attachment.buffer.node.parent;
        while (parent) |node| : (parent = node.node.parent) {
            if (node == tree) return true;
        }
    }
    return false;
}
