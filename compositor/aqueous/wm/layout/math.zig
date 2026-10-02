// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("types.zig");

pub const AxisCell = struct { offset: i32, size: i32 };

/// Cap a lone tile's width while retaining its full available height. Clamp
/// before converting to integer pixels, including for very large finite ratios.
pub fn centerSingleWindow(area: types.Rect, aspect_ratio: f64) types.Rect {
    if (area.width <= 0 or area.height <= 0 or !std.math.isFinite(aspect_ratio) or aspect_ratio <= 0) return area;
    const width: i32 = @intFromFloat(@max(1, @min(
        @as(f64, @floatFromInt(area.width)),
        @round(@as(f64, @floatFromInt(area.height)) * aspect_ratio),
    )));
    return .{ .x = area.x + @divTrunc(area.width - width, 2), .y = area.y, .width = width, .height = area.height };
}

pub fn shrink(rect: types.Rect, margin: i32) types.Rect {
    if (margin <= 0) return rect;
    return .{
        .x = rect.x + margin,
        .y = rect.y + margin,
        .width = @max(1, rect.width - 2 * margin),
        .height = @max(1, rect.height - 2 * margin),
    };
}

pub fn intersect(a: types.Rect, b: types.Rect) types.Rect {
    if (a.width <= 0 or a.height <= 0 or b.width <= 0 or b.height <= 0) return .empty;
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const width = @min(a.right(), b.right()) - x;
    const height = @min(a.bottom(), b.bottom()) - y;
    if (width <= 0 or height <= 0) return .empty;
    return .{ .x = x, .y = y, .width = width, .height = height };
}

pub fn clampToHints(rect: types.Rect, window: types.Window) types.Rect {
    var result = rect;
    if (window.min_width > 0 and result.width < window.min_width) result.width = window.min_width;
    if (window.min_height > 0 and result.height < window.min_height) result.height = window.min_height;
    if (window.max_width > 0 and result.width > window.max_width) result.width = window.max_width;
    if (window.max_height > 0 and result.height > window.max_height) result.height = window.max_height;
    return result;
}

pub fn splitAxis(allocator: std.mem.Allocator, length: i32, count: u32, gap: i32) ![]AxisCell {
    if (count == 0) return allocator.alloc(AxisCell, 0);
    const count_i32: i32 = @intCast(count);
    const total_gap = gap * (count_i32 - 1);
    const each_size = @max(1, @divTrunc(length - total_gap, count_i32));
    const leftover = @max(0, length - total_gap - each_size * count_i32);
    const result = try allocator.alloc(AxisCell, count);
    var current: i32 = 0;
    for (result, 0..) |*cell, i| {
        const size = each_size + if (i + 1 == count) leftover else 0;
        cell.* = .{ .offset = current, .size = size };
        current += size + gap;
    }
    return result;
}

test "rectangle operations are total" {
    try std.testing.expectEqual(types.Rect{ .x = 5, .y = 5, .width = 1, .height = 1 }, shrink(.{
        .x = 0,
        .y = 0,
        .width = 4,
        .height = 4,
    }, 5));
    try std.testing.expectEqual(types.Rect.empty, intersect(.{
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 2,
    }, .{ .x = 2, .y = 0, .width = 2, .height = 2 }));
    try std.testing.expectEqual(types.Rect{ .x = 2, .y = 2, .width = 2, .height = 2 }, intersect(.{
        .x = 0,
        .y = 0,
        .width = 4,
        .height = 4,
    }, .{ .x = 2, .y = 2, .width = 4, .height = 4 }));
}

test "split axis assigns remainder to final cell" {
    const cells = try splitAxis(std.testing.allocator, 100, 3, 4);
    defer std.testing.allocator.free(cells);
    try std.testing.expectEqualSlices(AxisCell, &.{
        .{ .offset = 0, .size = 30 },
        .{ .offset = 34, .size = 30 },
        .{ .offset = 68, .size = 32 },
    }, cells);
}

test "single window width cap respects local bounds and extreme ratios" {
    const area: types.Rect = .{ .x = -2000, .y = 31, .width = 3441, .height = 1000 };
    try std.testing.expectEqual(types.Rect{ .x = -1169, .y = 31, .width = 1778, .height = 1000 }, centerSingleWindow(area, 16.0 / 9.0));
    const portrait: types.Rect = .{ .x = 72, .y = -900, .width = 600, .height = 1000 };
    try std.testing.expectEqual(portrait, centerSingleWindow(portrait, 16.0 / 9.0));
    try std.testing.expectEqual(area, centerSingleWindow(area, std.math.floatMax(f64)));
    try std.testing.expectEqual(@as(i32, 1), centerSingleWindow(area, 1e-300).width);
    try std.testing.expectEqual(types.Rect.empty, centerSingleWindow(.empty, 1));
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64) }) |ratio| {
        try std.testing.expectEqual(area, centerSingleWindow(area, ratio));
    }
}
