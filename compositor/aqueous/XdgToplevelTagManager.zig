// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const Manager = @This();
const std = @import("std");
const c = @import("c");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const XdgToplevel = @import("XdgToplevel.zig");
const util = @import("util.zig");
const server = &@import("main.zig").server;
const TagEvent = c.struct_wlr_xdg_toplevel_tag_manager_v1_set_tag_event;
const DescriptionEvent = c.struct_wlr_xdg_toplevel_tag_manager_v1_set_description_event;

manager: *c.struct_wlr_xdg_toplevel_tag_manager_v1,
set_tag: wl.Listener(*TagEvent) = .init(handleTag),
set_description: wl.Listener(*DescriptionEvent) = .init(handleDescription),

pub fn init(display: *wl.Server) !Manager {
    return .{ .manager = c.wlr_xdg_toplevel_tag_manager_v1_create(@ptrCast(display), 1) orelse return error.OutOfMemory };
}
pub fn listen(manager: *Manager) void {
    const tag: *wl.Signal(*TagEvent) = @ptrCast(&manager.manager.events.set_tag);
    const description: *wl.Signal(*DescriptionEvent) = @ptrCast(&manager.manager.events.set_description);
    tag.add(&manager.set_tag);
    description.add(&manager.set_description);
}
pub fn deinit(manager: *Manager) void {
    manager.set_tag.link.remove();
    manager.set_description.link.remove();
}
pub fn global(manager: Manager) *wl.Global {
    return @ptrCast(manager.manager.global);
}
fn handleTag(_: *wl.Listener(*TagEvent), event: *TagEvent) void {
    assign(event.toplevel, .tag, event.tag);
}
fn handleDescription(_: *wl.Listener(*DescriptionEvent), event: *DescriptionEvent) void {
    assign(event.toplevel, .description, event.description);
}
fn assign(native: ?*c.struct_wlr_xdg_toplevel, comptime field: anytype, value: [*c]const u8) void {
    const top: *wlr.XdgToplevel = @ptrCast(@alignCast(native orelse return));
    // wlroots emits new_toplevel synchronously from get_toplevel, so valid
    // requests before the first commit already have Aqueous-owned state.
    const data = top.base.data orelse return;
    const toplevel: *XdgToplevel = @ptrCast(@alignCast(data));
    const changed = toplevel.tag_metadata.set(util.gpa, field, std.mem.span(value)) catch {
        top.resource.postNoMemory();
        return;
    };
    if (!changed) return;
    if (field == .tag) server.wm.dirtyWindowing();
    server.shell_manager.dirty();
}
