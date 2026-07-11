// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("types.zig");

pub const State = struct {
    items: std.ArrayListUnmanaged(types.Handle) = .empty,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.items.deinit(allocator);
    }

    pub fn sync(state: *State, allocator: std.mem.Allocator, windows: []const types.Window) !void {
        var write: usize = 0;
        for (state.items.items) |handle| {
            if (containsWindow(windows, handle)) {
                state.items.items[write] = handle;
                write += 1;
            }
        }
        state.items.shrinkRetainingCapacity(write);
        for (windows) |window| {
            if (std.mem.indexOfScalar(types.Handle, state.items.items, window.handle) == null) {
                try state.items.append(allocator, window.handle);
            }
        }
    }

    pub fn swap(state: *State, a: types.Handle, b: types.Handle) bool {
        if (a == b) return false;
        const ia = std.mem.indexOfScalar(types.Handle, state.items.items, a) orelse return false;
        const ib = std.mem.indexOfScalar(types.Handle, state.items.items, b) orelse return false;
        std.mem.swap(types.Handle, &state.items.items[ia], &state.items.items[ib]);
        return true;
    }
};

fn containsWindow(windows: []const types.Window, handle: types.Handle) bool {
    for (windows) |window| if (window.handle == handle) return true;
    return false;
}

test "sync retains live order, drops stale, and appends new handles" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try state.sync(std.testing.allocator, &.{ .{ .handle = 1 }, .{ .handle = 2 } });
    try state.sync(std.testing.allocator, &.{ .{ .handle = 3 }, .{ .handle = 1 } });
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3 }, state.items.items);
}
