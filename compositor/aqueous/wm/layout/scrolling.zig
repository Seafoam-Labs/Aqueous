// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const order = @import("order.zig");
const types = @import("types.zig");

pub const State = struct {
    order: order.State = .{},
    viewport_x: i32 = 0,
    focused_index: usize = 0,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.order.deinit(allocator);
    }
};

pub const Options = struct {
    column_width: f64 = 0.5,
    center_focused: bool = true,
    follow_new_windows: bool = true,
    snap_to_columns: bool = false,
    allow_overscroll: bool = true,
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, focused: ?types.Handle, options: types.Options, scrolling_options: Options) ![]types.Placement {
    const old_count = state.order.items.items.len;
    try state.order.sync(allocator, windows);
    const handles = state.order.items.items;
    const result = try allocator.alloc(types.Placement, handles.len);
    if (handles.len == 0) {
        state.viewport_x = 0;
        state.focused_index = 0;
        return result;
    }
    const area = math.shrink(usable_area, options.gaps_outer);
    const base_width = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(area.width)) * scrolling_options.column_width))));
    const widths = try allocator.alloc(i32, handles.len);
    defer allocator.free(widths);
    const offsets = try allocator.alloc(i32, handles.len);
    defer allocator.free(offsets);
    var cursor: i32 = 0;
    for (handles, widths, offsets) |handle, *width, *offset| {
        const window = findWindow(windows, handle).?;
        width.* = @max(base_width, window.min_width);
        offset.* = cursor;
        cursor += width.* + options.gaps_inner;
    }
    const total_width = cursor - options.gaps_inner;
    if (focused) |handle| {
        state.focused_index = std.mem.indexOfScalar(types.Handle, handles, handle) orelse state.focused_index;
    } else if (scrolling_options.follow_new_windows and handles.len > old_count) {
        state.focused_index = handles.len - 1;
    }
    state.focused_index = @min(state.focused_index, handles.len - 1);
    if (scrolling_options.center_focused) {
        state.viewport_x = offsets[state.focused_index] + @divTrunc(widths[state.focused_index], 2) - @divTrunc(area.width, 2);
    }
    const step = base_width + options.gaps_inner;
    if (scrolling_options.snap_to_columns and step > 0) {
        state.viewport_x = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(state.viewport_x)) / @as(f64, @floatFromInt(step))))) * step;
    }
    if (!scrolling_options.allow_overscroll) {
        state.viewport_x = std.math.clamp(state.viewport_x, 0, @max(0, total_width - area.width));
    }
    for (result, handles, widths, offsets, 0..) |*placement, handle, width, offset, index| {
        const x = area.x + offset - state.viewport_x;
        placement.* = .{
            .handle = handle,
            .geometry = .{ .x = x, .y = area.y, .width = width, .height = area.height },
            .z_order = if (index == state.focused_index) 1 else 0,
            .visible = x + width > area.x and x < area.right(),
            .border = options.border,
        };
    }
    return result;
}

fn findWindow(windows: []const types.Window, handle: types.Handle) ?types.Window {
    for (windows) |window| if (window.handle == handle) return window;
    return null;
}

test "scrolling centres focus and hides off-screen columns" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 },
    }, 3, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(i32, 25), placements[2].geometry.x);
    try std.testing.expect(!placements[0].visible);
    try std.testing.expect(placements[2].visible);
}