// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const posix = std.posix;

var original_rlimit: ?posix.rlimit = null;

pub fn setup() void {
    // Ignore SIGPIPE so we don't get killed when writing to a socket that
    // has had its read end closed by another process.
    const sig_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_ign, null);

    // Match labwc by allowing the compositor to use the full hard FD limit.
    // Preserve the inherited limits so cleanupChild() can restore them.
    if (posix.getrlimit(.NOFILE)) |original| {
        original_rlimit = original;
        const new: posix.rlimit = .{
            .cur = original.max,
            .max = original.max,
        };
        if (posix.setrlimit(.NOFILE, new)) {
            std.log.info("set Aqueous file descriptor soft limit to hard limit {d}", .{new.cur});
        } else |_| {
            std.log.err("setrlimit failed, using system default file descriptor limit of {d}", .{
                original.cur,
            });
        }
    } else |_| {
        std.log.err("getrlimit failed, using system default file descriptor limit ", .{});
    }
}

/// Teardown runs without the event loop: signal handling that depends on loop
/// dispatch is gone, and individual steps (driver, renderer, session) may block
/// for unbounded time. Until the process exits it holds session-wide resources
/// (DRM master, the logind session, listening sockets), so teardown must stay
/// responsive to stop signals and must be bounded - exiting is the only
/// guaranteed way to release those resources and hand the session back.
pub fn armTeardownGuard() void {
    noteStage("entry");
    const act = posix.Sigaction{
        .handler = .{ .handler = teardownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
    // Signal masks are per-thread and inherited by spawned threads, and the
    // loop's signalfd sources leave these signals blocked. A handler is only
    // useful if some thread can receive the signal, so unblock them here.
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.TERM);
    posix.sigaddset(&mask, posix.SIG.INT);
    _ = posix.system.sigprocmask(posix.SIG.UNBLOCK, &mask, null);
    const thread = std.Thread.spawn(.{}, teardownWatchdog, .{}) catch return;
    thread.detach();
}

fn teardownSignal(_: posix.SIG) callconv(.c) void {
    // A stop signal during teardown means "hand the session back now"; the
    // kernel reclaims whatever the unfinished cleanup leaves behind.
    std.c._exit(0);
}

fn teardownWatchdog() void {
    stall(teardown_deadline_ms);
    const ptr = current_stage.load(.monotonic);
    const stage: []const u8 = if (ptr == 0) "unknown" else std.mem.span(@as([*:0]const u8, @ptrFromInt(ptr)));
    std.log.err("teardown stalled at stage '{s}' for {d}ms; exiting to release the session", .{ stage, teardown_deadline_ms });
    // The blocked thread cannot be unwound safely; exit is what releases the
    // session resources held on behalf of the process.
    std.c._exit(1);
}

var current_stage: std.atomic.Value(usize) = .init(0);

/// A blocked teardown produces no output of its own; recording the step about
/// to run lets the watchdog exit say where progress stopped.
pub fn noteStage(name: []const u8) void {
    current_stage.store(@intFromPtr(name.ptr), .monotonic);
}

/// Millisecond sleep that depends on neither the Io interface nor the event
/// loop, both of which are unavailable during teardown.
pub fn stall(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    const req = std.c.timespec{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    while (std.c.nanosleep(&req, null) != 0) {}
}

/// Past this bound, releasing the session matters more than finishing cleanup.
const teardown_deadline_ms: u64 = 8000;

pub fn cleanupChild() void {
    if (std.c.setsid() < 0) unreachable;
    if (posix.system.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null) < 0) unreachable;

    const sig_dfl = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_dfl, null);

    if (original_rlimit) |original| {
        posix.setrlimit(.NOFILE, original) catch {
            std.log.err("failed to restore original file descriptor limit for " ++
                "child process, setrlimit failed", .{});
        };
    }
}
