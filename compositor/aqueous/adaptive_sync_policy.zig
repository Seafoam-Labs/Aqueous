// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

pub const Context = struct {
    enabled: bool = true,
    mirror: bool = false,
    session_active: bool = true,
    unlocked: bool = true,
    overview: bool = false,
    fullscreen: bool = false,
};

pub fn target(master: bool, fullscreen_only: bool, context: Context) bool {
    if (!master or !context.enabled or context.mirror) return false;
    if (!fullscreen_only) return true;
    return context.session_active and context.unlocked and !context.overview and context.fullscreen;
}

/// A rejected target is retried only after the target, configuration or output
/// capabilities change. Ordinary manage/render cycles must not create a loop.
pub const State = struct {
    target: bool = false,
    failure: ?enum { unsupported, commit_failed } = null,
    attempts: u64 = 0,

    pub fn update(state: *State, requested: bool) void {
        if (state.target != requested) state.reset();
        state.target = requested;
    }

    pub fn reset(state: *State) void {
        state.failure = null;
    }

    pub fn shouldCommit(state: State, actual: bool) bool {
        return state.failure == null and state.target != actual;
    }
};

test "fullscreen-only is an output-local gate on the master preference" {
    for ([_]bool{ false, true }) |master| {
        for ([_]bool{ false, true }) |modifier| {
            for ([_]bool{ false, true }) |fullscreen| {
                try std.testing.expectEqual(master and (!modifier or fullscreen), target(master, modifier, .{ .fullscreen = fullscreen }));
            }
        }
    }
    try std.testing.expect(!target(true, true, .{ .fullscreen = true, .enabled = false }));
    try std.testing.expect(!target(true, true, .{ .fullscreen = true, .mirror = true }));
    try std.testing.expect(!target(true, true, .{ .fullscreen = true, .unlocked = false }));
    try std.testing.expect(!target(true, true, .{ .fullscreen = true, .session_active = false }));
    try std.testing.expect(!target(true, true, .{ .fullscreen = true, .overview = true }));
    try std.testing.expect(target(true, false, .{ .unlocked = false, .session_active = false, .overview = true }));
}

test "failed automatic enable and disable do not repeatedly retry" {
    for ([_]bool{ false, true }) |requested| {
        var state: State = .{};
        state.update(requested);
        try std.testing.expect(state.shouldCommit(!requested));
        state.failure = .commit_failed;
        state.update(requested);
        try std.testing.expect(!state.shouldCommit(!requested));
        state.update(!requested);
        try std.testing.expect(state.failure == null);
        state.update(requested);
        try std.testing.expect(state.shouldCommit(!requested));
        state.failure = .unsupported;
        state.reset();
        try std.testing.expect(state.shouldCommit(!requested));
        try std.testing.expect(!state.shouldCommit(requested));
    }
}
