// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const composable = @import("composable.zig");
const config = @import("../config/layout.zig");
const game_mode = @import("game_mode.zig");
const leaf = @import("leaf.zig");
const types = @import("types.zig");

pub const State = struct {
    active_layout: config.LayoutId = .tile,
    standalone: leaf.State = .{},
    composite: composable.State = .{},

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.standalone.deinit(allocator);
        state.composite.deinit(allocator);
    }
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, snapshot: *const config.Snapshot, area: types.Rect, windows: []const types.Window, focused: ?types.Handle, game_options: game_mode.Options) ![]types.Placement {
    const id = snapshot.default;
    state.active_layout = id;
    return if (id == .composable)
        composable.arrange(allocator, &state.composite, snapshot, area, windows, focused, game_options)
    else
        leaf.arrange(allocator, &state.standalone, id, snapshot, area, windows, focused, game_options);
}

/// Swap two tiled windows in every initialized layout order. Keeping dormant
/// orders synchronized makes a pointer reorder survive layout switches.
pub fn swap(state: *State, a: types.Handle, b: types.Handle) bool {
    return if (state.active_layout == .composable)
        composable.swap(&state.composite, a, b)
    else
        leaf.swap(&state.standalone, a, b);
}

pub fn drop(allocator: std.mem.Allocator, state: *State, dragged: types.Handle, target: types.Handle, zone: types.DropZone) !bool {
    return if (state.active_layout == .composable)
        composable.drop(allocator, &state.composite, dragged, target, zone)
    else
        leaf.drop(allocator, &state.standalone, dragged, target, zone);
}

pub fn consumeWindowIntoColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle) !bool {
    return if (state.active_layout == .composable)
        composable.consumeWindowIntoColumn(allocator, &state.composite, focused)
    else
        leaf.consumeWindowIntoColumn(allocator, &state.standalone, focused);
}

pub fn expelWindowFromColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle) !bool {
    return if (state.active_layout == .composable)
        composable.expelWindowFromColumn(allocator, &state.composite, focused)
    else
        leaf.expelWindowFromColumn(allocator, &state.standalone, focused);
}

pub fn moveScrolling(allocator: std.mem.Allocator, state: *State, focused: types.Handle, dx: i32, dy: i32) !bool {
    return if (state.active_layout == .composable)
        composable.moveScrolling(allocator, &state.composite, focused, dx, dy)
    else
        leaf.moveScrolling(allocator, &state.standalone, focused, dx, dy);
}

pub fn moveScrollingColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle, delta: i32) !bool {
    return if (state.active_layout == .composable)
        composable.moveScrollingColumn(allocator, &state.composite, focused, delta)
    else
        leaf.moveScrollingColumn(allocator, &state.standalone, focused, delta);
}

pub fn scrollViewport(state: *State, focused: types.Handle, dx: i32, dy: i32) ?types.Handle {
    return if (state.active_layout == .composable)
        composable.scrollViewport(&state.composite, focused, dx, dy)
    else
        leaf.scrollViewport(&state.standalone, focused, dx, dy);
}

pub fn supportsViewportScroll(state: *const State, handle: types.Handle) bool {
    return if (state.active_layout == .composable)
        composable.supportsViewportScroll(&state.composite, handle)
    else
        leaf.supportsViewportScroll(&state.standalone, handle);
}

pub fn prefersVerticalScroll(state: *const State, handle: types.Handle) bool {
    return if (state.active_layout == .composable)
        composable.prefersVerticalScroll(&state.composite, handle)
    else
        leaf.prefersVerticalScroll(&state.standalone, handle);
}

pub fn canResizeScrolling(state: *const State, handle: types.Handle) bool {
    return if (state.active_layout == .composable)
        composable.canResizeScrolling(&state.composite, handle)
    else
        leaf.canResizeScrolling(&state.standalone, handle);
}

pub fn isGameAnchor(state: *const State, handle: types.Handle) bool {
    return if (state.active_layout == .composable)
        composable.isGameAnchor(&state.composite, handle)
    else
        leaf.isGameAnchor(&state.standalone, handle);
}

pub fn scrollingExpandedOwner(state: *const State, handle: types.Handle) ?types.Handle {
    return if (state.active_layout == .composable)
        composable.scrollingExpandedOwner(&state.composite, handle)
    else
        leaf.scrollingExpandedOwner(&state.standalone, handle);
}

pub fn scrollingColumnMembers(state: *const State, handle: types.Handle) ?[]const types.Handle {
    return if (state.active_layout == .composable)
        composable.scrollingColumnMembers(&state.composite, handle)
    else
        leaf.scrollingColumnMembers(&state.standalone, handle);
}

pub fn resizeScrolling(
    allocator: std.mem.Allocator,
    state: *State,
    handle: types.Handle,
    update: types.ResizeUpdate,
) !bool {
    return if (state.active_layout == .composable)
        composable.resizeScrolling(allocator, &state.composite, handle, update)
    else
        leaf.resizeScrolling(allocator, &state.standalone, handle, update);
}

pub fn resetScrollingSize(state: *State, handle: types.Handle) bool {
    return if (state.active_layout == .composable)
        composable.resetScrollingSize(&state.composite, handle)
    else
        leaf.resetScrollingSize(&state.standalone, handle);
}

pub fn setFloatingGeometry(allocator: std.mem.Allocator, state: *State, handle: types.Handle, geometry: types.Rect) !void {
    if (state.active_layout == .composable) {
        try composable.setFloatingGeometry(allocator, &state.composite, handle, geometry);
    } else {
        try leaf.setFloatingGeometry(allocator, &state.standalone, handle, geometry);
    }
}

pub fn floatingGeometry(state: *const State, handle: types.Handle) ?types.Rect {
    return if (state.active_layout == .composable)
        composable.floatingGeometry(&state.composite, handle)
    else
        leaf.floatingGeometry(&state.standalone, handle);
}

pub fn forgetWindow(state: *State, handle: types.Handle) void {
    leaf.forgetWindow(&state.standalone, handle);
    composable.forgetWindow(&state.composite, handle);
}

pub fn layoutForHandle(state: *const State, handle: types.Handle) config.LayoutId {
    if (state.active_layout != .composable) return state.active_layout;
    return composable.layoutForHandle(&state.composite, handle) orelse .composable;
}

pub fn usesFloatingLayout(state: *const State, handle: types.Handle) bool {
    return layoutForHandle(state, handle) == .floating;
}

pub fn usesSpecialMove(state: *const State, handle: types.Handle) bool {
    return switch (layoutForHandle(state, handle)) {
        .scrolling, .game_mode => true,
        else => false,
    };
}

pub fn focusComposableSlot(state: *const State, slot: u8) ?types.Handle {
    if (state.active_layout != .composable) return null;
    return composable.focusTarget(&state.composite, slot);
}

pub fn moveToComposableSlot(state: *State, handle: types.Handle, slot: u8) bool {
    if (state.active_layout != .composable) return false;
    return composable.moveToSlot(&state.composite, handle, slot);
}

pub fn acceptsFloatingTransfer(state: *const State) bool {
    return if (state.active_layout == .composable)
        composable.activeLayout(&state.composite) == .floating
    else
        state.active_layout == .floating;
}

pub fn prepareFloatingTransfer(state: *State, allocator: std.mem.Allocator) !bool {
    if (!acceptsFloatingTransfer(state)) return false;
    if (state.active_layout == .composable) return composable.prepareAdmission(&state.composite, allocator);
    return true;
}

pub fn commitFloatingTransfer(state: *State, handle: types.Handle) void {
    if (state.active_layout == .composable) composable.admitToActiveAssumeCapacity(&state.composite, handle);
}

pub fn gameModeState(state: *State) *game_mode.State {
    return &state.standalone.game_mode;
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
    try std.testing.expectEqualSlices(types.Handle, &.{ 2, 1 }, state.standalone.rows.order.items.items);
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
        config.LayoutId.reverse_dwindle,
        config.LayoutId.scrolling,
        config.LayoutId.game_mode,
        config.LayoutId.composable,
    }) |id| {
        var state: State = .{};
        defer state.deinit(std.testing.allocator);
        var snapshot: config.Snapshot = .{};
        snapshot.default = id;
        if (id == .composable) config.apply(&snapshot,
            \\[layout.composable.a]
            \\layout = "tile"
            \\p1 = [0.0, 0.0]
            \\p2 = [1.0, 0.0]
            \\p3 = [1.0, 1.0]
            \\p4 = [0.0, 1.0]
        );
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

test "viewport scroll support follows the active standalone layout" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var snapshot: config.Snapshot = .{};
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };

    snapshot.default = .scrolling;
    var placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(supportsViewportScroll(&state, 1));
    try std.testing.expect(!supportsViewportScroll(&state, 99));

    snapshot.default = .tile;
    placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(!supportsViewportScroll(&state, 1));

    snapshot.default = .floating;
    placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(!supportsViewportScroll(&state, 1));
}

test "tile members resize through the engine like scrolling members" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var snapshot: config.Snapshot = .{};
    snapshot.default = .tile;
    snapshot.options[@intFromEnum(config.LayoutId.tile)].gaps_outer = 0;
    snapshot.options[@intFromEnum(config.LayoutId.tile)].gaps_inner = 4;
    snapshot.options[@intFromEnum(config.LayoutId.tile)].master_ratio = 0.5;
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };

    var placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(canResizeScrolling(&state, 1));
    try std.testing.expect(!canResizeScrolling(&state, 99));
    try std.testing.expect(try resizeScrolling(std.testing.allocator, &state, 1, .{ .width = 70 }));

    placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 70, .height = 80 }, placements[0].geometry);
    std.testing.allocator.free(placements);

    try std.testing.expect(try resizeScrolling(std.testing.allocator, &state, 1, .{ .height = 60 }));
    placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 70, .height = 60 }, placements[0].geometry);
    std.testing.allocator.free(placements);

    try std.testing.expect(resetScrollingSize(&state, 1));
    placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 50, .height = 80 }, placements[0].geometry);
}

test "viewport scroll support routes through game mode and rejects its anchor" {
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 300, .height = 100 };
    var snapshot: config.Snapshot = .{};
    snapshot.default = .game_mode;

    var fallback_state: State = .{};
    defer fallback_state.deinit(std.testing.allocator);
    const fallback = try arrange(
        std.testing.allocator,
        &fallback_state,
        &snapshot,
        area,
        &windows,
        1,
        .{ .fallback = .scrolling },
    );
    std.testing.allocator.free(fallback);
    try std.testing.expect(supportsViewportScroll(&fallback_state, 1));

    var anchored_state: State = .{};
    defer anchored_state.deinit(std.testing.allocator);
    const game_state = gameModeState(&anchored_state);
    game_state.rule_anchor = 1;
    game_state.rule_options = .{
        .size = .{ .pixels = .{ .width = 100, .height = 100 } },
        .remainder = .scrolling,
        .gaps_inner = 0,
    };
    const anchored = try arrange(
        std.testing.allocator,
        &anchored_state,
        &snapshot,
        area,
        &windows,
        2,
        .{},
    );
    std.testing.allocator.free(anchored);
    try std.testing.expect(!supportsViewportScroll(&anchored_state, 1));
    try std.testing.expect(supportsViewportScroll(&anchored_state, 2));
}

test "viewport scroll support routes to the focused composable child" {
    var snapshot: config.Snapshot = .{};
    snapshot.default = .composable;
    config.apply(&snapshot,
        \\[layout.composable.a]
        \\layout = "scrolling"
        \\p1 = [0.0, 0.0]
        \\p2 = [0.5, 0.0]
        \\p3 = [0.5, 1.0]
        \\p4 = [0.0, 1.0]
        \\[layout.composable.b]
        \\layout = "tile"
        \\p1 = [0.5, 0.0]
        \\p2 = [1.0, 0.0]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.5, 1.0]
    );
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };

    var placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(moveToComposableSlot(&state, 2, 1));
    placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 2, .{});
    std.testing.allocator.free(placements);

    try std.testing.expect(supportsViewportScroll(&state, 1));
    try std.testing.expect(!supportsViewportScroll(&state, 2));
}

test "vertical scroll preference follows the active standalone arrangement" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var snapshot: config.Snapshot = .{};
    snapshot.default = .scrolling;
    snapshot.scrolling_prefer_vertical_on_portrait = true;
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const portrait: types.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 120 };
    const landscape: types.Rect = .{ .x = 0, .y = 0, .width = 120, .height = 80 };

    var placements = try arrange(std.testing.allocator, &state, &snapshot, portrait, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(prefersVerticalScroll(&state, 1));
    try std.testing.expect(!prefersVerticalScroll(&state, 99));

    placements = try arrange(std.testing.allocator, &state, &snapshot, landscape, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(!prefersVerticalScroll(&state, 1));
}

test "vertical scroll preference routes through game mode and rejects its anchor" {
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } };
    var snapshot: config.Snapshot = .{};
    snapshot.default = .game_mode;

    var fallback_state: State = .{};
    defer fallback_state.deinit(std.testing.allocator);
    const portrait_area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 300 };
    const fallback = try arrange(
        std.testing.allocator,
        &fallback_state,
        &snapshot,
        portrait_area,
        &windows,
        1,
        .{ .fallback = .scrolling, .scrolling_options = .{ .prefer_vertical_on_portrait = true } },
    );
    std.testing.allocator.free(fallback);
    try std.testing.expect(prefersVerticalScroll(&fallback_state, 2));

    const landscape_area: types.Rect = .{ .x = 0, .y = 0, .width = 300, .height = 100 };
    const landscape = try arrange(
        std.testing.allocator,
        &fallback_state,
        &snapshot,
        landscape_area,
        &windows,
        1,
        .{ .fallback = .scrolling, .scrolling_options = .{ .prefer_vertical_on_portrait = true } },
    );
    std.testing.allocator.free(landscape);
    try std.testing.expect(!prefersVerticalScroll(&fallback_state, 2));

    var anchored_state: State = .{};
    defer anchored_state.deinit(std.testing.allocator);
    const game_state = gameModeState(&anchored_state);
    game_state.rule_anchor = 1;
    game_state.rule_options = .{
        .size = .{ .pixels = .{ .width = 100, .height = 100 } },
        .remainder = .scrolling,
        .gaps_inner = 0,
    };
    // A portrait anchor area whose side remainders are themselves portrait,
    // so only the anchor guard can reject the anchor handle.
    const anchored_area: types.Rect = .{ .x = 0, .y = 0, .width = 300, .height = 400 };
    const anchored = try arrange(
        std.testing.allocator,
        &anchored_state,
        &snapshot,
        anchored_area,
        &windows,
        2,
        .{ .scrolling_options = .{ .prefer_vertical_on_portrait = true } },
    );
    std.testing.allocator.free(anchored);
    try std.testing.expect(!prefersVerticalScroll(&anchored_state, 1));
    try std.testing.expect(prefersVerticalScroll(&anchored_state, 2));
}

test "vertical scroll preference routes to the focused composable child" {
    var snapshot: config.Snapshot = .{};
    snapshot.default = .composable;
    snapshot.scrolling_prefer_vertical_on_portrait = true;
    config.apply(&snapshot,
        \\[layout.composable.a]
        \\layout = "scrolling"
        \\p1 = [0.0, 0.0]
        \\p2 = [0.25, 0.0]
        \\p3 = [0.25, 1.0]
        \\p4 = [0.0, 1.0]
        \\[layout.composable.b]
        \\layout = "scrolling"
        \\p1 = [0.25, 0.0]
        \\p2 = [1.0, 0.0]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.25, 1.0]
    );
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const windows = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 } };
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };

    var placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(moveToComposableSlot(&state, 2, 1));
    placements = try arrange(std.testing.allocator, &state, &snapshot, area, &windows, 2, .{});
    std.testing.allocator.free(placements);

    // Region a is 50x100 (portrait) while region b is 150x100 (landscape).
    try std.testing.expect(prefersVerticalScroll(&state, 1));
    try std.testing.expect(!prefersVerticalScroll(&state, 2));
}
