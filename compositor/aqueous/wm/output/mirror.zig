// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
pub const Box = struct { x: i32, y: i32, width: i32, height: i32 };

pub fn fit(sw: i32, sh: i32, dw: i32, dh: i32) Box {
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const wide = @as(i64, sw) * dh > @as(i64, dw) * sh;
    const width: i32 = if (wide) dw else @intCast(@max(1, @divTrunc(@as(i64, sw) * dh, sh)));
    const height: i32 = if (wide) @intCast(@max(1, @divTrunc(@as(i64, sh) * dw, sw))) else dh;
    return .{ .x = @divTrunc(dw - width, 2), .y = @divTrunc(dh - height, 2), .width = width, .height = height };
}

test "mirror preserves aspect ratio and centers letterboxing" {
    try std.testing.expectEqual(Box{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, fit(2560, 1440, 1920, 1080));
    try std.testing.expectEqual(Box{ .x = 240, .y = 0, .width = 1440, .height = 1080 }, fit(1600, 1200, 1920, 1080));
    try std.testing.expectEqual(Box{ .x = 0, .y = 240, .width = 1080, .height = 1440 }, fit(1200, 1600, 1080, 1920));
    try std.testing.expectEqual(@as(i32, 0), fit(0, 0, 1920, 1080).width);
}
