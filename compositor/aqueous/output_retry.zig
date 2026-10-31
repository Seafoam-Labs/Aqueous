// SPDX-License-Identifier: GPL-3.0-only
//! Allocation-free output recovery policy. Times are monotonic milliseconds.
const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;

pub const Stage = enum { scene_build, output_commit, fallback_build, fallback_commit };
pub const Outcome = union(enum) { skipped, committed, failed: Stage };

pub const State = struct {
    pub const scene_build_recover_threshold: u8 = 8;

    pending: bool = false,
    failures: u32 = 0,
    copy_failures: u8 = 0,
    scene_build_failures: u8 = 0,
    renderer_recovery_requested: bool = false,
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

    /// Count failed frame commits, not scene-build or synchronization failures.
    /// The caller invokes this only while the output uses direct presentation.
    pub fn allowCopyAfterFailure(state: *State, stage: Stage) bool {
        if (stage != .output_commit and stage != .fallback_commit) return false;
        state.copy_failures = @min(state.copy_failures + 1, 5);
        return state.copy_failures == 5;
    }

    /// Track consecutive real scene-build failures and request a one-shot
    /// renderer recovery once the streak reaches `scene_build_recover_threshold`.
    pub fn shouldRecoverRenderer(state: *State, stage: Stage) bool {
        if (stage != .scene_build and stage != .fallback_build) return false;
        state.scene_build_failures = @min(
            state.scene_build_failures + 1,
            scene_build_recover_threshold,
        );
        if (state.scene_build_failures < scene_build_recover_threshold or
            state.renderer_recovery_requested)
        {
            return false;
        }
        state.renderer_recovery_requested = true;
        return true;
    }

    pub fn resetSceneBuildStreak(state: *State) void {
        state.scene_build_failures = 0;
    }

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
        state.copy_failures = 0;
        state.scene_build_failures = 0;
        state.renderer_recovery_requested = false;
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
        state.copy_failures = 0;
        state.scene_build_failures = 0;
        state.renderer_recovery_requested = false;
        state.pending = false;
        state.failures = 0;
        state.deadline_ms = 0;
        state.frame_requested = false;
        state.recovery_commit = null;
        state.accepted_commit = null;
    }
};

/// Emergency file-descriptor reserve released immediately before recreating a
/// lost Vulkan renderer so device/DRM/pipeline setup can succeed at EMFILE.
pub const FdReserve = struct {
    pub const capacity = 64;
    pub const min_soft_limit: u64 = 256;

    fds: [capacity]i32 = @splat(-1),

    pub fn fill(reserve: *FdReserve) void {
        if (comptime builtin.os.tag != .linux) return;
        const soft = queryNofileSoftLimit() orelse return;
        if (soft < min_soft_limit) return;
        for (&reserve.fds) |*slot| {
            if (slot.* >= 0) continue;
            const rc = linux.open("/dev/null", .{ .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) break;
            slot.* = @intCast(rc);
        }
    }

    pub fn release(reserve: *FdReserve) usize {
        if (comptime builtin.os.tag != .linux) return 0;
        var closed: usize = 0;
        for (&reserve.fds) |*slot| {
            if (slot.* >= 0) {
                _ = linux.close(slot.*);
                slot.* = -1;
                closed += 1;
            }
        }
        return closed;
    }

    pub fn heldCount(reserve: *const FdReserve) usize {
        var n: usize = 0;
        for (reserve.fds) |fd| {
            if (fd >= 0) n += 1;
        }
        return n;
    }
};

/// Allocation-free policy for proactive renderer refresh when process FD usage
/// crosses a high-water mark well below RLIMIT_NOFILE.
pub const FdPressure = struct {
    pub const check_interval_frames: u32 = 512;
    pub const min_soft_limit_for_refresh: u64 = 2048;
    pub const headroom: u64 = 512;
    pub const max_threshold: u64 = 16_384;
    pub const cooldown_ms: u64 = 60_000;

    committed_frames: u32 = 0,
    last_recovery_ms: ?u64 = null,

    pub fn highWaterThreshold(soft_limit: u64) ?u64 {
        if (soft_limit < min_soft_limit_for_refresh) return null;
        return @min(max_threshold, soft_limit - headroom);
    }

    pub fn pollDue(pressure: *FdPressure) bool {
        pressure.committed_frames +%= 1;
        return (pressure.committed_frames % check_interval_frames) == 0;
    }

    pub fn shouldTriggerRecovery(
        pressure: *FdPressure,
        open_fds: u64,
        soft_limit: u64,
        now_ms: u64,
    ) bool {
        const threshold = highWaterThreshold(soft_limit) orelse return false;
        if (open_fds < threshold) return false;
        if (pressure.last_recovery_ms) |last_ms| {
            if (now_ms -| last_ms < cooldown_ms) return false;
        }
        pressure.last_recovery_ms = now_ms;
        return true;
    }
};

pub fn queryNofileSoftLimit() ?u64 {
    if (comptime builtin.os.tag != .linux) return null;
    var rlim: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.NOFILE, &rlim)) != .SUCCESS) return null;
    return @intCast(rlim.cur);
}

/// Count open file descriptors up to `stop_at` without heap allocation.
pub fn countOpenFdsBounded(soft_limit: u64, stop_at: u64) ?u64 {
    if (comptime builtin.os.tag != .linux) return null;
    if (stop_at == 0) return 0;

    const open_rc = linux.open("/proc/self/fd", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    switch (linux.errno(open_rc)) {
        .SUCCESS => {
            const dir_fd: i32 = @intCast(open_rc);
            defer _ = linux.close(dir_fd);
            var raw_entries: u64 = 0;
            var buf: [4096]u8 align(8) = undefined;
            while (true) {
                const n = linux.getdents64(dir_fd, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS) return null;
                if (n == 0) return raw_entries -| 1;
                var offset: usize = 0;
                while (offset < n) {
                    const entry: *const linux.dirent64 = @ptrCast(@alignCast(&buf[offset]));
                    const name = std.mem.span(@as([*:0]const u8, @ptrCast(&buf[offset + @offsetOf(linux.dirent64, "name")])));
                    offset += entry.reclen;
                    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                    raw_entries += 1;
                    if (raw_entries -| 1 >= stop_at) return raw_entries -| 1;
                }
            }
        },
        .MFILE => return soft_limit,
        else => {
            const scan_limit: usize = @intCast(@min(soft_limit, 65_536));
            var count: u64 = 0;
            for (0..scan_limit) |fd| {
                const rc = linux.fcntl(@intCast(fd), linux.F.GETFD, 0);
                if (linux.errno(rc) == .SUCCESS) {
                    count += 1;
                    if (count >= stop_at) return count;
                }
            }
            return count;
        },
    }
}

test "copy fallback requires five failed commits on the same output and resets on success" {
    var first: State = .{};
    var second: State = .{};
    for (0..4) |_| try std.testing.expect(!first.allowCopyAfterFailure(.output_commit));
    try std.testing.expect(!first.allowCopyAfterFailure(.scene_build));
    try std.testing.expect(!first.allowCopyAfterFailure(.fallback_build));
    try std.testing.expect(!second.allowCopyAfterFailure(.output_commit));
    try std.testing.expect(first.allowCopyAfterFailure(.fallback_commit));
    for (0..300) |_| try std.testing.expect(first.allowCopyAfterFailure(.output_commit));
    _ = first.committed(1);
    for (0..4) |_| try std.testing.expect(!first.allowCopyAfterFailure(.output_commit));
    first.cancel();
    try std.testing.expect(!first.allowCopyAfterFailure(.output_commit));
    try std.testing.expectEqual(@as(u8, 1), second.copy_failures);
}

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

test "scene-build recovery escalation is one-shot per failure episode and resets on build/commit/cancel" {
    var state: State = .{};
    for (0..20) |_| try std.testing.expect(!state.shouldRecoverRenderer(.output_commit));
    for (0..20) |_| try std.testing.expect(!state.shouldRecoverRenderer(.fallback_commit));
    try std.testing.expectEqual(@as(u8, 0), state.scene_build_failures);

    for (0..State.scene_build_recover_threshold - 1) |_| {
        try std.testing.expect(!state.shouldRecoverRenderer(.scene_build));
    }
    state.resetSceneBuildStreak();
    try std.testing.expectEqual(@as(u8, 0), state.scene_build_failures);

    for (0..State.scene_build_recover_threshold - 1) |_| {
        try std.testing.expect(!state.shouldRecoverRenderer(.scene_build));
    }
    try std.testing.expect(state.shouldRecoverRenderer(.fallback_build));
    for (0..16) |_| {
        try std.testing.expect(!state.shouldRecoverRenderer(.scene_build));
    }

    // Even if a transient build succeeds before output commit succeeds, do not
    // re-request renderer recovery inside the same unrecovered episode.
    state.resetSceneBuildStreak();
    for (0..State.scene_build_recover_threshold) |_| {
        try std.testing.expect(!state.shouldRecoverRenderer(.scene_build));
    }

    _ = state.committed(7);
    try std.testing.expect(!state.renderer_recovery_requested);
    try std.testing.expectEqual(@as(u8, 0), state.scene_build_failures);
    for (0..State.scene_build_recover_threshold - 1) |_| {
        try std.testing.expect(!state.shouldRecoverRenderer(.scene_build));
    }
    try std.testing.expect(state.shouldRecoverRenderer(.scene_build));

    state.cancel();
    try std.testing.expect(!state.renderer_recovery_requested);
    try std.testing.expectEqual(@as(u8, 0), state.scene_build_failures);
}

test "FD high-water threshold, polling cadence, cooldown, and emergency FD reserve" {
    try std.testing.expectEqual(@as(?u64, null), FdPressure.highWaterThreshold(0));
    try std.testing.expectEqual(@as(?u64, null), FdPressure.highWaterThreshold(1024));
    try std.testing.expectEqual(@as(?u64, 1536), FdPressure.highWaterThreshold(2048));
    try std.testing.expectEqual(@as(?u64, 3584), FdPressure.highWaterThreshold(4096));
    try std.testing.expectEqual(@as(?u64, 16_384), FdPressure.highWaterThreshold(65_536));
    try std.testing.expectEqual(@as(?u64, 16_384), FdPressure.highWaterThreshold(1_048_576));

    var pressure: FdPressure = .{};
    for (0..FdPressure.check_interval_frames - 1) |_| {
        try std.testing.expect(!pressure.pollDue());
    }
    try std.testing.expect(pressure.pollDue());

    // Early monotonic boot timestamps (< cooldown_ms) must still allow the first trigger.
    try std.testing.expect(!pressure.shouldTriggerRecovery(16_383, 65_536, 500));
    try std.testing.expect(pressure.shouldTriggerRecovery(16_384, 65_536, 500));
    try std.testing.expect(!pressure.shouldTriggerRecovery(20_000, 65_536, 60_499));
    try std.testing.expect(pressure.shouldTriggerRecovery(16_384, 65_536, 60_500));

    if (comptime builtin.os.tag == .linux) {
        const soft = queryNofileSoftLimit() orelse return error.SkipZigTest;
        if (soft >= FdReserve.min_soft_limit) {
            const before = countOpenFdsBounded(soft, soft) orelse return error.Unexpected;
            var reserve: FdReserve = .{};
            reserve.fill();
            defer _ = reserve.release();
            try std.testing.expectEqual(@as(usize, FdReserve.capacity), reserve.heldCount());
            const during = countOpenFdsBounded(soft, soft) orelse return error.Unexpected;
            try std.testing.expectEqual(before + FdReserve.capacity, during);
            const capped = countOpenFdsBounded(soft, before + 8) orelse return error.Unexpected;
            try std.testing.expectEqual(before + 8, capped);
            try std.testing.expectEqual(@as(usize, FdReserve.capacity), reserve.release());
            try std.testing.expectEqual(@as(usize, 0), reserve.heldCount());
            const after = countOpenFdsBounded(soft, soft) orelse return error.Unexpected;
            try std.testing.expectEqual(before, after);
        }
    }
}
