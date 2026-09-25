// SPDX-License-Identifier: GPL-3.0-only
//! Immediate-focus workspace cycling. Presentation never owns keyboard focus.
const Self = @This();
const std = @import("std");
const wl = @import("wayland").server.wl;
const server = &@import("main.zig").server;
const a = @import("util.zig").gpa;
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Workspace = @import("Workspace.zig");
const model = @import("wm/switcher/model.zig");
const overview = @import("wm/overview/model.zig");

rings: std.AutoHashMapUnmanaged(u32, model.Ring) = .empty,
output: ?*Output = null,
workspace: u32 = 0,
seat: ?*Seat = null,
input_seat: ?*Seat = null,
owner: ?*anyopaque = null,
selected: ?u64 = null,
position: usize = 0,
total: usize = 0,
serial: u64 = 0,
reduced_motion: bool = false,
timer: ?*wl.EventSource = null,

pub fn init(self: *Self) !void {
    self.* = .{};
    self.timer = try server.wl_server.getEventLoop().addTimer(*Self, timeout, self);
}
pub fn deinit(self: *Self) void {
    self.dismiss();
    if (self.timer) |t| t.remove();
    var it = self.rings.valueIterator();
    while (it.next()) |ring| ring.deinit(a);
    self.rings.deinit(a);
}
fn timeout(self: *Self) c_int {
    self.dismiss();
    return 0;
}
pub fn dismiss(self: *Self) void {
    if (self.output == null) return;
    self.output = null;
    self.owner = null;
    self.seat = null;
    self.selected = null;
    self.position = 0;
    self.total = 0;
    if (self.timer) |t| t.timerUpdate(0) catch {};
    server.aqueous.api.hideOverview();
    server.aqueous.api.suppressPointerConstraints(false);
    server.aqueous.api.refreshPointerFocus();
    server.shell_manager.dirty();
}
pub fn eligible(window: *Window, ws: *Workspace) bool {
    return window.state == .mapped and window.workspace == ws and window.wm_scheduled.accepts_focus and window.policy_state.focus_allowed and !window.policy_state.skip_switcher and window.policy_state.kind() != .minimized and Window.resolveModalHandle(@bitCast(window.ref)) == @as(u64, @bitCast(window.ref));
}
fn reconcile(self: *Self, ws: *Workspace) !*model.Ring {
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(a);
    var it = ws.windows.iterator(.forward);
    while (it.next()) |window| if (eligible(window, ws)) try ids.append(a, @bitCast(window.ref));
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    const entry = try self.rings.getOrPut(a, ws.id);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    try entry.value_ptr.reconcile(a, ids.items);
    return entry.value_ptr;
}
pub fn step(self: *Self, output: *Output, seat: *Seat, workspace: u32, reverse: bool, reduced_motion: bool) !void {
    if (server.lock_manager.state != .unlocked or !output.policyExposed()) return error.Unavailable;
    const ws = output.active_workspace orelse return error.Unavailable;
    if (ws.id != workspace) return error.StaleWorkspace;
    const ring = try self.reconcile(ws);
    const current = if (self.output == output and self.seat == seat and self.workspace == workspace) self.selected else seat.policyFocusedHandle();
    const next = ring.next(current, reverse) orelse {
        self.dismiss();
        return;
    };
    if (ring.ids.items.len == 1) {
        self.dismiss();
        return;
    }
    const ref: Window.Ref = @bitCast(next);
    const window = ref.get() orelse return error.Unavailable;
    const area = output.policyUsableBox();
    var cards: [3]overview.Card = undefined;
    var n: usize = 0;
    const at = std.mem.indexOfScalar(u64, ring.ids.items, next).?;
    const offsets = [_]usize{ 0, 1, ring.ids.items.len - 1 };
    for (offsets, 0..) |offset, slot| {
        const handle = ring.ids.items[(at + offset) % ring.ids.items.len];
        var duplicate = false;
        for (cards[0..n]) |card| duplicate = duplicate or card.handle == handle;
        if (duplicate) continue;
        const source = server.aqueous.api.windowGeometry(handle) orelse continue;
        cards[n] = .{ .handle = handle, .source = source, .target = model.cardRect(source, .{ .x = area.x, .y = area.y, .width = area.width, .height = area.height }, slot) };
        n += 1;
    }
    server.aqueous.cancelOverview();
    if (self.output != null and (self.output != output or self.seat != seat or self.workspace != workspace)) self.dismiss();
    // Scene failure is reported before focus is changed.
    server.overview.showDeck(output, cards[0..n], next, reduced_motion, reverse) catch |err| {
        self.dismiss();
        return err;
    };
    if (!server.aqueous.activateShellWindow(@bitCast(window.ref), std.mem.span(seat.wlr_seat.name))) {
        self.dismiss();
        server.overview.hide();
        return error.Unavailable;
    }
    self.output = output;
    self.owner = null;
    self.workspace = workspace;
    self.seat = seat;
    self.selected = next;
    self.position = at + 1;
    self.total = ring.ids.items.len;
    self.serial +%= 1;
    self.reduced_motion = reduced_motion;
    server.aqueous.api.suppressPointerConstraints(true);
    try self.timer.?.timerUpdate(1500);
    server.shell_manager.dirty();
}
/// Called with each policy transaction; prune rings even while presentation is idle.
pub fn validate(self: *Self) void {
    var keys: std.ArrayListUnmanaged(u32) = .empty;
    defer keys.deinit(a);
    var it = self.rings.keyIterator();
    while (it.next()) |key| keys.append(a, key.*) catch return;
    for (keys.items) |key| {
        var found: ?*Workspace = null;
        var outputs = server.om.outputs.iterator(.forward);
        while (outputs.next()) |out| {
            var spaces = out.workspaces.iterator(.forward);
            while (spaces.next()) |ws| if (ws.id == key) {
                found = ws;
                break;
            };
        }
        if (found) |ws| {
            _ = self.reconcile(ws) catch {};
        } else if (self.rings.fetchRemove(key)) |entry| {
            var ring = entry.value;
            ring.deinit(a);
        }
    }
    const output = self.output orelse return;
    if (server.lock_manager.state != .unlocked or !output.policyExposed()) return self.dismiss();
    const ws = output.active_workspace orelse return self.dismiss();
    if (ws.id != self.workspace) return self.dismiss();
    const seat = self.seat orelse return self.dismiss();
    const handle = self.selected orelse return self.dismiss();
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return self.dismiss();
    if (!eligible(window, ws) or seat.selected_output != output) return self.dismiss();
    const requested = server.aqueous.requested_stack_focus;
    if (requested != handle and seat.policyFocusedHandle() != handle) return self.dismiss();
    for (server.overview.entries.items) |entry| {
        const candidate: Window.Ref = @bitCast(entry.handle);
        const live = candidate.get() orelse return self.dismiss();
        if (!eligible(live, ws)) return self.dismiss();
    }
    const ring = self.rings.get(ws.id) orelse return self.dismiss();
    self.position = (std.mem.indexOfScalar(u64, ring.ids.items, handle) orelse return self.dismiss()) + 1;
    self.total = ring.ids.items.len;
}
pub fn builtin(self: *Self, reverse: bool) void {
    var seats = server.input_manager.seats.iterator(.forward);
    const seat = self.input_seat orelse blk: {
        const only = seats.next() orelse return;
        if (seats.next() != null) return;
        break :blk only;
    };
    const output = seat.selected_output orelse return;
    const ws = output.active_workspace orelse return;
    self.step(output, seat, ws.id, reverse, false) catch {};
}
