// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
pub const base_dpi: u32 = 96 * 1024;

/// Preserve fractional output scaling in XSettings' fixed-point DPI units.
pub fn fromScale(scale: f32) u32 {
    if (!std.math.isFinite(scale) or scale <= 0) return base_dpi;
    return @intFromFloat(@round(@as(f64, base_dpi) * std.math.clamp(@as(f64, scale), 0.25, 16)));
}

test "application DPI follows output scale without integer rounding" {
    try std.testing.expectEqual(@as(u32, 96 * 1024), fromScale(1));
    try std.testing.expectEqual(@as(u32, 120 * 1024), fromScale(1.25));
    try std.testing.expectEqual(@as(u32, 144 * 1024), fromScale(1.5));
    try std.testing.expectEqual(@as(u32, 192 * 1024), fromScale(2));
    try std.testing.expectEqual(@as(u32, 129761), fromScale(1.32));
    try std.testing.expectEqual(base_dpi, fromScale(std.math.nan(f32)));
    try std.testing.expectEqual(base_dpi, fromScale(0));
}
