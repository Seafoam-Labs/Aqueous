const std = @import("std");

/// Supported output scale range. Single source of truth for every scale
/// entry point: config files, the output service socket, and
/// wlr-output-management-v1 (via `Output.State.fromHeadState`).
pub const min_scale: f32 = 0.5;
pub const max_scale: f32 = 3.0;

/// Preferred client-buffer scaling strategy. `native` advertises the exact
/// fractional output scale. `integer_ceil` keeps the output's logical geometry
/// fractional while asking clients for the next integer-sized backing buffer,
/// matching the compatibility path used for clients without fractional-scale
/// support.
pub const BufferScalePolicy = enum {
    native,
    integer_ceil,

    pub fn parse(value: []const u8) ?BufferScalePolicy {
        if (std.mem.eql(u8, value, "native")) return .native;
        if (std.mem.eql(u8, value, "integer-ceil") or
            std.mem.eql(u8, value, "integer_ceil")) return .integer_ceil;
        return null;
    }

    pub fn advertisedScale(policy: BufferScalePolicy, output_scale: f32) f64 {
        const normalized: f64 = @floatCast(normalizeScale(output_scale));
        return switch (policy) {
            .native => normalized,
            .integer_ceil => @ceil(normalized),
        };
    }
};

/// Resampling filter for a surface whose buffer scale does not match the
/// output scale. `auto` (the default) selects the high-quality area downscale
/// only when the buffer is actually minified; matched 1:1 surfaces keep the
/// cheap bilinear path. `bilinear`/`nearest` force the stock wlroots filters.
/// `high_quality` is an explicit opt-in to the area downscale whenever the
/// surface is minified, identical to `auto` but independent of future default
/// changes.
pub const ScaleFilter = enum {
    auto,
    bilinear,
    nearest,
    high_quality,

    pub fn parse(value: []const u8) ?ScaleFilter {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "bilinear") or std.mem.eql(u8, value, "linear")) return .bilinear;
        if (std.mem.eql(u8, value, "nearest")) return .nearest;
        if (std.mem.eql(u8, value, "high-quality") or
            std.mem.eql(u8, value, "high_quality")) return .high_quality;
        return null;
    }
};

/// The filter actually used for one draw once the resampling ratio is known.
pub const ResolvedFilter = enum { bilinear, nearest, area };

/// Ratio of physical destination pixels to source buffer pixels. Values below
/// 1 mean the buffer is minified (the blurry-text case from fractional scaling
/// with integer-buffer clients); values above 1 mean magnification. The smaller
/// axis governs so anisotropic scaling still triggers the downscale filter.
/// Zero-sized inputs yield 1 (no resampling decision).
pub fn downscaleRatio(src_w: f64, src_h: f64, dst_w: f64, dst_h: f64) f64 {
    if (src_w <= 0 or src_h <= 0 or dst_w <= 0 or dst_h <= 0) return 1;
    return @min(dst_w / src_w, dst_h / src_h);
}

/// Tolerance around 1:1 within which resampling is treated as identity. Slightly
/// looser than f64 epsilon because destination sizes are rounded to whole
/// physical pixels, so a nominally matched surface can differ by a fraction of
/// a percent without any visible resampling.
pub const ratio_epsilon: f64 = 0.001;

/// Resolve the configured filter for a draw at the given resampling ratio.
/// The area downscale only benefits minification; magnification keeps bilinear
/// because a box filter cannot add detail beyond the source.
pub fn resolveFilter(filter: ScaleFilter, ratio: f64) ResolvedFilter {
    const minified = ratio < 1.0 - ratio_epsilon;
    return switch (filter) {
        .nearest => .nearest,
        .bilinear => .bilinear,
        .auto, .high_quality => if (minified) .area else .bilinear,
    };
}

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

test "buffer scale policy parses aliases and advertises integer ceilings" {
    try std.testing.expectEqual(BufferScalePolicy.native, BufferScalePolicy.parse("native").?);
    try std.testing.expectEqual(BufferScalePolicy.integer_ceil, BufferScalePolicy.parse("integer-ceil").?);
    try std.testing.expectEqual(BufferScalePolicy.integer_ceil, BufferScalePolicy.parse("integer_ceil").?);
    try std.testing.expect(BufferScalePolicy.parse("nearest") == null);
    try std.testing.expectEqual(@as(f64, 1.25), BufferScalePolicy.native.advertisedScale(1.25));
    try std.testing.expectEqual(@as(f64, 2.0), BufferScalePolicy.integer_ceil.advertisedScale(1.25));
    try std.testing.expectEqual(@as(f64, 2.0), BufferScalePolicy.integer_ceil.advertisedScale(2.0));
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

test "scale filter parses aliases and rejects unknown values" {
    try std.testing.expectEqual(ScaleFilter.auto, ScaleFilter.parse("auto").?);
    try std.testing.expectEqual(ScaleFilter.bilinear, ScaleFilter.parse("bilinear").?);
    try std.testing.expectEqual(ScaleFilter.bilinear, ScaleFilter.parse("linear").?);
    try std.testing.expectEqual(ScaleFilter.nearest, ScaleFilter.parse("nearest").?);
    try std.testing.expectEqual(ScaleFilter.high_quality, ScaleFilter.parse("high-quality").?);
    try std.testing.expectEqual(ScaleFilter.high_quality, ScaleFilter.parse("high_quality").?);
    try std.testing.expect(ScaleFilter.parse("lanczos") == null);
}

test "downscale ratio classifies fractional-scaling buffer mismatches" {
    // GTK3 / integer-ceil client: 2x buffer on a 1.25 output -> 0.625.
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), downscaleRatio(2000, 1000, 1250, 625), 1e-9);
    // 1.5 output -> 0.75; 1.75 output -> 0.875.
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), downscaleRatio(2000, 1000, 1500, 750), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), downscaleRatio(2000, 1000, 1750, 875), 1e-9);
    // Fractional-capable client renders 1:1.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), downscaleRatio(1250, 625, 1250, 625), 1e-9);
    // Scale-ignoring client upscaled.
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), downscaleRatio(1000, 500, 1250, 625), 1e-9);
    // The smaller axis governs anisotropic scaling.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), downscaleRatio(1000, 1000, 800, 500), 1e-9);
    // Degenerate sizes are treated as identity.
    try std.testing.expectEqual(@as(f64, 1), downscaleRatio(0, 100, 100, 100));
}

test "resolve filter applies area downscale only to minified auto surfaces" {
    // Auto: area when minified, bilinear when matched or magnified.
    try std.testing.expectEqual(ResolvedFilter.area, resolveFilter(.auto, 0.625));
    try std.testing.expectEqual(ResolvedFilter.area, resolveFilter(.auto, 0.875));
    try std.testing.expectEqual(ResolvedFilter.bilinear, resolveFilter(.auto, 1.0));
    try std.testing.expectEqual(ResolvedFilter.bilinear, resolveFilter(.auto, 1.25));
    // Within epsilon of 1:1 stays bilinear.
    try std.testing.expectEqual(ResolvedFilter.bilinear, resolveFilter(.auto, 1.0 - ratio_epsilon / 2));
    // Explicit high_quality behaves like auto for the ratio decision.
    try std.testing.expectEqual(ResolvedFilter.area, resolveFilter(.high_quality, 0.625));
    try std.testing.expectEqual(ResolvedFilter.bilinear, resolveFilter(.high_quality, 1.0));
    // Forced filters ignore the ratio.
    try std.testing.expectEqual(ResolvedFilter.nearest, resolveFilter(.nearest, 0.625));
    try std.testing.expectEqual(ResolvedFilter.nearest, resolveFilter(.nearest, 1.0));
    try std.testing.expectEqual(ResolvedFilter.bilinear, resolveFilter(.bilinear, 0.625));
}
