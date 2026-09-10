// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

/// Exact logical size and scale, then least downsampling, then least upsampling.
pub fn rank(width: i32, scale: i32, logical: u32, output_scale: f64) u64 {
    if (width <= 0 or scale <= 0) return std.math.maxInt(u64);
    const target: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(logical)) * output_scale));
    const pixels: u32 = @intCast(width);
    if (pixels == target and @as(f64, @floatFromInt(scale)) == output_scale and
        pixels == @as(u64, logical) * @as(u32, @intCast(scale))) return 0;
    if (pixels >= target) return 1 + @as(u64, pixels - target);
    return (@as(u64, 1) << 32) + target - pixels;
}

test "icon selection prefers density match then downsampling then largest smaller" {
    try std.testing.expect(rank(64, 2, 32, 2) < rank(64, 1, 32, 2));
    try std.testing.expect(rank(64, 1, 32, 1.5) < rank(32, 1, 32, 1.5));
    try std.testing.expect(rank(64, 1, 32, 1.5) < rank(128, 2, 32, 1.5));
    try std.testing.expect(rank(32, 1, 64, 2) < rank(16, 1, 64, 2));
    try std.testing.expectEqual(std.math.maxInt(u64), rank(32, 0, 32, 1));
    try std.testing.expectEqual(std.math.maxInt(u64), rank(32, -1, 32, 1));
}
