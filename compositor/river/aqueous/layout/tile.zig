// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const order = @import("order.zig");
const types = @import("types.zig");

pub const State = struct {
    order: order.State = .{},
    master_count: u32 = 1,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.order.deinit(allocator);
    }
};

pub fn arrange(
    allocator: std.mem.Allocator,
    state: *State,
    usable_area: types.Rect,
    windows: []const types.Window,
    options: types.Options,
) ![]types.Placement {
    try state.order.sync(allocator, windows);
    const handles = state.order.items.items;
    const result = try allocator.alloc(types.Placement, handles.len);
    if (handles.len == 0) return result;

    const area = math.shrink(usable_area, options.gaps_outer);
    state.master_count = @max(1, @min(options.master_count, @as(u32, @intCast(handles.len))));
    if (handles.len == 1) {
        result[0] = .{ .handle = handles[0], .geometry = area, .z_order = 0, .visible = true, .border = options.border };
        return result;
    }

    const stack_count: u32 = @intCast(handles.len - state.master_count);
    const master_width = if (stack_count == 0)
        area.width
    else
        @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(area.width)) * options.master_ratio))));
    const stack_width = if (stack_count == 0) 0 else @max(1, area.width - master_width - options.gaps_inner);

    try splitVertical(allocator, result[0..state.master_count], handles[0..state.master_count], .{
        .x = area.x,
        .y = area.y,
        .width = master_width,
        .height = area.height,
    }, options);
    if (stack_count > 0) {
        try splitVertical(allocator, result[state.master_count..], handles[state.master_count..], .{
            .x = area.x + master_width + options.gaps_inner,
            .y = area.y,
            .width = stack_width,
            .height = area.height,
        }, options);
    }
    return result;
}

fn splitVertical(allocator: std.mem.Allocator, placements: []types.Placement, handles: []const types.Handle, area: types.Rect, options: types.Options) !void {
    const rows = try math.splitAxis(allocator, area.height, @intCast(handles.len), options.gaps_inner);
    defer allocator.free(rows);
    for (placements, handles, rows) |*placement, handle, row| {
        placement.* = .{
            .handle = handle,
            .geometry = .{ .x = area.x, .y = area.y + row.offset, .width = area.width, .height = row.size },
            .z_order = 0,
            .visible = true,
            .border = options.border,
        };
    }
}

test "tile preserves master-stack geometry" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 80,
    }, &.{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } }, .{
        .gaps_outer = 0,
        .gaps_inner = 4,
        .master_ratio = 0.5,
    });
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 50, .height = 80 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 0, .width = 46, .height = 38 }, placements[1].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 42, .width = 46, .height = 38 }, placements[2].geometry);
}
