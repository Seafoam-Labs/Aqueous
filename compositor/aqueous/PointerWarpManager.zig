// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const PointerWarpManager = @This();
const wl = @import("wayland").server.wl;
const wp = @import("wayland").server.wp;
const wlr = @import("wlroots");
const Seat = @import("Seat.zig");
const server = &@import("main.zig").server;

extern fn wlr_seat_client_validate_pointer_enter_serial(client: *wlr.Seat.Client, serial: u32) bool;

global: *wl.Global,

pub fn init(self: *PointerWarpManager) !void {
    self.* = .{ .global = try wl.Global.create(server.wl_server, wp.PointerWarpV1, 1, *PointerWarpManager, self, bind) };
}

pub fn deinit(self: *PointerWarpManager) void {
    self.global.destroy();
}

fn bind(client: *wl.Client, self: *PointerWarpManager, version: u32, id: u32) void {
    const resource = wp.PointerWarpV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*PointerWarpManager, handleRequest, null, self);
}

fn handleRequest(resource: *wp.PointerWarpV1, request: wp.PointerWarpV1.Request, _: *PointerWarpManager) void {
    switch (request) {
        .destroy => resource.destroy(),
        .warp_pointer => |args| {
            const client = wlr.Seat.Client.fromWlPointer(args.pointer) orelse return;
            if (client.client != resource.getClient() or args.surface.getClient() != client.client) return;
            const seat_data = client.seat.data orelse return;
            const surface = wlr.Surface.fromWlSurface(args.surface);
            if (client.seat.pointer_state.focused_client != client or
                client.seat.pointer_state.focused_surface != surface or
                !wlr_seat_client_validate_pointer_enter_serial(client, args.serial)) return;
            const seat: *Seat = @ptrCast(@alignCast(seat_data));
            seat.cursor.warpForClient(surface, args.x.toDouble(), args.y.toDouble());
        },
    }
}
