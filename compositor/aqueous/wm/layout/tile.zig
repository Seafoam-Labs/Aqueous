// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const order = @import("order.zig");
const types = @import("types.zig");

pub const State = struct {
    order: order.State = .{},
    master_count: u32 = 1,
    /// Pointer resizing records an explicit master/stack split. Null follows
    /// the configured master ratio.
    master_ratio_override: ?f64 = null,
    /// Vertical sizing belongs to a member rather than its column. Keeping the
    /// overrides keyed by stable handle lets them follow reorders inside this
    /// tile state.
    height_overrides: std.AutoHashMapUnmanaged(types.Handle, i32) = .empty,
    /// Geometry of the most recent arrange, used to translate pointer pixel
    /// deltas into a split ratio.
    last_area_width: i32 = 0,
    last_gaps_inner: i32 = 0,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.order.deinit(allocator);
        state.height_overrides.deinit(allocator);
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
    try pruneHeightOverrides(allocator, state, windows);
    const handles = state.order.items.items;
    const result = try allocator.alloc(types.Placement, handles.len);
    if (handles.len == 0) return result;

    const area = math.shrink(usable_area, options.gaps_outer);
    state.last_area_width = area.width;
    state.last_gaps_inner = options.gaps_inner;
    state.master_count = @max(1, @min(options.master_count, @as(u32, @intCast(handles.len))));
    if (handles.len == 1) {
        result[0] = .{ .handle = handles[0], .geometry = area, .z_order = 0, .visible = true, .border = options.border };
        return result;
    }

    const stack_count: u32 = @intCast(handles.len - state.master_count);
    const master_ratio = state.master_ratio_override orelse options.master_ratio;
    const master_width = if (stack_count == 0)
        area.width
    else
        @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(area.width)) * master_ratio))));
    const stack_width = if (stack_count == 0) 0 else @max(1, area.width - master_width - options.gaps_inner);

    try splitVertical(allocator, state, result[0..state.master_count], handles[0..state.master_count], .{
        .x = area.x,
        .y = area.y,
        .width = master_width,
        .height = area.height,
    }, options);
    if (stack_count > 0) {
        try splitVertical(allocator, state, result[state.master_count..], handles[state.master_count..], .{
            .x = area.x + master_width + options.gaps_inner,
            .y = area.y,
            .width = stack_width,
            .height = area.height,
        }, options);
    }
    return result;
}

fn splitVertical(allocator: std.mem.Allocator, state: *const State, placements: []types.Placement, handles: []const types.Handle, area: types.Rect, options: types.Options) !void {
    const rows = try splitColumnRows(allocator, state, handles, area.height, options.gaps_inner);
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

/// Members with a pointer-resized height keep their explicit size; the
/// remaining space is shared evenly by the unmodified members.
fn splitColumnRows(allocator: std.mem.Allocator, state: *const State, handles: []const types.Handle, length: i32, gap: i32) ![]math.AxisCell {
    if (handles.len == 0) return allocator.alloc(math.AxisCell, 0);
    const result = try allocator.alloc(math.AxisCell, handles.len);
    errdefer allocator.free(result);

    var fixed_total: i32 = 0;
    var flexible_count: i32 = 0;
    for (handles) |handle| {
        if (state.height_overrides.get(handle)) |requested| {
            fixed_total += @max(1, requested);
        } else {
            flexible_count += 1;
        }
    }
    const total_gap = gap * (@as(i32, @intCast(handles.len)) - 1);
    const flexible_space = @max(0, length - total_gap - fixed_total);
    const each_size = if (flexible_count == 0) 0 else @max(1, @divTrunc(flexible_space, flexible_count));

    var current: i32 = 0;
    var flexible_index: i32 = 0;
    for (result, handles) |*cell, handle| {
        const size = if (state.height_overrides.get(handle)) |requested|
            @max(1, requested)
        else blk: {
            flexible_index += 1;
            const leftover = if (flexible_index == flexible_count) @max(0, flexible_space - each_size * flexible_count) else 0;
            break :blk each_size + leftover;
        };
        cell.* = .{ .offset = current, .size = size };
        current += size + gap;
    }
    return result;
}

pub fn canResize(state: *const State, handle: types.Handle) bool {
    return std.mem.indexOfScalar(types.Handle, state.order.items.items, handle) != null;
}

/// Resize a tiled member without removing it from the layout. Horizontal
/// motion moves the master/stack split shared by every member; vertical
/// motion changes only the selected member's height within its column.
pub fn resize(
    allocator: std.mem.Allocator,
    state: *State,
    handle: types.Handle,
    width: i32,
    height: i32,
) !bool {
    const index = std.mem.indexOfScalar(types.Handle, state.order.items.items, handle) orelse return false;
    if (state.last_area_width <= 0) return false;
    var changed = false;

    const has_stack = state.order.items.items.len > state.master_count;
    if (has_stack) {
        const master_width: i32 = if (index < state.master_count)
            width
        else
            state.last_area_width - state.last_gaps_inner - width;
        const ratio = @as(f64, @floatFromInt(master_width)) / @as(f64, @floatFromInt(state.last_area_width));
        if (ratio > 0 and ratio < 1 and state.master_ratio_override != ratio) {
            state.master_ratio_override = ratio;
            changed = true;
        }
    }

    const requested_height = @max(1, height);
    if (state.height_overrides.get(handle) != requested_height) {
        try state.height_overrides.put(allocator, handle, requested_height);
        changed = true;
    }
    return changed;
}

/// Restore the configured master ratio and the selected member's default even
/// column height. Other members retain their independent height overrides.
pub fn resetSize(state: *State, handle: types.Handle) bool {
    const changed = state.master_ratio_override != null or state.height_overrides.contains(handle);
    state.master_ratio_override = null;
    _ = state.height_overrides.remove(handle);
    return changed;
}

fn pruneHeightOverrides(allocator: std.mem.Allocator, state: *State, windows: []const types.Window) !void {
    var stale: std.ArrayListUnmanaged(types.Handle) = .empty;
    defer stale.deinit(allocator);
    var it = state.height_overrides.keyIterator();
    while (it.next()) |key| {
        var live = false;
        for (windows) |window| {
            if (window.handle == key.*) {
                live = true;
                break;
            }
        }
        if (!live) try stale.append(allocator, key.*);
    }
    for (stale.items) |handle| _ = state.height_overrides.remove(handle);
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

test "tile resize from the master column moves the shared split" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 };
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };

    var placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    std.testing.allocator.free(placements);
    try std.testing.expect(canResize(&state, 1));
    try std.testing.expect(!canResize(&state, 99));
    try std.testing.expect(try resize(std.testing.allocator, &state, 1, 70, 80));
    try std.testing.expect(!try resize(std.testing.allocator, &state, 99, 70, 80));

    placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 70, .height = 80 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 74, .y = 0, .width = 26, .height = 38 }, placements[1].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 74, .y = 42, .width = 26, .height = 38 }, placements[2].geometry);
}

test "tile resize from the stack column derives the same split" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 };
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };

    var placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    std.testing.allocator.free(placements);
    // Dragging the stack's left edge rightward by ten pixels shrinks the
    // stack width from 46 to 36, so the master grows to 60.
    try std.testing.expect(try resize(std.testing.allocator, &state, 2, 36, 38));

    placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 60, .height = 80 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 64, .y = 0, .width = 36, .height = 38 }, placements[1].geometry);
}

test "tile resize rejects splits outside the usable area" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 };
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };

    const placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    defer std.testing.allocator.free(placements);
    // Overshooting either edge leaves the configured split untouched, but
    // the vertical motion still records the member height.
    try std.testing.expect(try resize(std.testing.allocator, &state, 1, 500, 60));
    try std.testing.expectEqual(@as(?f64, null), state.master_ratio_override);
    try std.testing.expectEqual(@as(?i32, 60), state.height_overrides.get(1));
    try std.testing.expect(try resize(std.testing.allocator, &state, 2, 500, 38));
    try std.testing.expectEqual(@as(?f64, null), state.master_ratio_override);
}

test "tile height override keeps explicit sizes while siblings share the rest" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 };
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };

    var placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    std.testing.allocator.free(placements);
    try std.testing.expect(try resize(std.testing.allocator, &state, 2, 46, 60));

    placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 0, .width = 46, .height = 60 }, placements[1].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 64, .width = 46, .height = 16 }, placements[2].geometry);
}

test "tile reset restores the configured ratio and member height" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 };
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };

    var placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    std.testing.allocator.free(placements);
    try std.testing.expect(try resize(std.testing.allocator, &state, 1, 70, 60));
    // The split is shared, so resetting from any member restores it. Other
    // members retain their independent height overrides.
    try std.testing.expect(resetSize(&state, 2));

    placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 50, .height = 60 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 0, .width = 46, .height = 38 }, placements[1].geometry);
    std.testing.allocator.free(placements);

    try std.testing.expect(resetSize(&state, 1));
    try std.testing.expect(!resetSize(&state, 1));

    placements = try arrange(std.testing.allocator, &state, area, &windows, options);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 50, .height = 80 }, placements[0].geometry);
}

test "tile drops height overrides when windows close" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 };

    var placements = try arrange(std.testing.allocator, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } }, options);
    std.testing.allocator.free(placements);
    try std.testing.expect(try resize(std.testing.allocator, &state, 3, 46, 20));

    placements = try arrange(std.testing.allocator, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, options);
    defer std.testing.allocator.free(placements);
    try std.testing.expect(!state.height_overrides.contains(3));
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 0, .width = 46, .height = 80 }, placements[1].geometry);
}
