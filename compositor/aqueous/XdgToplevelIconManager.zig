// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const Manager = @This();
const c = @import("c");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const XdgToplevel = @import("XdgToplevel.zig");
const Event = c.struct_wlr_xdg_toplevel_icon_manager_v1_set_icon_event;

manager: *c.struct_wlr_xdg_toplevel_icon_manager_v1,
set_icon: wl.Listener(*Event) = .init(handleSetIcon),

pub fn init(display: *wl.Server) !Manager {
    const manager = c.wlr_xdg_toplevel_icon_manager_v1_create(@ptrCast(display), 1) orelse return error.OutOfMemory;
    var sizes = [_]c_int{ 32, 64, 128 };
    c.wlr_xdg_toplevel_icon_manager_v1_set_sizes(manager, &sizes, sizes.len);
    return .{ .manager = manager };
}

pub fn listen(manager: *Manager) void {
    const signal: *wl.Signal(*Event) = @ptrCast(&manager.manager.events.set_icon);
    signal.add(&manager.set_icon);
}

pub fn deinit(manager: *Manager) void {
    manager.set_icon.link.remove();
}

pub fn global(manager: Manager) *wl.Global {
    return @ptrCast(manager.manager.global);
}

fn handleSetIcon(_: *wl.Listener(*Event), event: *Event) void {
    const top: *wlr.XdgToplevel = @ptrCast(@alignCast(event.toplevel));
    const data = top.base.data orelse return;
    const toplevel: *XdgToplevel = @ptrCast(@alignCast(data));
    toplevel.icon.assign(event.icon);
}
