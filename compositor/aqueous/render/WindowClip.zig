// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

/// Rounded window silhouette in destination-local logical coordinates. A null
/// clip means no mask; a present clip with radius zero is a rectangular mask.
/// The origin may lie outside a buffer (padding, subsurfaces or viewport crops).
pub const RoundedClip = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    radius: f64,

    pub fn init(box: struct { x: i32, y: i32, width: i32, height: i32 }, radius: u31) RoundedClip {
        return .{
            .x = @floatFromInt(box.x),
            .y = @floatFromInt(box.y),
            .width = @floatFromInt(box.width),
            .height = @floatFromInt(box.height),
            .radius = @min(@as(f64, @floatFromInt(radius)), @as(f64, @floatFromInt(@max(0, @min(box.width, box.height)))) / 2),
        };
    }

    pub fn translated(clip: RoundedClip, x: f64, y: f64) RoundedClip {
        var result = clip;
        result.x += x;
        result.y += y;
        return result;
    }

    /// Overview cards retain circular corners when integer rounding gives the
    /// two destination axes slightly different scale factors.
    pub fn scaled(clip: RoundedClip, x: f64, y: f64) RoundedClip {
        return .{
            .x = clip.x * x,
            .y = clip.y * y,
            .width = clip.width * x,
            .height = clip.height * y,
            .radius = clip.radius * @min(x, y),
        };
    }
};

test "window mask follows padded and cropped buffers without acquiring new corners" {
    const window = RoundedClip.init(.{ .x = 0, .y = 0, .width = 320, .height = 240 }, 15);
    const padded = window.translated(20, 20);
    try std.testing.expectEqual(@as(f64, 20), padded.x);
    const child = window.translated(-8, -6);
    try std.testing.expectEqual(@as(f64, -8), child.x);
    try std.testing.expectEqual(window.width, child.width);
    const cropped = padded.translated(-40, -10);
    try std.testing.expectEqual(@as(f64, -20), cropped.x);
    try std.testing.expectEqual(window.radius, cropped.radius);
    try std.testing.expectEqual(padded, cropped.translated(40, 10));
    const thumbnail = padded.scaled(0.5, 0.5).translated(-3, -4);
    try std.testing.expectEqual(@as(f64, 7), thumbnail.x);
    try std.testing.expectEqual(@as(f64, 160), thumbnail.width);
    try std.testing.expectEqual(@as(f64, 7.5), thumbnail.radius);
    try std.testing.expectEqual(@as(f64, 5), RoundedClip.init(.{ .x = 0, .y = 0, .width = 10, .height = 20 }, 15).radius);
}

test "thumbnail buffers retain a shared mask despite independent destination rounding" {
    const window = RoundedClip.init(.{ .x = 0, .y = 0, .width = 360, .height = 260 }, 15);
    const scale = 1003.0 / 360.0;
    const parent = window.translated(32, 32);
    const child = window.translated(-340, -240);
    // Cropped thumbnail destinations need not begin at the same pixel.
    const parent_mask = parent.translated(-32, -32).scaled(scale, scale).translated(0, 0);
    const child_mask = child.translated(340, 240).scaled(scale, scale).translated(-947, -669);
    try std.testing.expectEqual(parent_mask, child_mask.translated(947, 669));
}
