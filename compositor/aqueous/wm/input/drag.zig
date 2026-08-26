// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const PolicyState = @import("../state/PolicyState.zig");
const types = @import("../layout/types.zig");

pub const Action = enum { move_floating, resize_floating, resize_scrolling, swap_tiled };

pub const ResizeEdges = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn any(edges: ResizeEdges) bool {
        return edges.top or edges.bottom or edges.left or edges.right;
    }
};

pub const double_click_msec: u32 = 400;
pub const click_motion_tolerance: f64 = 4;

pub fn stayedClick(pointer_x: f64, pointer_y: f64, last_x: f64, last_y: f64) bool {
    return @abs(last_x - pointer_x) <= click_motion_tolerance and
        @abs(last_y - pointer_y) <= click_motion_tolerance;
}

pub fn withinDoubleClick(previous_msec: u32, current_msec: u32) bool {
    return current_msec -% previous_msec <= double_click_msec;
}

/// Position a restored floating rectangle beneath the pointer which initiated
/// a move from maximized state. Preserve the horizontal grab ratio so dragging
/// from either end of a titlebar feels stable, and retain the pointer's
/// vertical offset from the maximized top edge.
pub fn restoredMoveStart(
    maximized: types.Rect,
    normal: types.Rect,
    pointer_x: f64,
    pointer_y: f64,
) types.Rect {
    const maximized_width: f64 = @floatFromInt(@max(1, maximized.width));
    const normal_width: f64 = @floatFromInt(normal.width);
    const normal_height: f64 = @floatFromInt(normal.height);
    const horizontal_ratio = std.math.clamp(
        (pointer_x - @as(f64, @floatFromInt(maximized.x))) / maximized_width,
        0,
        1,
    );
    const vertical_offset = std.math.clamp(
        pointer_y - @as(f64, @floatFromInt(maximized.y)),
        0,
        @max(0, normal_height - 1),
    );
    return .{
        .x = @intFromFloat(@round(pointer_x - horizontal_ratio * normal_width)),
        .y = @intFromFloat(@round(pointer_y - vertical_offset)),
        .width = normal.width,
        .height = normal.height,
    };
}

pub fn action(
    button: u32,
    kind: PolicyState.Kind,
    layout_floating: bool,
    scrolling_resizable: bool,
) Action {
    if (button == 0x110 and kind == .tiled and !layout_floating) return .swap_tiled;
    if (button == 0x111 and kind == .tiled and scrolling_resizable) return .resize_scrolling;
    return if (button == 0x111) .resize_floating else .move_floating;
}

/// Resolve an edge-anchored interactive resize. Client constraints and output
/// bounds are intentionally applied by later geometry milestones; this helper
/// guarantees a valid positive rectangle while preserving the requested edge.
pub fn resize(start: types.Rect, dx: i32, dy: i32, edges: ResizeEdges) types.Rect {
    var result = start;
    if (edges.left) {
        result.x = start.x + dx;
        result.width = start.width - dx;
        if (result.width < 1) {
            result.x = start.right() - 1;
            result.width = 1;
        }
    } else if (edges.right) {
        result.width = @max(1, start.width + dx);
    }
    if (edges.top) {
        result.y = start.y + dy;
        result.height = start.height - dy;
        if (result.height < 1) {
            result.y = start.bottom() - 1;
            result.height = 1;
        }
    } else if (edges.bottom) {
        result.height = @max(1, start.height + dy);
    }
    return result;
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
    try std.testing.expectEqual(Action.swap_tiled, action(0x110, .tiled, false, false));
    try std.testing.expectEqual(Action.move_floating, action(0x110, .floating, false, false));
    try std.testing.expectEqual(Action.move_floating, action(0x110, .tiled, true, false));
    try std.testing.expectEqual(Action.resize_floating, action(0x111, .tiled, false, false));
}

test "modified right drag keeps scrolling members tiled" {
    try std.testing.expectEqual(Action.resize_scrolling, action(0x111, .tiled, false, true));
    try std.testing.expectEqual(Action.resize_floating, action(0x111, .floating, false, true));
}

test "double click timing and motion reject drags" {
    try std.testing.expect(stayedClick(100, 50, 103, 54));
    try std.testing.expect(!stayedClick(100, 50, 105, 50));
    try std.testing.expect(withinDoubleClick(1000, 1400));
    try std.testing.expect(!withinDoubleClick(1000, 1401));
    try std.testing.expect(withinDoubleClick(std.math.maxInt(u32) - 10, 20));
}

test "maximized move restore keeps the titlebar beneath the pointer" {
    const maximized: types.Rect = .{ .x = 100, .y = 40, .width = 1200, .height = 800 };
    const normal: types.Rect = .{ .x = 250, .y = 180, .width = 600, .height = 400 };

    try std.testing.expectEqual(
        types.Rect{ .x = 400, .y = 40, .width = 600, .height = 400 },
        restoredMoveStart(maximized, normal, 700, 62),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 40, .width = 600, .height = 400 },
        restoredMoveStart(maximized, normal, 100, 50),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 700, .y = 40, .width = 600, .height = 400 },
        restoredMoveStart(maximized, normal, 1300, 55),
    );
}

test "drop zones distinguish vertical stacks from adjacent columns" {
    const geometry: types.Rect = .{ .x = 100, .y = 50, .width = 300, .height = 180 };
    try std.testing.expectEqual(types.DropZone.stack_before, dropZone(geometry, 250, 60));
    try std.testing.expectEqual(types.DropZone.stack_after, dropZone(geometry, 250, 220));
    try std.testing.expectEqual(types.DropZone.column_before, dropZone(geometry, 120, 140));
    try std.testing.expectEqual(types.DropZone.column_after, dropZone(geometry, 380, 140));
}

test "floating resize preserves the requested edge anchors" {
    const start: types.Rect = .{ .x = 100, .y = 50, .width = 300, .height = 200 };
    try std.testing.expectEqual(
        types.Rect{ .x = 80, .y = 40, .width = 320, .height = 210 },
        resize(start, -20, -10, .{ .top = true, .left = true }),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 50, .width = 340, .height = 230 },
        resize(start, 40, 30, .{ .bottom = true, .right = true }),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 399, .y = 249, .width = 1, .height = 1 },
        resize(start, 500, 500, .{ .top = true, .left = true }),
    );
}
