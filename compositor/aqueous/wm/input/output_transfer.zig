// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("../layout/types.zig");

/// Output ownership changes when the pointer enters the output's full logical
/// rectangle. Half-open edges give adjacent outputs a single deterministic
/// owner, including layouts with negative origins.
pub fn containsPoint(area: types.Rect, x: f64, y: f64) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    return x >= @as(f64, @floatFromInt(area.x)) and
        y >= @as(f64, @floatFromInt(area.y)) and
        x < @as(f64, @floatFromInt(@as(i64, area.x) + area.width)) and
        y < @as(f64, @floatFromInt(@as(i64, area.y) + area.height));
}

/// Recover a floating rectangle after its output disappears. Logical size is
/// preserved across output scales and transforms. A window that fits is made
/// fully visible; an oversized window is aligned to the usable top-left so its
/// controls remain reachable without silently resizing it.
pub fn recoverGeometry(geometry: types.Rect, usable_area: types.Rect) types.Rect {
    if (geometry.width <= 0 or geometry.height <= 0 or
        usable_area.width <= 0 or usable_area.height <= 0)
    {
        return geometry;
    }
    return .{
        .x = fitAxis(geometry.x, geometry.width, usable_area.x, usable_area.width),
        .y = fitAxis(geometry.y, geometry.height, usable_area.y, usable_area.height),
        .width = geometry.width,
        .height = geometry.height,
    };
}

fn fitAxis(position: i32, size: i32, area_position: i32, area_size: i32) i32 {
    if (size >= area_size) return area_position;
    const minimum: i64 = area_position;
    const maximum = minimum + area_size - size;
    return @intCast(std.math.clamp(@as(i64, position), minimum, maximum));
}

test "point ownership uses half-open logical output edges" {
    const area: types.Rect = .{ .x = -1280, .y = 64, .width = 1280, .height = 720 };
    try std.testing.expect(containsPoint(area, -1280, 64));
    try std.testing.expect(containsPoint(area, -0.01, 783.99));
    try std.testing.expect(!containsPoint(area, 0, 200));
    try std.testing.expect(!containsPoint(area, -100, 784));
    try std.testing.expect(!containsPoint(area, std.math.nan(f64), 100));
}

test "recovery preserves logical size inside negative transformed usable area" {
    // A rotated, scaled destination is already represented by its logical
    // 360x640 rectangle. Static/dynamic struts reduced it to this usable area.
    const usable: types.Rect = .{ .x = -720, .y = 48, .width = 328, .height = 592 };
    const recovered = recoverGeometry(
        .{ .x = 500, .y = -300, .width = 300, .height = 200 },
        usable,
    );
    try std.testing.expectEqual(
        types.Rect{ .x = -692, .y = 48, .width = 300, .height = 200 },
        recovered,
    );
}

test "oversized recovery keeps dimensions and exposes the usable top-left" {
    const recovered = recoverGeometry(
        .{ .x = 4000, .y = 3000, .width = 1200, .height = 900 },
        .{ .x = 1280, .y = 32, .width = 640, .height = 688 },
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 1280, .y = 32, .width = 1200, .height = 900 },
        recovered,
    );
}
