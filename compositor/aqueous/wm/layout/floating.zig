// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const types = @import("types.zig");

pub const State = struct {
    rects: std.AutoHashMapUnmanaged(types.Handle, types.Rect) = .empty,

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
        if (!entry.found_existing) entry.value_ptr.* = initial;
        placement.* = .{
            .handle = window.handle,
            .geometry = entry.value_ptr.*,
            .z_order = if (focused != null and focused.? == window.handle) 1 else 0,
            .visible = true,
            .border = options.border,
            .tiled = false,
        };
    }
    var stale: std.ArrayListUnmanaged(types.Handle) = .empty;
    defer stale.deinit(allocator);
    var iterator = state.rects.keyIterator();
    while (iterator.next()) |handle| if (!contains(windows, handle.*)) try stale.append(allocator, handle.*);
    for (stale.items) |handle| _ = state.rects.remove(handle);
    return result;
}

fn contains(windows: []const types.Window, handle: types.Handle) bool {
    for (windows) |window| if (window.handle == handle) return true;
    return false;
}

test "floating remembers centred geometry and collects stale windows" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &.{.{ .handle = 1 }}, 1, .{ .gaps_outer = 0 });
    try std.testing.expectEqual(types.Rect{ .x = 200, .y = 160, .width = 600, .height = 480 }, placements[0].geometry);
    std.testing.allocator.free(placements);
    placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, &.{.{ .handle = 2 }}, null, .{ .gaps_outer = 0 });
    defer std.testing.allocator.free(placements);
    try std.testing.expect(!state.rects.contains(1));
}
