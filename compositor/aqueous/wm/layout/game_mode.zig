// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const geometry = @import("game_geometry.zig");
const dwindle = @import("dwindle.zig");
const floating = @import("floating.zig");
const grid = @import("grid.zig");
const math = @import("math.zig");
const monocle = @import("monocle.zig");
const order = @import("order.zig");
const rows = @import("rows.zig");
const scrolling = @import("scrolling.zig");
const tile = @import("tile.zig");
const types = @import("types.zig");

pub const RemainderState = struct {
    grid: grid.State = .{},
    rows: rows.State = .{},
    tile: tile.State = .{},
    monocle: monocle.State = .{},
    dwindle: dwindle.State = .{},
    scrolling: scrolling.State = .{},
    floating: floating.State = .{},
    pub fn deinit(state: *RemainderState, allocator: std.mem.Allocator) void {
        state.grid.deinit(allocator);
        state.rows.deinit(allocator);
        state.tile.deinit(allocator);
        state.monocle.deinit(allocator);
        state.dwindle.deinit(allocator);
        state.scrolling.deinit(allocator);
        state.floating.deinit(allocator);
    }

    fn orderFor(state: *RemainderState, kind: Remainder) ?*order.State {
        return switch (kind) {
            .tile => &state.tile.order,
            .monocle => &state.monocle.order,
            .grid => &state.grid.order,
            .rows => &state.rows.order,
            .dwindle => &state.dwindle.order,
            .scrolling => null,
            .floating => null,
        };
    }
};

pub const State = struct {
    fallback: RemainderState = .{},
    left: RemainderState = .{},
    right: RemainderState = .{},
    /// A matched game rule claimed this workspace's layout. The claim remains
    /// after its anchor closes so fallback_layout is actually reachable, and
    /// is released only by an explicit user layout selection.
    rule_layout_owned: bool = false,
    anchor: ?types.Handle = null,
    rule_anchor: ?types.Handle = null,
    rule_options: Options = .{},
    active_remainder: Remainder = .grid,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.fallback.deinit(allocator);
        state.left.deinit(allocator);
        state.right.deinit(allocator);
    }
};

pub const Options = struct {
    size: geometry.Size = .{ .fraction = .{ .width = 0.5, .height = 1.0 } },
    anchor: geometry.Anchor = .center,
    scale: f64 = 1,
    remainder: Remainder = .grid,
    fallback: Remainder = .grid,
    gaps_inner: ?i32 = null,
    anchor_area: ?types.Rect = null,
};

pub const Remainder = enum { tile, monocle, grid, rows, dwindle, scrolling, floating };

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, focused: ?types.Handle, options: types.Options, game_options: Options) ![]types.Placement {
    const result = try allocator.alloc(types.Placement, windows.len);
    if (windows.len == 0) {
        state.anchor = null;
        return result;
    }
    const effective = if (state.rule_anchor != null) state.rule_options else game_options;
    if (state.rule_anchor == null) {
        state.anchor = null;
        state.active_remainder = effective.fallback;
        const placements = try arrangeRemainder(allocator, &state.fallback, effective.fallback, usable_area, windows, focused, options);
        defer allocator.free(placements);
        @memcpy(result, placements);
        return result;
    }
    state.active_remainder = effective.remainder;
    if (state.rule_anchor) |anchor| {
        if (contains(windows, anchor)) state.anchor = anchor;
    } else if (focused != null and contains(windows, focused.?)) state.anchor = focused;
    if (state.anchor == null or !contains(windows, state.anchor.?)) state.anchor = windows[0].handle;
    const anchor_window = find(windows, state.anchor.?).?;
    const area = math.shrink(usable_area, options.gaps_outer);
    const anchor_area = if (effective.anchor_area) |raw| math.shrink(raw, options.gaps_outer) else area;
    const anchor_rect = geometry.resolveAnchor(anchor_area, @max(1, anchor_window.min_width), @max(1, anchor_window.min_height), effective.size, effective.anchor, effective.scale);
    result[0] = .{ .handle = state.anchor.?, .geometry = anchor_rect, .z_order = 1, .visible = true, .border = .none };

    const columns = geometry.resolveSideColumns(area, anchor_rect);
    var left_windows: std.ArrayListUnmanaged(types.Window) = .empty;
    defer left_windows.deinit(allocator);
    var right_windows: std.ArrayListUnmanaged(types.Window) = .empty;
    defer right_windows.deinit(allocator);
    const left_empty = columns.left.width <= 0 or columns.left.height <= 0;
    const right_empty = columns.right.width <= 0 or columns.right.height <= 0;
    var non_anchor_index: usize = 0;
    for (windows) |window| {
        if (window.handle == state.anchor.?) continue;
        if (left_empty and right_empty) {
            non_anchor_index += 1;
            continue;
        }
        if (left_empty) {
            try right_windows.append(allocator, window);
        } else if (right_empty or non_anchor_index % 2 == 0) {
            try left_windows.append(allocator, window);
        } else {
            try right_windows.append(allocator, window);
        }
        non_anchor_index += 1;
    }

    if (left_empty and right_empty) {
        var write: usize = 1;
        for (windows) |window| {
            if (window.handle == state.anchor.?) continue;
            result[write] = .{ .handle = window.handle, .geometry = .empty, .z_order = 0, .visible = false, .border = .none };
            write += 1;
        }
        return result;
    }

    var remainder_options = options;
    remainder_options.gaps_outer = 0;
    remainder_options.gaps_inner = effective.gaps_inner orelse options.gaps_inner;
    var write: usize = 1;
    const left_placements = try arrangeRemainder(allocator, &state.left, effective.remainder, columns.left, left_windows.items, focused, remainder_options);
    defer allocator.free(left_placements);
    @memcpy(result[write .. write + left_placements.len], left_placements);
    write += left_placements.len;
    const right_placements = try arrangeRemainder(allocator, &state.right, effective.remainder, columns.right, right_windows.items, focused, remainder_options);
    defer allocator.free(right_placements);
    @memcpy(result[write .. write + right_placements.len], right_placements);
    write += right_placements.len;
    std.debug.assert(write == result.len);
    return result;
}

fn arrangeRemainder(allocator: std.mem.Allocator, state: *RemainderState, kind: Remainder, area: types.Rect, windows: []const types.Window, focused: ?types.Handle, options: types.Options) ![]types.Placement {
    return switch (kind) {
        .tile => tile.arrange(allocator, &state.tile, area, windows, options),
        .monocle => monocle.arrange(allocator, &state.monocle, area, windows, focused, options, .{}),
        .grid => grid.arrange(allocator, &state.grid, area, windows, options),
        .rows => rows.arrange(allocator, &state.rows, area, windows, options),
        .dwindle => dwindle.arrange(allocator, &state.dwindle, area, windows, options, .{}),
        .scrolling => scrolling.arrange(allocator, &state.scrolling, area, windows, focused, options, .{}),
        .floating => floating.arrange(allocator, &state.floating, area, windows, focused, options),
    };
}

pub fn swap(state: *State, a: types.Handle, b: types.Handle) bool {
    var changed = false;
    inline for (.{ &state.fallback, &state.left, &state.right }) |side| {
        inline for (.{ &side.tile.order, &side.monocle.order, &side.grid.order, &side.rows.order, &side.dwindle.order }) |layout_order| {
            if (layout_order.swap(a, b)) changed = true;
        }
        if (scrolling.swap(&side.scrolling, a, b)) changed = true;
    }
    return changed;
}

pub fn moveAdjacent(state: *State, focused: types.Handle, delta: i32) bool {
    if (state.active_remainder == .scrolling) return false;
    for ([_]*RemainderState{ &state.fallback, &state.left, &state.right }) |side| {
        const layout_order = side.orderFor(state.active_remainder) orelse return false;
        const index = std.mem.indexOfScalar(types.Handle, layout_order.items.items, focused) orelse continue;
        const target = @as(isize, @intCast(index)) + delta;
        if (target < 0 or target >= layout_order.items.items.len) return false;
        std.mem.swap(types.Handle, &layout_order.items.items[index], &layout_order.items.items[@intCast(target)]);
        return true;
    }
    return false;
}

pub fn scrollViewport(state: *State, focused: types.Handle, delta: i32) bool {
    if (state.active_remainder != .scrolling) return false;
    for ([_]*RemainderState{ &state.fallback, &state.left, &state.right }) |side| {
        if (scrolling.containsHandle(&side.scrolling, focused)) {
            return scrolling.scrollViewport(&side.scrolling, delta);
        }
    }
    return false;
}

fn contains(windows: []const types.Window, handle: types.Handle) bool {
    return find(windows, handle) != null;
}

fn find(windows: []const types.Window, handle: types.Handle) ?types.Window {
    for (windows) |window| if (window.handle == handle) return window;
    return null;
}

test "game mode anchors focus and tiles the remainder" {
    var state: State = .{
        .rule_anchor = 2,
        .rule_options = .{ .gaps_inner = 0 },
    };
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 200, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(types.Handle, 2), placements[0].handle);
    try std.testing.expectEqual(types.Rect{ .x = 50, .y = 0, .width = 100, .height = 100 }, placements[0].geometry);
    try std.testing.expect(placements[1].visible);
    try std.testing.expect(placements[2].visible);
}

test "game mode delegates a no-anchor output to the configured tile fallback" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, 1, .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 }, .{ .fallback = .tile });
    defer std.testing.allocator.free(placements);

    try std.testing.expectEqual(@as(?types.Handle, null), state.anchor);
    try std.testing.expectEqual(Remainder.tile, state.active_remainder);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 50, .height = 80 }, findPlacement(placements, 1).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 0, .width = 46, .height = 38 }, findPlacement(placements, 2).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 54, .y = 42, .width = 46, .height = 38 }, findPlacement(placements, 3).geometry);
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 2, 3 }, state.fallback.tile.order.items.items);
    try std.testing.expectEqual(@as(usize, 0), state.fallback.grid.order.items.items.len);
}

test "game mode routes viewport movement to a scrolling fallback" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{ .fallback = .scrolling });
    std.testing.allocator.free(placements);

    try std.testing.expect(scrollViewport(&state, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), state.fallback.scrolling.viewport_column);
}

test "game mode preserves each scrolling side column as its own viewport" {
    var state: State = .{
        .rule_anchor = 1,
        .rule_options = .{
            .size = .{ .pixels = .{ .width = 100, .height = 100 } },
            .remainder = .scrolling,
            .gaps_inner = 0,
        },
    };
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 300, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 }, .{ .handle = 5 },
    }, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(placements);

    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 100, .height = 100 }, findPlacement(placements, 2).clip.?);
    try std.testing.expectEqual(types.Rect{ .x = 25, .y = 0, .width = 100, .height = 100 }, findPlacement(placements, 3).clip.?);
    try std.testing.expectEqual(types.Rect{ .x = -25, .y = 0, .width = 100, .height = 100 }, findPlacement(placements, 4).clip.?);
    try std.testing.expectEqual(types.Rect{ .x = -25, .y = 0, .width = 100, .height = 100 }, findPlacement(placements, 5).clip.?);
}

test "game mode applies rows independently to both side columns" {
    var state: State = .{
        .rule_anchor = 1,
        .rule_options = .{
            .size = .{ .pixels = .{ .width = 100, .height = 100 } },
            .remainder = .rows,
            .gaps_inner = 0,
        },
    };
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 300, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 }, .{ .handle = 5 },
    }, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(placements);

    try std.testing.expectEqual(types.Rect{ .x = 100, .y = 0, .width = 100, .height = 100 }, findPlacement(placements, 1).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 100, .height = 50 }, findPlacement(placements, 2).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 200, .y = 0, .width = 100, .height = 50 }, findPlacement(placements, 3).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 50, .width = 100, .height = 50 }, findPlacement(placements, 4).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 200, .y = 50, .width = 100, .height = 50 }, findPlacement(placements, 5).geometry);
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 4 }, state.left.rows.order.items.items);
    try std.testing.expectEqualSlices(types.Handle, &.{ 3, 5 }, state.right.rows.order.items.items);
}

test "game mode sends all remainder windows to a surviving edge column" {
    var state: State = .{
        .rule_anchor = 1,
        .rule_options = .{
            .size = .{ .pixels = .{ .width = 100, .height = 100 } },
            .anchor = .left,
            .remainder = .rows,
            .gaps_inner = 0,
        },
    };
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 300, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 },
    }, 1, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(placements);

    try std.testing.expectEqual(types.Rect{ .x = 100, .y = 0, .width = 100, .height = 50 }, findPlacement(placements, 2).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 200, .y = 0, .width = 100, .height = 50 }, findPlacement(placements, 3).geometry);
    try std.testing.expectEqual(types.Rect{ .x = 100, .y = 50, .width = 200, .height = 50 }, findPlacement(placements, 4).geometry);
    try std.testing.expectEqual(@as(usize, 0), state.left.rows.order.items.items.len);
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 3, 4 }, state.right.rows.order.items.items);
}

fn findPlacement(placements: []const types.Placement, handle: types.Handle) types.Placement {
    for (placements) |placement| if (placement.handle == handle) return placement;
    unreachable;
}
