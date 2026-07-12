// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const OpaqueRegionPolicy = enum {
    client,
    empty,
};

pub fn fractionToOpacity(value: u32) f32 {
    return @floatCast(@as(f64, @floatFromInt(value)) /
        @as(f64, @floatFromInt(std.math.maxInt(u32))));
}

pub fn opaqueRegionPolicy(opacity: f32) OpaqueRegionPolicy {
    return if (opacity < 1) .empty else .client;
}

test "translucent buffers never advertise an opaque region" {
    try std.testing.expectEqual(OpaqueRegionPolicy.empty, opaqueRegionPolicy(0));
    try std.testing.expectEqual(OpaqueRegionPolicy.empty, opaqueRegionPolicy(0.85));
    try std.testing.expectEqual(OpaqueRegionPolicy.client, opaqueRegionPolicy(1));
}

test "protocol opacity fractions preserve endpoints" {
    try std.testing.expectEqual(@as(f32, 0), fractionToOpacity(0));
    try std.testing.expectEqual(@as(f32, 1), fractionToOpacity(std.math.maxInt(u32)));
}
