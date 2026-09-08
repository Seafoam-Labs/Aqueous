// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const discrete_step: i64 = 120;
pub const finger_step: f64 = 50.0;
pub const idle_reset_msec: u32 = 200;

pub const NavigationAxis = enum(u1) {
    horizontal,
    vertical,
};

pub const Direction = enum {
    up,
    down,
    left,
    right,

    pub fn parse(token: []const u8) ?Direction {
        inline for (.{ .{ "WheelUp", Direction.up }, .{ "WheelDown", Direction.down }, .{ "WheelLeft", Direction.left }, .{ "WheelRight", Direction.right } }) |entry| {
            if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn fromAxis(axis: NavigationAxis, negative: bool) Direction {
        return switch (axis) {
            .horizontal => if (negative) .left else .right,
            .vertical => if (negative) .up else .down,
        };
    }
};

/// These actions preserve the contextual, portrait-aware navigation defaults.
/// Ordinary scroll_viewport_* actions always use their explicitly named axis.
pub const Navigation = struct { axis: NavigationAxis, steps: i32 };

pub fn navigationForVerb(verb: []const u8) ?Navigation {
    const entries = .{
        .{ "builtin:wheel_scroll_left", Navigation{ .axis = .horizontal, .steps = -1 } },
        .{ "builtin:wheel_scroll_right", Navigation{ .axis = .horizontal, .steps = 1 } },
        .{ "builtin:wheel_scroll_up", Navigation{ .axis = .vertical, .steps = -1 } },
        .{ "builtin:wheel_scroll_down", Navigation{ .axis = .vertical, .steps = 1 } },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, verb, entry[0])) return entry[1];
    return null;
}

pub const Source = enum {
    wheel,
    finger,
};

const Accumulator = struct {
    discrete: i64 = 0,
    continuous: f64 = 0,
    direction: i8 = 0,
    source: ?Source = null,
    last_update_msec: ?u32 = null,

    fn reset(accumulator: *Accumulator) void {
        accumulator.* = .{};
    }
};

pub const State = struct {
    accumulators: [2]Accumulator = .{ .{}, .{} },

    pub fn reset(state: *State) void {
        state.* = .{};
    }

    pub fn resetAxis(state: *State, axis: NavigationAxis) void {
        state.accumulators[@intFromEnum(axis)].reset();
    }

    pub fn captured(state: *const State, axis: NavigationAxis) bool {
        return state.accumulators[@intFromEnum(axis)].direction != 0;
    }

    /// Consume one captured axis update and return the number of
    /// whole binding steps it represents. Wheel input uses wlroots' raw v120
    /// units so client scroll_factor policy cannot change notch navigation.
    pub fn update(
        state: *State,
        axis: NavigationAxis,
        source: Source,
        time_msec: u32,
        delta: f64,
        delta_discrete_raw: i32,
    ) i32 {
        const accumulator = &state.accumulators[@intFromEnum(axis)];
        if ((accumulator.source != null and accumulator.source.? != source) or
            (accumulator.last_update_msec != null and time_msec -% accumulator.last_update_msec.? > idle_reset_msec))
        {
            accumulator.reset();
        }
        accumulator.source = source;

        const value: f64 = switch (source) {
            .wheel => @floatFromInt(delta_discrete_raw),
            .finger => delta,
        };
        if (!std.math.isFinite(value)) {
            accumulator.reset();
            return 0;
        }
        if (value == 0) {
            // libinput terminates finger scroll sequences with a zero update.
            // Do not carry a partial gesture into the next sequence.
            if (source == .finger) accumulator.reset();
            return 0;
        }

        const direction: i8 = if (value < 0) -1 else 1;
        if (accumulator.direction != 0 and accumulator.direction != direction) accumulator.reset();
        accumulator.direction = direction;
        accumulator.source = source;
        accumulator.last_update_msec = time_msec;

        return switch (source) {
            .wheel => blk: {
                accumulator.discrete += delta_discrete_raw;
                const steps = @divTrunc(accumulator.discrete, discrete_step);
                accumulator.discrete -= steps * discrete_step;
                break :blk @intCast(steps);
            },
            .finger => blk: {
                accumulator.continuous += delta;
                const steps_float = @trunc(accumulator.continuous / finger_step);
                const steps = std.math.lossyCast(i32, steps_float);
                if (steps == std.math.minInt(i32) or steps == std.math.maxInt(i32)) {
                    accumulator.continuous = 0;
                } else {
                    accumulator.continuous -= @as(f64, @floatFromInt(steps)) * finger_step;
                }
                break :blk steps;
            },
        };
    }
};

/// Scrolling instances arranged with the portrait preference follow their
/// stacked axis: the primary chord scrolls the focused column while the
/// alternate chord keeps column panning reachable. Horizontal instances keep
/// the default axis mapping.
pub fn applyLayoutPreference(axis: NavigationAxis, prefer_vertical: bool) NavigationAxis {
    if (!prefer_vertical) return axis;
    return switch (axis) {
        .horizontal => .vertical,
        .vertical => .horizontal,
    };
}

test "layout preference swaps navigation axes only for vertical instances" {
    try std.testing.expectEqual(NavigationAxis.horizontal, applyLayoutPreference(.horizontal, false));
    try std.testing.expectEqual(NavigationAxis.vertical, applyLayoutPreference(.vertical, false));
    try std.testing.expectEqual(NavigationAxis.vertical, applyLayoutPreference(.horizontal, true));
    try std.testing.expectEqual(NavigationAxis.horizontal, applyLayoutPreference(.vertical, true));
}

test "wheel v120 updates preserve partial notches and emit multiple steps" {
    var state: State = .{};
    try std.testing.expectEqual(@as(i32, 0), state.update(.horizontal, .wheel, 0, 3.75, 30));
    try std.testing.expectEqual(@as(i32, 1), state.update(.horizontal, .wheel, 10, 3.75, 90));
    try std.testing.expectEqual(@as(i32, 2), state.update(.horizontal, .wheel, 20, 30, 240));
}

test "raw wheel notches are independent of scaled client delta" {
    var state: State = .{};
    try std.testing.expectEqual(@as(i32, 1), state.update(.horizontal, .wheel, 0, 1.0, 120));
    try std.testing.expectEqual(@as(i32, -1), state.update(.horizontal, .wheel, 10, -60.0, -120));
}

test "finger input accumulates and resets on direction changes" {
    var state: State = .{};
    try std.testing.expectEqual(@as(i32, 0), state.update(.horizontal, .finger, 0, 30, 0));
    try std.testing.expectEqual(@as(i32, 0), state.update(.horizontal, .finger, 10, -30, 0));
    try std.testing.expectEqual(@as(i32, -1), state.update(.horizontal, .finger, 20, -20, 0));
}

test "idle action and source transitions discard partial bursts" {
    var state: State = .{};
    try std.testing.expectEqual(@as(i32, 0), state.update(.horizontal, .wheel, 0, 0, 60));
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .wheel, 10, 0, 60));
    try std.testing.expectEqual(@as(i32, 1), state.update(.vertical, .wheel, 20, 0, 60));

    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .wheel, 30, 0, 60));
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .wheel, 231, 0, 60));
    try std.testing.expectEqual(@as(i32, 1), state.update(.vertical, .wheel, 240, 0, 60));

    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .finger, 250, 25, 0));
    try std.testing.expectEqual(@as(i32, 1), state.update(.vertical, .finger, 260, 25, 0));
}

test "finger stop and explicit reset discard partial gestures" {
    var state: State = .{};
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .finger, 0, 30, 0));
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .finger, 10, 0, 0));
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .finger, 20, 20, 0));
    state.reset();
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .finger, 30, 30, 0));
    try std.testing.expectEqual(@as(i32, 1), state.update(.vertical, .finger, 40, 20, 0));
}

test "interleaved physical axes keep independent partial steps and stops" {
    var state: State = .{};
    try std.testing.expectEqual(@as(i32, 0), state.update(.horizontal, .wheel, 0, 0, 60));
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .wheel, 10, 0, -60));
    try std.testing.expectEqual(@as(i32, 1), state.update(.horizontal, .wheel, 20, 0, 60));
    try std.testing.expectEqual(@as(i32, -1), state.update(.vertical, .wheel, 30, 0, -60));
    try std.testing.expectEqual(@as(i32, 0), state.update(.horizontal, .finger, 40, 30, 0));
    try std.testing.expectEqual(@as(i32, 0), state.update(.vertical, .finger, 50, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), state.update(.horizontal, .finger, 60, 20, 0));
    try std.testing.expectEqual(@as(i32, 0), state.update(.horizontal, .wheel, 70, 0, 60));
    state.resetAxis(.vertical);
    try std.testing.expectEqual(@as(i32, 1), state.update(.horizontal, .wheel, 80, 0, 60));
}

test "wheel directions and navigation verbs distinguish physical and layout axes" {
    try std.testing.expectEqual(Direction.up, Direction.fromAxis(.vertical, true));
    try std.testing.expectEqual(Direction.down, Direction.fromAxis(.vertical, false));
    try std.testing.expectEqual(Direction.left, Direction.fromAxis(.horizontal, true));
    try std.testing.expectEqual(Direction.right, Direction.fromAxis(.horizontal, false));
    const navigation = navigationForVerb("builtin:wheel_scroll_left").?;
    try std.testing.expectEqual(NavigationAxis.horizontal, navigation.axis);
    try std.testing.expectEqual(@as(i32, -1), navigation.steps);
    try std.testing.expectEqual(NavigationAxis.vertical, applyLayoutPreference(navigation.axis, true));
    try std.testing.expect(navigationForVerb("builtin:scroll_viewport_left") == null);
    try std.testing.expect(navigationForVerb("builtin:wheel_scroll_left_unknown") == null);
}
