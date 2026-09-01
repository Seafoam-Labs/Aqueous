// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Shared, overflow-safe freeform geometry policy.

const std = @import("std");
const types = @import("types.zig");

pub const ResizeEdges = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn any(edges: ResizeEdges) bool {
        return edges.top or edges.bottom or edges.left or edges.right;
    }
};

pub const Constraints = struct {
    min_width: i32 = 1,
    min_height: i32 = 1,
    max_width: i32 = 0,
    max_height: i32 = 0,
    base_width: i32 = 0,
    base_height: i32 = 0,
    width_inc: i32 = 0,
    height_inc: i32 = 0,
    min_aspect_num: i32 = 0,
    min_aspect_den: i32 = 0,
    max_aspect_num: i32 = 0,
    max_aspect_den: i32 = 0,

    pub fn fromWindow(window: types.Window) Constraints {
        return .{
            .min_width = @max(1, window.min_width),
            .min_height = @max(1, window.min_height),
            .max_width = window.max_width,
            .max_height = window.max_height,
            .base_width = window.base_width,
            .base_height = window.base_height,
            .width_inc = window.width_inc,
            .height_inc = window.height_inc,
            .min_aspect_num = window.min_aspect_num,
            .min_aspect_den = window.min_aspect_den,
            .max_aspect_num = window.max_aspect_num,
            .max_aspect_den = window.max_aspect_den,
        };
    }
};

pub const Size = struct { width: i32, height: i32 };

pub fn constrainSize(raw_width: i64, raw_height: i64, constraints: Constraints, edges: ResizeEdges) Size {
    const minimum_width: i64 = @max(1, constraints.min_width);
    const minimum_height: i64 = @max(1, constraints.min_height);
    const maximum_width: i64 = if (constraints.max_width > 0) @max(constraints.max_width, constraints.min_width) else std.math.maxInt(i32);
    const maximum_height: i64 = if (constraints.max_height > 0) @max(constraints.max_height, constraints.min_height) else std.math.maxInt(i32);
    var width = std.math.clamp(raw_width, minimum_width, maximum_width);
    var height = std.math.clamp(raw_height, minimum_height, maximum_height);

    width = quantize(width, constraints.base_width, constraints.width_inc, minimum_width, maximum_width);
    height = quantize(height, constraints.base_height, constraints.height_inc, minimum_height, maximum_height);

    const horizontal = edges.left or edges.right;
    const vertical = edges.top or edges.bottom;
    if (validRatio(constraints.min_aspect_num, constraints.min_aspect_den) and
        width * constraints.min_aspect_den < height * constraints.min_aspect_num)
    {
        if (horizontal or !vertical) {
            width = ceilDiv(height * constraints.min_aspect_num, constraints.min_aspect_den);
        } else {
            height = @divTrunc(width * constraints.min_aspect_den, constraints.min_aspect_num);
        }
    }
    if (validRatio(constraints.max_aspect_num, constraints.max_aspect_den) and
        width * constraints.max_aspect_den > height * constraints.max_aspect_num)
    {
        if (horizontal or !vertical) {
            width = @divTrunc(height * constraints.max_aspect_num, constraints.max_aspect_den);
        } else {
            height = ceilDiv(width * constraints.max_aspect_den, constraints.max_aspect_num);
        }
    }

    width = quantize(std.math.clamp(width, minimum_width, maximum_width), constraints.base_width, constraints.width_inc, minimum_width, maximum_width);
    height = quantize(std.math.clamp(height, minimum_height, maximum_height), constraints.base_height, constraints.height_inc, minimum_height, maximum_height);
    return .{ .width = clampI32(width), .height = clampI32(height) };
}

/// Resolve an edge-anchored interactive resize. The opposite edge remains
/// fixed when constraints alter the pointer-requested dimensions.
pub fn resize(start: types.Rect, dx: i32, dy: i32, edges: ResizeEdges, constraints: Constraints) types.Rect {
    var raw_width: i64 = start.width;
    var raw_height: i64 = start.height;
    if (edges.left) raw_width -= dx else if (edges.right) raw_width += dx;
    if (edges.top) raw_height -= dy else if (edges.bottom) raw_height += dy;
    const size = constrainSize(raw_width, raw_height, constraints, edges);
    const fixed_right = @as(i64, start.x) + start.width;
    const fixed_bottom = @as(i64, start.y) + start.height;
    return .{
        .x = if (edges.left) clampI32(fixed_right - size.width) else start.x,
        .y = if (edges.top) clampI32(fixed_bottom - size.height) else start.y,
        .width = size.width,
        .height = size.height,
    };
}

/// Keep at least the requested portion of a window inside the usable area.
/// This permits intentional off-screen placement without allowing a window to
/// become permanently unreachable.
pub fn keepReachable(rect: types.Rect, area: types.Rect, reachable_width: i32, reachable_height: i32) types.Rect {
    if (rect.width <= 0 or rect.height <= 0 or area.width <= 0 or area.height <= 0) return rect;
    const visible_width: i64 = @min(rect.width, @max(1, reachable_width));
    const visible_height: i64 = @min(rect.height, @max(1, reachable_height));
    const minimum_x = @as(i64, area.x) - rect.width + visible_width;
    const maximum_x = @as(i64, area.x) + area.width - visible_width;
    const minimum_y = @as(i64, area.y) - rect.height + visible_height;
    const maximum_y = @as(i64, area.y) + area.height - visible_height;
    return .{
        .x = clampI32(std.math.clamp(@as(i64, rect.x), minimum_x, maximum_x)),
        .y = clampI32(std.math.clamp(@as(i64, rect.y), minimum_y, maximum_y)),
        .width = rect.width,
        .height = rect.height,
    };
}

pub const SnapDirection = enum {
    left,
    right,
    up,
    down,
    up_left,
    up_right,
    down_left,
    down_right,
    center,
};

pub fn snap(area: types.Rect, direction: SnapDirection, gap: i32) types.Rect {
    const inset = @max(0, gap);
    const inner = types.Rect{
        .x = clampI32(@as(i64, area.x) + inset),
        .y = clampI32(@as(i64, area.y) + inset),
        .width = @max(1, area.width -| inset *| 2),
        .height = @max(1, area.height -| inset *| 2),
    };
    const left_width = @divFloor(inner.width, 2);
    const right_width = inner.width - left_width;
    const top_height = @divFloor(inner.height, 2);
    const bottom_height = inner.height - top_height;
    return switch (direction) {
        .left => .{ .x = inner.x, .y = inner.y, .width = left_width, .height = inner.height },
        .right => .{ .x = inner.x + left_width, .y = inner.y, .width = right_width, .height = inner.height },
        .up => .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = top_height },
        .down => .{ .x = inner.x, .y = inner.y + top_height, .width = inner.width, .height = bottom_height },
        .up_left => .{ .x = inner.x, .y = inner.y, .width = left_width, .height = top_height },
        .up_right => .{ .x = inner.x + left_width, .y = inner.y, .width = right_width, .height = top_height },
        .down_left => .{ .x = inner.x, .y = inner.y + top_height, .width = left_width, .height = bottom_height },
        .down_right => .{ .x = inner.x + left_width, .y = inner.y + top_height, .width = right_width, .height = bottom_height },
        .center => inner,
    };
}

/// Apply client size constraints to a snap slot while retaining the edge or
/// corner which gives that slot its meaning.
pub fn constrainSnap(target: types.Rect, direction: SnapDirection, constraints: Constraints) types.Rect {
    const size = constrainSize(target.width, target.height, constraints, .{ .right = true, .bottom = true });
    const align_right = switch (direction) {
        .right, .up_right, .down_right => true,
        else => false,
    };
    const align_bottom = switch (direction) {
        .down, .down_left, .down_right => true,
        else => false,
    };
    const center_x = switch (direction) {
        .up, .down, .center => true,
        else => false,
    };
    const center_y = switch (direction) {
        .left, .right, .center => true,
        else => false,
    };
    return .{
        .x = if (center_x)
            clampI32(@as(i64, target.x) + @divTrunc(@as(i64, target.width) - size.width, 2))
        else if (align_right)
            clampI32(@as(i64, target.x) + target.width - size.width)
        else
            target.x,
        .y = if (center_y)
            clampI32(@as(i64, target.y) + @divTrunc(@as(i64, target.height) - size.height, 2))
        else if (align_bottom)
            clampI32(@as(i64, target.y) + target.height - size.height)
        else
            target.y,
        .width = size.width,
        .height = size.height,
    };
}

pub fn snapDirectionAt(area: types.Rect, x: i32, y: i32, threshold: i32, top_maximizes: bool) ?SnapDirection {
    if (threshold <= 0 or area.width <= 0 or area.height <= 0) return null;
    const near_left = @as(i64, x) <= @as(i64, area.x) + threshold;
    const near_right = @as(i64, x) >= @as(i64, area.x) + area.width - threshold;
    const near_top = @as(i64, y) <= @as(i64, area.y) + threshold;
    const near_bottom = @as(i64, y) >= @as(i64, area.y) + area.height - threshold;
    if (near_left and near_top) return .up_left;
    if (near_right and near_top) return .up_right;
    if (near_left and near_bottom) return .down_left;
    if (near_right and near_bottom) return .down_right;
    if (near_left) return .left;
    if (near_right) return .right;
    if (near_bottom) return .down;
    if (near_top) return if (top_maximizes) .center else .up;
    return null;
}

/// Apply magnetic edge attraction against one output or peer rectangle.
pub fn attractToRect(rect: types.Rect, target: types.Rect, threshold: i32) types.Rect {
    if (threshold <= 0 or rect.width <= 0 or rect.height <= 0 or target.width <= 0 or target.height <= 0) return rect;
    var result = rect;
    const vertical_overlap = @as(i64, rect.y) < @as(i64, target.y) + target.height and @as(i64, rect.y) + rect.height > target.y;
    if (vertical_overlap) {
        const candidates = [_]i64{ target.x, @as(i64, target.x) + target.width, @as(i64, target.x) - rect.width, @as(i64, target.x) + target.width - rect.width };
        var best_delta: i64 = threshold + 1;
        for (candidates) |candidate| {
            const delta = candidate - rect.x;
            if (@abs(delta) <= threshold and @abs(delta) < @abs(best_delta)) best_delta = delta;
        }
        if (@abs(best_delta) <= threshold) result.x = clampI32(@as(i64, rect.x) + best_delta);
    }
    const horizontal_overlap = @as(i64, result.x) <= @as(i64, target.x) + target.width and @as(i64, result.x) + result.width >= target.x;
    if (horizontal_overlap) {
        const candidates = [_]i64{ target.y, @as(i64, target.y) + target.height, @as(i64, target.y) - rect.height, @as(i64, target.y) + target.height - rect.height };
        var best_delta: i64 = threshold + 1;
        for (candidates) |candidate| {
            const delta = candidate - rect.y;
            if (@abs(delta) <= threshold and @abs(delta) < @abs(best_delta)) best_delta = delta;
        }
        if (@abs(best_delta) <= threshold) result.y = clampI32(@as(i64, rect.y) + best_delta);
    }
    return result;
}

fn quantize(value: i64, raw_base: i32, raw_increment: i32, minimum: i64, maximum: i64) i64 {
    const increment: i64 = raw_increment;
    if (increment <= 1) return std.math.clamp(value, minimum, maximum);
    const base: i64 = @max(0, raw_base);
    const relative = @max(0, value - base);
    const snapped = base + @divTrunc(relative + @divTrunc(increment, 2), increment) * increment;
    return std.math.clamp(snapped, minimum, maximum);
}

fn validRatio(numerator: i32, denominator: i32) bool {
    return numerator > 0 and denominator > 0;
}

fn ceilDiv(numerator: i64, denominator: i32) i64 {
    return @divTrunc(numerator + denominator - 1, denominator);
}

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

test "resize honors min max increments and anchored edges" {
    const start: types.Rect = .{ .x = 100, .y = 50, .width = 300, .height = 200 };
    const constrained = resize(start, 500, -37, .{ .left = true, .bottom = true }, .{
        .min_width = 120,
        .max_width = 500,
        .min_height = 100,
        .max_height = 400,
        .base_width = 100,
        .base_height = 80,
        .width_inc = 20,
        .height_inc = 10,
    });
    try std.testing.expectEqual(types.Rect{ .x = 280, .y = 50, .width = 120, .height = 160 }, constrained);
}

test "aspect constraints preserve the dragged axis" {
    const wide = constrainSize(300, 400, .{ .min_aspect_num = 16, .min_aspect_den = 9 }, .{ .right = true });
    try std.testing.expectEqual(@as(i32, 712), wide.width);
    try std.testing.expectEqual(@as(i32, 400), wide.height);
    const tall = constrainSize(1000, 200, .{ .max_aspect_num = 4, .max_aspect_den = 3 }, .{ .bottom = true });
    try std.testing.expectEqual(@as(i32, 1000), tall.width);
    try std.testing.expectEqual(@as(i32, 750), tall.height);
}

test "reachability permits offscreen placement but preserves an access strip" {
    try std.testing.expectEqual(
        types.Rect{ .x = -936, .y = -568, .width = 1000, .height = 600 },
        keepReachable(.{ .x = -5000, .y = -5000, .width = 1000, .height = 600 }, .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, 64, 32),
    );
}

test "snap divides odd usable areas without gaps" {
    const area: types.Rect = .{ .x = -100, .y = 20, .width = 1001, .height = 801 };
    const left = snap(area, .left, 0);
    const right = snap(area, .right, 0);
    try std.testing.expectEqual(left.x + left.width, right.x);
    try std.testing.expectEqual(area.width, left.width + right.width);
    try std.testing.expectEqual(types.Rect{ .x = 400, .y = 420, .width = 501, .height = 401 }, snap(area, .down_right, 0));
}

test "constrained snap preserves its semantic edge" {
    const target = snap(.{ .x = 0, .y = 0, .width = 1000, .height = 800 }, .right, 0);
    const result = constrainSnap(target, .right, .{ .max_width = 300, .max_height = 400 });
    try std.testing.expectEqual(types.Rect{ .x = 700, .y = 200, .width = 300, .height = 400 }, result);
}

test "snap detection prioritizes corners and configurable top maximize" {
    const area: types.Rect = .{ .x = -100, .y = 20, .width = 1000, .height = 800 };
    try std.testing.expectEqual(SnapDirection.up_left, snapDirectionAt(area, -90, 25, 24, true).?);
    try std.testing.expectEqual(SnapDirection.center, snapDirectionAt(area, 400, 25, 24, true).?);
    try std.testing.expectEqual(SnapDirection.up, snapDirectionAt(area, 400, 25, 24, false).?);
    try std.testing.expectEqual(@as(?SnapDirection, null), snapDirectionAt(area, 400, 400, 24, true));
}

test "edge attraction joins nearby window borders" {
    try std.testing.expectEqual(
        types.Rect{ .x = 300, .y = 100, .width = 200, .height = 150 },
        attractToRect(.{ .x = 307, .y = 94, .width = 200, .height = 150 }, .{ .x = 0, .y = 100, .width = 300, .height = 300 }, 10),
    );
}
