// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const ShortcutInhibitManager = @This();
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const server = &@import("main.zig").server;
manager: ?*wlr.KeyboardShortcutsInhibitManagerV1 = null,
new_inhibitor: wl.Listener(*wlr.KeyboardShortcutsInhibitorV1) = .init(onNew),
destroy: wl.Listener(*wlr.KeyboardShortcutsInhibitManagerV1) = .init(onDestroy),

pub fn init(self: *ShortcutInhibitManager) !void {
    self.* = .{ .manager = try wlr.KeyboardShortcutsInhibitManagerV1.create(server.wl_server) };
    self.manager.?.events.new_inhibitor.add(&self.new_inhibitor);
    self.manager.?.events.destroy.add(&self.destroy);
}
fn onDestroy(listener: *wl.Listener(*wlr.KeyboardShortcutsInhibitManagerV1), _: *wlr.KeyboardShortcutsInhibitManagerV1) void {
    const self: *ShortcutInhibitManager = @fieldParentPtr("destroy", listener);
    self.new_inhibitor.link.remove();
    self.destroy.link.remove();
    self.manager = null;
}
fn onNew(_: *wl.Listener(*wlr.KeyboardShortcutsInhibitorV1), _: *wlr.KeyboardShortcutsInhibitorV1) void {
    server.shortcuts.refresh();
}
pub fn refresh(self: *ShortcutInhibitManager) void {
    const manager = self.manager orelse return;
    var it = manager.inhibitors.iterator(.forward);
    while (it.next()) |inhibitor| {
        const eligible = server.lock_manager.state == .unlocked and
            server.aqueous.overview == null and inhibitor.seat.keyboard_state.focused_surface == inhibitor.surface;
        if (eligible and !inhibitor.active) inhibitor.activate();
        if (!eligible and inhibitor.active) inhibitor.deactivate();
    }
}
pub fn active(self: *ShortcutInhibitManager, seat: *wlr.Seat) bool {
    self.refresh();
    const manager = self.manager orelse return false;
    var it = manager.inhibitors.iterator(.forward);
    while (it.next()) |inhibitor| if (inhibitor.active and inhibitor.seat == seat) return true;
    return false;
}
