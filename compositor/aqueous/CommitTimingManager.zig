// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! The pinned wlroots owns ordered timing state and event-loop wakeups.
//! Applying due state produces scene damage before output frame construction.
const CommitTimingManager = @This();
const wl = @import("wayland").server.wl;
const c = @import("c");

manager: *c.struct_wlr_commit_timing_manager_v1,

pub fn init(display: *wl.Server) !CommitTimingManager {
    return .{ .manager = c.wlr_commit_timing_manager_v1_create(@ptrCast(display)) orelse return error.OutOfMemory };
}

pub fn global(timing: CommitTimingManager) *wl.Global {
    return @ptrCast(c.wlr_commit_timing_manager_v1_get_global(timing.manager));
}
