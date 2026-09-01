// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Stable per-workspace bottom-to-top window order.
//!
//! Ranks are derived from list positions instead of monotonically increasing
//! counters, so arbitrary raise/lower operations cannot overflow. Semantic
//! layers and transient constraints are resolved separately by policy.

const Stack = @This();

const std = @import("std");
const types = @import("../layout/types.zig");

items: std.ArrayListUnmanaged(types.Handle) = .empty,

pub fn deinit(stack: *Stack, allocator: std.mem.Allocator) void {
    stack.items.deinit(allocator);
}

pub fn contains(stack: *const Stack, handle: types.Handle) bool {
    return std.mem.indexOfScalar(types.Handle, stack.items.items, handle) != null;
}

/// Reconcile membership while preserving the order of surviving windows.
/// Newly visible windows are appended at the top in declared order.
pub fn sync(stack: *Stack, allocator: std.mem.Allocator, visible: []const types.Handle) !void {
    var index: usize = 0;
    while (index < stack.items.items.len) {
        if (std.mem.indexOfScalar(types.Handle, visible, stack.items.items[index]) != null) {
            index += 1;
        } else {
            _ = stack.items.orderedRemove(index);
        }
    }
    for (visible) |handle| {
        if (!stack.contains(handle)) try stack.items.append(allocator, handle);
    }
}

pub fn remove(stack: *Stack, handle: types.Handle) void {
    if (std.mem.indexOfScalar(types.Handle, stack.items.items, handle)) |index| {
        _ = stack.items.orderedRemove(index);
    }
}

pub fn raise(stack: *Stack, handle: types.Handle) bool {
    const index = std.mem.indexOfScalar(types.Handle, stack.items.items, handle) orelse return false;
    if (index + 1 == stack.items.items.len) return false;
    const value = stack.items.orderedRemove(index);
    stack.items.appendAssumeCapacity(value);
    return true;
}

pub fn lower(stack: *Stack, handle: types.Handle) bool {
    const index = std.mem.indexOfScalar(types.Handle, stack.items.items, handle) orelse return false;
    if (index == 0) return false;
    const value = stack.items.orderedRemove(index);
    stack.items.insertAssumeCapacity(0, value);
    return true;
}

pub fn placeAbove(stack: *Stack, handle: types.Handle, sibling: types.Handle) bool {
    return stack.placeRelative(handle, sibling, true);
}

pub fn placeBelow(stack: *Stack, handle: types.Handle, sibling: types.Handle) bool {
    return stack.placeRelative(handle, sibling, false);
}

fn placeRelative(stack: *Stack, handle: types.Handle, sibling: types.Handle, above: bool) bool {
    if (handle == sibling) return false;
    const source = std.mem.indexOfScalar(types.Handle, stack.items.items, handle) orelse return false;
    const value = stack.items.orderedRemove(source);
    const sibling_index = std.mem.indexOfScalar(types.Handle, stack.items.items, sibling) orelse {
        stack.items.insertAssumeCapacity(source, value);
        return false;
    };
    stack.items.insertAssumeCapacity(sibling_index + @intFromBool(above), value);
    return true;
}

/// One-based stable rank suitable for Placement.stack_order. Zero remains the
/// sentinel for handles which do not participate in this workspace stack.
pub fn rank(stack: *const Stack, handle: types.Handle) u64 {
    const index = std.mem.indexOfScalar(types.Handle, stack.items.items, handle) orelse return 0;
    return @intCast(index + 1);
}

test "sync preserves survivors and admits new windows at the top" {
    var stack: Stack = .{};
    defer stack.deinit(std.testing.allocator);
    try stack.sync(std.testing.allocator, &.{ 1, 2, 3 });
    _ = stack.raise(1);
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 3, 1 }, stack.items.items);
    try stack.sync(std.testing.allocator, &.{ 1, 3, 4 });
    try std.testing.expectEqualSlices(types.Handle, &.{ 3, 1, 4 }, stack.items.items);
}

test "raise lower and relative placement derive bounded ranks" {
    var stack: Stack = .{};
    defer stack.deinit(std.testing.allocator);
    try stack.sync(std.testing.allocator, &.{ 10, 20, 30, 40 });
    try std.testing.expect(stack.lower(30));
    try std.testing.expectEqualSlices(types.Handle, &.{ 30, 10, 20, 40 }, stack.items.items);
    try std.testing.expect(stack.raise(10));
    try std.testing.expectEqualSlices(types.Handle, &.{ 30, 20, 40, 10 }, stack.items.items);
    try std.testing.expect(stack.placeBelow(10, 20));
    try std.testing.expectEqualSlices(types.Handle, &.{ 30, 10, 20, 40 }, stack.items.items);
    try std.testing.expect(stack.placeAbove(30, 40));
    try std.testing.expectEqualSlices(types.Handle, &.{ 10, 20, 40, 30 }, stack.items.items);
    try std.testing.expectEqual(@as(u64, 4), stack.rank(30));
    try std.testing.expectEqual(@as(u64, 0), stack.rank(99));
}
