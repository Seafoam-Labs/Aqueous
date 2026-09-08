// SPDX-License-Identifier: GPL-3.0-only
//! Allocation-free output recovery policy. Times are monotonic milliseconds.
const std = @import("std");

pub const Stage = enum { scene_build, output_commit, fallback_build, fallback_commit };
pub const Outcome = union(enum) { skipped, committed, failed: Stage };

pub const State = struct {
    pending: bool = false,
    failures: u32 = 0,
    total_failures: u64 = 0,
    retries: u64 = 0,
    started_ms: u64 = 0,
    deadline_ms: u64 = 0,
    last_attempt_ms: u64 = 0,
    last_log_ms: u64 = 0,
    last_stage: Stage = .scene_build,
    frame_requested: bool = false,
    recovery_commit: ?u32 = null,
    accepted_commit: ?u32 = null,
    presented_commit: ?u32 = null,

    pub fn delayMs(refresh_mhz: i32, failures: u32) u32 {
        const period: u32 = if (refresh_mhz > 0)
            @intCast((@as(u64, 1_000_000) + @as(u32, @intCast(refresh_mhz)) - 1) / @as(u32, @intCast(refresh_mhz)))
        else
            16;
        const base = std.math.clamp(period, 8, 1000);
        return @min(1000, base << @as(u5, @intCast(@min(failures -| 1, 7))));
    }

    pub fn ready(state: State, now_ms: u64) bool {
        return !state.pending or now_ms >= state.deadline_ms;
    }

    pub fn attempted(state: *State, now_ms: u64) void {
        std.debug.assert(state.ready(now_ms));
        if (state.pending) state.retries +|= 1;
        state.last_attempt_ms = now_ms;
        state.frame_requested = false;
    }

    /// Returns whether this failure needs a log message.
    pub fn failed(state: *State, stage: Stage, now_ms: u64, refresh_mhz: i32) bool {
        const first = !state.pending;
        if (first) state.started_ms = now_ms;
        state.pending = true;
        state.failures +|= 1;
        state.total_failures +|= 1;
        state.last_stage = stage;
        state.deadline_ms = now_ms +| delayMs(refresh_mhz, state.failures);
        state.frame_requested = false;
        state.recovery_commit = null;
        const should_log = first or now_ms -| state.last_log_ms >= 5000;
        if (should_log) state.last_log_ms = now_ms;
        return should_log;
    }

    pub fn committed(state: *State, sequence: u32) bool {
        const recovering = state.pending;
        if (recovering) state.recovery_commit = sequence;
        state.accepted_commit = sequence;
        state.pending = false;
        state.failures = 0;
        state.deadline_ms = 0;
        state.frame_requested = false;
        return recovering;
    }

    pub fn presented(state: *State, sequence: u32, success: bool) bool {
        const recovery = state.recovery_commit orelse return false;
        const accepted = state.accepted_commit orelse return false;
        // A later successfully presented buffer also proves output recovery.
        // Wrapping serial comparison rejects both stale and future events.
        if (!success or sequence -% recovery >= 0x80000000 or accepted -% sequence >= 0x80000000) return false;
        state.presented_commit = sequence;
        state.recovery_commit = null;
        return true;
    }

    pub fn cancel(state: *State) void {
        state.pending = false;
        state.failures = 0;
        state.deadline_ms = 0;
        state.frame_requested = false;
        state.recovery_commit = null;
        state.accepted_commit = null;
    }
};

test "backoff respects refresh, caps rate, and saturates counters" {
    try std.testing.expectEqual(@as(u32, 8), State.delayMs(180000, 1));
    try std.testing.expectEqual(@as(u32, 17), State.delayMs(60000, 1));
    try std.testing.expectEqual(@as(u32, 16), State.delayMs(0, 1));
    try std.testing.expectEqual(@as(u32, 1000), State.delayMs(1, 1));
    var state: State = .{};
    var now: u64 = 100;
    for (0..30) |_| {
        state.attempted(now);
        _ = state.failed(.output_commit, now, 180000);
        try std.testing.expect(!state.ready(state.deadline_ms - 1));
        try std.testing.expect(state.ready(state.deadline_ms));
        now = state.deadline_ms;
    }
    try std.testing.expectEqual(@as(u64, 1000), state.deadline_ms - state.last_attempt_ms);
    state.failures = std.math.maxInt(u32);
    state.total_failures = std.math.maxInt(u64);
    _ = state.failed(.scene_build, std.math.maxInt(u64) - 1, 180000);
    try std.testing.expectEqual(std.math.maxInt(u64), state.deadline_ms);
    try std.testing.expectEqual(std.math.maxInt(u32), state.failures);
}

test "unrelated frame requests cannot reset or postpone recovery; commit does" {
    var state: State = .{};
    try std.testing.expect(state.failed(.fallback_commit, 100, 60000));
    for (101..117) |now| try std.testing.expect(!state.ready(now));
    try std.testing.expectEqual(@as(u64, 117), state.deadline_ms);
    state.attempted(117);
    try std.testing.expect(!state.failed(.fallback_build, 117, 60000));
    try std.testing.expectEqual(@as(u64, 151), state.deadline_ms);
    try std.testing.expect(state.failed(.scene_build, 5200, 60000));
    try std.testing.expect(state.committed(42));
    try std.testing.expect(!state.pending);
    try std.testing.expectEqual(@as(u32, 0), state.failures);
    try std.testing.expect(!state.presented(41, true));
    try std.testing.expect(!state.presented(42, false));
    try std.testing.expect(!state.presented(43, true));
    try std.testing.expect(state.presented(42, true));
    try std.testing.expect(!state.presented(42, true));
}

test "presentation tracking handles wrapping serials, superseding commits and cancellation" {
    var state: State = .{};
    _ = state.failed(.output_commit, 0, 180000);
    _ = state.committed(std.math.maxInt(u32));
    _ = state.committed(0);
    try std.testing.expect(!state.presented(std.math.maxInt(u32) - 1, true));
    try std.testing.expect(state.presented(0, true));
    _ = state.failed(.output_commit, 1, 180000);
    _ = state.committed(1);
    state.cancel();
    try std.testing.expect(!state.presented(1, true));
    try std.testing.expect(!state.pending);
}
