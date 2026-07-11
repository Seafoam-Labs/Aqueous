// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const order = @import("order.zig");
const types = @import("types.zig");

pub const State = struct {
    order: order.State = .{},
    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.order.deinit(allocator);
    }
};

pub const Options = struct {
    start_vertical: bool = true,
    split_ratio: f64 = 0.5,
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, options: types.Options, dwindle_options: Options) ![]types.Placement {
    try state.order.sync(allocator, windows);
    const handles = state.order.items.items;
    const result = try allocator.alloc(types.Placement, handles.len);
    var area = math.shrink(usable_area, options.gaps_outer);
    var vertical = dwindle_options.start_vertical;
    for (result, handles, 0..) |*placement, handle, index| {
        if (index == handles.len - 1) {
            placement.* = makePlacement(handle, area, options.border);
            break;
        }
        const pair = split(area, vertical, if (index == 0) options.master_ratio else dwindle_options.split_ratio, options.gaps_inner);
        placement.* = makePlacement(handle, pair.primary, options.border);
        area = pair.remainder;
        vertical = !vertical;
    }
    return result;
}

const Split = struct { primary: types.Rect, remainder: types.Rect };

fn split(area: types.Rect, vertical: bool, ratio: f64, gap: i32) Split {
    if (vertical) {
        const available = @max(1, area.width - gap);
        const primary_width = @min(available, @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(available)) * ratio)))));
        return .{
            .primary = .{ .x = area.x, .y = area.y, .width = primary_width, .height = area.height },
            .remainder = .{ .x = area.x + primary_width + gap, .y = area.y, .width = @max(1, available - primary_width), .height = area.height },
        };
    }
    const available = @max(1, area.height - gap);
    const primary_height = @min(available, @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(available)) * ratio)))));
    return .{
        .primary = .{ .x = area.x, .y = area.y, .width = area.width, .height = primary_height },
        .remainder = .{ .x = area.x, .y = area.y + primary_height + gap, .width = area.width, .height = @max(1, available - primary_height) },
    };
}

fn makePlacement(handle: types.Handle, geometry: types.Rect, border: types.Border) types.Placement {
    return .{ .handle = handle, .geometry = geometry, .z_order = 0, .visible = true, .border = border };
}

test "dwindle alternates split axes" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 }, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 48, .height = 80 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 52, .y = 0, .width = 48, .height = 38 }, placements[1].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 52, .y = 42, .width = 48, .height = 38 }, placements[2].geometry);
}