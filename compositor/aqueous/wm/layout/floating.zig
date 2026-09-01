// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const geometry_policy = @import("geometry.zig");
const math = @import("math.zig");
const types = @import("types.zig");

pub const State = struct {
    rects: std.AutoHashMapUnmanaged(types.Handle, types.Rect) = .empty,
    next_cascade: u32 = 0,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.rects.deinit(allocator);
    }
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, focused: ?types.Handle, options: types.Options) ![]types.Placement {
    const area = math.shrink(usable_area, options.gaps_outer);
    const result = try allocator.alloc(types.Placement, windows.len);
    for (result, windows) |*placement, window| {
        const entry = try state.rects.getOrPut(allocator, window.handle);
        if (!entry.found_existing) {
            const initial = initialGeometry(area, window);
            entry.value_ptr.* = switch (options.floating_placement) {
                .center => initial,
                .under_pointer => underPointer(initial, area, options.pointer_x, options.pointer_y),
                .minimal_overlap => minimalOverlap(state, windows, window.handle, initial, area),
                .cascade => cascade(initial, area, state.next_cascade, options.floating_cascade_step),
            };
            state.next_cascade +%= 1;
        }
        placement.* = .{
            .handle = window.handle,
            .geometry = entry.value_ptr.*,
            .z_order = if (focused != null and focused.? == window.handle) 1 else 0,
            .visible = true,
            .border = options.border,
            .tiled = false,
        };
    }
    return result;
}

pub fn setGeometry(state: *State, allocator: std.mem.Allocator, handle: types.Handle, rect: types.Rect) !void {
    if (rect.width <= 0 or rect.height <= 0) return;
    try state.rects.put(allocator, handle, rect);
}

pub fn geometry(state: *const State, handle: types.Handle) ?types.Rect {
    return state.rects.get(handle);
}

pub fn remove(state: *State, handle: types.Handle) void {
    _ = state.rects.remove(handle);
}

fn initialGeometry(area: types.Rect, window: types.Window) types.Rect {
    const fallback_width = @min(800, @max(1, @divTrunc(@as(i64, area.width) * 3, 5)));
    const fallback_height = @min(600, @max(1, @divTrunc(@as(i64, area.height) * 3, 5)));
    const size = geometry_policy.constrainSize(
        if (window.preferred_width > 0) window.preferred_width else fallback_width,
        if (window.preferred_height > 0) window.preferred_height else fallback_height,
        geometry_policy.Constraints.fromWindow(window),
        .{},
    );
    return fit(.{
        .x = clampI32(@as(i64, area.x) + @divTrunc(@as(i64, area.width) - size.width, 2)),
        .y = clampI32(@as(i64, area.y) + @divTrunc(@as(i64, area.height) - size.height, 2)),
        .width = size.width,
        .height = size.height,
    }, area);
}

fn underPointer(initial: types.Rect, area: types.Rect, pointer_x: ?i32, pointer_y: ?i32) types.Rect {
    if (pointer_x == null or pointer_y == null) return initial;
    return fit(.{
        .x = clampI32(@as(i64, pointer_x.?) - @divTrunc(initial.width, 2)),
        .y = clampI32(@as(i64, pointer_y.?) - @divTrunc(initial.height, 2)),
        .width = initial.width,
        .height = initial.height,
    }, area);
}

fn cascade(initial: types.Rect, area: types.Rect, index: u32, configured_step: i32) types.Rect {
    const step = @max(1, configured_step);
    const travel_x = @max(0, area.width - initial.width);
    const travel_y = @max(0, area.height - initial.height);
    const slots_x: u32 = @intCast(@divTrunc(travel_x, step) + 1);
    const slots_y: u32 = @intCast(@divTrunc(travel_y, step) + 1);
    const slots = @max(1, @min(slots_x, slots_y));
    const offset: i32 = @intCast((index % slots) * @as(u32, @intCast(step)));
    return fit(.{
        .x = clampI32(@as(i64, initial.x) + offset),
        .y = clampI32(@as(i64, initial.y) + offset),
        .width = initial.width,
        .height = initial.height,
    }, area);
}

fn minimalOverlap(state: *const State, windows: []const types.Window, handle: types.Handle, initial: types.Rect, area: types.Rect) types.Rect {
    var choice = initial;
    var best = scoreCandidate(state, windows, handle, choice, initial);
    const positions = [_]types.Rect{
        .{ .x = area.x, .y = area.y, .width = initial.width, .height = initial.height },
        .{ .x = clampI32(@as(i64, area.x) + area.width - initial.width), .y = area.y, .width = initial.width, .height = initial.height },
        .{ .x = area.x, .y = clampI32(@as(i64, area.y) + area.height - initial.height), .width = initial.width, .height = initial.height },
        .{ .x = clampI32(@as(i64, area.x) + area.width - initial.width), .y = clampI32(@as(i64, area.y) + area.height - initial.height), .width = initial.width, .height = initial.height },
    };
    for (positions) |candidate| considerCandidate(state, windows, handle, fit(candidate, area), initial, &choice, &best);
    for (windows) |window| {
        if (window.handle == handle) continue;
        const other = state.rects.get(window.handle) orelse continue;
        const candidates = [_]types.Rect{
            .{ .x = clampI32(@as(i64, other.x) - initial.width), .y = other.y, .width = initial.width, .height = initial.height },
            .{ .x = clampI32(@as(i64, other.x) + other.width), .y = other.y, .width = initial.width, .height = initial.height },
            .{ .x = other.x, .y = clampI32(@as(i64, other.y) - initial.height), .width = initial.width, .height = initial.height },
            .{ .x = other.x, .y = clampI32(@as(i64, other.y) + other.height), .width = initial.width, .height = initial.height },
        };
        for (candidates) |candidate| considerCandidate(state, windows, handle, fit(candidate, area), initial, &choice, &best);
    }
    return choice;
}

const CandidateScore = struct { overlap: u64, distance: u64 };

fn considerCandidate(state: *const State, windows: []const types.Window, handle: types.Handle, candidate: types.Rect, origin: types.Rect, choice: *types.Rect, best: *CandidateScore) void {
    const score = scoreCandidate(state, windows, handle, candidate, origin);
    if (score.overlap < best.overlap or (score.overlap == best.overlap and score.distance < best.distance)) {
        choice.* = candidate;
        best.* = score;
    }
}

fn scoreCandidate(state: *const State, windows: []const types.Window, handle: types.Handle, candidate: types.Rect, origin: types.Rect) CandidateScore {
    var overlap: u64 = 0;
    for (windows) |window| {
        if (window.handle == handle) continue;
        const other = state.rects.get(window.handle) orelse continue;
        const intersection = math.intersect(candidate, other);
        if (intersection.width > 0 and intersection.height > 0) {
            overlap +|= @as(u64, @intCast(intersection.width)) *| @as(u64, @intCast(intersection.height));
        }
    }
    const dx: u64 = @intCast(@abs(@as(i64, candidate.x) - origin.x));
    const dy: u64 = @intCast(@abs(@as(i64, candidate.y) - origin.y));
    return .{ .overlap = overlap, .distance = dx +| dy };
}

fn fit(rect: types.Rect, area: types.Rect) types.Rect {
    return geometry_policy.keepReachable(rect, area, @min(rect.width, area.width), @min(rect.height, area.height));
}

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

test "floating cascades new windows and remembers geometry across absence" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, 1, .{ .gaps_outer = 0 });
    try std.testing.expectEqual(types.Rect{ .x = 200, .y = 160, .width = 600, .height = 480 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 232, .y = 192, .width = 600, .height = 480 }, placements[1].geometry);
    std.testing.allocator.free(placements);

    try setGeometry(&state, std.testing.allocator, 1, .{ .x = 40, .y = 50, .width = 500, .height = 300 });
    placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &.{.{ .handle = 2 }}, null, .{ .gaps_outer = 0 });
    std.testing.allocator.free(placements);
    placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, null, .{ .gaps_outer = 0 });
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 40, .y = 50, .width = 500, .height = 300 }, placements[0].geometry);
}

test "explicit removal collects stale geometry" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try setGeometry(&state, std.testing.allocator, 7, .{ .x = 1, .y = 2, .width = 3, .height = 4 });
    try std.testing.expect(geometry(&state, 7) != null);
    remove(&state, 7);
    try std.testing.expectEqual(@as(?types.Rect, null), geometry(&state, 7));
}

test "floating placement uses natural size constraints under the pointer" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &.{.{
        .handle = 1,
        .preferred_width = 377,
        .preferred_height = 241,
        .base_width = 17,
        .base_height = 1,
        .width_inc = 20,
        .height_inc = 10,
    }}, null, .{ .gaps_outer = 0, .floating_placement = .under_pointer, .pointer_x = 900, .pointer_y = 700 });
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 623, .y = 559, .width = 377, .height = 241 }, placements[0].geometry);
}

test "minimal overlap selects a free edge deterministically" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try setGeometry(&state, std.testing.allocator, 1, .{ .x = 200, .y = 160, .width = 600, .height = 480 });
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &.{ .{ .handle = 1 }, .{ .handle = 2, .preferred_width = 200, .preferred_height = 160 } }, null, .{ .gaps_outer = 0, .floating_placement = .minimal_overlap });
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 200, .y = 0, .width = 200, .height = 160 }, placements[1].geometry);
}
