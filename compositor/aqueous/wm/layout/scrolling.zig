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
    viewport_index: usize = 0,
    last_focused: ?types.Handle = null,
    viewport_dirty: bool = false,

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
        state.viewport_index = 0;
        state.last_focused = null;
        state.viewport_dirty = false;
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
        const requested_width = if (window.scrolling_full_width) area.width else base_width;
        width.* = @max(requested_width, window.min_width);
        offset.* = cursor;
        cursor += width.* + options.gaps_inner;
    }
    const total_width = cursor - options.gaps_inner;
    const focus_changed = focused != state.last_focused;
    var resolved_focus = false;
    if (focused) |handle| {
        if (std.mem.indexOfScalar(types.Handle, handles, handle)) |index| {
            resolved_focus = true;
            state.focused_index = index;
            if (focus_changed) state.viewport_index = index;
        }
    }
    if (!resolved_focus and scrolling_options.follow_new_windows and handles.len > old_count) {
        state.focused_index = handles.len - 1;
        state.viewport_index = handles.len - 1;
        state.viewport_dirty = true;
    }
    state.focused_index = @min(state.focused_index, handles.len - 1);
    state.viewport_index = @min(state.viewport_index, handles.len - 1);
    state.last_focused = focused;
    if (scrolling_options.center_focused or state.viewport_dirty) {
        state.viewport_x = offsets[state.viewport_index] + @divTrunc(widths[state.viewport_index], 2) - @divTrunc(area.width, 2);
        state.viewport_dirty = false;
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
        const geometry: types.Rect = .{ .x = x, .y = area.y, .width = width, .height = area.height };
        const visible = math.intersect(geometry, area).width > 0;
        placement.* = .{
            .handle = handle,
            .geometry = geometry,
            // The viewport stays fixed while the full window moves behind it.
            // Expressing it relative to the window keeps the compositor-side
            // clip correct for non-zero output origins and nested scrolling
            // areas such as game-mode side columns.
            .clip = if (visible) .{
                .x = area.x - geometry.x,
                .y = area.y - geometry.y,
                .width = area.width,
                .height = area.height,
            } else null,
            .z_order = if (index == state.focused_index) 1 else 0,
            .visible = visible,
            .border = options.border,
        };
    }
    return result;
}

/// Pan by whole columns. Keeping the viewport anchor separate from keyboard
/// focus lets an explicit pan survive the following manage cycle; a later
/// focus change still recentres that newly focused column.
pub fn scrollViewport(state: *State, delta_columns: i32) bool {
    const count = state.order.items.items.len;
    if (count == 0 or delta_columns == 0) return false;

    const current: i64 = @intCast(@min(state.viewport_index, count - 1));
    const last: i64 = @intCast(count - 1);
    const requested = std.math.clamp(current + @as(i64, delta_columns), 0, last);
    const next: usize = @intCast(requested);
    if (next == state.viewport_index) return false;
    state.viewport_index = next;
    state.viewport_dirty = true;
    return true;
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
    try std.testing.expectEqual(@as(?types.Rect, null), placements[0].clip);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 100, .height = 80 }, placements[1].clip.?);
    try std.testing.expect(placements[2].visible);
    try std.testing.expectEqual(types.Rect{ .x = -75, .y = 0, .width = 100, .height = 80 }, placements[3].clip.?);
}

test "scrolling clips oversized columns to a non-zero viewport" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(
        std.testing.allocator,
        &state,
        .{ .x = 200, .y = 40, .width = 120, .height = 90 },
        &.{.{ .handle = 1, .min_width = 160 }},
        1,
        .{ .gaps_outer = 10, .gaps_inner = 0 },
        .{},
    );
    defer std.testing.allocator.free(placements);

    try std.testing.expectEqual(types.Rect{ .x = 180, .y = 50, .width = 160, .height = 70 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 30, .y = 0, .width = 100, .height = 70 }, placements[0].clip.?);
    try std.testing.expect(placements[0].visible);
}

test "a full-width window does not resize neighboring columns and remains scrollable" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{
        .{ .handle = 1 },
        .{ .handle = 2, .scrolling_full_width = true },
        .{ .handle = 3 },
    };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 0 };

    const expanded = try arrange(std.testing.allocator, &state, area, &windows, 2, options, .{});
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqual(@as(i32, 50), expanded[0].geometry.width);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 100, .height = 80 }, expanded[1].geometry);
    try std.testing.expectEqual(@as(i32, 50), expanded[2].geometry.width);

    try std.testing.expect(scrollViewport(&state, 1));
    const scrolled = try arrange(std.testing.allocator, &state, area, &windows, 2, options, .{});
    defer std.testing.allocator.free(scrolled);
    try std.testing.expectEqual(@as(i32, 25), scrolled[2].geometry.x);
    try std.testing.expectEqual(@as(i32, 50), scrolled[2].geometry.width);
}

test "manual column pan survives arrange while focus is unchanged" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };

    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqual(@as(i32, 25), initial[0].geometry.x);

    try std.testing.expect(scrollViewport(&state, 1));
    const panned = try arrange(std.testing.allocator, &state, area, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(panned);
    try std.testing.expectEqual(@as(i32, 25), panned[1].geometry.x);
    try std.testing.expectEqual(@as(i32, -25), panned[0].geometry.x);
    try std.testing.expectEqual(@as(i32, 1), panned[0].z_order);
}

test "focus change recentres after a manual pan" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };

    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(initial);
    try std.testing.expect(scrollViewport(&state, 2));

    const focused = try arrange(std.testing.allocator, &state, area, &windows, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(focused);
    try std.testing.expectEqual(@as(i32, 25), focused[1].geometry.x);
    try std.testing.expectEqual(@as(i32, 1), focused[1].z_order);
}

test "column pan clamps at both ends" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(placements);

    try std.testing.expect(scrollViewport(&state, 99));
    try std.testing.expectEqual(@as(usize, 2), state.viewport_index);
    try std.testing.expect(!scrollViewport(&state, 1));
    try std.testing.expect(scrollViewport(&state, -99));
    try std.testing.expectEqual(@as(usize, 0), state.viewport_index);
    try std.testing.expect(!scrollViewport(&state, -1));
}

test "manual column pan works when automatic focus centering is disabled" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: Options = .{ .center_focused = false };

    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, options);
    std.testing.allocator.free(initial);
    try std.testing.expect(scrollViewport(&state, 1));

    const panned = try arrange(std.testing.allocator, &state, area, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, options);
    defer std.testing.allocator.free(panned);
    try std.testing.expectEqual(@as(i32, 25), panned[1].geometry.x);
}
