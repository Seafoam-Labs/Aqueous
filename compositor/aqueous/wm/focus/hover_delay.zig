// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Handle = u64;

pub const Action = union(enum) {
    none,
    disarm,
    immediate: Handle,
    arm: i32,
};

pub const State = struct {
    pending: ?Handle = null,

    /// Process a real pointer-motion hover update. Repeated motion over the
    /// same target intentionally re-arms the timer, making the configured
    /// delay a dwell period rather than an age attached to the window.
    pub fn hover(
        state: *State,
        target: ?Handle,
        focused: ?Handle,
        delayed: bool,
        delay_ms: i32,
    ) Action {
        const handle = target orelse return state.cancelAction();
        if (focused == handle) return state.cancelAction();
        if (!delayed or delay_ms == 0) {
            state.pending = null;
            return .{ .immediate = handle };
        }
        state.pending = handle;
        return .{ .arm = delay_ms };
    }

    pub fn cancel(state: *State) bool {
        const armed = state.pending != null;
        state.pending = null;
        return armed;
    }

    /// Consume the pending request and return it only if the compositor's
    /// current pointer/focus/layout state still agrees with the request.
    pub fn expire(
        state: *State,
        hovered: ?Handle,
        focused: ?Handle,
        valid_context: bool,
    ) ?Handle {
        const target = state.pending orelse return null;
        state.pending = null;
        if (!valid_context or hovered != target or focused == target) return null;
        return target;
    }

    fn cancelAction(state: *State) Action {
        return if (state.cancel()) .disarm else .none;
    }
};

test "zero delay and non-scrolling targets focus immediately" {
    var state: State = .{};
    try std.testing.expectEqual(Action{ .immediate = 2 }, state.hover(2, 1, true, 0));
    try std.testing.expectEqual(Action{ .immediate = 3 }, state.hover(3, 1, false, 150));
    try std.testing.expectEqual(@as(?Handle, null), state.pending);
}

test "motion arms and resets a delayed hover request" {
    var state: State = .{};
    try std.testing.expectEqual(Action{ .arm = 150 }, state.hover(2, 1, true, 150));
    try std.testing.expectEqual(@as(?Handle, 2), state.pending);
    try std.testing.expectEqual(Action{ .arm = 150 }, state.hover(2, 1, true, 150));
    try std.testing.expectEqual(Action{ .arm = 150 }, state.hover(3, 1, true, 150));
    try std.testing.expectEqual(@as(?Handle, 3), state.pending);
}

test "null hover, current focus, and explicit focus cancel pending requests" {
    var state: State = .{};
    _ = state.hover(2, 1, true, 150);
    try std.testing.expectEqual(Action.disarm, state.hover(null, 1, true, 150));
    try std.testing.expectEqual(Action.none, state.hover(null, 1, true, 150));
    _ = state.hover(2, 1, true, 150);
    try std.testing.expectEqual(Action.disarm, state.hover(2, 2, true, 150));
    _ = state.hover(3, 2, true, 150);
    try std.testing.expect(state.cancel());
    try std.testing.expect(!state.cancel());
}

test "expiry revalidates hover focus and scrolling context" {
    var state: State = .{};
    _ = state.hover(2, 1, true, 150);
    try std.testing.expectEqual(@as(?Handle, 2), state.expire(2, 1, true));

    _ = state.hover(2, 1, true, 150);
    try std.testing.expectEqual(@as(?Handle, null), state.expire(3, 1, true));
    _ = state.hover(2, 1, true, 150);
    try std.testing.expectEqual(@as(?Handle, null), state.expire(2, 2, true));
    _ = state.hover(2, 1, true, 150);
    try std.testing.expectEqual(@as(?Handle, null), state.expire(2, 1, false));
}
