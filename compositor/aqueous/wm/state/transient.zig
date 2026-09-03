// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const geometry_policy = @import("../layout/geometry.zig");
const types = @import("../layout/types.zig");
const PolicyState = @import("PolicyState.zig");

/// Return true until a newly declared non-null parent has either been placed
/// or deliberately ignored. A pending natural-size handshake remains eligible
/// so the first committed buffer can complete placement.
pub fn placementPending(state: *PolicyState, parent: ?types.Handle) bool {
    const handle = parent orelse {
        state.cancelPendingNaturalSize();
        state.auto_float_parent = 0;
        return false;
    };
    return state.auto_float_parent != handle;
}

pub fn waitingForNaturalSize(state: *const PolicyState, parent: ?types.Handle) bool {
    return parent != null and state.pending_natural_parent == parent.?;
}

pub fn deferForNaturalSize(state: *PolicyState, parent: types.Handle) void {
    state.pending_natural_parent = parent;
}

pub fn finishPlacement(state: *PolicyState, parent: types.Handle) void {
    state.auto_float_parent = parent;
    state.pending_natural_parent = 0;
}

/// Center a client's natural size over its parent, after applying the client's
/// actual size constraints. No compositor-selected fallback belongs here: an
/// XDG client without a natural size must first receive an unspecified-size
/// configure and retry after committing its first buffer.
pub fn geometry(
    area: types.Rect,
    parent: types.Rect,
    natural_width: i32,
    natural_height: i32,
    constraints: geometry_policy.Constraints,
) ?types.Rect {
    if (natural_width <= 0 or natural_height <= 0) return null;
    const size = geometry_policy.constrainSize(natural_width, natural_height, constraints, .{});
    return geometry_policy.keepReachable(.{
        .x = parent.x + @divTrunc(parent.width - size.width, 2),
        .y = parent.y + @divTrunc(parent.height - size.height, 2),
        .width = size.width,
        .height = size.height,
    }, area, @min(size.width, area.width), @min(size.height, area.height));
}

test "placement stays pending through a natural-size handshake" {
    const std = @import("std");
    var state: PolicyState = .{};
    try std.testing.expect(!placementPending(&state, null));
    try std.testing.expect(placementPending(&state, 12));
    deferForNaturalSize(&state, 12);
    try std.testing.expect(placementPending(&state, 12));
    try std.testing.expect(waitingForNaturalSize(&state, 12));
    finishPlacement(&state, 12);
    try std.testing.expect(!placementPending(&state, 12));
    try std.testing.expect(!waitingForNaturalSize(&state, 12));
    try std.testing.expect(placementPending(&state, 34));
    try std.testing.expect(!placementPending(&state, null));
    try std.testing.expect(placementPending(&state, 34));
}

test "geometry uses natural size then constraints" {
    const std = @import("std");
    const area: types.Rect = .{ .x = 100, .y = 50, .width = 1000, .height = 700 };
    const parent: types.Rect = .{ .x = 300, .y = 150, .width = 600, .height = 500 };
    try std.testing.expectEqual(
        types.Rect{ .x = 400, .y = 300, .width = 400, .height = 200 },
        geometry(area, parent, 400, 200, .{ .min_width = 1, .min_height = 1 }).?,
    );

    try std.testing.expectEqual(
        types.Rect{ .x = 350, .y = 280, .width = 500, .height = 240 },
        geometry(area, parent, 400, 200, .{ .min_width = 500, .min_height = 240 }).?,
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 450, .y = 330, .width = 300, .height = 140 },
        geometry(area, parent, 400, 200, .{ .max_width = 300, .max_height = 140 }).?,
    );
    try std.testing.expectEqual(
        types.Rect{ .x = -100, .y = -50, .width = 1400, .height = 900 },
        geometry(area, parent, 1400, 900, .{}).?,
    );
    try std.testing.expectEqual(@as(?types.Rect, null), geometry(area, parent, 0, 0, .{}));
}
