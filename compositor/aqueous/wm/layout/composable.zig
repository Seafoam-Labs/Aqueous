// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! A fixed collection of independently stateful layout regions.

const std = @import("std");
const config = @import("../config/layout.zig");
const game_mode = @import("game_mode.zig");
const leaf = @import("leaf.zig");
const types = @import("types.zig");

pub const State = struct {
    children: [config.max_composable_regions]leaf.State = .{ .{}, .{}, .{}, .{} },
    membership: std.AutoHashMapUnmanaged(types.Handle, u8) = .empty,
    enabled: [config.max_composable_regions]bool = .{ false, false, false, false },
    layouts: [config.max_composable_regions]config.LayoutId = .{ .tile, .tile, .tile, .tile },
    active: u8 = 0,
    last_focused: [config.max_composable_regions]?types.Handle = .{ null, null, null, null },
    first_member: [config.max_composable_regions]?types.Handle = .{ null, null, null, null },

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        for (&state.children) |*child| child.deinit(allocator);
        state.membership.deinit(allocator);
    }
};

pub fn arrange(
    allocator: std.mem.Allocator,
    state: *State,
    snapshot: *const config.Snapshot,
    area: types.Rect,
    windows: []const types.Window,
    focused: ?types.Handle,
    game_options: game_mode.Options,
) ![]types.Placement {
    configure(state, snapshot);

    if (focused) |handle| {
        if (state.membership.get(handle)) |slot| {
            if (state.enabled[slot]) {
                state.active = slot;
                state.last_focused[slot] = handle;
            }
        }
    }
    if (!state.enabled[state.active]) state.active = firstEnabled(state);

    var child_windows = [_]std.ArrayListUnmanaged(types.Window){.empty} ** config.max_composable_regions;
    defer for (&child_windows) |*items| items.deinit(allocator);
    state.first_member = .{ null, null, null, null };

    for (windows) |window| {
        var slot = state.membership.get(window.handle) orelse state.active;
        if (!state.enabled[slot]) slot = state.active;
        try state.membership.put(allocator, window.handle, slot);
        try child_windows[slot].append(allocator, window);
        if (state.first_member[slot] == null) state.first_member[slot] = window.handle;
        if (focused != null and focused.? == window.handle) {
            state.active = slot;
            state.last_focused[slot] = window.handle;
        }
    }
    for (0..config.max_composable_regions) |index| {
        if (state.last_focused[index]) |handle| {
            if (focused != handle and !containsHandle(child_windows[index].items, handle)) {
                state.last_focused[index] = null;
            }
        }
    }

    const result = try allocator.alloc(types.Placement, windows.len);
    errdefer allocator.free(result);
    var write: usize = 0;
    for (0..config.max_composable_regions) |index| {
        if (!state.enabled[index]) continue;
        const child_area = resolvedArea(snapshot, area, index);
        const child_focus: ?types.Handle = if (focused) |handle|
            if (state.membership.get(handle) == @as(?u8, @intCast(index))) handle else null
        else
            null;
        const placements = try leaf.arrange(
            allocator,
            &state.children[index],
            state.layouts[index],
            snapshot,
            child_area,
            child_windows[index].items,
            child_focus,
            game_options,
        );
        defer allocator.free(placements);

        if (state.layouts[index] == .floating) {
            for (placements) |*placement| {
                placement.geometry = constrain(placement.geometry, child_area);
                try leaf.setFloatingGeometry(allocator, &state.children[index], placement.handle, placement.geometry);
            }
        }
        @memcpy(result[write .. write + placements.len], placements);
        write += placements.len;
    }
    std.debug.assert(write == result.len);
    return result;
}

fn configure(state: *State, snapshot: *const config.Snapshot) void {
    if (!snapshot.composableValid()) {
        state.enabled = .{ true, false, false, false };
        state.layouts = .{ .tile, .tile, .tile, .tile };
    } else {
        for (snapshot.composable, 0..) |region, index| {
            state.enabled[index] = region.configured();
            if (state.enabled[index]) state.layouts[index] = region.layout;
        }
    }
    if (!state.enabled[state.active]) state.active = firstEnabled(state);
}

fn firstEnabled(state: *const State) u8 {
    for (state.enabled, 0..) |enabled, index| if (enabled) return @intCast(index);
    unreachable;
}

fn resolvedArea(snapshot: *const config.Snapshot, area: types.Rect, index: usize) types.Rect {
    if (!snapshot.composableValid()) return area;
    const points = snapshot.composable[index].points;
    const left = resolveCoordinate(area.x, area.width, points[0].x);
    const top = resolveCoordinate(area.y, area.height, points[0].y);
    const right = resolveCoordinate(area.x, area.width, points[2].x);
    const bottom = resolveCoordinate(area.y, area.height, points[2].y);
    return .{
        .x = left,
        .y = top,
        .width = @max(1, right - left),
        .height = @max(1, bottom - top),
    };
}

fn resolveCoordinate(origin: i32, length: i32, fraction: f64) i32 {
    return origin + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(length)) * fraction)));
}

fn constrain(rect: types.Rect, area: types.Rect) types.Rect {
    const width = @min(@max(1, rect.width), area.width);
    const height = @min(@max(1, rect.height), area.height);
    return .{
        .x = std.math.clamp(rect.x, area.x, area.right() - width),
        .y = std.math.clamp(rect.y, area.y, area.bottom() - height),
        .width = width,
        .height = height,
    };
}

fn containsHandle(windows: []const types.Window, handle: types.Handle) bool {
    for (windows) |window| if (window.handle == handle) return true;
    return false;
}

fn childForHandle(state: *State, handle: types.Handle) ?*leaf.State {
    const slot = state.membership.get(handle) orelse return null;
    if (!state.enabled[slot]) return null;
    return &state.children[slot];
}

fn constChildForHandle(state: *const State, handle: types.Handle) ?*const leaf.State {
    const slot = state.membership.get(handle) orelse return null;
    if (!state.enabled[slot]) return null;
    return &state.children[slot];
}

pub fn layoutForHandle(state: *const State, handle: types.Handle) ?config.LayoutId {
    const slot = state.membership.get(handle) orelse return null;
    if (!state.enabled[slot]) return null;
    return state.layouts[slot];
}

pub fn swap(state: *State, a: types.Handle, b: types.Handle) bool {
    const a_slot = state.membership.get(a) orelse return false;
    const b_slot = state.membership.get(b) orelse return false;
    if (a_slot == b_slot) return leaf.swap(&state.children[a_slot], a, b);
    state.membership.getPtr(a).?.* = b_slot;
    state.membership.getPtr(b).?.* = a_slot;
    if (state.last_focused[a_slot] == a) state.last_focused[a_slot] = b;
    if (state.last_focused[b_slot] == b) state.last_focused[b_slot] = a;
    return true;
}

pub fn drop(allocator: std.mem.Allocator, state: *State, dragged: types.Handle, target: types.Handle, zone: types.DropZone) !bool {
    const dragged_slot = state.membership.get(dragged) orelse return false;
    const target_slot = state.membership.get(target) orelse return false;
    if (dragged_slot != target_slot) return swap(state, dragged, target);
    return leaf.drop(allocator, &state.children[dragged_slot], dragged, target, zone);
}

pub fn consumeWindowIntoColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle) !bool {
    const child = childForHandle(state, focused) orelse return false;
    return leaf.consumeWindowIntoColumn(allocator, child, focused);
}

pub fn expelWindowFromColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle) !bool {
    const child = childForHandle(state, focused) orelse return false;
    return leaf.expelWindowFromColumn(allocator, child, focused);
}

pub fn moveScrolling(allocator: std.mem.Allocator, state: *State, focused: types.Handle, dx: i32, dy: i32) !bool {
    const child = childForHandle(state, focused) orelse return false;
    return leaf.moveScrolling(allocator, child, focused, dx, dy);
}

pub fn moveScrollingColumn(allocator: std.mem.Allocator, state: *State, focused: types.Handle, delta: i32) !bool {
    const child = childForHandle(state, focused) orelse return false;
    return leaf.moveScrollingColumn(allocator, child, focused, delta);
}

pub fn scrollViewport(state: *State, focused: types.Handle, dx: i32, dy: i32) ?types.Handle {
    const child = childForHandle(state, focused) orelse return null;
    return leaf.scrollViewport(child, focused, dx, dy);
}

pub fn supportsViewportScroll(state: *const State, handle: types.Handle) bool {
    const child = constChildForHandle(state, handle) orelse return false;
    return leaf.supportsViewportScroll(child, handle);
}

pub fn canResizeScrolling(state: *const State, handle: types.Handle) bool {
    const child = constChildForHandle(state, handle) orelse return false;
    return leaf.canResizeScrolling(child, handle);
}

pub fn isGameAnchor(state: *const State, handle: types.Handle) bool {
    const child = constChildForHandle(state, handle) orelse return false;
    return leaf.isGameAnchor(child, handle);
}

pub fn scrollingExpandedOwner(state: *const State, handle: types.Handle) ?types.Handle {
    const child = constChildForHandle(state, handle) orelse return null;
    return leaf.scrollingExpandedOwner(child, handle);
}

pub fn scrollingColumnMembers(state: *const State, handle: types.Handle) ?[]const types.Handle {
    const child = constChildForHandle(state, handle) orelse return null;
    return leaf.scrollingColumnMembers(child, handle);
}

pub fn resizeScrolling(allocator: std.mem.Allocator, state: *State, handle: types.Handle, width: i32, height: i32) !bool {
    const child = childForHandle(state, handle) orelse return false;
    return leaf.resizeScrolling(allocator, child, handle, width, height);
}

pub fn resetScrollingSize(state: *State, handle: types.Handle) bool {
    const child = childForHandle(state, handle) orelse return false;
    return leaf.resetScrollingSize(child, handle);
}

pub fn setFloatingGeometry(allocator: std.mem.Allocator, state: *State, handle: types.Handle, geometry: types.Rect) !void {
    const child = childForHandle(state, handle) orelse return;
    try leaf.setFloatingGeometry(allocator, child, handle, geometry);
}

pub fn floatingGeometry(state: *const State, handle: types.Handle) ?types.Rect {
    const child = constChildForHandle(state, handle) orelse return null;
    return leaf.floatingGeometry(child, handle);
}

pub fn forgetWindow(state: *State, handle: types.Handle) void {
    _ = state.membership.remove(handle);
    for (&state.children) |*child| leaf.forgetWindow(child, handle);
    for (0..config.max_composable_regions) |index| {
        if (state.last_focused[index] == handle) state.last_focused[index] = null;
        if (state.first_member[index] == handle) state.first_member[index] = null;
    }
}

pub fn focusTarget(state: *const State, slot: u8) ?types.Handle {
    if (slot >= config.max_composable_regions or !state.enabled[slot]) return null;
    if (state.last_focused[slot]) |handle| {
        if (state.membership.get(handle) == @as(?u8, slot)) return handle;
    }
    if (state.first_member[slot]) |handle| {
        if (state.membership.get(handle) == @as(?u8, slot)) return handle;
    }
    return null;
}

pub fn moveToSlot(state: *State, handle: types.Handle, slot: u8) bool {
    if (slot >= config.max_composable_regions or !state.enabled[slot]) return false;
    const current = state.membership.getPtr(handle) orelse return false;
    if (current.* == slot) return false;
    const old = current.*;
    current.* = slot;
    leaf.forgetWindow(&state.children[old], handle);
    if (state.last_focused[old] == handle) state.last_focused[old] = null;
    if (state.first_member[old] == handle) state.first_member[old] = null;
    state.active = slot;
    state.last_focused[slot] = handle;
    return true;
}

pub fn activeLayout(state: *const State) config.LayoutId {
    return if (state.enabled[state.active]) state.layouts[state.active] else .tile;
}

pub fn prepareAdmission(state: *State, allocator: std.mem.Allocator) !bool {
    if (!state.enabled[state.active]) return false;
    try state.membership.ensureUnusedCapacity(allocator, 1);
    return true;
}

pub fn admitToActiveAssumeCapacity(state: *State, handle: types.Handle) void {
    std.debug.assert(state.enabled[state.active]);
    state.membership.putAssumeCapacity(handle, state.active);
    state.last_focused[state.active] = handle;
}

test "composable partitions windows and follows member focus" {
    var snapshot: config.Snapshot = .{};
    config.apply(&snapshot,
        \\[layout.composable.a]
        \\layout = "rows"
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
    snapshot.options[@intFromEnum(config.LayoutId.rows)].gaps_outer = 0;
    snapshot.options[@intFromEnum(config.LayoutId.tile)].gaps_outer = 0;
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    var placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 100, .y = 50, .width = 200, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 },
    }, 1, .{});
    std.testing.allocator.free(placements);
    try std.testing.expect(moveToSlot(&state, 2, 1));

    placements = try arrange(std.testing.allocator, &state, &snapshot, .{ .x = 100, .y = 50, .width = 200, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, 2, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(?u8, 0), state.membership.get(1));
    try std.testing.expectEqual(@as(?u8, 1), state.membership.get(2));
    try std.testing.expectEqual(@as(?u8, 1), state.membership.get(3));
    try std.testing.expectEqual(types.Rect{ .x = 100, .y = 50, .width = 100, .height = 100 }, findPlacement(placements, 1).geometry);
    try std.testing.expect(findPlacement(placements, 2).geometry.x >= 200);
    try std.testing.expect(findPlacement(placements, 3).geometry.x >= 200);
    try std.testing.expectEqual(@as(?types.Handle, 2), focusTarget(&state, 1));
    try std.testing.expectEqual(@as(?types.Handle, 1), focusTarget(&state, 0));
    try std.testing.expect(moveToSlot(&state, 1, 1));
    try std.testing.expectEqual(@as(?types.Handle, null), focusTarget(&state, 0));
}

test "floating children stay within their configured region" {
    var snapshot: config.Snapshot = .{};
    config.apply(&snapshot,
        \\[layout.composable.a]
        \\layout = "float"
        \\p1 = [0.25, 0.25]
        \\p2 = [0.75, 0.25]
        \\p3 = [0.75, 0.75]
        \\p4 = [0.25, 0.75]
    );
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    var placements = try arrange(
        std.testing.allocator,
        &state,
        &snapshot,
        .{ .x = 0, .y = 0, .width = 200, .height = 200 },
        &.{.{ .handle = 1 }},
        1,
        .{},
    );
    std.testing.allocator.free(placements);
    try setFloatingGeometry(
        std.testing.allocator,
        &state,
        1,
        .{ .x = -100, .y = -100, .width = 500, .height = 500 },
    );

    placements = try arrange(
        std.testing.allocator,
        &state,
        &snapshot,
        .{ .x = 0, .y = 0, .width = 200, .height = 200 },
        &.{.{ .handle = 1 }},
        1,
        .{},
    );
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(
        types.Rect{ .x = 50, .y = 50, .width = 100, .height = 100 },
        placements[0].geometry,
    );
    try std.testing.expectEqual(placements[0].geometry, floatingGeometry(&state, 1).?);
}

test "focus targets exclude members absent from the current workspace" {
    var snapshot: config.Snapshot = .{};
    config.apply(&snapshot,
        \\[layout.composable.a]
        \\layout = "tile"
        \\p1 = [0.0, 0.0]
        \\p2 = [1.0, 0.0]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.0, 1.0]
    );
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    var placements = try arrange(
        std.testing.allocator,
        &state,
        &snapshot,
        .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        &.{.{ .handle = 1 }},
        1,
        .{},
    );
    std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(?types.Handle, 1), focusTarget(&state, 0));

    placements = try arrange(
        std.testing.allocator,
        &state,
        &snapshot,
        .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        &.{},
        null,
        .{},
    );
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(?types.Handle, null), focusTarget(&state, 0));
}

fn findPlacement(placements: []const types.Placement, handle: types.Handle) types.Placement {
    for (placements) |placement| if (placement.handle == handle) return placement;
    unreachable;
}
