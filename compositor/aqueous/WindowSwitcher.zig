// SPDX-License-Identifier: GPL-3.0-only
//! Immediate-focus workspace and global cycling. Presentation never owns keyboard focus.
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
global_rings: std.AutoHashMapUnmanaged(*Seat, model.Ring) = .empty,
all: bool = false,
activating: bool = false,
warp_allowed: bool = false,
handoff: ?struct { seat: *Seat, ref: Window.Ref, workspace: u32, output_id: u64, owner: ?*anyopaque } = null,
output: ?*Output = null,
workspace: u32 = 0,
presentation_workspace: u32 = 0,
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
    var globals = self.global_rings.valueIterator();
    while (globals.next()) |ring| ring.deinit(a);
    self.global_rings.deinit(a);
    self.global_rings = .empty;
    self.rings = .empty;
    self.timer = null;
}
fn timeout(self: *Self) c_int {
    self.finish();
    return 0;
}
pub fn dismiss(self: *Self) void {
    self.handoff = null;
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
/// Finish only user selection, never lifecycle cancellation.
pub fn finish(self: *Self) void {
    const workspace = self.selectedWorkspace();
    const handoff: @TypeOf(self.handoff) = if (self.all and self.warp_allowed and self.seat != null and self.selected != null and workspace != null)
        .{ .seat = self.seat.?, .ref = @as(Window.Ref, @bitCast(self.selected.?)), .workspace = workspace.?.id, .output_id = workspace.?.output.policyId(), .owner = self.owner }
    else
        null;
    self.dismiss();
    self.handoff = handoff;
    if (handoff) |pending| {
        if (pending.ref.get()) |window| if (window.workspace) |ws| ws.output.prepareOverview();
        server.wm.dirtyWindowing();
    }
}
pub fn pointerIntent(self: *Self, seat: *Seat) void {
    if (self.seat == seat) self.warp_allowed = false;
    if (self.handoff) |pending| if (pending.seat == seat) {
        self.handoff = null;
    };
}
pub fn removeSeat(self: *Self, seat: *Seat) void {
    if (self.seat == seat) self.dismiss();
    self.pointerIntent(seat);
    if (self.global_rings.fetchRemove(seat)) |entry| {
        var ring = entry.value;
        ring.deinit(a);
    }
}
/// After every live tree has committed, never against animation clones.
pub fn finishWarp(self: *Self) void {
    const pending = self.handoff orelse return;
    self.handoff = null;
    const seat = pending.seat;
    if (!seat.canWarpPointer()) return;
    const window = pending.ref.get() orelse return;
    const ws = window.workspace orelse return;
    if (ws.id != pending.workspace or ws.output.policyId() != pending.output_id or
        !eligible(window, ws) or !ws.isActive() or seat.selected_output != ws.output or
        seat.focused != .window or seat.focused.window != window or
        seat.wlr_seat.keyboard_state.focused_surface != window.rootSurface()) return;
    seat.cursor.warpToFocusedWindow(window);
}
pub fn selectedWorkspace(self: *const Self) ?*Workspace {
    const ref: Window.Ref = @bitCast(self.selected orelse return null);
    return (ref.get() orelse return null).workspace;
}
pub fn confirmed(self: *const Self) bool {
    const seat = self.seat orelse return false;
    return self.selected != null and seat.policyFocusedHandle() == self.selected;
}
pub fn eligible(window: *Window, ws: *Workspace) bool {
    return ws.output.policyTransferTarget() and window.state == .mapped and window.workspace == ws and window.wm_scheduled.accepts_focus and window.policy_state.focus_allowed and !window.policy_state.skip_switcher and window.policy_state.kind() != .minimized and Window.resolveModalHandle(@bitCast(window.ref)) == @as(u64, @bitCast(window.ref));
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
fn reconcileGlobal(self: *Self, seat: *Seat) !*model.Ring {
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(a);
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        const ws = window.workspace orelse continue;
        if (eligible(window, ws)) try ids.append(a, @bitCast(window.ref));
    }
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    const entry = try self.global_rings.getOrPut(a, seat);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    try entry.value_ptr.reconcile(a, ids.items);
    return entry.value_ptr;
}
pub fn step(self: *Self, origin: *Output, seat: *Seat, workspace: u32, reverse: bool, reduced_motion: bool, all: bool) !void {
    if (server.lock_manager.state != .unlocked or !origin.policyTransferTarget()) return error.Unavailable;
    const output = if (all and self.all and self.seat == seat) self.output orelse origin else origin;
    const ws = output.active_workspace orelse return error.Unavailable;
    if (!all and ws.id != workspace) return error.StaleWorkspace;
    const ring = if (all) try self.reconcileGlobal(seat) else try self.reconcile(ws);
    const continuing = self.output == output and self.seat == seat and self.all == all and (all or self.workspace == workspace);
    const next = ring.next(if (continuing) self.selected else seat.policyFocusedHandle(), reverse) orelse {
        self.dismiss();
        return;
    };
    if (!all and ring.ids.items.len == 1) {
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
        var source: @import("wm/layout/types.zig").Rect = server.aqueous.api.windowGeometry(handle) orelse .{ .x = 0, .y = 0, .width = 640, .height = 480 };
        source.width = @max(1, source.width);
        source.height = @max(1, source.height);
        cards[n] = .{ .handle = handle, .source = source, .target = model.cardRect(source, .{ .x = area.x, .y = area.y, .width = area.width, .height = area.height }, slot) };
        n += 1;
    }
    server.aqueous.cancelOverview();
    if (!continuing) self.dismiss();
    self.handoff = null;
    // Allocate the presentation before activation can change focus/workspaces.
    if (ring.ids.items.len > 1) server.overview.showDeck(output, cards[0..n], next, reduced_motion, reverse) catch |err| {
        self.dismiss();
        return err;
    };
    self.output = output;
    self.owner = null;
    self.workspace = workspace;
    self.seat = seat;
    self.selected = next;
    self.position = at + 1;
    self.total = ring.ids.items.len;
    self.all = all;
    self.warp_allowed = all;
    self.serial +%= 1;
    self.reduced_motion = reduced_motion;
    self.activating = true;
    defer self.activating = false;
    if (!server.aqueous.activateShellWindow(@bitCast(window.ref), std.mem.span(seat.wlr_seat.name))) {
        self.dismiss();
        return error.Unavailable;
    }
    if (all and reduced_motion) if (window.workspace) |destination| destination.output.prepareOverview();
    self.presentation_workspace = (output.active_workspace orelse return error.Unavailable).id;
    server.aqueous.api.suppressPointerConstraints(true);
    self.timer.?.timerUpdate(1500) catch |err| {
        self.dismiss();
        return err;
    };
    server.shell_manager.dirty();
}
/// Called after focus/geometry commit. The one-window case needs no deck.
pub fn committed(self: *Self) void {
    if (self.output != null and self.all and self.total == 1 and self.confirmed()) self.finish();
    self.finishWarp();
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
    var globals = self.global_rings.keyIterator();
    while (globals.next()) |seat| {
        _ = self.reconcileGlobal(seat.*) catch {};
    }
    const output = self.output orelse return;
    if (server.lock_manager.state != .unlocked or !output.policyTransferTarget()) return self.dismiss();
    if ((output.active_workspace orelse return self.dismiss()).id != self.presentation_workspace) return self.dismiss();
    const ws = if (self.all) self.selectedWorkspace() orelse return self.dismiss() else output.active_workspace orelse return self.dismiss();
    if ((!self.all and ws.id != self.workspace) or !ws.isActive()) return self.dismiss();
    const seat = self.seat orelse return self.dismiss();
    const handle = self.selected orelse return self.dismiss();
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return self.dismiss();
    if (!eligible(window, ws) or seat.selected_output != ws.output) return self.dismiss();
    const requested = server.aqueous.requested_stack_focus;
    if (requested != handle and seat.policyFocusedHandle() != handle) return self.dismiss();
    for (server.overview.entries.items) |entry| {
        const candidate: Window.Ref = @bitCast(entry.handle);
        const live = candidate.get() orelse return self.dismiss();
        if (!eligible(live, if (self.all) live.workspace orelse return self.dismiss() else ws)) return self.dismiss();
    }
    const ring = (if (self.all) self.global_rings.get(seat) else self.rings.get(ws.id)) orelse return self.dismiss();
    self.position = (std.mem.indexOfScalar(u64, ring.ids.items, handle) orelse return self.dismiss()) + 1;
    self.total = ring.ids.items.len;
    server.overview.syncDeckScene(output) catch self.dismiss();
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
    self.step(output, seat, ws.id, reverse, false, true) catch {};
}

pub const Metadata = struct {
    scope: ?[]const u8,
    seat: ?[]const u8,
    workspace: ?[]const u8,
    output: ?[]const u8,
    pending: bool,
};
pub fn metadata(self: *const Self, allocator: std.mem.Allocator) !Metadata {
    const ws = self.selectedWorkspace();
    return .{
        .scope = if (self.output != null) (if (self.all) "all" else "workspace") else null,
        .seat = if (self.seat) |seat| std.mem.span(seat.wlr_seat.name) else null,
        .workspace = if (ws) |space| try std.fmt.allocPrint(allocator, "{d}", .{space.id}) else null,
        .output = if (ws) |space| try std.fmt.allocPrint(allocator, "{d}", .{space.output.shell_id}) else null,
        .pending = self.output != null and !self.confirmed(),
    };
}
