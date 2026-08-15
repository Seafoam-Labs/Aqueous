// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const types = @import("types.zig");

pub const Column = struct {
    windows: std.ArrayListUnmanaged(types.Handle) = .empty,
    /// Pointer resizing records an explicit logical-pixel width for the whole
    /// column. Null follows the configured column fraction.
    width_override: ?i32 = null,
    /// The member whose per-window flag currently expands this column. All
    /// members necessarily share the column width.
    expanded_owner: ?types.Handle = null,
    /// Vertical viewport state is kept on the column so moving between columns
    /// restores each stack to its previous position.
    viewport_y: i32 = 0,
    viewport_max_y: i32 = 0,
    viewport_anchor: ?types.Handle = null,
    viewport_dirty: bool = false,
    reveal_focused: bool = false,

    fn deinit(column: *Column, allocator: std.mem.Allocator) void {
        column.windows.deinit(allocator);
    }
};

pub const State = struct {
    columns: std.ArrayListUnmanaged(Column) = .empty,
    /// Vertical sizing belongs to a member rather than its column. Keeping the
    /// overrides keyed by stable handle lets them follow reorders and stacking
    /// operations inside this scrolling state.
    height_overrides: std.AutoHashMapUnmanaged(types.Handle, i32) = .empty,
    viewport_x: i32 = 0,
    focused_column: usize = 0,
    viewport_column: usize = 0,
    last_focused: ?types.Handle = null,
    viewport_dirty: bool = false,
    /// Effective vertical preference from the most recent arrange: the
    /// configured portrait option applied while this instance's usable
    /// rectangle was taller than it was wide.
    prefer_vertical: bool = false,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        for (state.columns.items) |*column| column.deinit(allocator);
        state.columns.deinit(allocator);
        state.height_overrides.deinit(allocator);
    }
};

pub const Options = struct {
    column_width: f64 = 0.5,
    center_focused: bool = true,
    follow_new_windows: bool = true,
    prefer_vertical_on_portrait: bool = false,
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
    const prefer_vertical = scrolling_options.prefer_vertical_on_portrait and usable_area.height > usable_area.width;
    const appended_vertical = try sync(state, allocator, windows, focused, prefer_vertical);
    state.prefer_vertical = prefer_vertical;
    if (appended_vertical) |location| {
        if (scrolling_options.follow_new_windows) {
            const column = &state.columns.items[location.column];
            column.viewport_anchor = column.windows.items[location.row];
            column.viewport_dirty = true;
        }
    }
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
    const border_width = options.border.width;
    // Scrolling dimensions describe the complete tile footprint. Borders are
    // drawn outside the client surface, so reserve their space here instead of
    // letting them enlarge the tile and consume the configured gaps.
    const base_outer_width = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(area.width)) * scrolling_options.column_width))));
    const base_width = contentLength(base_outer_width, border_width);
    const widths = try allocator.alloc(i32, state.columns.items.len);
    defer allocator.free(widths);
    const offsets = try allocator.alloc(i32, state.columns.items.len);
    defer allocator.free(offsets);

    var cursor: i32 = 0;
    for (state.columns.items, widths, offsets) |column, *width, *offset| {
        var minimum_width: i32 = 0;
        var maximum_width: i32 = 0;
        for (column.windows.items) |handle| {
            const window = findWindow(windows, handle).?;
            minimum_width = @max(minimum_width, window.min_width);
            if (window.max_width > 0) {
                maximum_width = if (maximum_width == 0)
                    window.max_width
                else
                    @min(maximum_width, window.max_width);
            }
        }
        const requested_width = if (column.expanded_owner != null)
            contentLength(area.width, border_width)
        else
            column.width_override orelse base_width;
        width.* = if (column.expanded_owner == null and column.width_override != null)
            clampRequestedSize(requested_width, minimum_width, maximum_width)
        else
            @max(requested_width, minimum_width);
        offset.* = cursor;
        cursor += outerLength(width.*, border_width) + options.gaps_inner;
    }
    const total_width = cursor - options.gaps_inner;

    const focus_changed = focused != state.last_focused;
    var resolved_focus = false;
    var focused_location: ?Location = null;
    var focused_column_changed = false;
    if (focused) |handle| {
        if (locate(state, handle)) |location| {
            resolved_focus = true;
            focused_location = location;
            focused_column_changed = location.column != state.focused_column;
            state.focused_column = location.column;
            if (focus_changed or focused_column_changed) state.viewport_column = location.column;
        }
    }
    if (!resolved_focus and scrolling_options.follow_new_windows and (appended_vertical != null or windows.len > old_count)) {
        const target_column = if (appended_vertical) |location| location.column else state.columns.items.len - 1;
        state.focused_column = target_column;
        state.viewport_column = target_column;
        state.viewport_dirty = true;
    }
    state.focused_column = @min(state.focused_column, state.columns.items.len - 1);
    state.viewport_column = @min(state.viewport_column, state.columns.items.len - 1);
    state.last_focused = focused;
    if (scrolling_options.center_focused or scrolling_options.snap_to_columns or state.viewport_dirty) {
        state.viewport_x = offsets[state.viewport_column] +
            @divTrunc(outerLength(widths[state.viewport_column], border_width), 2) -
            @divTrunc(area.width, 2);
        state.viewport_dirty = false;
    }
    if (!scrolling_options.allow_overscroll) {
        state.viewport_x = std.math.clamp(state.viewport_x, 0, @max(0, total_width - area.width));
    }

    var write: usize = 0;
    for (state.columns.items, widths, offsets, 0..) |*column, width, offset, column_index| {
        const rows = try splitColumnRows(
            allocator,
            state,
            column.windows.items,
            windows,
            area.height,
            options.gaps_inner,
            border_width,
        );
        defer allocator.free(rows);
        const total_height = rows[rows.len - 1].offset + rows[rows.len - 1].size + border_width;
        column.viewport_max_y = @max(0, total_height - area.height);
        column.viewport_y = std.math.clamp(column.viewport_y, 0, column.viewport_max_y);
        if (column.viewport_anchor != null and
            std.mem.indexOfScalar(types.Handle, column.windows.items, column.viewport_anchor.?) == null)
        {
            column.viewport_anchor = null;
        }

        const reveal_location = if (focused_location) |location|
            if (location.column == column_index and (focus_changed or focused_column_changed or column.reveal_focused)) location.row else null
        else
            null;
        if (column.viewport_dirty) {
            if (column.viewport_anchor) |anchor| {
                if (std.mem.indexOfScalar(types.Handle, column.windows.items, anchor)) |row_index| {
                    column.viewport_y = centeredRowOffset(rows[row_index], area.height, column.viewport_max_y, border_width);
                }
            }
            column.viewport_dirty = false;
        } else if (reveal_location) |row_index| {
            column.viewport_anchor = column.windows.items[row_index];
            column.viewport_y = revealRow(rows[row_index], column.viewport_y, area.height, column.viewport_max_y, border_width);
        }
        column.reveal_focused = false;
        if (column.viewport_max_y == 0) column.viewport_y = 0;

        const x = area.x + border_width + offset - state.viewport_x;
        for (column.windows.items, rows) |handle, row| {
            const geometry: types.Rect = .{
                .x = x,
                .y = area.y + row.offset - column.viewport_y,
                .width = width,
                .height = row.size,
            };
            const footprint: types.Rect = .{
                .x = geometry.x - border_width,
                .y = geometry.y - border_width,
                .width = outerLength(geometry.width, border_width),
                .height = outerLength(geometry.height, border_width),
            };
            const intersection = math.intersect(footprint, area);
            const visible = intersection.width > 0 and intersection.height > 0;
            result[write] = .{
                .handle = handle,
                .geometry = geometry,
                // Keep the complete viewport, including for placements whose
                // settled geometry is off-screen. The compositor intersects
                // this box with the live surface, while position animations
                // use it as the fixed aperture that entering and leaving
                // members move behind. Reducing this to the final intersection
                // truncates that motion and makes viewport changes look like
                // windows appearing/disappearing instead of one smooth strip.
                .clip = .{
                    .x = area.x - geometry.x,
                    .y = area.y - geometry.y,
                    .width = area.width,
                    .height = area.height,
                },
                .z_order = 0,
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

/// Pan the focused column vertically by whole members without changing focus.
/// The cached overflow bound is refreshed by arrange(), so this is a no-op for
/// columns whose members fit in the viewport.
pub fn scrollColumn(state: *State, focused: types.Handle, delta_rows: i32) bool {
    if (delta_rows == 0) return false;
    const location = locate(state, focused) orelse return false;
    const column = &state.columns.items[location.column];
    if (column.viewport_max_y == 0) return false;
    const current_row = if (column.viewport_anchor) |anchor|
        std.mem.indexOfScalar(types.Handle, column.windows.items, anchor) orelse location.row
    else
        location.row;
    const last: i64 = @intCast(column.windows.items.len - 1);
    const requested = std.math.clamp(
        @as(i64, @intCast(current_row)) + @as(i64, delta_rows),
        0,
        last,
    );
    const next: usize = @intCast(requested);
    if (next == current_row) return false;
    column.viewport_anchor = column.windows.items[next];
    column.viewport_dirty = true;
    column.reveal_focused = false;
    return true;
}

/// Whether the most recent arrange stacked this instance vertically. Input
/// policy uses this to follow the stacked axis with the primary navigation
/// chord instead of panning columns.
pub fn prefersVerticalScroll(state: *const State, handle: types.Handle) bool {
    return state.prefer_vertical and containsHandle(state, handle);
}

/// Window occupying the primary position of the selected viewport column.
/// Explicit keyboard viewport movement uses this to keep keyboard focus with
/// the content it brought on-screen. Pointer focus remains an independent
/// input-policy decision.
pub fn viewportFocusTarget(state: *const State) ?types.Handle {
    if (state.columns.items.len == 0) return null;
    const column = &state.columns.items[@min(state.viewport_column, state.columns.items.len - 1)];
    if (column.viewport_anchor) |anchor| {
        if (contains(column.windows.items, anchor)) return anchor;
    }
    return if (column.windows.items.len > 0) column.windows.items[0] else null;
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

/// Move the focused member into the adjacent column in the requested
/// direction. This is distinct from moveColumn(): window movement builds a
/// vertical stack, while explicit column movement swaps whole columns.
pub fn moveToAdjacentColumn(
    state: *State,
    allocator: std.mem.Allocator,
    focused: types.Handle,
    delta: i32,
) !bool {
    if (delta == 0) return false;
    const location = locate(state, focused) orelse return false;
    const destination = @as(i64, @intCast(location.column)) + @as(i64, delta);
    if (destination < 0 or destination >= state.columns.items.len) {
        // A stacked member can leave its column at either horizontal edge.
        // Do not move a single-window edge column: it is already expelled.
        if (state.columns.items[location.column].windows.items.len == 1) return false;
        var new_column = try singleWindowColumn(allocator, focused);
        errdefer new_column.deinit(allocator);
        try state.columns.ensureUnusedCapacity(allocator, 1);
        detach(state, location, allocator);
        const insert_at = if (delta < 0) location.column else location.column + 1;
        state.columns.insert(allocator, insert_at, new_column) catch unreachable;
        state.columns.items[insert_at].viewport_anchor = focused;
        state.columns.items[insert_at].reveal_focused = true;
        return true;
    }
    const target_handle = state.columns.items[@intCast(destination)].windows.items[0];
    try state.columns.items[@intCast(destination)].windows.ensureUnusedCapacity(allocator, 1);
    detach(state, location, allocator);
    const current_target = locate(state, target_handle) orelse unreachable;
    const target_column = &state.columns.items[current_target.column];
    target_column.windows.appendAssumeCapacity(focused);
    target_column.viewport_anchor = focused;
    target_column.reveal_focused = true;
    return true;
}

pub fn moveWithinColumn(state: *State, focused: types.Handle, delta: i32) bool {
    if (delta == 0) return false;
    const location = locate(state, focused) orelse return false;
    const windows = state.columns.items[location.column].windows.items;
    const destination = @as(i64, @intCast(location.row)) + @as(i64, delta);
    if (destination < 0 or destination >= windows.len) return false;
    std.mem.swap(types.Handle, &windows[location.row], &windows[@intCast(destination)]);
    state.columns.items[location.column].reveal_focused = true;
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
    state.columns.items[location.column].reveal_focused = true;
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
    state.columns.items[location.column + 1].viewport_anchor = focused;
    state.columns.items[location.column + 1].reveal_focused = true;
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
            state.columns.items[current_target.column].reveal_focused = true;
        },
        .column_before, .column_after => {
            const source_is_single = state.columns.items[dragged_location.column].windows.items.len == 1;
            if (source_is_single) {
                if (zone == .column_before and dragged_location.column + 1 == target_location.column) return false;
                if (zone == .column_after and target_location.column + 1 == dragged_location.column) return false;
            }
            var new_column = try singleWindowColumn(allocator, dragged);
            errdefer new_column.deinit(allocator);
            if (source_is_single) {
                new_column.width_override = state.columns.items[dragged_location.column].width_override;
            }
            try state.columns.ensureUnusedCapacity(allocator, 1);
            detach(state, dragged_location, allocator);
            const current_target = locate(state, target) orelse unreachable;
            const insert_at = current_target.column + @intFromBool(zone == .column_after);
            state.columns.insert(allocator, insert_at, new_column) catch unreachable;
            state.columns.items[insert_at].viewport_anchor = dragged;
            state.columns.items[insert_at].reveal_focused = true;
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

pub fn expandedOwner(state: *const State, handle: types.Handle) ?types.Handle {
    const location = locate(state, handle) orelse return null;
    return state.columns.items[location.column].expanded_owner;
}

pub fn columnMembers(state: *const State, handle: types.Handle) ?[]const types.Handle {
    const location = locate(state, handle) orelse return null;
    return state.columns.items[location.column].windows.items;
}

/// Resize a tiled scrolling member without removing it from the layout. Width
/// is shared by every member in the column; height belongs only to `handle`.
pub fn resize(
    state: *State,
    allocator: std.mem.Allocator,
    handle: types.Handle,
    width: i32,
    height: i32,
) !bool {
    const location = locate(state, handle) orelse return false;
    const requested_width = @max(1, width);
    const requested_height = @max(1, height);
    const column = &state.columns.items[location.column];
    const old_width = column.width_override;
    const old_height = state.height_overrides.get(handle);
    if (old_width == requested_width and old_height == requested_height) return false;
    try state.height_overrides.put(allocator, handle, requested_height);
    column.width_override = requested_width;
    return true;
}

/// Restore the configured column width and the selected member's default full
/// viewport height. Other members retain their independent height overrides.
pub fn resetSize(state: *State, handle: types.Handle) bool {
    const location = locate(state, handle) orelse return false;
    const column = &state.columns.items[location.column];
    const changed = column.width_override != null or state.height_overrides.contains(handle);
    column.width_override = null;
    _ = state.height_overrides.remove(handle);
    return changed;
}

fn sync(
    state: *State,
    allocator: std.mem.Allocator,
    windows: []const types.Window,
    focused: ?types.Handle,
    prefer_vertical: bool,
) !?Location {
    var column_index: usize = 0;
    while (column_index < state.columns.items.len) {
        var column = &state.columns.items[column_index];
        var row: usize = 0;
        while (row < column.windows.items.len) {
            if (findWindow(windows, column.windows.items[row]) == null) {
                const removed_handle = column.windows.orderedRemove(row);
                if (column.viewport_anchor == removed_handle) column.viewport_anchor = null;
                _ = state.height_overrides.remove(removed_handle);
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

    var target_column: ?usize = null;
    if (prefer_vertical and state.columns.items.len > 0) {
        target_column = if (focused) |handle|
            if (locate(state, handle)) |location| location.column else null
        else
            null;
        if (target_column == null) {
            target_column = if (state.last_focused) |handle|
                if (locate(state, handle)) |location| location.column else null
            else
                null;
        }
        if (target_column == null) target_column = state.columns.items.len - 1;
    }

    var appended_vertical: ?Location = null;
    for (windows) |window| {
        if (locate(state, window.handle) != null) continue;
        if (prefer_vertical and target_column != null) {
            const column = &state.columns.items[target_column.?];
            try column.windows.append(allocator, window.handle);
            appended_vertical = .{ .column = target_column.?, .row = column.windows.items.len - 1 };
            continue;
        }
        var column = try singleWindowColumn(allocator, window.handle);
        state.columns.append(allocator, column) catch |err| {
            column.deinit(allocator);
            return err;
        };
        if (prefer_vertical) {
            target_column = state.columns.items.len - 1;
            appended_vertical = .{ .column = target_column.?, .row = 0 };
        }
    }
    for (state.columns.items) |*column| refreshExpandedOwner(column, windows);
    return appended_vertical;
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
    const removed_handle = state.columns.items[location.column].windows.orderedRemove(location.row);
    if (state.columns.items[location.column].viewport_anchor == removed_handle) {
        state.columns.items[location.column].viewport_anchor = null;
    }
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

/// Unmodified members retain a full vertical viewport. Pointer-sized members
/// use their requested height, allowing a deliberately shortened stack to show
/// more than one member while preserving the existing default behavior.
fn splitColumnRows(
    allocator: std.mem.Allocator,
    state: *const State,
    handles: []const types.Handle,
    windows: []const types.Window,
    length: i32,
    gap: i32,
    border_width: i32,
) ![]math.AxisCell {
    if (handles.len == 0) return allocator.alloc(math.AxisCell, 0);
    const rows = try allocator.alloc(math.AxisCell, handles.len);
    errdefer allocator.free(rows);

    var cursor: i32 = 0;
    for (handles, rows) |handle, *row| {
        const window = findWindow(windows, handle).?;
        row.offset = cursor + border_width;
        row.size = if (state.height_overrides.get(handle)) |requested|
            clampRequestedSize(requested, window.min_height, window.max_height)
        else
            @max(contentLength(length, border_width), window.min_height);
        cursor += outerLength(row.size, border_width) + gap;
    }
    return rows;
}

fn contentLength(outer: i32, border_width: i32) i32 {
    return @max(1, outer -| (border_width *| 2));
}

fn outerLength(content: i32, border_width: i32) i32 {
    return content +| (border_width *| 2);
}

fn clampRequestedSize(requested: i32, minimum: i32, maximum: i32) i32 {
    const lower = @max(1, minimum);
    // Contradictory client hints are resolved in favor of the minimum, matching
    // the existing scrolling behavior for windows larger than their viewport.
    const upper = if (maximum > 0) @max(lower, maximum) else std.math.maxInt(i32);
    return std.math.clamp(requested, lower, upper);
}

fn centeredRowOffset(row: math.AxisCell, viewport_height: i32, maximum: i32, border_width: i32) i32 {
    const outer_size = outerLength(row.size, border_width);
    const outer_offset = row.offset - border_width;
    const requested = if (outer_size >= viewport_height)
        outer_offset
    else
        outer_offset + @divTrunc(outer_size, 2) - @divTrunc(viewport_height, 2);
    return std.math.clamp(requested, 0, maximum);
}

fn revealRow(row: math.AxisCell, current: i32, viewport_height: i32, maximum: i32, border_width: i32) i32 {
    const outer_size = outerLength(row.size, border_width);
    const outer_offset = row.offset - border_width;
    if (outer_size >= viewport_height) return std.math.clamp(outer_offset, 0, maximum);
    var requested = std.math.clamp(current, 0, maximum);
    if (outer_offset < requested) {
        requested = outer_offset;
    } else if (outer_offset + outer_size > requested + viewport_height) {
        requested = outer_offset + outer_size - viewport_height;
    }
    return std.math.clamp(requested, 0, maximum);
}

fn findPlacement(placements: []const types.Placement, handle: types.Handle) types.Placement {
    for (placements) |placement| if (placement.handle == handle) return placement;
    unreachable;
}

// Shared fixtures for the portrait placement tests below.
const portrait_area: types.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 120 };
const square_area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
const landscape_area: types.Rect = .{ .x = 0, .y = 0, .width = 120, .height = 80 };
const test_gaps: types.Options = .{ .gaps_outer = 0, .gaps_inner = 0 };

test "portrait preference stacks arrivals while default and non-portrait areas remain horizontal" {
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };

    var portrait: State = .{};
    defer portrait.deinit(std.testing.allocator);
    const portrait_placements = try arrange(std.testing.allocator, &portrait, portrait_area, &windows, null, test_gaps, .{
        .follow_new_windows = false,
        .prefer_vertical_on_portrait = true,
    });
    defer std.testing.allocator.free(portrait_placements);
    try std.testing.expectEqual(@as(usize, 1), portrait.columns.items.len);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 2, 3 }, portrait.columns.items[0].windows.items);

    var disabled: State = .{};
    defer disabled.deinit(std.testing.allocator);
    const disabled_placements = try arrange(std.testing.allocator, &disabled, portrait_area, &windows, null, test_gaps, .{});
    defer std.testing.allocator.free(disabled_placements);
    try std.testing.expectEqual(@as(usize, 3), disabled.columns.items.len);

    var square: State = .{};
    defer square.deinit(std.testing.allocator);
    const square_placements = try arrange(std.testing.allocator, &square, square_area, &windows, null, test_gaps, .{ .prefer_vertical_on_portrait = true });
    defer std.testing.allocator.free(square_placements);
    try std.testing.expectEqual(@as(usize, 3), square.columns.items.len);

    var landscape: State = .{};
    defer landscape.deinit(std.testing.allocator);
    const landscape_placements = try arrange(std.testing.allocator, &landscape, landscape_area, &windows, null, test_gaps, .{ .prefer_vertical_on_portrait = true });
    defer std.testing.allocator.free(landscape_placements);
    try std.testing.expectEqual(@as(usize, 3), landscape.columns.items.len);
}

test "vertical scroll preference follows the effective portrait arrangement" {
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const scrolling_options: Options = .{ .prefer_vertical_on_portrait = true };

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var placements = try arrange(std.testing.allocator, &state, portrait_area, &windows, null, test_gaps, scrolling_options);
    std.testing.allocator.free(placements);
    try std.testing.expect(prefersVerticalScroll(&state, 1));
    try std.testing.expect(!prefersVerticalScroll(&state, 99));

    // The same instance re-arranged into a landscape area becomes horizontal again.
    placements = try arrange(std.testing.allocator, &state, landscape_area, &windows, null, test_gaps, scrolling_options);
    std.testing.allocator.free(placements);
    try std.testing.expect(!prefersVerticalScroll(&state, 1));

    // The option off keeps landscape behavior even in portrait areas.
    placements = try arrange(std.testing.allocator, &state, portrait_area, &windows, null, test_gaps, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(!prefersVerticalScroll(&state, 1));
}

test "portrait insertion selects current then previous then last column and preserves arrival order" {
    const initial_windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const scrolling_options: Options = .{ .follow_new_windows = false, .prefer_vertical_on_portrait = true };
    // A handle that is not mapped, exercising the focus fallback chain.
    const missing: ?types.Handle = 99;

    var current: State = .{};
    defer current.deinit(std.testing.allocator);
    const current_initial = try arrange(std.testing.allocator, &current, landscape_area, &initial_windows, 2, test_gaps, scrolling_options);
    std.testing.allocator.free(current_initial);
    const current_added = try arrange(std.testing.allocator, &current, portrait_area, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 },
    }, 1, test_gaps, scrolling_options);
    defer std.testing.allocator.free(current_added);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3, 4 }, current.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{2}, current.columns.items[1].windows.items);

    var previous: State = .{};
    defer previous.deinit(std.testing.allocator);
    const previous_initial = try arrange(std.testing.allocator, &previous, landscape_area, &initial_windows, 1, test_gaps, scrolling_options);
    std.testing.allocator.free(previous_initial);
    const previous_added = try arrange(std.testing.allocator, &previous, portrait_area, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, missing, test_gaps, scrolling_options);
    defer std.testing.allocator.free(previous_added);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3 }, previous.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{2}, previous.columns.items[1].windows.items);

    var last: State = .{};
    defer last.deinit(std.testing.allocator);
    const last_initial = try arrange(std.testing.allocator, &last, landscape_area, &initial_windows, null, test_gaps, scrolling_options);
    std.testing.allocator.free(last_initial);
    const last_added = try arrange(std.testing.allocator, &last, portrait_area, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, missing, test_gaps, scrolling_options);
    defer std.testing.allocator.free(last_added);
    try std.testing.expectEqualSlices(types.Handle, &.{1}, last.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 3 }, last.columns.items[1].windows.items);
}

test "portrait follow reveals the last appended member and can be disabled" {
    var following: State = .{};
    defer following.deinit(std.testing.allocator);
    const following_initial = try arrange(std.testing.allocator, &following, portrait_area, &.{.{ .handle = 1 }}, 1, test_gaps, .{ .prefer_vertical_on_portrait = true });
    std.testing.allocator.free(following_initial);
    const following_added = try arrange(std.testing.allocator, &following, portrait_area, &.{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } }, 1, test_gaps, .{ .prefer_vertical_on_portrait = true });
    defer std.testing.allocator.free(following_added);
    try std.testing.expectEqual(@as(?types.Handle, 3), following.columns.items[0].viewport_anchor);
    try std.testing.expectEqual(@as(i32, 0), findPlacement(following_added, 3).geometry.y);
    try std.testing.expect(findPlacement(following_added, 1).geometry.y < 0);

    var stationary: State = .{};
    defer stationary.deinit(std.testing.allocator);
    const stationary_initial = try arrange(std.testing.allocator, &stationary, portrait_area, &.{.{ .handle = 1 }}, 1, test_gaps, .{
        .follow_new_windows = false,
        .prefer_vertical_on_portrait = true,
    });
    std.testing.allocator.free(stationary_initial);
    const stationary_added = try arrange(std.testing.allocator, &stationary, portrait_area, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, 1, test_gaps, .{
        .follow_new_windows = false,
        .prefer_vertical_on_portrait = true,
    });
    defer std.testing.allocator.free(stationary_added);
    try std.testing.expectEqual(@as(i32, 0), stationary.columns.items[0].viewport_y);
    try std.testing.expectEqual(@as(i32, 0), findPlacement(stationary_added, 1).geometry.y);
    try std.testing.expectEqual(@as(i32, 120), findPlacement(stationary_added, 2).geometry.y);
}

test "portrait insertion respects explicit columns and removal membership" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const scrolling_options: Options = .{ .follow_new_windows = false, .prefer_vertical_on_portrait = true };
    const initial = try arrange(std.testing.allocator, &state, portrait_area, &.{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } }, 1, test_gaps, scrolling_options);
    std.testing.allocator.free(initial);
    try std.testing.expect(try expelToRight(&state, std.testing.allocator, 2));
    try std.testing.expect(try moveToAdjacentColumn(&state, std.testing.allocator, 3, 1));
    try std.testing.expectEqualSlices(types.Handle, &.{1}, state.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 3 }, state.columns.items[1].windows.items);

    const added = try arrange(std.testing.allocator, &state, portrait_area, &.{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 } }, 3, test_gaps, scrolling_options);
    std.testing.allocator.free(added);
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 3, 4 }, state.columns.items[1].windows.items);

    const removed = try arrange(std.testing.allocator, &state, portrait_area, &.{ .{ .handle = 1 }, .{ .handle = 3 }, .{ .handle = 4 } }, 3, test_gaps, scrolling_options);
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualSlices(types.Handle, &.{ 3, 4 }, state.columns.items[1].windows.items);
    const projection = try flattened(std.testing.allocator, &state);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3, 4 }, projection);
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
    try std.testing.expectEqual(types.Rect{ .x = 75, .y = 0, .width = 100, .height = 80 }, placements[0].clip.?);
    try std.testing.expect(placements[2].visible);
}

test "column members retain full viewport height" {
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
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 50, .height = 80 }, stacked[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 84, .width = 50, .height = 80 }, stacked[1].geometry);
    try std.testing.expectEqual(@as(i32, 84), state.columns.items[0].viewport_max_y);
    try std.testing.expectEqual(@as(usize, 2), state.columns.items.len);
    try std.testing.expect(scrollColumn(&state, 1, 1));
    try std.testing.expectEqual(@as(?types.Handle, 2), viewportFocusTarget(&state));

    const scrolled = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    defer std.testing.allocator.free(scrolled);
    try std.testing.expectEqual(@as(i32, -84), findPlacement(scrolled, 1).geometry.y);
    try std.testing.expectEqual(@as(i32, 0), findPlacement(scrolled, 2).geometry.y);
}

test "pointer resize changes a whole column width and one member height" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{
        .{ .handle = 1, .min_width = 40, .max_width = 70, .min_height = 20, .max_height = 60 },
        .{ .handle = 2, .max_width = 65 },
    };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 0 };
    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    std.testing.allocator.free(initial);
    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    try std.testing.expect(try resize(&state, std.testing.allocator, 1, 90, 10));

    const resized = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    defer std.testing.allocator.free(resized);
    const first = findPlacement(resized, 1);
    const second = findPlacement(resized, 2);
    // The tightest column maximum applies to every member; the selected
    // member's independent height is clamped to its own minimum.
    try std.testing.expectEqual(@as(i32, 65), first.geometry.width);
    try std.testing.expectEqual(@as(i32, 65), second.geometry.width);
    try std.testing.expectEqual(@as(i32, 20), first.geometry.height);
    try std.testing.expectEqual(@as(i32, 80), second.geometry.height);
    try std.testing.expectEqual(@as(i32, 20), second.geometry.y);
    try std.testing.expect(!try resize(&state, std.testing.allocator, 99, 50, 50));

    try std.testing.expect(resetSize(&state, 1));
    const reset = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    defer std.testing.allocator.free(reset);
    try std.testing.expectEqual(@as(i32, 50), findPlacement(reset, 1).geometry.width);
    try std.testing.expectEqual(@as(i32, 80), findPlacement(reset, 1).geometry.height);
    try std.testing.expect(!resetSize(&state, 1));
}

test "minimum heights overflow and the focused column scrolls by member" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{
        .{ .handle = 1, .min_height = 60 },
        .{ .handle = 2, .min_height = 60 },
        .{ .handle = 3 },
    };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4 };
    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    std.testing.allocator.free(initial);

    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    const overflow = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    defer std.testing.allocator.free(overflow);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 50, .height = 80 }, overflow[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 84, .width = 50, .height = 80 }, overflow[1].geometry);
    try std.testing.expectEqual(types.Rect{ .x = -25, .y = -84, .width = 100, .height = 80 }, overflow[1].clip.?);
    try std.testing.expectEqual(@as(i32, 84), state.columns.items[0].viewport_max_y);

    try std.testing.expect(scrollColumn(&state, 1, 1));
    const scrolled = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    defer std.testing.allocator.free(scrolled);
    try std.testing.expectEqual(@as(i32, -84), scrolled[0].geometry.y);
    try std.testing.expectEqual(types.Rect{ .x = -25, .y = 84, .width = 100, .height = 80 }, scrolled[0].clip.?);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 50, .height = 80 }, scrolled[1].geometry);
    try std.testing.expect(!scrollColumn(&state, 1, 1));

    const after_removal = try arrange(std.testing.allocator, &state, area, &.{
        .{ .handle = 1, .min_height = 60 },
        .{ .handle = 3 },
    }, 1, options, .{});
    defer std.testing.allocator.free(after_removal);
    try std.testing.expectEqual(@as(i32, 0), state.columns.items[0].viewport_y);
    try std.testing.expectEqual(@as(i32, 0), state.columns.items[0].viewport_max_y);
    try std.testing.expectEqual(@as(?types.Handle, null), state.columns.items[0].viewport_anchor);
}

test "vertical viewport positions are independent per column" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{
        .{ .handle = 1, .min_height = 60 },
        .{ .handle = 2, .min_height = 60 },
        .{ .handle = 3, .min_height = 60 },
        .{ .handle = 4, .min_height = 60 },
    };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 0 };
    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    std.testing.allocator.free(initial);
    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 3));
    const stacked = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    std.testing.allocator.free(stacked);

    try std.testing.expect(scrollColumn(&state, 1, 1));
    const scrolled = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    defer std.testing.allocator.free(scrolled);
    try std.testing.expectEqual(@as(i32, -80), findPlacement(scrolled, 1).geometry.y);
    try std.testing.expectEqual(@as(i32, 0), findPlacement(scrolled, 2).geometry.y);
    try std.testing.expectEqual(@as(i32, 0), findPlacement(scrolled, 3).geometry.y);
    try std.testing.expectEqual(@as(i32, 80), findPlacement(scrolled, 4).geometry.y);
}

test "focus changes reveal vertically clipped members" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{
        .{ .handle = 1, .min_height = 60 },
        .{ .handle = 2, .min_height = 60 },
        .{ .handle = 3 },
    };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 0 };
    const initial = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    std.testing.allocator.free(initial);
    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));
    const stacked = try arrange(std.testing.allocator, &state, area, &windows, 1, options, .{});
    std.testing.allocator.free(stacked);

    const bottom = try arrange(std.testing.allocator, &state, area, &windows, 2, options, .{});
    defer std.testing.allocator.free(bottom);
    try std.testing.expectEqual(@as(i32, -80), findPlacement(bottom, 1).geometry.y);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 50, .height = 80 }, findPlacement(bottom, 2).geometry);
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

test "horizontal window movement joins adjacent columns" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(placements);

    try std.testing.expect(try moveToAdjacentColumn(&state, std.testing.allocator, 2, -1));
    try std.testing.expectEqual(@as(usize, 2), state.columns.items.len);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 2 }, state.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{3}, state.columns.items[1].windows.items);

    try std.testing.expect(try moveToAdjacentColumn(&state, std.testing.allocator, 2, 1));
    try std.testing.expectEqualSlices(types.Handle, &.{1}, state.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{ 3, 2 }, state.columns.items[1].windows.items);
    try std.testing.expectEqual(@as(?types.Handle, 2), state.columns.items[1].viewport_anchor);
    try std.testing.expect(try moveToAdjacentColumn(&state, std.testing.allocator, 2, 1));
    try std.testing.expectEqualSlices(types.Handle, &.{1}, state.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{3}, state.columns.items[1].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{2}, state.columns.items[2].windows.items);
    try std.testing.expect(!try moveToAdjacentColumn(&state, std.testing.allocator, 2, 1));
}

test "edge movement expels a stacked member in the requested direction" {
    var left_state: State = .{};
    defer left_state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const left_placements = try arrange(std.testing.allocator, &left_state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(left_placements);
    try std.testing.expect(try moveToAdjacentColumn(&left_state, std.testing.allocator, 2, -1));
    try std.testing.expect(try moveToAdjacentColumn(&left_state, std.testing.allocator, 2, -1));
    try std.testing.expectEqualSlices(types.Handle, &.{2}, left_state.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{1}, left_state.columns.items[1].windows.items);
    try std.testing.expect(!try moveToAdjacentColumn(&left_state, std.testing.allocator, 2, -1));

    var right_state: State = .{};
    defer right_state.deinit(std.testing.allocator);
    const right_placements = try arrange(std.testing.allocator, &right_state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    std.testing.allocator.free(right_placements);
    try std.testing.expect(try moveToAdjacentColumn(&right_state, std.testing.allocator, 1, 1));
    try std.testing.expect(try moveToAdjacentColumn(&right_state, std.testing.allocator, 1, 1));
    try std.testing.expectEqualSlices(types.Handle, &.{2}, right_state.columns.items[0].windows.items);
    try std.testing.expectEqualSlices(types.Handle, &.{1}, right_state.columns.items[1].windows.items);
    try std.testing.expect(!try moveToAdjacentColumn(&right_state, std.testing.allocator, 1, 1));
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
    try std.testing.expectEqual(@as(?types.Handle, 3), viewportFocusTarget(&state));
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
    try std.testing.expectEqual(@as(?types.Handle, 3), viewportFocusTarget(&state));
    const focused = try arrange(std.testing.allocator, &state, area, &windows, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(focused);
    try std.testing.expectEqual(@as(i32, 25), focused[1].geometry.x);
}

test "scrolling reserves outward borders and preserves exact gaps" {
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const initial = try arrange(
        std.testing.allocator,
        &state,
        area,
        &windows,
        1,
        .{
            .gaps_outer = 0,
            .gaps_inner = 6,
            .border = .{
                .width = 2,
                .focused = 0,
                .normal = 0,
                .urgent = 0,
            },
        },
        .{},
    );
    std.testing.allocator.free(initial);
    try std.testing.expect(try consumeFromRight(&state, std.testing.allocator, 1));

    const placements = try arrange(std.testing.allocator, &state, area, &windows, 1, .{
        .gaps_outer = 0,
        .gaps_inner = 6,
        .border = .{
            .width = 2,
            .focused = 0,
            .normal = 0,
            .urgent = 0,
        },
    }, .{});
    defer std.testing.allocator.free(placements);

    const first = findPlacement(placements, 1);
    const second = findPlacement(placements, 2);
    const third = findPlacement(placements, 3);
    // The first member's outline spans exactly the 80-pixel viewport. The
    // second outline begins six clear pixels later, without changing that
    // viewport-sized scrolling stride into an oversized window.
    try std.testing.expectEqual(types.Rect{ .x = 27, .y = 2, .width = 46, .height = 76 }, first.geometry);
    try std.testing.expectEqual(types.Rect{ .x = 27, .y = 88, .width = 46, .height = 76 }, second.geometry);
    try std.testing.expectEqual(@as(i32, 86), state.columns.items[0].viewport_max_y);
    // Adjacent column outlines also retain the exact configured gap.
    try std.testing.expectEqual(@as(i32, 83), third.geometry.x);
    try std.testing.expectEqual(@as(i32, 46), third.geometry.width);
    try std.testing.expectEqual(@as(i32, 0), first.z_order);
    try std.testing.expectEqual(@as(i32, 0), second.z_order);
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
