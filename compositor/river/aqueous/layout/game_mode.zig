// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const geometry = @import("game_geometry.zig");
const grid = @import("grid.zig");
const math = @import("math.zig");
const types = @import("types.zig");

pub const State = struct {
    grid: grid.State = .{},
    anchor: ?types.Handle = null,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.grid.deinit(allocator);
    }
};

pub const Options = struct {
    size: geometry.Size = .{ .fraction = .{ .width = 0.5, .height = 1.0 } },
    anchor: geometry.Anchor = .center,
    scale: f64 = 1,
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, focused: ?types.Handle, options: types.Options, game_options: Options) ![]types.Placement {
    const result = try allocator.alloc(types.Placement, windows.len);
    if (windows.len == 0) {
        state.anchor = null;
        return result;
    }
    if (focused != null and contains(windows, focused.?)) state.anchor = focused;
    if (state.anchor == null or !contains(windows, state.anchor.?)) state.anchor = windows[0].handle;
    const anchor_window = find(windows, state.anchor.?).?;
    const area = math.shrink(usable_area, options.gaps_outer);
    const anchor_rect = geometry.resolveAnchor(area, @max(1, anchor_window.min_width), @max(1, anchor_window.min_height), game_options.size, game_options.anchor, game_options.scale);
    result[0] = .{ .handle = state.anchor.?, .geometry = anchor_rect, .z_order = 1, .visible = true, .border = .none };

    var remainder_windows: std.ArrayListUnmanaged(types.Window) = .empty;
    defer remainder_windows.deinit(allocator);
    for (windows) |window| if (window.handle != state.anchor.?) try remainder_windows.append(allocator, window);
    const remainder = geometry.resolveRemainder(area, anchor_rect);
    if (remainder_windows.items.len > 0 and remainder.width > 0 and remainder.height > 0) {
        const placements = try grid.arrange(allocator, &state.grid, remainder, remainder_windows.items, .{ .gaps_outer = 0, .gaps_inner = options.gaps_inner, .border = options.border });
        defer allocator.free(placements);
        @memcpy(result[1..], placements);
    } else {
        for (result[1..], remainder_windows.items) |*placement, window| {
            placement.* = .{ .handle = window.handle, .geometry = .empty, .z_order = 0, .visible = false, .border = .none };
        }
    }
    return result;
}

fn contains(windows: []const types.Window, handle: types.Handle) bool {
    return find(windows, handle) != null;
}

fn find(windows: []const types.Window, handle: types.Handle) ?types.Window {
    for (windows) |window| if (window.handle == handle) return window;
    return null;
}

test "game mode anchors focus and tiles the remainder" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 200, .height = 100 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, 2, .{ .gaps_outer = 0, .gaps_inner = 0 }, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(types.Handle, 2), placements[0].handle);
    try std.testing.expectEqual(types.Rect{ .x = 50, .y = 0, .width = 100, .height = 100 }, placements[0].geometry);
    try std.testing.expect(placements[1].visible);
    try std.testing.expect(placements[2].visible);
}