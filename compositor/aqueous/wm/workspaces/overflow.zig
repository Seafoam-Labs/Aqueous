// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! A bounded, compositor-independent overflow transaction. Workspaces own
//! cloned layout states; only accepted admissions affect the eventual commit.
const std = @import("std");
const types = @import("../layout/types.zig");
const config = @import("../config/layout.zig");
const engine = @import("../layout/engine.zig");
const clone = @import("../layout/clone.zig");
const game = @import("../layout/game_mode.zig");

pub const LayoutRule = struct {
    handle: types.Handle,
    layout: config.LayoutId,
    game_options: ?game.Options = null,
};

pub const Workspace = struct {
    layout: config.Snapshot,
    state: engine.State = .{},
    windows: std.ArrayListUnmanaged(types.Window) = .empty,
    game_options: game.Options = .{},
    focused: ?types.Handle = null,
    blocked: bool = false,
    changed: bool = false,
    force_scrolling: bool = false,
    layout_locked: bool = false,
    /// In the same snapshot order used by normal policy rule resolution.
    layout_rules: []const LayoutRule = &.{},

    pub fn deinit(workspace: *Workspace, a: std.mem.Allocator) void {
        workspace.state.deinit(a);
        workspace.windows.deinit(a);
    }

    fn arrange(workspace: *Workspace, a: std.mem.Allocator, area: types.Rect) ![]types.Placement {
        return engine.arrange(a, &workspace.state, &workspace.layout, area, workspace.windows.items, workspace.focused, workspace.game_options);
    }
};

pub const Move = struct { handle: types.Handle, destination: u32 };

/// Source and destination numbers are one-based. Search forward once, then
/// turn the final workspace (normally 9) into an unbounded scrolling sink.
pub fn plan(a: std.mem.Allocator, area: types.Rect, workspaces: []Workspace, source_number: u32) ![]Move {
    var moves: std.ArrayListUnmanaged(Move) = .empty;
    errdefer moves.deinit(a);
    if (source_number == 0 or source_number > workspaces.len) return moves.toOwnedSlice(a);
    const source_index: usize = source_number - 1;
    const source = &workspaces[source_index];
    const placements = try source.arrange(a, area);
    defer a.free(placements);
    for (placements) |placement| {
        if (!placement.overflow) continue;
        const window_index = for (source.windows.items, 0..) |window, index| {
            if (window.handle == placement.handle) break index;
        } else continue;
        const window = source.windows.items[window_index];
        var destination: ?usize = null;
        for (1..workspaces.len) |offset| {
            const index = (source_index + offset) % workspaces.len;
            if (try admit(a, area, &workspaces[index], window)) {
                destination = index;
                break;
            }
        }
        if (destination == null) {
            const last = workspaces.len - 1;
            const sink = &workspaces[last];
            if (!sink.force_scrolling) {
                // Preserve the old layout's resident order, including a
                // previously reordered dwindle tree or tiled stack.
                std.sort.insertion(types.Window, sink.windows.items, &sink.state, orderLessThan);
                sink.state.standalone.scrolling.deinit(a);
                sink.state.standalone.scrolling = .{};
                sink.state.standalone.game_mode.rule_layout_owned = false;
                sink.layout.default = .scrolling;
                sink.layout.scrolling_open_new_windows_to_right = false;
                sink.force_scrolling = true;
                sink.layout_locked = true;
                sink.changed = true;
            }
            if (last == source_index) break;
            try sink.windows.append(a, window);
            a.free(try sink.arrange(a, area));
            destination = last;
        }
        try moves.append(a, .{ .handle = window.handle, .destination = @intCast(destination.? + 1) });
        _ = source.windows.orderedRemove(window_index);
        source.changed = true;
    }
    // Remove transferred handles from dormant orders/trees before publishing.
    if (source.changed) a.free(try source.arrange(a, area));
    return moves.toOwnedSlice(a);
}

fn orderLessThan(state: *const engine.State, left: types.Window, right: types.Window) bool {
    return (engine.orderIndex(state, left.handle) orelse std.math.maxInt(u32)) <
        (engine.orderIndex(state, right.handle) orelse std.math.maxInt(u32));
}

fn admit(a: std.mem.Allocator, area: types.Rect, destination: *Workspace, window: types.Window) !bool {
    if (destination.blocked) return false;
    var trial = try clone.layout(a, &destination.state);
    defer trial.deinit(a);
    try destination.windows.append(a, window);
    var accepted = false;
    defer {
        if (!accepted) _ = destination.windows.pop();
    }
    var trial_layout = destination.layout;
    if (!destination.layout_locked) {
        for (destination.layout_rules) |rule| {
            const resident = for (destination.windows.items) |item| {
                if (item.handle == rule.handle) break true;
            } else false;
            if (!resident) continue;
            trial_layout.default = rule.layout;
            if (rule.game_options) |options| {
                trial.standalone.game_mode.rule_layout_owned = true;
                trial.standalone.game_mode.rule_anchor = rule.handle;
                trial.standalone.game_mode.rule_options = options;
            }
        }
        if (trial.standalone.game_mode.rule_layout_owned) trial_layout.default = .game_mode;
    }
    const placements = try engine.arrange(a, &trial, &trial_layout, area, destination.windows.items, destination.focused, destination.game_options);
    defer a.free(placements);
    for (placements) |placement| {
        if (placement.overflow) return false;
        // These layouts intentionally use a viewport, overlap, or one visible
        // window. Their capacity is not a count of disjoint on-screen tiles.
        switch (trial_layout.default) {
            .scrolling, .floating, .monocle => continue,
            else => {},
        }
        if (!placement.visible or placement.tiling != .tiled) continue;
        // An impossible minimum on a small monitor gets one bounded window,
        // never a transfer loop searching for an impossible larger display.
        if (destination.windows.items.len == 1) continue;
        const resident = for (destination.windows.items) |item| {
            if (item.handle == placement.handle) break item;
        } else unreachable;
        const minimum = types.readableMinimum(area);
        if (placement.geometry.width < @max(minimum.width, resident.min_width) or
            placement.geometry.height < @max(minimum.height, resident.min_height)) return false;
        if (placement.clip == null) {
            const rect = placement.geometry;
            const border: i64 = @max(0, placement.border.width);
            if (@as(i64, rect.x) - border < area.x or @as(i64, rect.y) - border < area.y or
                @as(i64, rect.x) + rect.width + border > @as(i64, area.x) + area.width or
                @as(i64, rect.y) + rect.height + border > @as(i64, area.y) + area.height) return false;
        }
    }
    std.mem.swap(engine.State, &destination.state, &trial);
    destination.layout = trial_layout;
    destination.changed = true;
    accepted = true;
    return true;
}

const test_area: types.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

fn testWorkspace() Workspace {
    var result: Workspace = .{ .layout = .{ .default = .dwindle } };
    for (&result.layout.options) |*options| options.readable_minimum = types.readableMinimum(test_area);
    return result;
}

fn addWindows(a: std.mem.Allocator, workspace: *Workspace, first: u64, count: usize) !void {
    for (0..count) |index| try workspace.windows.append(a, .{ .handle = first + index });
}

fn expectReadable(a: std.mem.Allocator, workspace: *Workspace) !void {
    const placements = try workspace.arrange(a, test_area);
    defer a.free(placements);
    const minimum = types.readableMinimum(test_area);
    for (placements) |placement| {
        try std.testing.expect(!placement.overflow);
        if (workspace.layout.default == .scrolling) continue;
        try std.testing.expect(placement.geometry.width >= minimum.width);
        try std.testing.expect(placement.geometry.height >= minimum.height);
        try std.testing.expect(placement.geometry.x >= 0 and placement.geometry.y >= 0);
        try std.testing.expect(placement.geometry.right() <= test_area.width);
        try std.testing.expect(placement.geometry.bottom() <= test_area.height);
    }
}

test "readability formula uses logical work area and rounds up" {
    try std.testing.expectEqual(types.Size{ .width = 384, .height = 270 }, types.readableMinimum(test_area));
    try std.testing.expectEqual(types.Size{ .width = 512, .height = 360 }, types.readableMinimum(.{ .x = 0, .y = 0, .width = 2560, .height = 1440 }));
    try std.testing.expectEqual(types.Size{ .width = 385, .height = 271 }, types.readableMinimum(.{ .x = -1920, .y = 0, .width = 1921, .height = 1081 }));
    try std.testing.expectEqual(types.Size{ .width = 320, .height = 200 }, types.readableMinimum(.{ .x = 0, .y = 0, .width = 800, .height = 600 }));
}

test "19 and 26 window transitions distribute readable dwindle tiles" {
    const a = std.testing.allocator;
    for ([_]config.LayoutId{ .floating, .scrolling }) |origin| {
        for ([_]config.LayoutId{ .dwindle, .reverse_dwindle }) |target| {
            for ([_]bool{ false, true }) |split_focused| {
                for ([_]usize{ 19, 26 }) |count| {
                    var workspaces: [9]Workspace = @splat(testWorkspace());
                    defer for (&workspaces) |*workspace| workspace.deinit(a);
                    try addWindows(a, &workspaces[0], 1, count);
                    workspaces[0].layout.default = origin;
                    a.free(try workspaces[0].arrange(a, test_area));
                    workspaces[0].layout.default = target;
                    workspaces[0].layout.dwindle_split_focused = split_focused;
                    workspaces[0].layout.reverse_dwindle_split_focused = split_focused;
                    const moves = try plan(a, test_area, &workspaces, 1);
                    defer a.free(moves);
                    try std.testing.expect(moves.len > 0);
                    var total: usize = 0;
                    for (&workspaces) |*workspace| {
                        total += workspace.windows.items.len;
                        try expectReadable(a, workspace);
                    }
                    try std.testing.expectEqual(count, total);
                    // A settled second transaction must not shuttle windows.
                    const repeated = try plan(a, test_area, &workspaces, 1);
                    defer a.free(repeated);
                    try std.testing.expectEqual(@as(usize, 0), repeated.len);
                }
            }
        }
    }
}

test "admission fills partial workspaces skips full ones and wraps once" {
    const a = std.testing.allocator;
    var workspaces: [9]Workspace = @splat(testWorkspace());
    defer for (&workspaces) |*workspace| workspace.deinit(a);
    try addWindows(a, &workspaces[0], 100, 4);
    try addWindows(a, &workspaces[1], 200, 3);
    try addWindows(a, &workspaces[8], 1, 7);
    const moves = try plan(a, test_area, &workspaces, 9);
    defer a.free(moves);
    try std.testing.expectEqual(@as(usize, 3), moves.len);
    try std.testing.expectEqual(@as(u32, 2), moves[0].destination);
    try std.testing.expectEqual(@as(u32, 3), moves[1].destination);
    try std.testing.expectEqual(@as(u32, 3), moves[2].destination);
    try std.testing.expectEqual(@as(usize, 4), workspaces[1].windows.items.len);
    try std.testing.expectEqual(@as(u64, 200), workspaces[1].windows.items[0].handle);
}

test "all full converts workspace nine to scrolling including source nine" {
    const a = std.testing.allocator;
    for ([_]usize{ 0, 8 }) |source| {
        var workspaces: [9]Workspace = @splat(testWorkspace());
        defer for (&workspaces) |*workspace| workspace.deinit(a);
        for (&workspaces, 0..) |*workspace, index| try addWindows(a, workspace, index * 100 + 1, 4);
        try addWindows(a, &workspaces[source], 1000, 22);
        const moves = try plan(a, test_area, &workspaces, @intCast(source + 1));
        defer a.free(moves);
        try std.testing.expect(workspaces[8].force_scrolling);
        try std.testing.expectEqual(config.LayoutId.scrolling, workspaces[8].layout.default);
        try std.testing.expectEqual(@as(usize, 26), workspaces[8].windows.items.len);
        for (moves) |move| try std.testing.expectEqual(@as(u32, 9), move.destination);
        try expectReadable(a, &workspaces[8]);
        for (0..4) |index| try std.testing.expectEqual(@as(u64, 801 + index), workspaces[8].windows.items[index].handle);
    }
}

test "focused admission probes do not mutate the live split tree" {
    const a = std.testing.allocator;
    var original = testWorkspace();
    defer original.deinit(a);
    original.layout.dwindle_split_focused = true;
    try addWindows(a, &original, 1, 4);
    const before = try original.arrange(a, test_area);
    defer a.free(before);
    var candidate = testWorkspace();
    defer candidate.deinit(a);
    candidate.layout = original.layout;
    candidate.state = try clone.layout(a, &original.state);
    try candidate.windows.appendSlice(a, original.windows.items);
    candidate.focused = 4;
    _ = try admit(a, test_area, &candidate, .{ .handle = 9, .min_width = 1500, .min_height = 1000 });
    const after = try original.arrange(a, test_area);
    defer a.free(after);
    try std.testing.expectEqualDeep(before, after);
}

test "incoming layout rules are included in destination capacity" {
    const a = std.testing.allocator;
    var destination = testWorkspace();
    defer destination.deinit(a);
    destination.layout.default = .floating;
    try addWindows(a, &destination, 1, 4);
    const rules = [_]LayoutRule{.{ .handle = 99, .layout = .dwindle }};
    destination.layout_rules = &rules;
    try std.testing.expect(!try admit(a, test_area, &destination, .{ .handle = 99 }));
    try std.testing.expectEqual(config.LayoutId.floating, destination.layout.default);
    try std.testing.expectEqual(@as(usize, 4), destination.windows.items.len);
    destination.layout.default = .scrolling;
    destination.layout_locked = true;
    try std.testing.expect(try admit(a, test_area, &destination, .{ .handle = 99 }));
    try std.testing.expectEqual(config.LayoutId.scrolling, destination.layout.default);
}

test "small displays and impossible client minima terminate without lost windows" {
    const a = std.testing.allocator;
    const area: types.Rect = .{ .x = -200, .y = 30, .width = 200, .height = 120 };
    var workspaces: [9]Workspace = @splat(testWorkspace());
    defer for (&workspaces) |*workspace| workspace.deinit(a);
    try addWindows(a, &workspaces[0], 1, 3);
    for (workspaces[0].windows.items) |*window| {
        window.min_width = 1000;
        window.min_height = 800;
    }
    const moves = try plan(a, area, &workspaces, 1);
    defer a.free(moves);
    try std.testing.expectEqual(@as(usize, 2), moves.len);
    for (workspaces[0..3]) |*workspace| {
        const placements = try workspace.arrange(a, area);
        defer a.free(placements);
        try std.testing.expectEqual(@as(usize, 1), placements.len);
        try std.testing.expect(!placements[0].overflow);
        try std.testing.expect(placements[0].geometry.x >= area.x);
        try std.testing.expect(placements[0].geometry.right() <= area.right());
        try std.testing.expect(placements[0].geometry.bottom() <= area.bottom());
    }
}

fn allocationFailureExercise(a: std.mem.Allocator) !void {
    var workspaces: [2]Workspace = @splat(testWorkspace());
    defer for (&workspaces) |*workspace| workspace.deinit(a);
    workspaces[0].layout.dwindle_split_focused = true;
    try addWindows(a, &workspaces[0], 1, 6);
    try addWindows(a, &workspaces[1], 100, 4);
    const moves = try plan(a, test_area, &workspaces, 1);
    defer a.free(moves);
}

test "overflow planning releases owned trees and previews on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
}
