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

/// Output-local physical pixel grid. Scene geometry remains expressed in
/// logical coordinates, but every visible origin is resolved through this
/// grid before it reaches the renderer. This is the same separation used by
/// compositors such as niri: clients still receive integral configure sizes,
/// while compositor-owned placement may use fractional logical coordinates.
pub const PhysicalGrid = struct {
    scale: f64,

    pub fn init(scale: f32) PhysicalGrid {
        return .{ .scale = @floatCast(normalizeScale(scale)) };
    }

    /// Nearest logical coordinate whose scaled value is an integer pixel.
    pub fn snap(grid: PhysicalGrid, logical_value: f64) f64 {
        return @round(logical_value * grid.scale) / grid.scale;
    }

    /// Snap in an output-local coordinate space. Output layout origins are
    /// logical coordinates and are not generally physical boundaries on a
    /// neighboring output with a different scale.
    pub fn snapFromOrigin(grid: PhysicalGrid, logical_value: f64, origin: f64) f64 {
        return origin + grid.snap(logical_value - origin);
    }

    /// Physical boundary selected for a logical coordinate.
    pub fn boundary(grid: PhysicalGrid, logical_value: f64) i32 {
        return @intFromFloat(@round(logical_value * grid.scale));
    }

    /// Convert an exact physical boundary back to logical coordinates.
    pub fn logical(grid: PhysicalGrid, physical: i32) f64 {
        return @as(f64, @floatFromInt(physical)) / grid.scale;
    }
};

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

test "physical grid snaps logical origins without subpixel filtering" {
    const grid = PhysicalGrid.init(1.25);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), grid.snap(1.0), 0.000_001);
    try std.testing.expectEqual(@as(i32, 1), grid.boundary(grid.snap(1.0)));
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), grid.logical(3), 0.000_001);
}

test "physical grid follows each output scale" {
    const low = PhysicalGrid.init(1.25);
    const high = PhysicalGrid.init(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), low.snap(8.2), 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0 + 2.0 / 3.0), high.snap(8.4), 0.000_001);
    try std.testing.expectEqual(@as(i32, 10), low.boundary(low.snap(8.2)));
    try std.testing.expectEqual(@as(i32, 13), high.boundary(high.snap(8.4)));
}

test "physical grid is local to the owning output origin" {
    const grid = PhysicalGrid.init(1.25);
    const origin: f64 = 1921;
    const snapped = grid.snapFromOrigin(1922, origin);
    try std.testing.expectApproxEqAbs(@as(f64, 1921.8), snapped, 0.000_001);
    try std.testing.expectEqual(@as(i32, 1), grid.boundary(snapped - origin));
}
