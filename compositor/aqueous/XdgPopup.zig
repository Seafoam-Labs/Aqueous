// SPDX-FileCopyrightText: © 2023 The River Developers
// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const XdgPopup = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const fx = @import("fx.zig");
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const SlotMap = @import("slotmap").SlotMap;
const Window = @import("Window.zig");

const log = std.log.scoped(.xdg_popup);

pub const Ref = packed struct {
    key: SlotMap(*XdgPopup).Key,

    pub fn get(ref: Ref) ?*XdgPopup {
        return server.layer_shell.popups.get(ref.key);
    }
};

ref: Ref,
wlr_popup: *wlr.XdgPopup,
tree: *wlr.SceneTree,
capture_tree: ?*wlr.SceneTree = null,
owner: ?Window.Ref,
/// Non-null only for popups whose root owner is a layer surface. The owning
/// LayerSurface destroys all of its protocol popups before freeing itself, so
/// this identity pointer is only compared and never dereferenced here.
layer_owner: ?*anyopaque,
blur_marker: *wlr.SceneRect,
backdrop_blur: ?fx.WindowBlur,
blur_requested: bool,

destroy: wl.Listener(void) = .init(handleDestroy),
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = .init(handleNewPopup),
reposition: wl.Listener(void) = .init(handleReposition),

// TODO check if popup is set_reactive and reposition on parent movement.
pub fn create(
    wlr_popup: *wlr.XdgPopup,
    parent: *wlr.SceneTree,
    capture_parent: ?*wlr.SceneTree,
    owner: ?Window.Ref,
    layer_owner: ?*anyopaque,
    blur_requested: bool,
) error{OutOfMemory}!void {
    const xdg_popup = try util.gpa.create(XdgPopup);
    errdefer util.gpa.destroy(xdg_popup);

    const key = try server.layer_shell.popups.put(util.gpa, xdg_popup);
    errdefer server.layer_shell.popups.remove(key);

    const tree = try parent.createSceneXdgSurface(wlr_popup.base);
    errdefer tree.node.destroy();
    const blur_marker = try tree.createSceneRect(
        0,
        0,
        &.{ 0, 0, 0, 1.0 / 255.0 },
    );
    blur_marker.node.lowerToBottom();
    blur_marker.node.setEnabled(false);
    fx.setRectInputEnabled(blur_marker, false);
    // Window-owned popups retain their existing behavior. Only layer-owned
    // popup chains participate in the layer rule and allocate blur metadata.
    const backdrop_blur = if (layer_owner != null)
        fx.createWindowBlur(tree)
    else
        null;

    xdg_popup.* = .{
        .ref = .{ .key = key },
        .wlr_popup = wlr_popup,
        .tree = tree,
        .owner = owner,
        .layer_owner = layer_owner,
        .blur_marker = blur_marker,
        .backdrop_blur = backdrop_blur,
        .blur_requested = blur_requested,
    };
    if (capture_parent) |p| {
        xdg_popup.capture_tree = try p.createSceneXdgSurface(wlr_popup.base);
    }
    if (backdrop_blur) |blur| {
        fx.configureWindowBlur(
            blur,
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            0,
            false,
        );
    }

    wlr_popup.events.destroy.add(&xdg_popup.destroy);
    wlr_popup.base.surface.events.commit.add(&xdg_popup.commit);
    wlr_popup.base.surface.events.map.add(&xdg_popup.map);
    wlr_popup.base.surface.events.unmap.add(&xdg_popup.unmap);
    wlr_popup.base.events.new_popup.add(&xdg_popup.new_popup);
    wlr_popup.events.reposition.add(&xdg_popup.reposition);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("destroy", listener);

    xdg_popup.restoreFocus();

    xdg_popup.map.link.remove();
    xdg_popup.unmap.link.remove();

    xdg_popup.destroy.link.remove();
    xdg_popup.commit.link.remove();
    xdg_popup.new_popup.link.remove();
    xdg_popup.reposition.link.remove();

    if (xdg_popup.backdrop_blur) |blur| fx.destroyWindowBlur(blur);
    server.layer_shell.popups.remove(xdg_popup.ref.key);
    util.gpa.destroy(xdg_popup);
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("commit", listener);

    if (xdg_popup.wlr_popup.base.initial_commit) {
        handleReposition(&xdg_popup.reposition);
    }
    if (xdg_popup.owner) |owner| if (owner.get()) |window| window.applyOpacity();
    xdg_popup.syncBackdropBlur();
    xdg_popup.invalidateBlur();
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_popup: *wlr.XdgPopup) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(
        wlr_popup,
        xdg_popup.tree,
        xdg_popup.capture_tree,
        xdg_popup.owner,
        xdg_popup.layer_owner,
        xdg_popup.blur_requested,
    ) catch {
        wlr_popup.resource.postNoMemory();
        return;
    };
}

fn handleReposition(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("reposition", listener);
    const wlr_popup = xdg_popup.wlr_popup;

    var parent_lx: c_int = undefined;
    var parent_ly: c_int = undefined;
    _ = xdg_popup.tree.node.parent.?.node.coords(&parent_lx, &parent_ly);

    var anchor = wlr_popup.scheduled.rules.anchor_rect;
    anchor.x += parent_lx;
    anchor.y += parent_ly;
    const wlr_output = server.om.maxOverlapOutput(&anchor) orelse return;

    var constraint: wlr.Box = undefined;
    server.om.output_layout.getBox(wlr_output, &constraint);
    constraint.x -= parent_lx;
    constraint.y -= parent_ly;

    wlr_popup.scheduled.rules.unconstrainBox(&constraint, &wlr_popup.scheduled.geometry);
    _ = wlr_popup.base.scheduleConfigure();
}

fn handleMap(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("map", listener);
    const wlr_popup = xdg_popup.wlr_popup;

    // Cover clients which map using a buffer committed before the ordinary
    // popup commit listener observed the complete scene subtree.
    if (xdg_popup.owner) |owner| if (owner.get()) |window| window.applyOpacity();
    xdg_popup.syncBackdropBlur();
    xdg_popup.invalidateBlur();

    if (wlr_popup.seat) |wlr_seat| {
        const seat: *Seat = @ptrCast(@alignCast(wlr_seat.data));
        seat.keyboardEnterOrLeave(wlr_popup.base.surface);
    }
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("unmap", listener);

    xdg_popup.restoreFocus();
    xdg_popup.disableBackdropBlur();
    xdg_popup.invalidateBlur();
}

pub fn applyBlurRule(xdg_popup: *XdgPopup, enabled: bool) void {
    if (xdg_popup.blur_requested == enabled) return;
    xdg_popup.blur_requested = enabled;
    xdg_popup.syncBackdropBlur();
    xdg_popup.invalidateBlur();
}

pub fn syncBackdropBlur(xdg_popup: *XdgPopup) void {
    const blur = xdg_popup.backdrop_blur orelse return;
    const surface = xdg_popup.wlr_popup.base.surface;
    const geometry = xdg_popup.wlr_popup.current.geometry;
    const active = xdg_popup.blur_requested and
        surface.mapped and
        server.wm.blur.enabled and
        server.wm.blur.radius > 0 and
        server.wm.blur.passes > 0 and
        geometry.width > 0 and
        geometry.height > 0;
    if (!active) {
        xdg_popup.disableBackdropBlur();
        return;
    }

    const box: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = geometry.width,
        .height = geometry.height,
    };
    xdg_popup.blur_marker.node.setPosition(0, 0);
    xdg_popup.blur_marker.setSize(box.width, box.height);
    xdg_popup.blur_marker.node.setEnabled(true);
    fx.configureWindowBlur(blur, box, 0, true);
}

fn disableBackdropBlur(xdg_popup: *XdgPopup) void {
    xdg_popup.blur_marker.node.setEnabled(false);
    const blur = xdg_popup.backdrop_blur orelse return;
    fx.configureWindowBlur(
        blur,
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        0,
        false,
    );
}

fn invalidateBlur(_: *XdgPopup) void {
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| output.markBlurDirty();
}

pub fn ownsNode(xdg_popup: *const XdgPopup, node: *wlr.SceneNode) bool {
    var current = node;
    while (true) {
        if (current == &xdg_popup.tree.node) return true;
        const parent = current.parent orelse return false;
        current = &parent.node;
    }
}

fn restoreFocus(xdg_popup: *XdgPopup) void {
    const wlr_popup = xdg_popup.wlr_popup;
    const popup_surface = wlr_popup.base.surface;

    var seat_it = server.input_manager.seats.iterator(.forward);
    while (seat_it.next()) |seat| {
        if (seat.wlr_seat.keyboard_state.focused_surface) |focused_surface| {
            if (focused_surface == popup_surface) {
                seat.keyboardEnterOrLeave(wlr_popup.parent orelse seat.focused.surface());
            }
        }
    }
}
