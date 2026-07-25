// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
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
    const initial_width = @min(800, @as(i32, @intFromFloat(@as(f64, @floatFromInt(area.width)) * 0.6)));
    const initial_height = @min(600, @as(i32, @intFromFloat(@as(f64, @floatFromInt(area.height)) * 0.6)));
    const initial = types.Rect{
        .x = area.x + @divTrunc(area.width - initial_width, 2),
        .y = area.y + @divTrunc(area.height - initial_height, 2),
        .width = initial_width,
        .height = initial_height,
    };
    const result = try allocator.alloc(types.Placement, windows.len);
    for (result, windows) |*placement, window| {
        const entry = try state.rects.getOrPut(allocator, window.handle);
        if (!entry.found_existing) {
            entry.value_ptr.* = cascade(initial, area, state.next_cascade);
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

fn cascade(initial: types.Rect, area: types.Rect, index: u32) types.Rect {
    const step: i32 = 32;
    const travel_x = @max(0, area.width - initial.width);
    const travel_y = @max(0, area.height - initial.height);
    const slots_x: u32 = @intCast(@divTrunc(travel_x, step) + 1);
    const slots_y: u32 = @intCast(@divTrunc(travel_y, step) + 1);
    const slots = @max(1, @min(slots_x, slots_y));
    const offset: i32 = @intCast((index % slots) * @as(u32, @intCast(step)));
    return .{
        .x = initial.x + offset,
        .y = initial.y + offset,
        .width = initial.width,
        .height = initial.height,
    };
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
