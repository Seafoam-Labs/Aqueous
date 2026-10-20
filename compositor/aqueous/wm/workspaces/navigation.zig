// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

/// Return the workspace that horizontal focus enters after running past the
/// edge of `current`, out of `count` workspaces. Navigation wraps between the
/// last workspace and workspace 1. Returns null when there is nowhere to go.
pub fn adjacent(current: u32, delta: i32, count: u32) ?u32 {
    if (delta == 0 or count < 2 or current == 0 or current > count) return null;
    if (delta > 0) return if (current == count) 1 else current + 1;
    return if (current == 1) count else current - 1;
}

test "adjacent visits every workspace" {
    try std.testing.expectEqual(@as(?u32, 2), adjacent(1, 1, 9));
    try std.testing.expectEqual(@as(?u32, 5), adjacent(4, 1, 9));
    try std.testing.expectEqual(@as(?u32, 3), adjacent(4, -1, 9));
    try std.testing.expectEqual(@as(?u32, 1), adjacent(2, -1, 9));
}

test "adjacent wraps at both ends" {
    try std.testing.expectEqual(@as(?u32, 1), adjacent(9, 1, 9));
    try std.testing.expectEqual(@as(?u32, 9), adjacent(1, -1, 9));
}

test "adjacent has nowhere to go" {
    try std.testing.expectEqual(@as(?u32, null), adjacent(1, 1, 1));
    try std.testing.expectEqual(@as(?u32, null), adjacent(0, 1, 9));
    try std.testing.expectEqual(@as(?u32, null), adjacent(10, 1, 9));
    try std.testing.expectEqual(@as(?u32, null), adjacent(2, 0, 9));
}
