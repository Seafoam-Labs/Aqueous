// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const OpaqueRegionPolicy = enum {
    client,
    empty,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Portion of a moving destination buffer which remains inside a fixed global
/// viewport. x/y are offsets from the original destination origin.
pub fn destinationCrop(destination: Rect, viewport: Rect) ?Rect {
    if (destination.width <= 0 or destination.height <= 0 or viewport.width <= 0 or viewport.height <= 0) return null;
    const x = @max(destination.x, viewport.x);
    const y = @max(destination.y, viewport.y);
    const right = @min(destination.x + destination.width, viewport.x + viewport.width);
    const bottom = @min(destination.y + destination.height, viewport.y + viewport.height);
    if (right <= x or bottom <= y) return null;
    return .{
        .x = x - destination.x,
        .y = y - destination.y,
        .width = right - x,
        .height = bottom - y,
    };
}

/// Whether a local clip preserves a content rectangle's complete outward
/// outline. An empty clip means unclipped. Use widened coordinates so policy
/// geometry near an i32 edge cannot overflow the containment test.
pub fn clipContainsOutline(content: Rect, clip: Rect, border_width: i32) bool {
    if (clip.width <= 0 or clip.height <= 0) return true;
    if (content.width <= 0 or content.height <= 0) return false;
    const border: i64 = @max(0, border_width);
    const outline_left = @as(i64, content.x) - border;
    const outline_top = @as(i64, content.y) - border;
    const outline_right = @as(i64, content.x) + @as(i64, content.width) + border;
    const outline_bottom = @as(i64, content.y) + @as(i64, content.height) + border;
    const clip_left: i64 = clip.x;
    const clip_top: i64 = clip.y;
    const clip_right = @as(i64, clip.x) + @as(i64, clip.width);
    const clip_bottom = @as(i64, clip.y) + @as(i64, clip.height);
    return clip_left <= outline_left and clip_top <= outline_top and
        clip_right >= outline_right and clip_bottom >= outline_bottom;
}

pub fn fractionToOpacity(value: u32) f32 {
    return @floatCast(@as(f64, @floatFromInt(value)) /
        @as(f64, @floatFromInt(std.math.maxInt(u32))));
}

pub fn effectsRequireComposition(
    rounded_corners: bool,
    backdrop_blur: bool,
) bool {
    return rounded_corners or backdrop_blur;
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

test "moving animation destinations remain clipped to a fixed viewport" {
    const viewport: Rect = .{ .x = 100, .y = 20, .width = 100, .height = 80 };
    try std.testing.expectEqual(Rect{ .x = 25, .y = 0, .width = 25, .height = 80 }, destinationCrop(
        .{ .x = 75, .y = 20, .width = 50, .height = 80 },
        viewport,
    ).?);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 25, .height = 80 }, destinationCrop(
        .{ .x = 175, .y = 20, .width = 50, .height = 80 },
        viewport,
    ).?);
    try std.testing.expectEqual(@as(?Rect, null), destinationCrop(
        .{ .x = 200, .y = 20, .width = 50, .height = 80 },
        viewport,
    ));
}

test "rounded outlines survive containing clips but not cut edges" {
    const content: Rect = .{ .x = 0, .y = 0, .width = 46, .height = 76 };
    try std.testing.expect(clipContainsOutline(content, .{ .x = -2, .y = -2, .width = 50, .height = 80 }, 2));
    try std.testing.expect(clipContainsOutline(content, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, 2));
    try std.testing.expect(!clipContainsOutline(content, .{ .x = 0, .y = -2, .width = 48, .height = 80 }, 2));
    try std.testing.expect(!clipContainsOutline(content, .{ .x = -2, .y = -2, .width = 49, .height = 80 }, 2));
}

test "direct scanout is blocked only by visible compositor effects" {
    try std.testing.expect(!effectsRequireComposition(false, false));
    try std.testing.expect(effectsRequireComposition(true, false));
    try std.testing.expect(effectsRequireComposition(false, true));
    try std.testing.expect(effectsRequireComposition(true, true));
}
