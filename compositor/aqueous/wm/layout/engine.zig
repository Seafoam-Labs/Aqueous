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
    if (state.scrolling.order.swap(a, b)) changed = true;
    if (game_mode.swap(&state.game_mode, a, b)) changed = true;
    return changed;
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
