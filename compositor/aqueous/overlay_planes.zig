// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Backend-independent policy and accounting for one DRM overlay candidate per
//! output. This module deliberately owns no wlroots or Window pointers so that
//! rejection/backoff and fallback behavior can be tested without DRM hardware.

const std = @import("std");

pub const initial_backoff_ms: u32 = 250;
pub const maximum_backoff_ms: u32 = 4_000;

pub const Capability = enum(u32) {
    unknown,
    available,
    unavailable,
};

pub const Phase = enum(u32) {
    disabled,
    unavailable,
    idle,
    testing,
    promoted,
    backed_off,
    fallback,
};

/// Values and names are part of the aqueousctl JSON compatibility surface.
pub const RejectionReason = enum(u32) {
    none,
    globally_disabled,
    backend_unavailable,
    no_candidate,
    candidate_destroyed,
    not_visible,
    not_opaque,
    transformed,
    scaled,
    clipped,
    effects_active,
    intersected,
    capture_active,
    session_locked,
    session_inactive,
    software_cursor,
    no_dmabuf,
    explicit_sync_unavailable,
    backend_test_rejected,
    promoted_commit_failed,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

/// A rejection cache key intentionally describes assignment compatibility, not
/// a particular swapchain buffer pointer. Games rotate buffers every frame;
/// including the pointer would defeat rejection suppression for a format and
/// geometry the KMS plane has already rejected.
pub const AssignmentKey = struct {
    candidate_id: u64,
    output_generation: u64,
    format: u32,
    modifier: u64,
    buffer_width: i32,
    buffer_height: i32,
    destination: Rect,
    output_scale_bits: u32,
    output_transform: u32,
    output_width: i32,
    output_height: i32,
    adaptive_sync: bool,
    blocker_generation: u64 = 0,

    pub fn eql(a: AssignmentKey, b: AssignmentKey) bool {
        return std.meta.eql(a, b);
    }
};

pub const CandidateScore = struct {
    currently_promoted: bool,
    focused_fullscreen: bool,
    focused: bool,
    fullscreen: bool,
    visible_area: u64,
    stable_id: u64,

    /// A stable ID wins the final tie in ascending order so selection is not
    /// affected by hash-map/list iteration order.
    pub fn betterThan(candidate: CandidateScore, current: CandidateScore) bool {
        inline for (.{
            "currently_promoted",
            "focused_fullscreen",
            "focused",
            "fullscreen",
        }) |field| {
            const a = @field(candidate, field);
            const b = @field(current, field);
            if (a != b) return a;
        }
        if (candidate.visible_area != current.visible_area) {
            return candidate.visible_area > current.visible_area;
        }
        return candidate.stable_id < current.stable_id;
    }
};

pub const Counters = struct {
    attempts: u64 = 0,
    accepted_tests: u64 = 0,
    backend_rejections: u64 = 0,
    backoff_skips: u64 = 0,
    fallback_retries: u64 = 0,
    promotions: u64 = 0,
    demotions: u64 = 0,
};

pub const Snapshot = struct {
    enabled: bool,
    capability: Capability,
    phase: Phase,
    reason: RejectionReason,
    candidate_id: u64,
    destination: Rect,
    format: u32,
    modifier: u64,
    backoff_remaining_ms: u32,
    counters: Counters,
};

pub const State = struct {
    enabled: bool = false,
    capability: Capability = .unknown,
    phase: Phase = .disabled,
    reason: RejectionReason = .globally_disabled,
    candidate_id: u64 = 0,
    committed_candidate_id: u64 = 0,
    destination: Rect = .{},
    format: u32 = 0,
    modifier: u64 = 0,
    committed: bool = false,

    pending_key: ?AssignmentKey = null,
    rejected_key: ?AssignmentKey = null,
    rejected_reason: RejectionReason = .none,
    backoff_until_ms: u64 = 0,
    next_backoff_ms: u32 = initial_backoff_ms,
    counters: Counters = .{},

    /// Incremented by the owner on modeset, renderer reset, or another change
    /// that invalidates cached plane capabilities.
    capability_generation: u64 = 1,
    blocker_generation: u64 = 0,
    transition_sequence: u64 = 0,
    trace_budget: u32 = 0,

    pub fn configure(state: *State, enabled: bool, capable: bool) void {
        state.enabled = enabled;
        // Creating the backend layer proves that the API exists, not that a
        // physical plane can accept this output/candidate combination.
        state.capability = if (capable) .unknown else .unavailable;
        if (!enabled) {
            state.setStatus(.disabled, .globally_disabled);
        } else if (!capable) {
            state.setStatus(.unavailable, .backend_unavailable);
        } else if (state.phase == .disabled or state.phase == .unavailable) {
            state.setStatus(.idle, .no_candidate);
        }
    }

    pub fn invalidateCapabilities(state: *State) void {
        state.capability_generation +%= 1;
        if (state.capability_generation == 0) state.capability_generation = 1;
        state.clearBackoff();
    }

    pub fn invalidateBlockers(state: *State) void {
        state.blocker_generation +%= 1;
        state.clearBackoff();
    }

    pub fn setIneligible(state: *State, reason: RejectionReason) void {
        state.clearBackoff();
        state.pending_key = null;
        state.candidate_id = 0;
        state.destination = .{};
        state.format = 0;
        state.modifier = 0;
        state.setStatus(.idle, reason);
    }

    pub fn setCandidateIneligible(
        state: *State,
        candidate_id: u64,
        destination: Rect,
        reason: RejectionReason,
    ) void {
        state.clearBackoff();
        state.pending_key = null;
        state.candidate_id = candidate_id;
        state.destination = destination;
        state.format = 0;
        state.modifier = 0;
        state.setStatus(.idle, reason);
    }

    pub fn shouldAttempt(state: *State, key: AssignmentKey, now_ms: u64) bool {
        state.candidate_id = key.candidate_id;
        state.destination = key.destination;
        state.format = key.format;
        state.modifier = key.modifier;

        if (state.rejected_key) |rejected| {
            if (rejected.eql(key) and now_ms < state.backoff_until_ms) {
                state.pending_key = null;
                state.counters.backoff_skips +%= 1;
                state.setStatus(.backed_off, state.rejected_reason);
                return false;
            }
            if (!rejected.eql(key)) state.clearBackoff();
        }

        state.pending_key = key;
        state.setStatus(.testing, .none);
        return true;
    }

    pub fn recordTestAccepted(state: *State) void {
        state.counters.attempts +%= 1;
        state.counters.accepted_tests +%= 1;
        state.rejected_key = null;
        state.rejected_reason = .none;
        state.backoff_until_ms = 0;
        state.next_backoff_ms = initial_backoff_ms;
        state.capability = .available;
        state.setStatus(.testing, .none);
    }

    pub fn recordTestRejected(
        state: *State,
        reason: RejectionReason,
        now_ms: u64,
    ) void {
        const key = state.pending_key orelse return;
        state.counters.attempts +%= 1;
        state.pending_key = null;
        state.rejected_key = key;
        state.rejected_reason = reason;
        if (reason == .backend_test_rejected) state.counters.backend_rejections +%= 1;
        state.backoff_until_ms = now_ms + state.next_backoff_ms;
        state.next_backoff_ms = @min(state.next_backoff_ms *| 2, maximum_backoff_ms);
        state.setStatus(.backed_off, reason);
    }

    pub fn recordEligibilityRejected(
        state: *State,
        reason: RejectionReason,
        now_ms: u64,
    ) void {
        const key = state.pending_key orelse return;
        state.pending_key = null;
        state.rejected_key = key;
        state.rejected_reason = reason;
        state.backoff_until_ms = now_ms + state.next_backoff_ms;
        state.next_backoff_ms = @min(state.next_backoff_ms *| 2, maximum_backoff_ms);
        state.setStatus(.backed_off, reason);
    }

    pub fn recordCommitSuccess(state: *State, promoted: bool) void {
        state.pending_key = null;
        if (promoted != state.committed) {
            if (promoted) state.counters.promotions +%= 1 else state.counters.demotions +%= 1;
            state.transition_sequence +%= 1;
        }
        state.committed = promoted;
        state.committed_candidate_id = if (promoted) state.candidate_id else 0;
        state.setStatus(
            if (promoted) .promoted else if (state.rejected_key != null) .backed_off else .idle,
            if (promoted) .none else state.reason,
        );
    }

    pub fn recordPromotedCommitFailure(state: *State, now_ms: u64) void {
        if (state.pending_key) |assignment| {
            state.rejected_key = assignment;
            state.rejected_reason = .promoted_commit_failed;
            state.backoff_until_ms = now_ms + state.next_backoff_ms;
            state.next_backoff_ms = @min(state.next_backoff_ms *| 2, maximum_backoff_ms);
        }
        state.pending_key = null;
        state.counters.fallback_retries +%= 1;
        if (state.committed) state.counters.demotions +%= 1;
        state.committed = false;
        state.committed_candidate_id = 0;
        state.transition_sequence +%= 1;
        state.setStatus(.fallback, .promoted_commit_failed);
    }

    pub fn snapshot(state: *const State, now_ms: u64) Snapshot {
        const remaining: u32 = if (state.backoff_until_ms > now_ms)
            @intCast(@min(state.backoff_until_ms - now_ms, std.math.maxInt(u32)))
        else
            0;
        return .{
            .enabled = state.enabled,
            .capability = state.capability,
            .phase = state.phase,
            .reason = state.reason,
            .candidate_id = state.candidate_id,
            .destination = state.destination,
            .format = state.format,
            .modifier = state.modifier,
            .backoff_remaining_ms = remaining,
            .counters = state.counters,
        };
    }

    fn clearBackoff(state: *State) void {
        state.rejected_key = null;
        state.rejected_reason = .none;
        state.backoff_until_ms = 0;
        state.next_backoff_ms = initial_backoff_ms;
    }

    fn setStatus(state: *State, phase: Phase, reason: RejectionReason) void {
        state.phase = phase;
        state.reason = reason;
    }
};

fn testKey(id: u64) AssignmentKey {
    return .{
        .candidate_id = id,
        .output_generation = 1,
        .format = 0x34325258,
        .modifier = 7,
        .buffer_width = 3840,
        .buffer_height = 2112,
        .destination = .{ .x = 1920, .width = 3840, .height = 2112 },
        .output_scale_bits = @bitCast(@as(f32, 1)),
        .output_transform = 0,
        .output_width = 7680,
        .output_height = 2160,
        .adaptive_sync = false,
    };
}

test "candidate arbitration is deterministic" {
    const base: CandidateScore = .{
        .currently_promoted = false,
        .focused_fullscreen = false,
        .focused = false,
        .fullscreen = false,
        .visible_area = 100,
        .stable_id = 9,
    };
    var focused = base;
    focused.focused = true;
    try std.testing.expect(focused.betterThan(base));

    var promoted = base;
    promoted.currently_promoted = true;
    try std.testing.expect(promoted.betterThan(focused));

    var lower_id = base;
    lower_id.stable_id = 2;
    try std.testing.expect(lower_id.betterThan(base));
}

test "rejected assignment backs off and changed assignment retries immediately" {
    var state: State = .{};
    state.configure(true, true);
    const first = testKey(1);
    try std.testing.expect(state.shouldAttempt(first, 1_000));
    state.recordTestRejected(.backend_test_rejected, 1_000);
    try std.testing.expect(!state.shouldAttempt(first, 1_100));
    try std.testing.expectEqual(@as(u64, 1), state.counters.backoff_skips);

    var changed = first;
    changed.modifier = 8;
    try std.testing.expect(state.shouldAttempt(changed, 1_100));
}

test "backoff is exponential and capped" {
    var state: State = .{};
    state.configure(true, true);
    const assignment = testKey(1);
    var now: u64 = 0;
    var previous: u32 = 0;
    for (0..8) |_| {
        now = state.backoff_until_ms;
        try std.testing.expect(state.shouldAttempt(assignment, now));
        state.recordTestRejected(.backend_test_rejected, now);
        const remaining = state.snapshot(now).backoff_remaining_ms;
        try std.testing.expect(remaining >= previous);
        try std.testing.expect(remaining <= maximum_backoff_ms);
        previous = remaining;
    }
    try std.testing.expectEqual(maximum_backoff_ms, previous);
}

test "promoted commit failure requests exactly one accounted fallback" {
    var state: State = .{};
    state.configure(true, true);
    try std.testing.expect(state.shouldAttempt(testKey(1), 0));
    state.recordTestAccepted();
    state.recordCommitSuccess(true);
    try std.testing.expect(state.shouldAttempt(testKey(1), 5));
    state.recordTestAccepted();
    state.recordPromotedCommitFailure(10);
    try std.testing.expectEqual(@as(u64, 1), state.counters.fallback_retries);
    try std.testing.expectEqual(Phase.fallback, state.phase);
    try std.testing.expect(!state.committed);
    try std.testing.expect(!state.shouldAttempt(testKey(1), 100));
}
