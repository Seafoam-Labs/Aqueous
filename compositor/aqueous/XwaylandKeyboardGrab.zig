// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const XwaylandKeyboardGrab = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.xwayland);

pub const Manager = struct {
    global: ?*wl.Global = null,
    grabs: wl.list.Head(XwaylandKeyboardGrab, .link) = undefined,

    pub fn init(manager: *Manager) !void {
        manager.* = .{};
        manager.grabs.init();

        // This protocol is meaningful and safe only for the Xwayland process.
        if (server.xwayland != null) {
            manager.global = try wl.Global.create(
                server.wl_server,
                zwp.XwaylandKeyboardGrabManagerV1,
                1,
                *Manager,
                manager,
                bind,
            );
            log.debug("created Xwayland keyboard-grab global", .{});
        }
    }

    pub fn deinit(manager: *Manager) void {
        std.debug.assert(manager.grabs.empty());
        if (manager.global) |global| global.destroy();
        manager.global = null;
    }

    pub fn releaseSurface(manager: *Manager, surface: *wlr.Surface) void {
        var affected_seat: ?*Seat = null;
        var grabs = manager.grabs.iterator(.forward);
        while (grabs.next()) |grab| {
            if (grab.surface == surface and (grab.honored or grab.active)) {
                grab.honored = false;
                affected_seat = grab.seat;
            }
        }
        if (affected_seat) |seat| manager.selectNewestForSeat(seat);
    }

    /// Stop honoring all Xwayland grabs for a seat. Session locking uses this
    /// before assigning focus to the lock surface so a client grab can never
    /// intercept the lock screen's keyboard input.
    pub fn cancelForSeat(manager: *Manager, seat: *Seat) void {
        var affected = false;
        var grabs = manager.grabs.iterator(.forward);
        while (grabs.next()) |grab| {
            if (grab.seat != seat or (!grab.honored and !grab.active)) continue;
            grab.honored = false;
            affected = true;
        }
        if (affected) manager.selectNewestForSeat(seat);
    }

    fn bind(client: *wl.Client, manager: *Manager, version: u32, id: u32) void {
        const xwayland = server.xwayland orelse return;
        const xwayland_server = xwayland.server orelse return;
        if (client != xwayland_server.client) {
            log.warn("denied non-Xwayland client binding keyboard-grab global", .{});
            return;
        }

        const object = zwp.XwaylandKeyboardGrabManagerV1.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        object.setHandler(*Manager, handleManagerRequest, null, manager);
        log.debug("Xwayland bound keyboard-grab manager version={d}", .{version});
    }

    fn handleManagerRequest(
        object: *zwp.XwaylandKeyboardGrabManagerV1,
        request: zwp.XwaylandKeyboardGrabManagerV1.Request,
        manager: *Manager,
    ) void {
        switch (request) {
            .destroy => object.destroy(),
            .grab_keyboard => |args| create(manager, object, args) catch {
                object.postNoMemory();
            },
        }
    }

    fn selectNewestForSeat(manager: *Manager, seat: *Seat) void {
        var had_active = false;
        var active_grabs = manager.grabs.iterator(.forward);
        while (active_grabs.next()) |grab| {
            if (grab.seat == seat and grab.active) {
                grab.deactivate();
                had_active = true;
            }
        }

        seat.xwayland_keyboard_grab_surface = null;
        var grabs = manager.grabs.iterator(.reverse);
        while (grabs.next()) |grab| {
            if (grab.seat == seat and grab.honored) {
                if (grab.activate()) return;
                break;
            }
        }

        if (had_active) seat.restoreKeyboardFocusAfterXwaylandGrab();
    }
};

manager: *Manager,
object: *zwp.XwaylandKeyboardGrabV1,
seat: *Seat,
surface: *wlr.Surface,
honored: bool = false,
active: bool = false,
keyboard_grab: wlr.Seat.KeyboardGrab,
surface_destroy: wl.Listener(*wlr.Surface) = .init(handleSurfaceDestroy),
surface_map: wl.Listener(void) = .init(handleSurfaceMap),
surface_unmap: wl.Listener(void) = .init(handleSurfaceUnmap),
link: wl.list.Link,

fn create(
    manager: *Manager,
    manager_object: *zwp.XwaylandKeyboardGrabManagerV1,
    args: anytype,
) error{OutOfMemory}!void {
    const object = zwp.XwaylandKeyboardGrabV1.create(
        manager_object.getClient(),
        manager_object.getVersion(),
        args.id,
    ) catch return error.OutOfMemory;

    // The protocol requires the object to be created even when the compositor
    // declines the grab. Invalid objects therefore remain inert until the
    // client destroys them.
    const wlr_seat_client = wlr.Seat.Client.fromWlSeat(args.seat) orelse {
        object.setHandler(?*anyopaque, handleIgnoredRequest, null, null);
        return;
    };
    const seat_data = wlr_seat_client.seat.data orelse {
        object.setHandler(?*anyopaque, handleIgnoredRequest, null, null);
        return;
    };
    const surface = wlr.Surface.fromWlSurface(args.surface);
    const seat: *Seat = @ptrCast(@alignCast(seat_data));

    const grab = try util.gpa.create(XwaylandKeyboardGrab);
    grab.* = .{
        .manager = manager,
        .object = object,
        .seat = seat,
        .surface = surface,
        .keyboard_grab = .{
            .interface = &keyboard_grab_interface,
            .seat = seat.wlr_seat,
            .data = null,
        },
        .link = undefined,
    };
    object.setHandler(*XwaylandKeyboardGrab, handleRequest, handleDestroy, grab);
    surface.events.destroy.add(&grab.surface_destroy);
    surface.events.map.add(&grab.surface_map);
    surface.events.unmap.add(&grab.surface_unmap);
    manager.grabs.append(grab);

    log.debug(
        "Xwayland requested keyboard grab surface=0x{x} mapped={}",
        .{ @intFromPtr(surface), surface.mapped },
    );

    grab.maybeHonor();
}

fn maybeHonor(grab: *XwaylandKeyboardGrab) void {
    if (grab.honored or !grab.surface.mapped) return;

    // Defense in depth: the global filter and bind callback already restrict
    // the manager, but never honor a grab for a non-Xwayland wl_surface.
    if (grab.surface.resource.getClient() != grab.object.getClient()) return;
    const node_data = SceneNodeData.fromSurface(grab.surface) orelse return;
    switch (node_data.data) {
        .window => |window| if (window.impl != .xwayland) return,
        .override_redirect => {},
        else => return,
    }

    grab.honored = true;
    grab.manager.selectNewestForSeat(grab.seat);
}

fn activate(grab: *XwaylandKeyboardGrab) bool {
    if (!grab.honored or grab.active or !grab.surface.mapped or
        server.lock_manager.state != .unlocked)
    {
        return false;
    }

    // A protocol keyboard grab supersedes any shorter-lived wlroots grab. End
    // it through the grab API so its owner receives the normal cancellation
    // callback instead of silently replacing the pointer in keyboard_state.
    if (grab.seat.wlr_seat.keyboardHasGrab()) {
        log.info("Xwayland keyboard grab replacing an existing seat grab", .{});
        grab.seat.wlr_seat.keyboardEndGrab();
    }

    // Establish the protocol target while the default grab is active. Once
    // our grab starts, enter/clear-focus requests are deliberately ignored and
    // key/modifier callbacks continue sending to this focused client.
    grab.seat.focusXwaylandGrabSurface(grab.surface);
    grab.seat.xwayland_keyboard_grab_surface = grab.surface;
    grab.seat.xwayland_keyboard_grab = &grab.keyboard_grab;
    grab.active = true;
    grab.seat.wlr_seat.keyboardStartGrab(&grab.keyboard_grab);
    log.info(
        "honoring Xwayland keyboard grab surface=0x{x}",
        .{@intFromPtr(grab.surface)},
    );
    return true;
}

fn deactivate(grab: *XwaylandKeyboardGrab) void {
    if (!grab.active) return;

    if (grab.seat.wlr_seat.keyboard_state.grab == &grab.keyboard_grab) {
        grab.seat.wlr_seat.keyboardEndGrab();
    } else {
        // A different wlroots subsystem may have superseded this grab. Its
        // target is no longer authoritative, but never end the newer grab.
        grab.active = false;
        if (grab.seat.xwayland_keyboard_grab_surface == grab.surface) {
            grab.seat.xwayland_keyboard_grab_surface = null;
        }
        if (grab.seat.xwayland_keyboard_grab == &grab.keyboard_grab) {
            grab.seat.xwayland_keyboard_grab = null;
        }
    }
}

const keyboard_grab_interface: wlr.Seat.KeyboardGrab.Interface = .{
    .enter = keyboardGrabEnter,
    .clear_focus = keyboardGrabClearFocus,
    .key = keyboardGrabKey,
    .modifiers = keyboardGrabModifiers,
    .cancel = keyboardGrabCancel,
};

fn keyboardGrabEnter(
    _: *wlr.Seat.KeyboardGrab,
    _: *wlr.Surface,
    _: ?[*]const u32,
    _: usize,
    _: ?*const wlr.Keyboard.Modifiers,
) callconv(.c) void {
    // Keyboard focus remains on the protocol target until this grab ends.
}

fn keyboardGrabClearFocus(_: *wlr.Seat.KeyboardGrab) callconv(.c) void {
    // Keyboard focus remains on the protocol target until this grab ends.
}

fn keyboardGrabKey(
    wlr_grab: *wlr.Seat.KeyboardGrab,
    time_msec: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    wlr_grab.seat.keyboardSendKey(time_msec, key, state);
}

fn keyboardGrabModifiers(
    wlr_grab: *wlr.Seat.KeyboardGrab,
    modifiers: ?*const wlr.Keyboard.Modifiers,
) callconv(.c) void {
    wlr_grab.seat.keyboardSendModifiers(modifiers);
}

fn keyboardGrabCancel(wlr_grab: *wlr.Seat.KeyboardGrab) callconv(.c) void {
    const grab: *XwaylandKeyboardGrab = @fieldParentPtr("keyboard_grab", wlr_grab);
    grab.active = false;
    if (grab.seat.xwayland_keyboard_grab_surface == grab.surface) {
        grab.seat.xwayland_keyboard_grab_surface = null;
    }
    if (grab.seat.xwayland_keyboard_grab == &grab.keyboard_grab) {
        grab.seat.xwayland_keyboard_grab = null;
    }
}

fn handleRequest(
    object: *zwp.XwaylandKeyboardGrabV1,
    request: zwp.XwaylandKeyboardGrabV1.Request,
    _: *XwaylandKeyboardGrab,
) void {
    switch (request) {
        .destroy => object.destroy(),
    }
}

fn handleIgnoredRequest(
    object: *zwp.XwaylandKeyboardGrabV1,
    request: zwp.XwaylandKeyboardGrabV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
    }
}

fn handleDestroy(_: *zwp.XwaylandKeyboardGrabV1, grab: *XwaylandKeyboardGrab) void {
    const manager = grab.manager;
    const seat = grab.seat;
    const was_honored = grab.honored or grab.active;
    grab.honored = false;
    if (was_honored) manager.selectNewestForSeat(seat);

    grab.surface_destroy.link.remove();
    grab.surface_map.link.remove();
    grab.surface_unmap.link.remove();
    grab.link.remove();
    util.gpa.destroy(grab);

    log.info("released Xwayland keyboard grab", .{});
}

fn handleSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const grab: *XwaylandKeyboardGrab = @fieldParentPtr("surface_destroy", listener);
    grab.object.destroy();
}

fn handleSurfaceMap(listener: *wl.Listener(void)) void {
    const grab: *XwaylandKeyboardGrab = @fieldParentPtr("surface_map", listener);
    grab.maybeHonor();
}

fn handleSurfaceUnmap(listener: *wl.Listener(void)) void {
    const grab: *XwaylandKeyboardGrab = @fieldParentPtr("surface_unmap", listener);
    grab.manager.releaseSurface(grab.surface);
}
