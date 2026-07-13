// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("../layout/types.zig");
const PolicyState = @import("PolicyState.zig");

/// Return true exactly once for each newly declared non-null parent. Clearing
/// the parent arms the heuristic again, while ordinary manage cycles and a
/// user's manual tile override leave it dormant.
pub fn parentChanged(state: *PolicyState, parent: ?types.Handle) bool {
    const handle = parent orelse {
        state.auto_float_parent = 0;
        return false;
    };
    if (state.auto_float_parent == handle) return false;
    state.auto_float_parent = handle;
    return true;
}

pub fn geometry(area: types.Rect, parent: types.Rect, width_hint: i32, height_hint: i32) types.Rect {
    const width = @min(area.width, if (width_hint > 0) width_hint else 580);
    const height = @min(area.height, if (height_hint > 0) height_hint else 360);
    const centered_x = parent.x + @divTrunc(parent.width - width, 2);
    const centered_y = parent.y + @divTrunc(parent.height - height, 2);
    return .{
        .x = std.math.clamp(centered_x, area.x, area.right() - width),
        .y = std.math.clamp(centered_y, area.y, area.bottom() - height),
        .width = width,
        .height = height,
    };
}

test "parent changes are edge-triggered" {
    var state: PolicyState = .{};
    try std.testing.expect(!parentChanged(&state, null));
    try std.testing.expect(parentChanged(&state, 12));
    try std.testing.expect(!parentChanged(&state, 12));
    try std.testing.expect(parentChanged(&state, 34));
    try std.testing.expect(!parentChanged(&state, null));
    try std.testing.expect(parentChanged(&state, 34));
}

test "geometry uses native hints and stays inside the usable area" {
    const area: types.Rect = .{ .x = 100, .y = 50, .width = 1000, .height = 700 };
    const parent: types.Rect = .{ .x = 300, .y = 150, .width = 600, .height = 500 };
    try std.testing.expectEqual(
        types.Rect{ .x = 400, .y = 300, .width = 400, .height = 200 },
        geometry(area, parent, 400, 200),
    );

    const partly_offscreen: types.Rect = .{ .x = 0, .y = 0, .width = 300, .height = 200 };
    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 50, .width = 580, .height = 360 },
        geometry(area, partly_offscreen, 0, 0),
    );
}
