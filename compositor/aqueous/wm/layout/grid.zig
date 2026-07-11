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

    pub fn moveFocused(state: *State, focused: types.Handle, direction: types.Direction) bool {
        const items = state.order.items.items;
        if (items.len < 2) return false;
        const index = std.mem.indexOfScalar(types.Handle, items, focused) orelse return false;
        const columns = ceilSqrt(items.len);
        var target: isize = switch (direction) {
            .left, .prev => @as(isize, @intCast(index)) - 1,
            .right, .next => @as(isize, @intCast(index)) + 1,
            .up => @as(isize, @intCast(index)) - @as(isize, @intCast(columns)),
            .down => @as(isize, @intCast(index)) + @as(isize, @intCast(columns)),
        };
        if (direction == .down and target >= items.len and index < items.len - 1) {
            target = @intCast(items.len - 1);
        }
        if (target < 0 or target >= items.len or target == index) return false;
        std.mem.swap(types.Handle, &items[index], &items[@intCast(target)]);
        return true;
    }
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, options: types.Options) ![]types.Placement {
    try state.order.sync(allocator, windows);
    const handles = state.order.items.items;
    const result = try allocator.alloc(types.Placement, handles.len);
    if (handles.len == 0) return result;

    const area = math.shrink(usable_area, options.gaps_outer);
    const columns = ceilSqrt(handles.len);
    const rows = (handles.len + columns - 1) / columns;
    const columns_i32: i32 = @intCast(columns);
    const rows_i32: i32 = @intCast(rows);
    const cell_width = @max(1, @divTrunc(area.width - options.gaps_inner * (columns_i32 - 1), columns_i32));
    const cell_height = @max(1, @divTrunc(area.height - options.gaps_inner * (rows_i32 - 1), rows_i32));

    for (result, handles, 0..) |*placement, handle, index| {
        const row = index / columns;
        const column = index % columns;
        const row_items = if (row == rows - 1) handles.len - row * columns else columns;
        const row_items_i32: i32 = @intCast(row_items);
        const row_offset = if (row == rows - 1)
            @divTrunc(area.width - (row_items_i32 * cell_width + options.gaps_inner * (row_items_i32 - 1)), 2)
        else
            0;
        placement.* = .{
            .handle = handle,
            .geometry = .{
                .x = area.x + row_offset + @as(i32, @intCast(column)) * (cell_width + options.gaps_inner),
                .y = area.y + @as(i32, @intCast(row)) * (cell_height + options.gaps_inner),
                .width = cell_width,
                .height = cell_height,
            },
            .z_order = 0,
            .visible = true,
            .border = options.border,
        };
    }
    return result;
}

fn ceilSqrt(value: usize) usize {
    var root: usize = 1;
    while (root * root < value) root += 1;
    return root;
}

test "grid centres a short final row and supports directional swaps" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, .{ .gaps_outer = 0, .gaps_inner = 0 });
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 50, .height = 50 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 50, .width = 50, .height = 50 }, placements[2].geometry);
    try std.testing.expect(state.moveFocused(2, .down));
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3, 2 }, state.order.items.items);
}