// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const discrete_step: i64 = 120;
pub const finger_step: f64 = 50.0;
pub const idle_reset_msec: u32 = 200;

const relevant_modifiers: u32 = 1 | 4 | 8 | 64;
const alt_modifier: u32 = 8;
const super_modifier: u32 = 64;

pub const NavigationAxis = enum(u1) {
    horizontal,
    vertical,
};

pub const Source = enum {
    wheel,
    finger,
};

const Accumulator = struct {
    discrete: i64 = 0,
    continuous: f64 = 0,
    direction: i8 = 0,

    fn reset(accumulator: *Accumulator) void {
        accumulator.* = .{};
    }
};

pub const State = struct {
    accumulators: [2]Accumulator = .{ .{}, .{} },
    active_axis: ?NavigationAxis = null,
    active_source: ?Source = null,
    last_update_msec: ?u32 = null,

    pub fn reset(state: *State) void {
        state.* = .{};
    }

    /// Consume one captured vertical-axis update and return the number of
    /// whole viewport steps it represents. Wheel input uses wlroots' raw v120
    /// units so client scroll_factor policy cannot change notch navigation.
    pub fn update(
        state: *State,
        axis: NavigationAxis,
        source: Source,
        time_msec: u32,
        delta: f64,
        delta_discrete_raw: i32,
    ) i32 {
        if ((state.active_axis != null and state.active_axis.? != axis) or
            (state.active_source != null and state.active_source.? != source) or
            (state.last_update_msec != null and time_msec -% state.last_update_msec.? > idle_reset_msec))
        {
            state.reset();
        }
        state.active_axis = axis;
        state.active_source = source;

        const value: f64 = switch (source) {
            .wheel => @floatFromInt(delta_discrete_raw),
            .finger => delta,
        };
        if (!std.math.isFinite(value)) {
            state.reset();
            return 0;
        }
        if (value == 0) {
            // libinput terminates finger scroll sequences with a zero update.
            // Do not carry a partial gesture into the next sequence.
            if (source == .finger) state.reset();
            return 0;
        }

        state.last_update_msec = time_msec;
        const direction: i8 = if (value < 0) -1 else 1;
        const accumulator = &state.accumulators[@intFromEnum(axis)];
        if (accumulator.direction != 0 and accumulator.direction != direction) accumulator.reset();
        accumulator.direction = direction;

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

/// Resolve the two exact compositor wheel chords. Lock modifiers outside the
/// binding mask are ignored, matching keyboard and pointer-button bindings.
pub fn resolveNavigationAxis(primary_modifier: u32, modifiers: u32) ?NavigationAxis {
    const masked = modifiers & relevant_modifiers;
    if (masked == primary_modifier) return .horizontal;
    const alternate_modifier: u32 = if (primary_modifier == alt_modifier)
        super_modifier
    else
        alt_modifier;
    if (masked == primary_modifier | alternate_modifier) return .vertical;
    return null;
}

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

test "modifier resolution supports Super and Alt primary configurations" {
    try std.testing.expectEqual(NavigationAxis.horizontal, resolveNavigationAxis(super_modifier, super_modifier).?);
    try std.testing.expectEqual(NavigationAxis.vertical, resolveNavigationAxis(super_modifier, super_modifier | alt_modifier).?);
    try std.testing.expectEqual(NavigationAxis.horizontal, resolveNavigationAxis(alt_modifier, alt_modifier).?);
    try std.testing.expectEqual(NavigationAxis.vertical, resolveNavigationAxis(alt_modifier, alt_modifier | super_modifier).?);
}

test "modifier resolution rejects relevant extras and ignores locks" {
    try std.testing.expect(resolveNavigationAxis(super_modifier, super_modifier | 1) == null);
    try std.testing.expect(resolveNavigationAxis(super_modifier, super_modifier | 4) == null);
    try std.testing.expectEqual(
        NavigationAxis.horizontal,
        resolveNavigationAxis(super_modifier, super_modifier | 2 | 16).?,
    );
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
