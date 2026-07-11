// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const order = @import("order.zig");
const types = @import("types.zig");

pub const State = struct {
    order: order.State = .{},

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.order.deinit(allocator);
    }
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, options: types.Options) ![]types.Placement {
    try state.order.sync(allocator, windows);
    const handles = state.order.items.items;
    const result = try allocator.alloc(types.Placement, windows.len);
    if (handles.len == 0) return result;
    const area = math.shrink(usable_area, options.gaps_outer);
    const top_count = (handles.len + 1) / 2;
    const bottom_count = handles.len - top_count;
    if (bottom_count == 0) {
        try placeRow(allocator, result, area, handles, options);
        return result;
    }
    const bands = try math.splitAxis(allocator, area.height, 2, options.gaps_inner);
    defer allocator.free(bands);
    try placeRow(allocator, result[0..top_count], .{
        .x = area.x,
        .y = area.y + bands[0].offset,
        .width = area.width,
        .height = bands[0].size,
    }, handles[0..top_count], options);
    try placeRow(allocator, result[top_count..], .{
        .x = area.x,
        .y = area.y + bands[1].offset,
        .width = area.width,
        .height = bands[1].size,
    }, handles[top_count..], options);
    return result;
}

fn placeRow(allocator: std.mem.Allocator, placements: []types.Placement, area: types.Rect, handles: []const types.Handle, options: types.Options) !void {
    const columns = try math.splitAxis(allocator, area.width, @intCast(handles.len), options.gaps_inner);
    defer allocator.free(columns);
    for (placements, handles, columns) |*placement, handle, column| {
        placement.* = .{
            .handle = handle,
            .geometry = .{ .x = area.x + column.offset, .y = area.y, .width = column.size, .height = area.height },
            .z_order = 0,
            .visible = true,
            .border = options.border,
        };
    }
}

test "rows uses at most two horizontal bands" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, .{ .gaps_outer = 0, .gaps_inner = 4 });
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 48, .height = 38 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 42, .width = 100, .height = 38 }, placements[2].geometry);
}
