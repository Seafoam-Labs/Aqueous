// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const actions = @import("../config/actions.zig");

pub const swipe_threshold: f64 = 50.0;
pub const pinch_in_threshold: f64 = 0.8;
pub const pinch_out_threshold: f64 = 1.2;

pub const Completed = struct {
    kind: actions.GestureKind,
    direction: actions.GestureDirection,
    fingers: u8,
};

const Active = union(enum) {
    none,
    swipe: Swipe,
    pinch: Pinch,
};

const Swipe = struct {
    fingers: u8,
    dx: f64 = 0,
    dy: f64 = 0,
};

const Pinch = struct {
    fingers: u8,
    scale: f64 = 1,
};

pub const State = struct {
    active: Active = .none,

    pub fn beginSwipe(state: *State, fingers: u32) bool {
        const finger_count = narrowFingerCount(fingers) orelse {
            state.reset();
            return false;
        };
        state.active = .{ .swipe = .{
            .fingers = finger_count,
            .dx = 0,
            .dy = 0,
        } };
        return true;
    }

    pub fn swipeActive(state: *const State) bool {
        return state.active == .swipe;
    }

    pub fn updateSwipe(state: *State, dx: f64, dy: f64) bool {
        switch (state.active) {
            .swipe => |*swipe| {
                swipe.dx += dx;
                swipe.dy += dy;
                return true;
            },
            else => return false,
        }
    }

    pub fn endSwipe(state: *State, cancelled: bool) ?Completed {
        const active = state.active;
        state.active = .none;

        if (cancelled) return null;

        return switch (active) {
            .swipe => |swipe| resolveSwipe(swipe),
            else => null,
        };
    }

    pub fn beginPinch(state: *State, fingers: u32) bool {
        const finger_count = narrowFingerCount(fingers) orelse {
            state.reset();
            return false;
        };
        state.active = .{ .pinch = .{
            .fingers = finger_count,
            .scale = 1,
        } };
        return true;
    }

    pub fn pinchActive(state: *const State) bool {
        return state.active == .pinch;
    }

    pub fn updatePinch(state: *State, scale: f64) bool {
        switch (state.active) {
            .pinch => |*pinch| {
                // wlroots reports scale relative to the begin event, not the
                // preceding update, so retain the newest value.
                pinch.scale = scale;
                return true;
            },
            else => return false,
        }
    }

    pub fn endPinch(state: *State, cancelled: bool) ?Completed {
        const active = state.active;
        state.active = .none;

        if (cancelled) return null;

        return switch (active) {
            .pinch => |pinch| resolvePinch(pinch),
            else => null,
        };
    }

    pub fn reset(state: *State) void {
        state.active = .none;
    }
};

fn narrowFingerCount(fingers: u32) ?u8 {
    if (fingers > std.math.maxInt(u8)) return null;
    return @intCast(fingers);
}

fn resolveSwipe(swipe: Swipe) ?Completed {
    const abs_dx = @abs(swipe.dx);
    const abs_dy = @abs(swipe.dy);
    if (@max(abs_dx, abs_dy) < swipe_threshold) return null;

    const direction: actions.GestureDirection = if (abs_dx >= abs_dy)
        if (swipe.dx < 0) .left else .right
    else if (swipe.dy < 0)
        .up
    else
        .down;

    return .{
        .kind = .swipe,
        .direction = direction,
        .fingers = swipe.fingers,
    };
}

fn resolvePinch(pinch: Pinch) ?Completed {
    const direction: actions.GestureDirection = if (pinch.scale <= pinch_in_threshold)
        .in
    else if (pinch.scale >= pinch_out_threshold)
        .out
    else
        return null;

    return .{
        .kind = .pinch,
        .direction = direction,
        .fingers = pinch.fingers,
    };
}

test "swipe resolves its dominant axis after crossing the threshold" {
    const cases = [_]struct {
        dx: f64,
        dy: f64,
        direction: actions.GestureDirection,
    }{
        .{ .dx = -60, .dy = 10, .direction = .left },
        .{ .dx = 60, .dy = -10, .direction = .right },
        .{ .dx = 10, .dy = -60, .direction = .up },
        .{ .dx = -10, .dy = 60, .direction = .down },
    };

    for (cases) |case| {
        const completed = resolveSwipe(.{
            .fingers = 3,
            .dx = case.dx,
            .dy = case.dy,
        }).?;
        try std.testing.expectEqual(actions.GestureKind.swipe, completed.kind);
        try std.testing.expectEqual(case.direction, completed.direction);
        try std.testing.expectEqual(@as(u8, 3), completed.fingers);
    }
}

test "swipe below the dominant-axis threshold does not complete" {
    try std.testing.expect(resolveSwipe(.{
        .fingers = 3,
        .dx = swipe_threshold - 1,
        .dy = -(swipe_threshold - 1),
    }) == null);
}

test "swipe state accumulates updates and resets after completion" {
    var state: State = .{};
    try std.testing.expect(state.beginSwipe(3));
    try std.testing.expect(state.swipeActive());
    try std.testing.expect(state.updateSwipe(-30, 2));
    try std.testing.expect(state.updateSwipe(-25, 3));

    const completed = state.endSwipe(false).?;
    try std.testing.expectEqual(actions.GestureDirection.left, completed.direction);
    try std.testing.expect(!state.swipeActive());
    try std.testing.expect(!state.updateSwipe(10, 0));
}

test "cancelled swipe is consumed without completing" {
    var state: State = .{};
    try std.testing.expect(state.beginSwipe(3));
    try std.testing.expect(state.updateSwipe(100, 0));
    try std.testing.expect(state.endSwipe(true) == null);
    try std.testing.expect(!state.swipeActive());
}

test "pinch resolves absolute scale outside its dead zone" {
    const cases = [_]struct {
        scale: f64,
        direction: actions.GestureDirection,
    }{
        .{ .scale = pinch_in_threshold, .direction = .in },
        .{ .scale = pinch_out_threshold, .direction = .out },
    };

    for (cases) |case| {
        var state: State = .{};
        try std.testing.expect(state.beginPinch(4));
        try std.testing.expect(state.pinchActive());
        try std.testing.expect(state.updatePinch(case.scale));
        const completed = state.endPinch(false).?;
        try std.testing.expectEqual(actions.GestureKind.pinch, completed.kind);
        try std.testing.expectEqual(case.direction, completed.direction);
        try std.testing.expectEqual(@as(u8, 4), completed.fingers);
    }
}

test "pinch in the dead zone and invalid finger counts do not complete" {
    var state: State = .{};
    try std.testing.expect(state.beginPinch(4));
    try std.testing.expect(state.updatePinch(1));
    try std.testing.expect(state.endPinch(false) == null);
    try std.testing.expect(!state.beginSwipe(std.math.maxInt(u8) + 1));
}
