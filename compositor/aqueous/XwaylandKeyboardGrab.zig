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
            if (grab.surface == surface and grab.honored) {
                grab.honored = false;
                affected_seat = grab.seat;
            }
        }
        if (affected_seat) |seat| manager.selectNewestForSeat(seat);
    }

    fn bind(client: *wl.Client, manager: *Manager, version: u32, id: u32) void {
        const xwayland = server.xwayland orelse return;
        const xwayland_server = xwayland.server orelse return;
        if (client != xwayland_server.client) return;

        const object = zwp.XwaylandKeyboardGrabManagerV1.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        object.setHandler(*Manager, handleManagerRequest, null, manager);
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
        seat.xwayland_keyboard_grab_surface = null;
        var grabs = manager.grabs.iterator(.reverse);
        while (grabs.next()) |grab| {
            if (grab.seat == seat and grab.honored) {
                seat.xwayland_keyboard_grab_surface = grab.surface;
                grab.focusSurface();
                return;
            }
        }
    }
};

manager: *Manager,
object: *zwp.XwaylandKeyboardGrabV1,
seat: *Seat,
surface: *wlr.Surface,
honored: bool = false,
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
    const surface_data = args.surface.getUserData() orelse {
        object.setHandler(?*anyopaque, handleIgnoredRequest, null, null);
        return;
    };
    const seat_data = args.seat.getUserData() orelse {
        object.setHandler(?*anyopaque, handleIgnoredRequest, null, null);
        return;
    };
    const surface: *wlr.Surface = @ptrCast(@alignCast(surface_data));
    const seat: *Seat = @ptrCast(@alignCast(seat_data));

    const grab = try util.gpa.create(XwaylandKeyboardGrab);
    grab.* = .{
        .manager = manager,
        .object = object,
        .seat = seat,
        .surface = surface,
        .link = undefined,
    };
    object.setHandler(*XwaylandKeyboardGrab, handleRequest, handleDestroy, grab);
    surface.events.destroy.add(&grab.surface_destroy);
    surface.events.map.add(&grab.surface_map);
    surface.events.unmap.add(&grab.surface_unmap);
    manager.grabs.append(grab);

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
    grab.seat.xwayland_keyboard_grab_surface = grab.surface;
    grab.focusSurface();
    log.info("honoring Xwayland keyboard grab", .{});
}

fn focusSurface(grab: *XwaylandKeyboardGrab) void {
    const node_data = SceneNodeData.fromSurface(grab.surface) orelse return;
    switch (node_data.data) {
        .window => |window| {
            if (window.impl == .xwayland) {
                grab.seat.focusFromClient(.{ .window = window });
            }
        },
        .override_redirect => |override_redirect| {
            grab.seat.focusFromClient(.{ .override_redirect = override_redirect });
        },
        else => {},
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
    grab.surface_destroy.link.remove();
    grab.surface_map.link.remove();
    grab.surface_unmap.link.remove();
    grab.link.remove();
    const manager = grab.manager;
    const seat = grab.seat;
    util.gpa.destroy(grab);

    manager.selectNewestForSeat(seat);
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
