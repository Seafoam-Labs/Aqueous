// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub fn hasOverlap(rects: []const Rect) bool {
    for (rects, 0..) |left, i| {
        if (left.width <= 0 or left.height <= 0) continue;
        for (rects[i + 1 ..]) |right| {
            if (right.width <= 0 or right.height <= 0) continue;
            if (left.x < right.x + right.width and
                right.x < left.x + left.width and
                left.y < right.y + right.height and
                right.y < left.y + left.height)
            {
                return true;
            }
        }
    }
    return false;
}

test "detects overlapping initial output rectangles" {
    try std.testing.expect(hasOverlap(&.{
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .{ .x = 0, .y = 0, .width = 2560, .height = 1440 },
    }));
    try std.testing.expect(hasOverlap(&.{
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .{ .x = 1800, .y = 100, .width = 2560, .height = 1440 },
    }));
}

test "edge touching and empty outputs do not overlap" {
    try std.testing.expect(!hasOverlap(&.{
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .{ .x = 1920, .y = 0, .width = 2560, .height = 1440 },
        .{ .x = 0, .y = 1080, .width = 1280, .height = 720 },
    }));
    try std.testing.expect(!hasOverlap(&.{
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
    }));
}
