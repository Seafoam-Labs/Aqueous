// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Reusable dispatcher for one non-composable layout instance.
//!
//! A workspace owns one of these for ordinary layouts. The composable layout
//! owns one per configured region so ordering, viewport, and floating geometry
//! never leak between regions.

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
    reverse_dwindle: dwindle.State = .{},
    scrolling: scrolling.State = .{},
    floating: floating.State = .{},
    game_mode: game_mode.State = .{},

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.tile.deinit(allocator);
        state.monocle.deinit(allocator);
        state.grid.deinit(allocator);
        state.rows.deinit(allocator);
        state.dwindle.deinit(allocator);
        state.reverse_dwindle.deinit(allocator);
        state.scrolling.deinit(allocator);
        state.floating.deinit(allocator);
        state.game_mode.deinit(allocator);
    }
};

pub fn arrange(
    allocator: std.mem.Allocator,
    state: *State,
    id: config.LayoutId,
    snapshot: *const config.Snapshot,
    area: types.Rect,
    windows: []const types.Window,
    focused: ?types.Handle,
    game_options: game_mode.Options,
) ![]types.Placement {
    std.debug.assert(id != .composable);
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
        .reverse_dwindle => dwindle.arrange(allocator, &state.reverse_dwindle, area, windows, options, .{
            .start_vertical = snapshot.reverse_dwindle_start_vertical,
            .split_ratio = snapshot.reverse_dwindle_split_ratio,
            .reverse = true,
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
        .composable => unreachable,
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
    if (state.reverse_dwindle.order.swap(a, b)) changed = true;
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
    state.reverse_dwindle.order.reorder(projection);
}

pub fn scrollViewport(state: *State, focused: types.Handle, dx: i32, dy: i32) ?types.Handle {
    return switch (state.active_layout) {
        .scrolling => blk: {
            const changed = if (dx != 0)
                scrolling.scrollViewport(&state.scrolling, dx)
            else
                scrolling.scrollColumn(&state.scrolling, focused, dy);
            break :blk if (changed) scrolling.viewportFocusTarget(&state.scrolling) else null;
        },
        .game_mode => if (game_mode.scrollViewport(&state.game_mode, focused, dx, dy))
            game_mode.viewportFocusTarget(&state.game_mode, focused)
        else
            null,
        else => null,
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
