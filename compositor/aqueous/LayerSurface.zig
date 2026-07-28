// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LayerSurface = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const fx = @import("fx.zig");
const util = @import("util.zig");

const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const SlotMap = @import("slotmap").SlotMap;
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.wm);

/// Only packed in order to make == work.
pub const Ref = packed struct {
    key: SlotMap(*LayerSurface).Key,

    pub fn get(ref: Ref) ?*LayerSurface {
        return server.layer_shell.surfaces.get(ref.key);
    }
};

ref: Ref,

wlr_layer_surface: *wlr.LayerSurfaceV1,
scene_layer_surface: *wlr.SceneLayerSurfaceV1,
popup_tree: *wlr.SceneTree,
/// Transparent checkpoint below the layer surface's own buffers.
blur_marker: *wlr.SceneRect,
backdrop_blur: ?fx.WindowBlur,
blur_requested: bool,
blur_popups_requested: bool,
/// Last scene layer used by this surface. The protocol's current layer has
/// already changed by the commit callback, so retaining the prior value lets us
/// invalidate blur when a surface moves into or out of a backdrop layer.
scene_layer: zwlr.LayerShellV1.Layer,

destroy: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleDestroy),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) error{OutOfMemory}!void {
    const layer_surface = try util.gpa.create(LayerSurface);
    errdefer util.gpa.destroy(layer_surface);

    const key = try server.layer_shell.surfaces.put(util.gpa, layer_surface);
    errdefer server.layer_shell.surfaces.remove(key);

    const layer_tree = server.scene.layerSurfaceTree(wlr_layer_surface.current.layer);

    const scene_layer_surface =
        try layer_tree.createSceneLayerSurfaceV1(wlr_layer_surface);
    errdefer scene_layer_surface.tree.node.destroy();
    const popup_tree = try server.scene.layers.popups.createSceneTree();
    errdefer popup_tree.node.destroy();
    const blur_marker = try scene_layer_surface.tree.createSceneRect(
        0,
        0,
        &.{ 0, 0, 0, 1.0 / 255.0 },
    );
    blur_marker.node.lowerToBottom();
    blur_marker.node.setEnabled(false);
    fx.setRectInputEnabled(blur_marker, false);
    const backdrop_blur = fx.createWindowBlur(scene_layer_surface.tree);

    layer_surface.* = .{
        .ref = .{ .key = key },
        .wlr_layer_surface = wlr_layer_surface,
        .scene_layer_surface = scene_layer_surface,
        .popup_tree = popup_tree,
        .blur_marker = blur_marker,
        .backdrop_blur = backdrop_blur,
        .blur_requested = server.aqueous.layerBlurEnabled(
            std.mem.span(wlr_layer_surface.namespace),
        ),
        .blur_popups_requested = server.aqueous.layerPopupBlurEnabled(
            std.mem.span(wlr_layer_surface.namespace),
        ),
        .scene_layer = wlr_layer_surface.current.layer,
    };
    if (backdrop_blur) |blur| {
        fx.configureWindowBlur(
            blur,
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            0,
            false,
        );
    }

    try SceneNodeData.attach(&layer_surface.scene_layer_surface.tree.node, .{ .layer_surface = layer_surface });
    try SceneNodeData.attach(&layer_surface.popup_tree.node, .{ .layer_surface = layer_surface });

    wlr_layer_surface.surface.data = &layer_surface.scene_layer_surface.tree.node;

    wlr_layer_surface.events.destroy.add(&layer_surface.destroy);
    wlr_layer_surface.surface.events.map.add(&layer_surface.map);
    wlr_layer_surface.surface.events.unmap.add(&layer_surface.unmap);
    wlr_layer_surface.surface.events.commit.add(&layer_surface.commit);
    wlr_layer_surface.events.new_popup.add(&layer_surface.new_popup);
}

pub fn destroyPopups(layer_surface: *LayerSurface) void {
    var it = layer_surface.wlr_layer_surface.popups.safeIterator(.forward);
    while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
}

/// Clear any seat keyboard focus, scheduled focus, or sent focus still pointing
/// at this surface. Shared by handleUnmap and handleDestroy so that a destroy
/// arriving without a preceding matching unmap (e.g. the direct
/// wlr_layer_surface.destroy() for bogus exclusive zones) cannot leave a
/// dangling *LayerSurface in any seat.
fn clearSeatFocus(layer_surface: *LayerSurface) void {
    var it = server.input_manager.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (seat.focused == .layer_surface and seat.focused.layer_surface == layer_surface) {
            seat.focus(.none);
        }
        switch (seat.layer_shell.scheduled.focus) {
            .exclusive, .non_exclusive => |ref| {
                if (ref == layer_surface.ref) {
                    seat.layer_shell.scheduled.focus = .none;
                    // Re-run the windowing/focus arbitration so the WM is told the
                    // layer surface relinquished its (possibly exclusive) keyboard
                    // focus and can restore window focus.
                    server.wm.dirtyWindowing();
                }
            },
            .none => {},
        }
        // NOTE: deliberately do NOT clear seat.layer_shell.sent.focus here.
        // LayerShellSeat.manageStart only emits focus_exclusive/non_exclusive/none
        // to the WM when scheduled.focus != sent.focus. If we forced sent.focus to
        // .none as well, the diff would vanish and the WM (Aqueous) would never be
        // told the exclusive keyboard grab was released — it would stay in its
        // "layer-shell exclusive" mode forever and suppress every window focus
        // request, so keyboard/text input would die after the launcher (e.g.
        // sherlock) closes. Leaving sent.focus intact lets manageStart detect the
        // transition and notify the WM. The now-stale LayerSurface.Ref in sent.focus
        // is harmless: it is only ever compared with == or resolved via Ref.get(),
        // which safely returns null for the removed surface.
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("destroy", listener);

    log.debug("layer surface '{s}' destroyed", .{layer_surface.wlr_layer_surface.namespace});

    layer_surface.destroy.link.remove();
    layer_surface.map.link.remove();
    layer_surface.unmap.link.remove();
    layer_surface.commit.link.remove();
    layer_surface.new_popup.link.remove();

    layer_surface.destroyPopups();
    layer_surface.invalidateBlur(layer_surface.scene_layer);
    if (layer_surface.backdrop_blur) |blur| fx.destroyWindowBlur(blur);

    // Defensively clear any seat focus/scheduled/sent focus still pointing at
    // this surface, in case destroy arrives without a preceding matching unmap.
    layer_surface.clearSeatFocus();

    layer_surface.popup_tree.node.destroy();

    // The wlr_surface may outlive the wlr_layer_surface so we must clean up the user data.
    layer_surface.wlr_layer_surface.surface.data = null;

    server.layer_shell.surfaces.remove(layer_surface.ref.key);
    util.gpa.destroy(layer_surface);
}

fn handleMap(listener: *wl.Listener(void)) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("map", listener);
    const wlr_layer_surface = layer_surface.wlr_layer_surface;

    log.debug("layer surface '{s}' mapped", .{wlr_layer_surface.namespace});

    if (wlr_layer_surface.current.keyboard_interactive == .on_demand) {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.layer_shell.scheduled.focus != .exclusive) {
                seat.layer_shell.scheduled.focus = .{ .non_exclusive = layer_surface.ref };
            }
        }
    }

    layer_surface.syncBackdropBlur();
    // Beware: it is possible for arrange() to destroy this LayerSurface!
    const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
    layer_surface.invalidateBlur(wlr_layer_surface.current.layer);
    output.layer_shell.arrange();
    server.layer_shell.checkExclusiveFocus();
    server.wm.dirtyWindowing();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("unmap", listener);

    log.debug("layer surface '{s}' unmapped", .{layer_surface.wlr_layer_surface.namespace});

    layer_surface.clearSeatFocus();
    layer_surface.disableBackdropBlur();

    // Beware: it is possible for arrange() to destroy this LayerSurface!
    const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
    layer_surface.invalidateBlur(layer_surface.scene_layer);
    output.layer_shell.arrange();
    server.layer_shell.checkExclusiveFocus();
    server.wm.dirtyWindowing();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("commit", listener);
    const wlr_layer_surface = layer_surface.wlr_layer_surface;

    assert(wlr_layer_surface.output != null);

    // If the layer was changed, move the LayerSurface to the proper tree.
    if (wlr_layer_surface.current.committed.layer) {
        layer_surface.invalidateBlur(layer_surface.scene_layer);
        const tree = server.scene.layerSurfaceTree(wlr_layer_surface.current.layer);
        layer_surface.scene_layer_surface.tree.node.reparent(tree);
        layer_surface.scene_layer = wlr_layer_surface.current.layer;
    }

    layer_surface.invalidateBlur(wlr_layer_surface.current.layer);
    layer_surface.syncBackdropBlur();

    if (wlr_layer_surface.initial_commit or
        @as(u32, @bitCast(wlr_layer_surface.current.committed)) != 0)
    {
        // Beware: it is possible for arrange() to destroy this LayerSurface!
        const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
        output.layer_shell.arrange();
        server.layer_shell.checkExclusiveFocus();
        server.wm.dirtyWindowing();
    }
}

fn invalidateBlur(layer_surface: *LayerSurface, layer: zwlr.LayerShellV1.Layer) void {
    switch (layer) {
        .background, .bottom => {},
        .top, .overlay => if (!server.aqueous.hasLayerBlurRules()) return,
        else => return,
    }
    const wlr_output = layer_surface.wlr_layer_surface.output orelse return;
    const output: *Output = @ptrCast(@alignCast(wlr_output.data orelse return));
    output.markBlurDirty();
}

pub fn applyBlurRule(
    layer_surface: *LayerSurface,
    enabled: bool,
    blur_popups: bool,
) void {
    const main_changed = layer_surface.blur_requested != enabled;
    const popups_changed =
        layer_surface.blur_popups_requested != blur_popups;
    if (!main_changed and !popups_changed) return;
    layer_surface.blur_requested = enabled;
    layer_surface.blur_popups_requested = blur_popups;
    if (main_changed) layer_surface.syncBackdropBlur();
    if (popups_changed) layer_surface.syncPopupBlurRules();
    if (layer_surface.wlr_layer_surface.output) |wlr_output| {
        const output: *Output =
            @ptrCast(@alignCast(wlr_output.data orelse return));
        output.markBlurDirty();
    }
}

pub fn syncBlurEffects(layer_surface: *LayerSurface) void {
    layer_surface.syncBackdropBlur();
    var popups = server.layer_shell.popups.iterator();
    while (popups.next()) |popup| {
        if (popup.layer_owner == @as(?*anyopaque, @ptrCast(layer_surface))) {
            popup.syncBackdropBlur();
        }
    }
}

fn syncPopupBlurRules(layer_surface: *LayerSurface) void {
    var popups = server.layer_shell.popups.iterator();
    while (popups.next()) |popup| {
        if (popup.layer_owner == @as(?*anyopaque, @ptrCast(layer_surface))) {
            popup.applyBlurRule(layer_surface.blur_popups_requested);
        }
    }
}

pub fn syncBackdropBlur(layer_surface: *LayerSurface) void {
    const blur = layer_surface.backdrop_blur orelse return;
    const surface = layer_surface.wlr_layer_surface.surface;
    const active = layer_surface.blur_requested and
        surface.mapped and
        server.wm.blur.enabled and
        server.wm.blur.radius > 0 and
        server.wm.blur.passes > 0 and
        surface.current.width > 0 and
        surface.current.height > 0;
    if (!active) {
        layer_surface.disableBackdropBlur();
        return;
    }
    const box: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = @intCast(surface.current.width),
        .height = @intCast(surface.current.height),
    };
    layer_surface.blur_marker.node.setPosition(0, 0);
    layer_surface.blur_marker.setSize(box.width, box.height);
    layer_surface.blur_marker.node.setEnabled(true);
    fx.configureWindowBlur(blur, box, 0, true);
}

fn disableBackdropBlur(layer_surface: *LayerSurface) void {
    layer_surface.blur_marker.node.setEnabled(false);
    const blur = layer_surface.backdrop_blur orelse return;
    fx.configureWindowBlur(
        blur,
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        0,
        false,
    );
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(
        wlr_xdg_popup,
        layer_surface.popup_tree,
        null,
        null,
        @ptrCast(layer_surface),
        layer_surface.blur_popups_requested,
    ) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
}
