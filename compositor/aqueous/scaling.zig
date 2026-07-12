const std = @import("std");

pub const min_scale: f32 = 0.1;
pub const max_scale: f32 = 10.0;

pub fn clampScale(requested: f32) f32 {
    return std.math.clamp(requested, min_scale, max_scale);
}

pub fn roundScale(scale: f32) f32 {
    return @round(scale * 120) / 120;
}

pub fn normalizeScale(requested: f32) f32 {
    return roundScale(clampScale(requested));
}

pub fn preferredBufferScale(scale: f32) i32 {
    return @intFromFloat(@ceil(scale));
}

test "clampScale bounds" {
    try std.testing.expectEqual(min_scale, clampScale(0.0));
    try std.testing.expectEqual(min_scale, clampScale(-3.0));
    try std.testing.expectEqual(max_scale, clampScale(11.0));
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
}

test "preferredBufferScale ceils" {
    try std.testing.expectEqual(@as(i32, 1), preferredBufferScale(1.0));
    try std.testing.expectEqual(@as(i32, 2), preferredBufferScale(1.5));
    try std.testing.expectEqual(@as(i32, 2), preferredBufferScale(1.25));
    try std.testing.expectEqual(@as(i32, 2), preferredBufferScale(2.0));
    try std.testing.expectEqual(@as(i32, 3), preferredBufferScale(2.5));
}
