// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const types = @import("types.zig");

pub const Column = struct {
    windows: std.ArrayListUnmanaged(types.Handle) = .empty,
    /// The member whose per-window flag currently expands this column. All
    /// members necessarily share the column width.
    expanded_owner: ?types.Handle = null,

    fn deinit(column: *Column, allocator: std.mem.Allocator) void {
        column.windows.deinit(allocator);
    }
};

pub const State = struct {
    columns: std.ArrayListUnmanaged(Column) = .empty,
    viewport_x: i32 = 0,
    focused_column: usize = 0,
    viewport_column: usize = 0,
    last_focused: ?types.Handle = null,
    viewport_dirty: bool = false,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        for (state.columns.items) |*column| column.deinit(allocator);
        state.columns.deinit(allocator);
    }
};

pub const Options = struct {
    column_width: f64 = 0.5,
    center_focused: bool = true,
    follow_new_windows: bool = true,
    snap_to_columns: bool = false,
    allow_overscroll: bool = true,
};

const Location = struct { column: usize, row: usize };

pub fn arrange(
    allocator: std.mem.Allocator,
    state: *State,
    usable_area: types.Rect,
    windows: []const types.Window,
    focused: ?types.Handle,
    options: types.Options,
    scrolling_options: Options,
) ![]types.Placement {
    const old_count = windowCount(state);
    try sync(state, allocator, windows);
    const result = try allocator.alloc(types.Placement, windows.len);
    if (state.columns.items.len == 0) {
        state.viewport_x = 0;
        state.focused_column = 0;
        state.viewport_column = 0;
        state.last_focused = null;
        state.viewport_dirty = false;
        return result;
    }

    const area = math.shrink(usable_area, options.gaps_outer);
    const base_width = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(area.width)) * scrolling_options.column_width))));
    const widths = try allocator.alloc(i32, state.columns.items.len);
    defer allocator.free(widths);
    const offsets = try allocator.alloc(i32, state.columns.items.len);
    defer allocator.free(offsets);

    var cursor: i32 = 0;
    for (state.columns.items, widths, offsets) |column, *width, *offset| {
        var minimum_width: i32 = 0;
        for (column.windows.items) |handle| {
            const window = findWindow(windows, handle).?;
            minimum_width = @max(minimum_width, window.min_width);
        }
        const requested_width = if (column.expanded_owner != null) area.width else base_width;
        width.* = @max(requested_width, minimum_width);
        offset.* = cursor;
        cursor += width.* + options.gaps_inner;
    }
    const total_width = cursor - options.gaps_inner;

    const focus_changed = focused != state.last_focused;
    var resolved_focus = false;
    if (focused) |handle| {
        if (locate(state, handle)) |location| {
            resolved_focus = true;
            const focused_column_changed = location.column != state.focused_column;
            state.focused_column = location.column;
            if (focus_changed or focused_column_changed) state.viewport_column = location.column;
        }
    }
    if (!resolved_focus and scrolling_options.follow_new_windows and windows.len > old_count) {
        state.focused_column = state.columns.items.len - 1;
        state.viewport_column = state.columns.items.len - 1;
        state.viewport_dirty = true;
    }
    state.focused_column = @min(state.focused_column, state.columns.items.len - 1);
    state.viewport_column = @min(state.viewport_column, state.columns.items.len - 1);
    state.last_focused = focused;
    if (scrolling_options.center_focused or scrolling_options.snap_to_columns or state.viewport_dirty) {
        state.viewport_x = offsets[state.viewport_column] + @divTrunc(widths[state.viewport_column], 2) - @divTrunc(area.width, 2);
        state.viewport_dirty = false;
    }
    if (!scrolling_options.allow_overscroll) {
        state.viewport_x = std.math.clamp(state.viewport_x, 0, @max(0, total_width - area.width));
    }

    var write: usize = 0;
    for (state.columns.items, widths, offsets) |column, width, offset| {
        const rows = try math.splitAxis(allocator, area.height, @intCast(column.windows.items.len), options.gaps_inner);
        defer allocator.free(rows);
        const x = area.x + offset - state.viewport_x;
        for (column.windows.items, rows) |handle, row| {
            const geometry: types.Rect = .{
                .x = x,
                .y = area.y + row.offset,
                .width = width,
                .height = row.size,
            };
            const visible = math.intersect(geometry, area).width > 0;
            result[write] = .{
                .handle = handle,
                .geometry = geometry,
                .clip = if (visible) .{
                    .x = area.x - geometry.x,
                    .y = area.y - geometry.y,
                    .width = area.width,
                    .height = area.height,
                } else null,
                .z_order = if (focused == handle) 1 else 0,
                .visible = visible,
                .border = options.border,
            };
            write += 1;
        }
    }
    return result;
}

/// Pan by whole columns. Keeping the viewport anchor separate from keyboard
/// focus lets an explicit pan survive the following manage cycle.
pub fn scrollViewport(state: *State, delta_columns: i32) bool {
    const count = state.columns.items.len;
    if (count == 0 or delta_columns == 0) return false;
    const current: i64 = @intCast(@min(state.viewport_column, count - 1));
    const last: i64 = @intCast(count - 1);
    const requested = std.math.clamp(current + @as(i64, delta_columns), 0, last);
    const next: usize = @intCast(requested);
    if (next == state.viewport_column) return false;
    state.viewport_column = next;
    state.viewport_dirty = true;
    return true;
}

pub fn swap(state: *State, a: types.Handle, b: types.Handle) bool {
    if (a == b) return false;
    const a_location = locate(state, a) orelse return false;
    const b_location = locate(state, b) orelse return false;
    std.mem.swap(
        types.Handle,
        &state.columns.items[a_location.column].windows.items[a_location.row],
        &state.columns.items[b_location.column].windows.items[b_location.row],
    );
    return true;
}

pub fn moveColumn(state: *State, focused: types.Handle, delta: i32) bool {
    if (delta == 0) return false;
    const location = locate(state, focused) orelse return false;
    const destination = @as(i64, @intCast(location.column)) + @as(i64, delta);
    if (destination < 0 or destination >= state.columns.items.len) return false;
    std.mem.swap(Column, &state.columns.items[location.column], &state.columns.items[@intCast(destination)]);
    return true;
}

pub fn moveWithinColumn(state: *State, focused: types.Handle, delta: i32) bool {
    if (delta == 0) return false;
    const location = locate(state, focused) orelse return false;
    const windows = state.columns.items[location.column].windows.items;
    const destination = @as(i64, @intCast(location.row)) + @as(i64, delta);
    if (destination < 0 or destination >= windows.len) return false;
    std.mem.swap(types.Handle, &windows[location.row], &windows[@intCast(destination)]);
    return true;
}

/// Consume the first window from the column to the right into the bottom of
/// the focused window's column, matching the common scrolling-WM operation.
pub fn consumeFromRight(state: *State, allocator: std.mem.Allocator, focused: types.Handle) !bool {
    const location = locate(state, focused) orelse return false;
    if (location.column + 1 >= state.columns.items.len) return false;
    try state.columns.items[location.column].windows.ensureUnusedCapacity(allocator, 1);
    const consumed = state.columns.items[location.column + 1].windows.items[0];
    detach(state, .{ .column = location.column + 1, .row = 0 }, allocator);
    state.columns.items[location.column].windows.appendAssumeCapacity(consumed);
    return true;
}

/// Expel the focused member into a new single-window column immediately to the
/// right. A single-window column is already expelled and is left unchanged.
pub fn expelToRight(state: *State, allocator: std.mem.Allocator, focused: types.Handle) !bool {
    const location = locate(state, focused) orelse return false;
    if (state.columns.items[location.column].windows.items.len == 1) return false;
    var new_column = try singleWindowColumn(allocator, focused);
    errdefer new_column.deinit(allocator);
    try state.columns.ensureUnusedCapacity(allocator, 1);
    detach(state, location, allocator);
    state.columns.insert(allocator, location.column + 1, new_column) catch unreachable;
    return true;
}

pub fn drop(
    state: *State,
    allocator: std.mem.Allocator,
    dragged: types.Handle,
    target: types.Handle,
    zone: types.DropZone,
) !bool {
    if (dragged == target) return false;
    const dragged_location = locate(state, dragged) orelse return false;
    const target_location = locate(state, target) orelse return false;

    switch (zone) {
        .stack_before, .stack_after => {
            if (dragged_location.column == target_location.column) {
                if (zone == .stack_before and dragged_location.row + 1 == target_location.row) return false;
                if (zone == .stack_after and target_location.row + 1 == dragged_location.row) return false;
            }
            try state.columns.items[target_location.column].windows.ensureUnusedCapacity(allocator, 1);
            detach(state, dragged_location, allocator);
            const current_target = locate(state, target) orelse unreachable;
            const insert_at = current_target.row + @intFromBool(zone == .stack_after);
            state.columns.items[current_target.column].windows.insert(allocator, insert_at, dragged) catch unreachable;
        },
        .column_before, .column_after => {
            const source_is_single = state.columns.items[dragged_location.column].windows.items.len == 1;
            if (source_is_single) {
                if (zone == .column_before and dragged_location.column + 1 == target_location.column) return false;
                if (zone == .column_after and target_location.column + 1 == dragged_location.column) return false;
            }
            var new_column = try singleWindowColumn(allocator, dragged);
            errdefer new_column.deinit(allocator);
            try state.columns.ensureUnusedCapacity(allocator, 1);
            detach(state, dragged_location, allocator);
            const current_target = locate(state, target) orelse unreachable;
            const insert_at = current_target.column + @intFromBool(zone == .column_after);
            state.columns.insert(allocator, insert_at, new_column) catch unreachable;
        },
    }
    return true;
}

pub fn flattened(allocator: std.mem.Allocator, state: *const State) ![]types.Handle {
    const result = try allocator.alloc(types.Handle, windowCount(state));
    var write: usize = 0;
    for (state.columns.items) |column| {
        @memcpy(result[write..][0..column.windows.items.len], column.windows.items);
        write += column.windows.items.len;
    }
    return result;
}

pub fn containsHandle(state: *const State, handle: types.Handle) bool {
    return locate(state, handle) != null;
}

fn sync(state: *State, allocator: std.mem.Allocator, windows: []const types.Window) !void {
    var column_index: usize = 0;
    while (column_index < state.columns.items.len) {
        var column = &state.columns.items[column_index];
        var row: usize = 0;
        while (row < column.windows.items.len) {
            if (findWindow(windows, column.windows.items[row]) == null) {
                _ = column.windows.orderedRemove(row);
            } else {
                row += 1;
            }
        }
        if (column.windows.items.len == 0) {
            var removed = state.columns.orderedRemove(column_index);
            removed.deinit(allocator);
        } else {
            column_index += 1;
        }
    }

    for (windows) |window| {
        if (locate(state, window.handle) != null) continue;
        var column = try singleWindowColumn(allocator, window.handle);
        state.columns.append(allocator, column) catch |err| {
            column.deinit(allocator);
            return err;
        };
    }
    for (state.columns.items) |*column| refreshExpandedOwner(column, windows);
}

fn refreshExpandedOwner(column: *Column, windows: []const types.Window) void {
    if (column.expanded_owner) |owner| {
        if (findWindow(windows, owner)) |window| {
            if (window.scrolling_full_width and contains(column.windows.items, owner)) return;
        }
    }
    column.expanded_owner = null;
    for (column.windows.items) |handle| {
        if (findWindow(windows, handle).?.scrolling_full_width) {
            column.expanded_owner = handle;
            return;
        }
    }
}

fn singleWindowColumn(allocator: std.mem.Allocator, handle: types.Handle) !Column {
    var column: Column = .{};
    try column.windows.append(allocator, handle);
    return column;
}

fn detach(state: *State, location: Location, allocator: std.mem.Allocator) void {
    _ = state.columns.items[location.column].windows.orderedRemove(location.row);
    if (state.columns.items[location.column].windows.items.len == 0) {
        var removed = state.columns.orderedRemove(location.column);
        removed.deinit(allocator);
    }
}

fn locate(state: *const State, handle: types.Handle) ?Location {
    for (state.columns.items, 0..) |column, column_index| {
        if (std.mem.indexOfScalar(types.Handle, column.windows.items, handle)) |row| {
            return .{ .column = column_index, .row = row };
        }
    }
    return null;
}

fn windowCount(state: *const State) usize {
    var count: usize = 0;
    for (state.columns.items) |column| count += column.windows.items.len;
    return count;
}

fn findWindow(windows: []const types.Window, handle: types.Handle) ?types.Window {
    for (windows) |window| if (window.handle == handle) return window;
    return null;
}

fn contains(handles: []const types.Handle, handle: types.Handle) bool {
    return std.mem.indexOfScalar(types.Handle, handles, handle) != null;
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
    try std.testing.expect(placements[2].visible);
}

test "a column splits its members vertically" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4 };
    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    std.testing.allocator.free(initial);

    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    const stacked = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    defer std.testing.allocator.free(stacked);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 50, .height = 38 }, stacked[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 42, .width = 50, .height = 38 }, stacked[1].geometry);
    try std.testing.expectEqual(@as(usize, 2), state.columns.items.len);
}

test "consume and expel preserve exactly one membership per window" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(placements);

    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 2 }, state.columns.items[0].windows.items);
    try std.testing.expect(try expelToRight(&state, std.testing.allocator, 2));
    try std.testing.expectEqual(@as(usize, 3), state.columns.items.len);
    const projection = try flattened(std.testing.allocator, &state);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 2, 3 }, projection);

    const expelled = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(expelled);
    try std.testing.expectEqual(@as(usize, 1), state.viewport_column);
    try std.testing.expectEqual(@as(i32, 25), expelled[1].geometry.x);
}

test "horizontal movement swaps a whole column and vertical movement reorders a member" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(placements);

    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    try std.testing.expect(moveWithinColumn(&state, 2, -1));
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 1 }, state.columns.items[0].windows.items);
    try std.testing.expect(moveColumn(&state, 2, 1));
    try std.testing.expectEqualSlices(types.Handle, &.{3}, state.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 1 }, state.columns.items[1].windows.items);
}

test "drop zones stack and detach windows" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(placements);

    try std.testing.expect(try drop(&state, std.testing.allocator, 3, 1, .stack_after));
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3 }, state.columns.items[0].windows.items);
    try std.testing.expect(try drop(&state, std.testing.allocator, 3, 2, .column_before));
    const projection = try flattened(std.testing.allocator, &state);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3, 2 }, projection);
}

test "a full-width owner expands only its column and remains scrollable" {
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

    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    const stacked = try arrange(std.testing.allocator, &state, area, &windows, 2, options, .{});
    defer std.testing.allocator.free(stacked);
    try std.testing.expectEqual(@as(i32, 100), stacked[0].geometry.width);
    try std.testing.expectEqual(@as(i32, 100), stacked[1].geometry.width);
    try std.testing.expectEqual(@as(i32, 50), stacked[2].geometry.width);

    try std.testing.expect(scrollViewport(&state, 1));
    const scrolled = try arrange(std.testing.allocator, &state, area, &windows, 2, options, .{});
    defer std.testing.allocator.free(scrolled);
    try std.testing.expectEqual(@as(i32, 25), scrolled[2].geometry.x);
}

test "focus change recentres the containing column" {
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
}

test "column pan clamps at both ends" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(scrollViewport(&state, 99));
    try std.testing.expectEqual(@as(usize, 2), state.viewport_column);
    try std.testing.expect(!scrollViewport(&state, 1));
    try std.testing.expect(scrollViewport(&state, -99));
    try std.testing.expectEqual(@as(usize, 0), state.viewport_column);
}
