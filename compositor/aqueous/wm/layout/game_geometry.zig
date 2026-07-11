// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("types.zig");

pub const Anchor = enum { center, top, bottom, left, right };

pub const Size = union(enum) {
    native,
    pixels: struct { width: i32, height: i32 },
    fraction: struct { width: f64, height: f64 },
};

pub fn resolveAnchor(usable_area: types.Rect, requested_width: i32, requested_height: i32, size: Size, anchor: Anchor, scale: f64) types.Rect {
    var width: i32, var height: i32 = switch (size) {
        .native => .{ requested_width, requested_height },
        .pixels => |pixels| .{ pixels.width, pixels.height },
        .fraction => |fraction| .{
            @intFromFloat(@as(f64, @floatFromInt(usable_area.width)) * fraction.width),
            @intFromFloat(@as(f64, @floatFromInt(usable_area.height)) * fraction.height),
        },
    };
    if (scale > 0 and scale != 1) {
        width = @intFromFloat(@as(f64, @floatFromInt(width)) * scale);
        height = @intFromFloat(@as(f64, @floatFromInt(height)) * scale);
    }
    width = std.math.clamp(width, 1, usable_area.width);
    height = std.math.clamp(height, 1, usable_area.height);
    return switch (anchor) {
        .top => .{ .x = usable_area.x + @divTrunc(usable_area.width - width, 2), .y = usable_area.y, .width = width, .height = height },
        .bottom => .{ .x = usable_area.x + @divTrunc(usable_area.width - width, 2), .y = usable_area.bottom() - height, .width = width, .height = height },
        .left => .{ .x = usable_area.x, .y = usable_area.y + @divTrunc(usable_area.height - height, 2), .width = width, .height = height },
        .right => .{ .x = usable_area.right() - width, .y = usable_area.y + @divTrunc(usable_area.height - height, 2), .width = width, .height = height },
        .center => .{ .x = usable_area.x + @divTrunc(usable_area.width - width, 2), .y = usable_area.y + @divTrunc(usable_area.height - height, 2), .width = width, .height = height },
    };
}

pub fn resolveRemainder(usable_area: types.Rect, anchor: types.Rect) types.Rect {
    const candidates = [_]types.Rect{
        .{ .x = usable_area.x, .y = usable_area.y, .width = usable_area.width, .height = anchor.y - usable_area.y },
        .{ .x = usable_area.x, .y = anchor.bottom(), .width = usable_area.width, .height = usable_area.bottom() - anchor.bottom() },
        .{ .x = usable_area.x, .y = usable_area.y, .width = anchor.x - usable_area.x, .height = usable_area.height },
        .{ .x = anchor.right(), .y = usable_area.y, .width = usable_area.right() - anchor.right(), .height = usable_area.height },
    };
    var best: types.Rect = .empty;
    var best_area: i64 = 0;
    for (candidates) |candidate| {
        const area = @as(i64, candidate.width) * candidate.height;
        if (area > 0 and area > best_area) {
            best = candidate;
            best_area = area;
        }
    }
    return best;
}

pub const SideColumns = struct { left: types.Rect, right: types.Rect };

pub fn resolveSideColumns(usable_area: types.Rect, anchor: types.Rect) SideColumns {
    const left_width = anchor.x - usable_area.x;
    const right_width = usable_area.right() - anchor.right();
    return .{
        .left = if (left_width > 0) .{ .x = usable_area.x, .y = usable_area.y, .width = left_width, .height = usable_area.height } else .empty,
        .right = if (right_width > 0) .{ .x = anchor.right(), .y = usable_area.y, .width = right_width, .height = usable_area.height } else .empty,
    };
}

test "game anchor resolves native, pixel, and fraction sizes" {
    const area = types.Rect{ .x = 0, .y = 0, .width = 2560, .height = 1440 };
    try std.testing.expectEqual(types.Rect{ .x = 320, .y = 180, .width = 1920, .height = 1080 }, resolveAnchor(area, 1920, 1080, .native, .center, 1));
    try std.testing.expectEqual(types.Rect{ .x = 640, .y = 360, .width = 1280, .height = 720 }, resolveAnchor(area, 1920, 1080, .{ .pixels = .{ .width = 1280, .height = 720 } }, .center, 1));
    try std.testing.expectEqual(types.Rect{ .x = 640, .y = 360, .width = 1280, .height = 720 }, resolveAnchor(area, 1, 1, .{ .fraction = .{ .width = 0.5, .height = 0.5 } }, .center, 1));
}

test "game anchor clamps and supports edge anchors" {
    const area = types.Rect{ .x = 10, .y = 20, .width = 100, .height = 80 };
    try std.testing.expectEqual(area, resolveAnchor(area, 200, 200, .native, .center, 1));
    try std.testing.expectEqual(types.Rect{ .x = 40, .y = 20, .width = 40, .height = 30 }, resolveAnchor(area, 40, 30, .native, .top, 1));
    try std.testing.expectEqual(types.Rect{ .x = 70, .y = 45, .width = 40, .height = 30 }, resolveAnchor(area, 40, 30, .native, .right, 1));
}

test "game remainder excludes zero bands and preserves tie priority" {
    const area = types.Rect{ .x = 0, .y = 0, .width = 2560, .height = 1440 };
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 2560, .height = 180 }, resolveRemainder(area, .{ .x = 320, .y = 180, .width = 1920, .height = 1080 }));
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 640, .height = 2160 }, resolveRemainder(.{ .x = 0, .y = 0, .width = 3840, .height = 2160 }, .{ .x = 640, .y = 0, .width = 2560, .height = 2160 }));
    try std.testing.expectEqual(types.Rect.empty, resolveRemainder(area, area));
}