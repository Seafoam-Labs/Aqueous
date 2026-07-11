// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const types = @import("types.zig");

pub fn arrange(allocator: std.mem.Allocator, usable_area: types.Rect, windows: []const types.Window, options: types.Options) ![]types.Placement {
    const result = try allocator.alloc(types.Placement, windows.len);
    if (windows.len == 0) return result;
    const area = math.shrink(usable_area, options.gaps_outer);
    const top_count = (windows.len + 1) / 2;
    const bottom_count = windows.len - top_count;
    if (bottom_count == 0) {
        try placeRow(allocator, result, area, windows, options);
        return result;
    }
    const bands = try math.splitAxis(allocator, area.height, 2, options.gaps_inner);
    defer allocator.free(bands);
    try placeRow(allocator, result[0..top_count], .{
        .x = area.x, .y = area.y + bands[0].offset, .width = area.width, .height = bands[0].size,
    }, windows[0..top_count], options);
    try placeRow(allocator, result[top_count..], .{
        .x = area.x, .y = area.y + bands[1].offset, .width = area.width, .height = bands[1].size,
    }, windows[top_count..], options);
    return result;
}

fn placeRow(allocator: std.mem.Allocator, placements: []types.Placement, area: types.Rect, windows: []const types.Window, options: types.Options) !void {
    const columns = try math.splitAxis(allocator, area.width, @intCast(windows.len), options.gaps_inner);
    defer allocator.free(columns);
    for (placements, windows, columns) |*placement, window, column| {
        placement.* = .{
            .handle = window.handle,
            .geometry = .{ .x = area.x + column.offset, .y = area.y, .width = column.size, .height = area.height },
            .z_order = 0, .visible = true, .border = options.border,
        };
    }
}

test "rows uses at most two horizontal bands" {
    const placements = try arrange(std.testing.allocator, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, .{ .gaps_outer = 0, .gaps_inner = 4 });
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 48, .height = 38 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 42, .width = 100, .height = 38 }, placements[2].geometry);
}