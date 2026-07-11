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
