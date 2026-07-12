// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const layout_config = @import("../config/layout.zig");
const PolicyState = @import("../state/PolicyState.zig");

pub const Action = enum { move_floating, resize_floating, swap_tiled, move_canvas, resize_canvas };

pub fn action(button: u32, kind: PolicyState.Kind, active_layout: layout_config.LayoutId) Action {
    if (button == 0x110 and kind == .tiled and active_layout == .canvas) return .move_canvas;
    if (button == 0x111 and kind == .tiled and active_layout == .canvas) return .resize_canvas;
    if (button == 0x110 and kind == .tiled and active_layout != .floating) return .swap_tiled;
    return if (button == 0x111) .resize_floating else .move_floating;
}

test "modified left drag swaps tiled windows without forcing floating" {
    try std.testing.expectEqual(Action.swap_tiled, action(0x110, .tiled, .tile));
    try std.testing.expectEqual(Action.swap_tiled, action(0x110, .tiled, .rows));
    try std.testing.expectEqual(Action.move_floating, action(0x110, .floating, .tile));
    try std.testing.expectEqual(Action.move_floating, action(0x110, .tiled, .floating));
    try std.testing.expectEqual(Action.resize_floating, action(0x111, .tiled, .tile));
    try std.testing.expectEqual(Action.move_canvas, action(0x110, .tiled, .canvas));
    try std.testing.expectEqual(Action.resize_canvas, action(0x111, .tiled, .canvas));
}
