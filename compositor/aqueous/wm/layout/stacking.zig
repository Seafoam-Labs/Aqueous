// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("types.zig");

// Layout engines use the small z-order range around zero for local semantics.
// Policy overlays live in disjoint bands so engine focus cannot overtake a
// floating or fullscreen window.
pub const maximized_band: i32 = 100;
pub const floating_band: i32 = 200;
pub const transient_band: i32 = 300;
pub const fullscreen_band: i32 = 400;

pub fn floatingZ(parent_depth: u32) i32 {
    if (parent_depth == 0) return floating_band;
    return transient_band + @as(i32, @intCast(@min(parent_depth, 99)));
}

pub fn lessThan(_: void, left: types.Placement, right: types.Placement) bool {
    if (left.z_order != right.z_order) return left.z_order < right.z_order;
    if (left.stack_order != right.stack_order) return left.stack_order < right.stack_order;
    return left.handle < right.handle;
}

/// Count the declared transient-parent chain. A missing parent still gives the
/// child transient priority, while the window-count bound makes malformed
/// parent cycles harmless.
pub fn transientDepth(windows: []const types.Window, window: types.Window) u32 {
    var parent = window.parent;
    var depth: u32 = 0;
    var remaining = windows.len;
    while (parent != null and remaining > 0) : (remaining -= 1) {
        depth += 1;
        const ancestor = findWindow(windows, parent.?) orelse break;
        parent = ancestor.parent;
    }
    return depth;
}

fn findWindow(windows: []const types.Window, handle: types.Handle) ?types.Window {
    for (windows) |window| if (window.handle == handle) return window;
    return null;
}

test "semantic bands sort tiled, maximized, floating, transient, and fullscreen" {
    var placements = [_]types.Placement{
        .{ .handle = 5, .geometry = .empty, .z_order = fullscreen_band, .visible = true, .border = .none },
        .{ .handle = 3, .geometry = .empty, .z_order = floating_band, .stack_order = 8, .visible = true, .border = .none },
        .{ .handle = 1, .geometry = .empty, .z_order = 1, .visible = true, .border = .none },
        .{ .handle = 4, .geometry = .empty, .z_order = floatingZ(1), .visible = true, .border = .none },
        .{ .handle = 2, .geometry = .empty, .z_order = maximized_band, .visible = true, .border = .none },
        .{ .handle = 6, .geometry = .empty, .z_order = floating_band, .stack_order = 12, .visible = true, .border = .none },
    };
    std.mem.sort(types.Placement, &placements, {}, lessThan);
    const expected = [_]types.Handle{ 1, 2, 3, 6, 4, 5 };
    for (placements, expected) |placement, handle| {
        try std.testing.expectEqual(handle, placement.handle);
    }
}

test "persistent raise order wins within a floating band" {
    var placements = [_]types.Placement{
        .{ .handle = 20, .geometry = .empty, .z_order = floating_band, .stack_order = 9, .visible = true, .border = .none },
        .{ .handle = 10, .geometry = .empty, .z_order = floating_band, .stack_order = 15, .visible = true, .border = .none },
    };
    std.mem.sort(types.Placement, &placements, {}, lessThan);
    try std.testing.expectEqual(@as(types.Handle, 20), placements[0].handle);
    try std.testing.expectEqual(@as(types.Handle, 10), placements[1].handle);
}

test "transient depth follows parent chains and bounds cycles" {
    const windows = [_]types.Window{
        .{ .handle = 1 },
        .{ .handle = 2, .parent = 1 },
        .{ .handle = 3, .parent = 2 },
        .{ .handle = 4, .parent = 99 },
    };
    try std.testing.expectEqual(@as(u32, 0), transientDepth(&windows, windows[0]));
    try std.testing.expectEqual(@as(u32, 1), transientDepth(&windows, windows[1]));
    try std.testing.expectEqual(@as(u32, 2), transientDepth(&windows, windows[2]));
    try std.testing.expectEqual(@as(u32, 1), transientDepth(&windows, windows[3]));

    const cycle = [_]types.Window{
        .{ .handle = 7, .parent = 8 },
        .{ .handle = 8, .parent = 7 },
    };
    try std.testing.expectEqual(@as(u32, cycle.len), transientDepth(&cycle, cycle[0]));
}
