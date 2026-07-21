// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const layout_config = @import("../config/layout.zig");
const PolicyState = @import("../state/PolicyState.zig");
const types = @import("../layout/types.zig");

pub const Action = enum { move_floating, resize_floating, swap_tiled };

pub fn action(button: u32, kind: PolicyState.Kind, active_layout: layout_config.LayoutId) Action {
    if (button == 0x110 and kind == .tiled and active_layout != .floating) return .swap_tiled;
    return if (button == 0x111) .resize_floating else .move_floating;
}

/// Divide a tiled target into vertical stacking zones and horizontal column
/// insertion zones. Top/bottom take priority so dropping near a horizontal
/// divider is stable even for narrow columns.
pub fn dropZone(geometry: types.Rect, x: f64, y: f64) types.DropZone {
    const top: f64 = @floatFromInt(geometry.y);
    const left: f64 = @floatFromInt(geometry.x);
    const width: f64 = @floatFromInt(geometry.width);
    const height: f64 = @floatFromInt(geometry.height);
    if (y < top + height / 3.0) return .stack_before;
    if (y >= top + height * 2.0 / 3.0) return .stack_after;
    return if (x < left + width / 2.0) .column_before else .column_after;
}

test "modified left drag swaps tiled windows without forcing floating" {
    try std.testing.expectEqual(Action.swap_tiled, action(0x110, .tiled, .tile));
    try std.testing.expectEqual(Action.swap_tiled, action(0x110, .tiled, .rows));
    try std.testing.expectEqual(Action.move_floating, action(0x110, .floating, .tile));
    try std.testing.expectEqual(Action.move_floating, action(0x110, .tiled, .floating));
    try std.testing.expectEqual(Action.resize_floating, action(0x111, .tiled, .tile));
}

test "drop zones distinguish vertical stacks from adjacent columns" {
    const geometry: types.Rect = .{ .x = 100, .y = 50, .width = 300, .height = 180 };
    try std.testing.expectEqual(types.DropZone.stack_before, dropZone(geometry, 250, 60));
    try std.testing.expectEqual(types.DropZone.stack_after, dropZone(geometry, 250, 220));
    try std.testing.expectEqual(types.DropZone.column_before, dropZone(geometry, 120, 140));
    try std.testing.expectEqual(types.DropZone.column_after, dropZone(geometry, 380, 140));
}
