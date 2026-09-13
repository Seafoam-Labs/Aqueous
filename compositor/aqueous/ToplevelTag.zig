// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const State = @This();
const std = @import("std");

tag: ?[:0]u8 = null,
description: ?[:0]u8 = null,

pub fn set(state: *State, allocator: std.mem.Allocator, comptime field: enum { tag, description }, value: []const u8) !bool {
    const slot = &@field(state, @tagName(field));
    if (slot.*) |old| if (std.mem.eql(u8, old, value)) return false;
    const owned = try allocator.dupeZ(u8, value);
    if (slot.*) |old| allocator.free(old);
    slot.* = owned;
    return true;
}

pub fn reset(state: *State, allocator: std.mem.Allocator) void {
    if (state.tag) |value| allocator.free(value);
    if (state.description) |value| allocator.free(value);
    state.* = .{};
}

test "metadata owns independent values and preserves state on allocation failure" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.reset(a);
    var source = [_]u8{'a'};
    try std.testing.expect(try state.set(a, .tag, &source));
    source[0] = 'b';
    try std.testing.expectEqualStrings("a", state.tag.?);
    try std.testing.expect(!try state.set(a, .tag, "a"));
    try std.testing.expect(try state.set(a, .description, ""));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.set(failing.allocator(), .tag, "replacement"));
    try std.testing.expectEqualStrings("a", state.tag.?);
    try std.testing.expectEqualStrings("", state.description.?);
    state.reset(a);
    try std.testing.expect(state.tag == null and state.description == null);
}
