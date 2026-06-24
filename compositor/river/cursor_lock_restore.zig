const std = @import("std");

pub const SurfacePoint = struct {
    sx: f64,
    sy: f64,
};

pub const transition_suppression_msec = 50;
pub const transition_delta_threshold = 100;

pub fn clampPoint(sx: f64, sy: f64, width: f64, height: f64) SurfacePoint {
    if (width <= 0 or height <= 0) return .{ .sx = 0, .sy = 0 };
    return .{
        .sx = std.math.clamp(sx, 0, width - 1),
        .sy = std.math.clamp(sy, 0, height - 1),
    };
}

pub fn suppressMotion(
    event_generation: u64,
    current_generation: u64,
    time_msec: u32,
    suppression_until: u32,
    dx: f64,
    dy: f64,
) bool {
    if (event_generation != current_generation) return true;
    if (suppression_until != 0 and time_msec <= suppression_until) {
        if (@abs(dx) + @abs(dy) > transition_delta_threshold) return true;
    }
    return false;
}

test "clampPoint keeps restore inside surface" {
    try std.testing.expectEqualDeep(SurfacePoint{ .sx = 0, .sy = 49 }, clampPoint(-25, 80, 100, 50));
    try std.testing.expectEqualDeep(SurfacePoint{ .sx = 99, .sy = 0 }, clampPoint(125, -10, 100, 50));
}

test "clampPoint handles empty surfaces" {
    try std.testing.expectEqualDeep(SurfacePoint{ .sx = 0, .sy = 0 }, clampPoint(10, 10, 0, 50));
    try std.testing.expectEqualDeep(SurfacePoint{ .sx = 0, .sy = 0 }, clampPoint(10, 10, 100, 0));
}

test "suppressMotion rejects stale generations and large transition deltas" {
    try std.testing.expect(suppressMotion(1, 2, 100, 150, 1, 1));
    try std.testing.expect(suppressMotion(2, 2, 125, 150, 101, 0));
    try std.testing.expect(!suppressMotion(2, 2, 125, 150, 50, 49));
    try std.testing.expect(!suppressMotion(2, 2, 175, 150, 200, 0));
}
