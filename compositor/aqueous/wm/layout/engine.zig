// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const config = @import("../config/layout.zig");
const dwindle = @import("dwindle.zig");
const floating = @import("floating.zig");
const game_mode = @import("game_mode.zig");
const grid = @import("grid.zig");
const monocle = @import("monocle.zig");
const rows = @import("rows.zig");
const scrolling = @import("scrolling.zig");
const tile = @import("tile.zig");
const types = @import("types.zig");

pub const State = struct {
    active_layout: config.LayoutId = .tile,
    tile: tile.State = .{},
    monocle: monocle.State = .{},
    grid: grid.State = .{},
    rows: rows.State = .{},
    dwindle: dwindle.State = .{},
    scrolling: scrolling.State = .{},
    floating: floating.State = .{},
    game_mode: game_mode.State = .{},

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.tile.deinit(allocator);
        state.monocle.deinit(allocator);
        state.grid.deinit(allocator);
        state.rows.deinit(allocator);
        state.dwindle.deinit(allocator);
        state.scrolling.deinit(allocator);
        state.floating.deinit(allocator);
        state.game_mode.deinit(allocator);
    }
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, snapshot: *const config.Snapshot, area: types.Rect, windows: []const types.Window, focused: ?types.Handle, game_options: game_mode.Options) ![]types.Placement {
    const id = snapshot.default;
    state.active_layout = id;
    const options = snapshot.layoutOptions(id);
    return switch (id) {
        .tile => tile.arrange(allocator, &state.tile, area, windows, options),
        .monocle => monocle.arrange(allocator, &state.monocle, area, windows, focused, options, .{
            .hide_others = snapshot.monocle_hide_others,
            .show_borders = snapshot.monocle_show_borders,
        }),
        .grid => grid.arrange(allocator, &state.grid, area, windows, options),
        .rows => rows.arrange(allocator, &state.rows, area, windows, options),
        .dwindle => dwindle.arrange(allocator, &state.dwindle, area, windows, options, .{
            .start_vertical = snapshot.dwindle_start_vertical,
            .split_ratio = snapshot.dwindle_split_ratio,
        }),
        .scrolling => scrolling.arrange(allocator, &state.scrolling, area, windows, focused, options, .{
            .column_width = snapshot.scrolling_column_fraction,
            .center_focused = snapshot.scrolling_center_focused,
            .follow_new_windows = snapshot.scrolling_follow_new,
            .snap_to_columns = snapshot.scrolling_snap,
            .allow_overscroll = snapshot.scrolling_overscroll,
        }),
        .floating => floating.arrange(allocator, &state.floating, area, windows, focused, options),
        .game_mode => game_mode.arrange(allocator, &state.game_mode, area, windows, focused, options, game_options),
    };
}

/// Swap two tiled windows in every initialized layout order. Keeping dormant
/// orders synchronized makes a pointer reorder survive layout switches.
pub fn swap(state: *State, a: types.Handle, b: types.Handle) bool {
    var changed = false;
    if (state.tile.order.swap(a, b)) changed = true;
    if (state.monocle.order.swap(a, b)) changed = true;
    if (state.grid.order.swap(a, b)) changed = true;
    if (state.rows.order.swap(a, b)) changed = true;
    if (state.dwindle.order.swap(a, b)) changed = true;
    if (scrolling.swap(&state.scrolling, a, b)) changed = true;
    if (game_mode.swap(&state.game_mode, a, b)) changed = true;
    return changed;
}

pub fn drop(allocator: std.mem.Allocator, state: *State, dragged: types.Handle, target: types.Handle, zone: types.DropZone) !bool {
    if (state.active_layout != .scrolling) return swap(state, dragged, target);
    if (!try scrolling.drop(&state.scrolling, allocator, dragged, target, zone)) return false;
    try projectScrollingOrder(allocator, state);
    return true;
}

pub fn consumeWindowIntoColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle) !bool {
    if (state.active_layout != .scrolling) return false;
    if (!try scrolling.consumeFromRight(&state.scrolling, allocator, focused)) return false;
    try projectScrollingOrder(allocator, state);
    return true;
}

pub fn expelWindowFromColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle) !bool {
    if (state.active_layout != .scrolling) return false;
    if (!try scrolling.expelToRight(&state.scrolling, allocator, focused)) return false;
    try projectScrollingOrder(allocator, state);
    return true;
}

pub fn moveScrolling(allocator: std.mem.Allocator, state: *State, focused: types.Handle, dx: i32, dy: i32) !bool {
    const changed = switch (state.active_layout) {
        .scrolling => if (dx != 0)
            try scrolling.moveToAdjacentColumn(&state.scrolling, allocator, focused, dx)
        else
            scrolling.moveWithinColumn(&state.scrolling, focused, dy),
        .game_mode => try game_mode.moveWindow(&state.game_mode, allocator, focused, dx, dy),
        else => return false,
    };
    if (!changed) return false;
    if (state.active_layout == .scrolling) try projectScrollingOrder(allocator, state);
    return true;
}

pub fn moveScrollingColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle, delta: i32) !bool {
    if (state.active_layout != .scrolling) return false;
    if (!scrolling.moveColumn(&state.scrolling, focused, delta)) return false;
    try projectScrollingOrder(allocator, state);
    return true;
}

fn projectScrollingOrder(allocator: std.mem.Allocator, state: *State) !void {
    const projection = try scrolling.flattened(allocator, &state.scrolling);
    defer allocator.free(projection);
    state.tile.order.reorder(projection);
    state.monocle.order.reorder(projection);
    state.grid.order.reorder(projection);
    state.rows.order.reorder(projection);
    state.dwindle.order.reorder(projection);
}

pub fn scrollViewport(state: *State, focused: types.Handle, dx: i32, dy: i32) bool {
    return switch (state.active_layout) {
        .scrolling => if (dx != 0)
            scrolling.scrollViewport(&state.scrolling, dx)
        else
            scrolling.scrollColumn(&state.scrolling, focused, dy),
        .game_mode => game_mode.scrollViewport(&state.game_mode, focused, dx, dy),
        else => false,
    };
}

pub fn canResizeScrolling(state: *const State, handle: types.Handle) bool {
    return switch (state.active_layout) {
        .scrolling => scrolling.containsHandle(&state.scrolling, handle),
        .game_mode => game_mode.canResizeScrolling(&state.game_mode, handle),
        else => false,
    };
}

pub fn isGameAnchor(state: *const State, handle: types.Handle) bool {
    return state.active_layout == .game_mode and game_mode.isAnchor(&state.game_mode, handle);
}

pub fn scrollingExpandedOwner(state: *const State, handle: types.Handle) ?types.Handle {
    return switch (state.active_layout) {
        .scrolling => if (scrolling.containsHandle(&state.scrolling, handle))
            scrolling.expandedOwner(&state.scrolling, handle)
        else
            null,
        .game_mode => game_mode.scrollingExpandedOwner(&state.game_mode, handle),
        else => null,
    };
}

pub fn scrollingColumnMembers(state: *const State, handle: types.Handle) ?[]const types.Handle {
    return switch (state.active_layout) {
        .scrolling => scrolling.columnMembers(&state.scrolling, handle),
        .game_mode => game_mode.scrollingColumnMembers(&state.game_mode, handle),
        else => null,
    };
}

pub fn resizeScrolling(
    allocator: std.mem.Allocator,
    state: *State,
    handle: types.Handle,
    width: i32,
    height: i32,
) !bool {
    return switch (state.active_layout) {
        .scrolling => scrolling.resize(&state.scrolling, allocator, handle, width, height),
        .game_mode => game_mode.resizeScrolling(&state.game_mode, allocator, handle, width, height),
        else => false,
    };
}

pub fn resetScrollingSize(state: *State, handle: types.Handle) bool {
    return switch (state.active_layout) {
        .scrolling => scrolling.resetSize(&state.scrolling, handle),
        .game_mode => game_mode.resetScrollingSize(&state.game_mode, handle),
        else => false,
    };
}

pub fn setFloatingGeometry(allocator: std.mem.Allocator, state: *State, handle: types.Handle, geometry: types.Rect) !void {
    try floating.setGeometry(&state.floating, allocator, handle, geometry);
}

pub fn floatingGeometry(state: *const State, handle: types.Handle) ?types.Rect {
    return floating.geometry(&state.floating, handle);
}

pub fn forgetWindow(state: *State, handle: types.Handle) void {
    floating.remove(&state.floating, handle);
}

test "dispatcher selects the configured engine" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var snapshot: config.Snapshot = .{};
    snapshot.default = .rows;
    snapshot.options[@intFromEnum(config.LayoutId.rows)].gaps_outer = 0;
    snapshot.options[@intFromEnum(config.LayoutId.rows)].gaps_inner = 0;
    const placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, null, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 40, .width = 100, .height = 40 }, placements[2].geometry);
}

test "pointer reorder swaps rows without changing window state" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var snapshot: config.Snapshot = .{};
    snapshot.default = .rows;
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const initial = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, null, .{});
    std.testing.allocator.free(initial);

    try std.testing.expect(swap(&state, 1, 2));
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 1 }, state.rows.order.items.items);
}

test "switching away from scrolling returns unclipped placements" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var snapshot: config.Snapshot = .{};
    snapshot.default = .scrolling;
    snapshot.options[@intFromEnum(config.LayoutId.scrolling)].gaps_outer = 0;
    snapshot.options[@intFromEnum(config.LayoutId.scrolling)].gaps_inner = 0;
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const scrolling_placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 1, .{});
    defer std.testing.allocator.free(scrolling_placements);
    try std.testing.expect(scrolling_placements[0].clip != null);

    snapshot.default = .tile;
    const tiled_placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &windows, 1, .{});
    defer std.testing.allocator.free(tiled_placements);
    try std.testing.expectEqual(@as(?types.Rect, null), tiled_placements[0].clip);
    try std.testing.expectEqual(@as(?types.Rect, null), tiled_placements[1].clip);
}

test "all managed layouts advertise tiled placements while floating does not" {
    inline for (.{
        config.LayoutId.tile,
        config.LayoutId.monocle,
        config.LayoutId.grid,
        config.LayoutId.rows,
        config.LayoutId.dwindle,
        config.LayoutId.scrolling,
        config.LayoutId.game_mode,
    }) |id| {
        var state: State = .{};
        defer state.deinit(std.testing.allocator);
        var snapshot: config.Snapshot = .{};
        snapshot.default = id;
        const placements = try arrange(
            std.testing.allocator,
            &state,
            &snapshot,
            .{ .x = 0, .y = 0, .width = 100, .height = 80 },
            &.{.{ .handle = 1 }},
            1,
            .{ .fallback = .dwindle },
        );
        defer std.testing.allocator.free(placements);
        try std.testing.expect(placements[0].tiled);
    }

    var floating_state: State = .{};
    defer floating_state.deinit(std.testing.allocator);
    var floating_snapshot: config.Snapshot = .{};
    floating_snapshot.default = .floating;
    const floating_placements = try arrange(
        std.testing.allocator,
        &floating_state,
        &floating_snapshot,
        .{ .x = 0, .y = 0, .width = 100, .height = 80 },
        &.{.{ .handle = 1 }},
        1,
        .{},
    );
    defer std.testing.allocator.free(floating_placements);
    try std.testing.expect(!floating_placements[0].tiled);
}

test "floating geometry survives temporary layout switches" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var snapshot: config.Snapshot = .{};
    const windows = [_]types.Window{.{ .handle = 1 }};
    const remembered: types.Rect = .{ .x = 17, .y = 29, .width = 420, .height = 260 };

    snapshot.default = .floating;
    try setFloatingGeometry(std.testing.allocator, &state, 1, remembered);
    var placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &windows, 1, .{});
    try std.testing.expectEqual(remembered, placements[0].geometry);
    std.testing.allocator.free(placements);

    snapshot.default = .tile;
    placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &windows, 1, .{});
    std.testing.allocator.free(placements);

    snapshot.default = .floating;
    placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &windows, 1, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(remembered, placements[0].geometry);
}
