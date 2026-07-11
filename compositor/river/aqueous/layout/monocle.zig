// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const order = @import("order.zig");
const types = @import("types.zig");

pub const State = struct {
    order: order.State = .{},
    current: ?types.Handle = null,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.order.deinit(allocator);
    }
};

pub const Options = struct {
    hide_others: bool = true,
    show_borders: bool = false,
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, focused: ?types.Handle, options: types.Options, monocle_options: Options) ![]types.Placement {
    try state.order.sync(allocator, windows);
    const result = try allocator.alloc(types.Placement, windows.len);
    if (windows.len == 0) {
        state.current = null;
        return result;
    }
    if (state.current == null or !contains(windows, state.current.?)) {
        state.current = if (focused != null and contains(windows, focused.?)) focused else windows[0].handle;
    }
    const area = math.shrink(usable_area, options.gaps_outer);
    for (result, windows) |*placement, window| {
        const current = window.handle == state.current.?;
        placement.* = .{
            .handle = window.handle,
            .geometry = if (current) area else .empty,
            .z_order = if (current) 1 else 0,
            .visible = current or !monocle_options.hide_others,
            .border = if (current and monocle_options.show_borders) options.border else .none,
        };
    }
    return result;
}

fn contains(windows: []const types.Window, handle: types.Handle) bool {
    for (windows) |window| if (window.handle == handle) return true;
    return false;
}

test "monocle shows the focused window and hides the rest" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 80, .height = 60 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 },
    }, 2, .{ .gaps_outer = 0 }, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expect(!placements[0].visible);
    try std.testing.expect(placements[1].visible);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 80, .height = 60 }, placements[1].geometry);
}