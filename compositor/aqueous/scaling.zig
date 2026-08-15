const std = @import("std");

/// Supported output scale range. Single source of truth for every scale
/// entry point: config files, the output service socket, and
/// wlr-output-management-v1 (via `Output.State.fromHeadState`).
pub const min_scale: f32 = 0.5;
pub const max_scale: f32 = 3.0;

pub fn clampScale(requested: f32) f32 {
    return std.math.clamp(requested, min_scale, max_scale);
}

pub fn roundScale(scale: f32) f32 {
    return @round(scale * 120) / 120;
}

/// Clamp into the supported range and snap to the 1/120 grid used by
/// wp_fractional_scale_v1.
pub fn normalizeScale(requested: f32) f32 {
    return roundScale(clampScale(requested));
}

/// Logical extent of a physical-pixel length at the given output scale.
/// Rounds rather than truncates, so modes whose pixel size does not divide
/// evenly by the scale do not report a logical size 1px short of the
/// boundary math layout uses in Output.zig (`scaleBoundary`).
pub fn logicalDimension(physical: i32, scale: f32) u31 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(physical)) / scale));
}

test "clampScale bounds" {
    try std.testing.expectEqual(min_scale, clampScale(0.0));
    try std.testing.expectEqual(min_scale, clampScale(-3.0));
    try std.testing.expectEqual(max_scale, clampScale(11.0));
    try std.testing.expectEqual(min_scale, clampScale(0.5));
    try std.testing.expectEqual(max_scale, clampScale(3.0));
    try std.testing.expectEqual(@as(f32, 1.0), clampScale(1.0));
    try std.testing.expectEqual(@as(f32, 1.5), clampScale(1.5));
}

test "roundScale snaps to 1/120" {
    try std.testing.expectEqual(@as(f32, 1.0), roundScale(1.0));
    try std.testing.expectEqual(@as(f32, 2.0), roundScale(2.0));
    try std.testing.expectEqual(@as(f32, @round(1.5 * 120)) / 120, roundScale(1.5));
    try std.testing.expectEqual(@as(f32, @round(1.25 * 120)) / 120, roundScale(1.25));
}

test "normalizeScale clamps then rounds" {
    try std.testing.expectEqual(roundScale(min_scale), normalizeScale(0.0));
    try std.testing.expectEqual(roundScale(max_scale), normalizeScale(50.0));
    try std.testing.expectEqual(@as(f32, 1.0), normalizeScale(1.0));
    try std.testing.expectEqual(@as(f32, 1.25), normalizeScale(1.25));
}

test "logicalDimension rounds non-even divisions" {
    // 1001 / 1.25 = 800.8; truncation would report 800.
    try std.testing.expectEqual(@as(u31, 801), logicalDimension(1001, 1.25));
    try std.testing.expectEqual(@as(u31, 800), logicalDimension(1000, 1.25));
    // Even divisions stay exact.
    try std.testing.expectEqual(@as(u31, 2048), logicalDimension(2560, 1.25));
    try std.testing.expectEqual(@as(u31, 960), logicalDimension(1920, 2.0));
    try std.testing.expectEqual(@as(u31, 1080), logicalDimension(1080, 1.0));
    try std.testing.expectEqual(@as(u31, 0), logicalDimension(0, 1.5));
}
