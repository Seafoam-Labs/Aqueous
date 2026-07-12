// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("types.zig");

pub const min_zoom: f64 = 0.25;
pub const max_zoom: f64 = 2.0;

pub const WorldRect = struct {
    x: f64,
    y: f64,
    width: i32,
    height: i32,
};

pub const Camera = struct {
    x: f64 = 0,
    y: f64 = 0,
    zoom: f64 = 1,
};

pub const State = struct {
    camera: Camera = .{},
    rects: std.AutoHashMapUnmanaged(types.Handle, WorldRect) = .empty,
    last_area: types.Rect = .empty,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.rects.deinit(allocator);
    }

    /// Move the camera by a screen-space pointer delta. Dividing by zoom keeps
    /// the content attached to the pointer at every magnification.
    pub fn panFrom(state: *State, start: Camera, dx: f64, dy: f64) bool {
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return false;
        const next_x = start.x - dx / start.zoom;
        const next_y = start.y - dy / start.zoom;
        if (next_x == state.camera.x and next_y == state.camera.y) return false;
        state.camera.x = next_x;
        state.camera.y = next_y;
        return true;
    }

    /// Zoom about a screen-space anchor while preserving the world point under
    /// that anchor. This avoids the canvas appearing to slide while zooming.
    pub fn zoomAt(state: *State, screen_x: f64, screen_y: f64, factor: f64) bool {
        if (!std.math.isFinite(factor) or factor <= 0) return false;
        const area = state.last_area;
        if (area.width <= 0 or area.height <= 0) return false;
        const old_zoom = state.camera.zoom;
        const next_zoom = std.math.clamp(old_zoom * factor, min_zoom, max_zoom);
        if (next_zoom == old_zoom) return false;

        const local_x = screen_x - @as(f64, @floatFromInt(area.x));
        const local_y = screen_y - @as(f64, @floatFromInt(area.y));
        const world_x = state.camera.x + local_x / old_zoom;
        const world_y = state.camera.y + local_y / old_zoom;
        state.camera.zoom = next_zoom;
        state.camera.x = world_x - local_x / next_zoom;
        state.camera.y = world_y - local_y / next_zoom;
        return true;
    }

    pub fn resetZoom(state: *State, screen_x: f64, screen_y: f64) bool {
        return state.zoomAt(screen_x, screen_y, 1.0 / state.camera.zoom);
    }

    pub fn moveWindowFrom(state: *State, handle: types.Handle, start: WorldRect, dx: f64, dy: f64) bool {
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return false;
        const next: WorldRect = .{
            .x = start.x + dx / state.camera.zoom,
            .y = start.y + dy / state.camera.zoom,
            .width = start.width,
            .height = start.height,
        };
        const current = state.rects.get(handle) orelse return false;
        if (current.x == next.x and current.y == next.y) return false;
        state.rects.putAssumeCapacity(handle, next);
        return true;
    }
};

pub fn arrange(
    allocator: std.mem.Allocator,
    state: *State,
    usable_area: types.Rect,
    windows: []const types.Window,
    options: types.Options,
) ![]types.Placement {
    state.last_area = usable_area;
    try syncRects(allocator, state, usable_area, windows, options);

    const placements = try allocator.alloc(types.Placement, windows.len);
    for (windows, placements, 0..) |window, *placement, index| {
        const world = state.rects.get(window.handle).?;
        const visual = project(world, usable_area, state.camera);
        placement.* = .{
            .handle = window.handle,
            // Client dimensions remain in world units. Only the origin is
            // projected here; Window applies scale to its presentation clone.
            .geometry = .{ .x = visual.x, .y = visual.y, .width = world.width, .height = world.height },
            .z_order = @intCast(index),
            .visible = intersects(visual, usable_area),
            .border = options.border,
            .scale = state.camera.zoom,
        };
    }
    return placements;
}

fn syncRects(
    allocator: std.mem.Allocator,
    state: *State,
    area: types.Rect,
    windows: []const types.Window,
    options: types.Options,
) !void {
    var stale: std.ArrayListUnmanaged(types.Handle) = .empty;
    defer stale.deinit(allocator);
    var keys = state.rects.keyIterator();
    while (keys.next()) |handle| if (!contains(windows, handle.*)) try stale.append(allocator, handle.*);
    for (stale.items) |handle| _ = state.rects.remove(handle);

    const inset_width = @max(1, area.width - options.gaps_outer * 2);
    const inset_height = @max(1, area.height - options.gaps_outer * 2);
    const default_width = @max(1, @divTrunc(inset_width * 3, 5));
    const default_height = @max(1, @divTrunc(inset_height * 3, 5));
    var new_index: usize = state.rects.count();
    for (windows) |window| {
        if (state.rects.contains(window.handle)) continue;
        const cascade: i32 = @intCast((new_index % 8) * 32);
        const viewport_world_width = @as(f64, @floatFromInt(area.width)) / state.camera.zoom;
        const viewport_world_height = @as(f64, @floatFromInt(area.height)) / state.camera.zoom;
        const width = constrain(default_width, window.min_width, window.max_width);
        const height = constrain(default_height, window.min_height, window.max_height);
        try state.rects.put(allocator, window.handle, .{
            .x = state.camera.x + (viewport_world_width - @as(f64, @floatFromInt(width))) / 2 + @as(f64, @floatFromInt(cascade)),
            .y = state.camera.y + (viewport_world_height - @as(f64, @floatFromInt(height))) / 2 + @as(f64, @floatFromInt(cascade)),
            .width = width,
            .height = height,
        });
        new_index += 1;
    }
}

pub fn project(world: WorldRect, area: types.Rect, camera: Camera) types.Rect {
    return .{
        .x = area.x + roundI32((world.x - camera.x) * camera.zoom),
        .y = area.y + roundI32((world.y - camera.y) * camera.zoom),
        .width = @max(1, roundI32(@as(f64, @floatFromInt(world.width)) * camera.zoom)),
        .height = @max(1, roundI32(@as(f64, @floatFromInt(world.height)) * camera.zoom)),
    };
}

pub fn unproject(screen_x: f64, screen_y: f64, area: types.Rect, camera: Camera) struct { x: f64, y: f64 } {
    return .{
        .x = camera.x + (screen_x - @as(f64, @floatFromInt(area.x))) / camera.zoom,
        .y = camera.y + (screen_y - @as(f64, @floatFromInt(area.y))) / camera.zoom,
    };
}

fn roundI32(value: f64) i32 {
    const bounded = std.math.clamp(value, @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32))));
    return @intFromFloat(@round(bounded));
}

fn constrain(value: i32, minimum: i32, maximum: i32) i32 {
    var result: i32 = @max(value, @max(1, minimum));
    if (maximum > 0) result = @min(result, maximum);
    return result;
}

fn contains(windows: []const types.Window, handle: types.Handle) bool {
    for (windows) |window| if (window.handle == handle) return true;
    return false;
}

fn intersects(a: types.Rect, b: types.Rect) bool {
    return a.right() > b.x and a.x < b.right() and a.bottom() > b.y and a.y < b.bottom();
}

test "projection and inverse projection round trip" {
    const area: types.Rect = .{ .x = 100, .y = 50, .width = 1000, .height = 800 };
    const camera: Camera = .{ .x = -40, .y = 25, .zoom = 0.5 };
    const screen = project(.{ .x = 200, .y = 125, .width = 600, .height = 400 }, area, camera);
    try std.testing.expectEqual(types.Rect{ .x = 220, .y = 100, .width = 300, .height = 200 }, screen);
    const world = unproject(@floatFromInt(screen.x), @floatFromInt(screen.y), area, camera);
    try std.testing.expectApproxEqAbs(@as(f64, 200), world.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 125), world.y, 0.001);
}

test "cursor anchored zoom preserves the world point" {
    var state: State = .{ .camera = .{ .x = 10, .y = 20, .zoom = 1 }, .last_area = .{ .x = 100, .y = 50, .width = 800, .height = 600 } };
    const before = unproject(400, 300, state.last_area, state.camera);
    try std.testing.expect(state.zoomAt(400, 300, 0.5));
    const after = unproject(400, 300, state.last_area, state.camera);
    try std.testing.expectApproxEqAbs(before.x, after.x, 0.001);
    try std.testing.expectApproxEqAbs(before.y, after.y, 0.001);
}

test "panning uses screen deltas at every zoom" {
    var state: State = .{ .camera = .{ .x = 100, .y = 200, .zoom = 0.5 } };
    try std.testing.expect(state.panFrom(state.camera, 25, -10));
    try std.testing.expectApproxEqAbs(@as(f64, 50), state.camera.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 220), state.camera.y, 0.001);
}

test "window dragging updates retained world coordinates" {
    var state: State = .{ .camera = .{ .zoom = 0.5 } };
    defer state.deinit(std.testing.allocator);
    try state.rects.put(std.testing.allocator, 7, .{ .x = 100, .y = 200, .width = 600, .height = 400 });
    const start = state.rects.get(7).?;
    try std.testing.expect(state.moveWindowFrom(7, start, 25, -10));
    try std.testing.expectApproxEqAbs(@as(f64, 150), state.rects.get(7).?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 180), state.rects.get(7).?.y, 0.001);
}

test "canvas state forgets closed windows" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const first = try arrange(std.testing.allocator, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, .{});
    std.testing.allocator.free(first);
    try std.testing.expectEqual(@as(usize, 2), state.rects.count());
    const second = try arrange(std.testing.allocator, &state, area, &.{.{ .handle = 2 }}, .{});
    std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 1), state.rects.count());
    try std.testing.expect(state.rects.contains(2));
}
