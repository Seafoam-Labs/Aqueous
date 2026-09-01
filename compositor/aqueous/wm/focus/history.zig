// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const History = @This();

const std = @import("std");

pub const Handle = u64;

allocator: std.mem.Allocator,
workspaces: std.AutoHashMapUnmanaged(Handle, std.ArrayListUnmanaged(Handle)) = .empty,

pub fn init(allocator: std.mem.Allocator) History {
    return .{ .allocator = allocator };
}

pub fn deinit(history: *History) void {
    var iterator = history.workspaces.valueIterator();
    while (iterator.next()) |items| items.deinit(history.allocator);
    history.workspaces.deinit(history.allocator);
}

pub fn record(history: *History, workspace: Handle, window: Handle) !void {
    if (workspace == 0 or window == 0) return;
    const entry = try history.workspaces.getOrPut(history.allocator, workspace);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    if (std.mem.indexOfScalar(Handle, entry.value_ptr.items, window)) |index| {
        _ = entry.value_ptr.orderedRemove(index);
    }
    try entry.value_ptr.insert(history.allocator, 0, window);
}

pub fn remove(history: *History, workspace: Handle, window: Handle) void {
    const items = history.workspaces.getPtr(workspace) orelse return;
    if (std.mem.indexOfScalar(Handle, items.items, window)) |index| _ = items.orderedRemove(index);
}

pub fn pick(history: *History, workspace: Handle, context: anytype, comptime is_valid: fn (@TypeOf(context), Handle) bool) Handle {
    if (workspace == 0) return 0;
    const items = history.workspaces.getPtr(workspace) orelse return 0;
    while (items.items.len > 0) {
        const candidate = items.items[0];
        if (is_valid(context, candidate)) return candidate;
        _ = items.orderedRemove(0);
    }
    return 0;
}

/// Choose the next valid MRU member without mutating history. Handles not yet
/// represented in history are appended in candidate order, which makes newly
/// admitted but deliberately unfocused windows reachable without destabilizing
/// the established MRU prefix.
pub fn cycle(
    history: *History,
    workspace: Handle,
    current: ?Handle,
    delta: i32,
    candidates: []const Handle,
    context: anytype,
    comptime is_valid: fn (@TypeOf(context), Handle) bool,
) !Handle {
    if (workspace == 0 or candidates.len == 0 or delta == 0) return 0;
    var order: std.ArrayListUnmanaged(Handle) = .empty;
    defer order.deinit(history.allocator);
    try order.ensureTotalCapacity(history.allocator, candidates.len);

    if (history.workspaces.get(workspace)) |items| {
        for (items.items) |handle| {
            if (!is_valid(context, handle) or std.mem.indexOfScalar(Handle, candidates, handle) == null) continue;
            order.appendAssumeCapacity(handle);
        }
    }
    for (candidates) |handle| {
        if (!is_valid(context, handle) or std.mem.indexOfScalar(Handle, order.items, handle) != null) continue;
        order.appendAssumeCapacity(handle);
    }
    if (order.items.len == 0) return 0;

    const index = if (current) |handle|
        std.mem.indexOfScalar(Handle, order.items, handle) orelse
            (if (delta > 0) order.items.len - 1 else 0)
    else if (delta > 0)
        order.items.len - 1
    else
        0;
    const next = if (delta > 0)
        (index + 1) % order.items.len
    else
        (index + order.items.len - 1) % order.items.len;
    return order.items[next];
}

test "history is MRU and lazily prunes stale handles" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.record(1, 10);
    try history.record(1, 20);
    try history.record(1, 10);
    const Valid = struct {
        fn check(_: void, handle: Handle) bool {
            return handle == 20;
        }
    };
    try std.testing.expectEqual(@as(Handle, 20), history.pick(1, {}, Valid.check));
    try std.testing.expectEqualSlices(Handle, &.{20}, history.workspaces.get(1).?.items);
}

test "cycle follows MRU and appends unseen valid candidates" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.record(1, 20);
    try history.record(1, 10);
    const Valid = struct {
        fn check(_: void, handle: Handle) bool {
            return handle != 40;
        }
    };
    const candidates = [_]Handle{ 10, 20, 30, 40 };
    try std.testing.expectEqual(@as(Handle, 20), try history.cycle(1, 10, 1, &candidates, {}, Valid.check));
    try std.testing.expectEqual(@as(Handle, 30), try history.cycle(1, 20, 1, &candidates, {}, Valid.check));
    try std.testing.expectEqual(@as(Handle, 30), try history.cycle(1, 10, -1, &candidates, {}, Valid.check));
}
