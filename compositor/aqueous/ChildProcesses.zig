// SPDX-License-Identifier: GPL-3.0-only
const Children = @This();
const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;

const poll_ms = 100;

allocator: std.mem.Allocator = undefined,
display: *wl.Server = undefined,
timer: ?*wl.EventSource = null,
stopping: bool = false,
pids: std.ArrayList(posix.pid_t) = .empty,

/// All methods run on the compositor thread. Bell audio, Xwayland and the
/// init process retain their existing owners; never wait for arbitrary PIDs.
pub fn init(children: *Children, allocator: std.mem.Allocator, display: *wl.Server) !void {
    children.* = .{ .allocator = allocator, .display = display };
    children.timer = try display.getEventLoop().addTimer(*Children, tick, children);
}

/// Reserve storage and schedule cleanup before creating a child. The caller
/// must exec or _exit immediately when this returns zero. Parent registration
/// cannot allocate or dispatch events, including when the child exits first.
pub fn fork(children: *Children) !posix.pid_t {
    return children.forkUsing(posix.system.fork);
}

fn forkUsing(children: *Children, comptime fork_fn: anytype) !posix.pid_t {
    if (children.stopping) return error.ChildTrackerStopped;
    const timer = children.timer orelse return error.ChildTrackerStopped;
    try children.pids.ensureUnusedCapacity(children.allocator, 1);
    if (children.pids.items.len == 0) try timer.timerUpdate(poll_ms);
    const rc = fork_fn();
    if (posix.errno(rc) != .SUCCESS) {
        if (children.pids.items.len == 0) children.updateTimer(0);
        return error.ForkFailed;
    }
    if (rc != 0) children.pids.appendAssumeCapacity(@intCast(rc));
    return @intCast(rc);
}

fn reap(children: *Children) void {
    var i: usize = 0;
    while (i < children.pids.items.len) {
        const pid = children.pids.items[i];
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, posix.W.NOHANG);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    i += 1;
                    continue;
                }
                _ = children.pids.swapRemove(i);
            },
            .INTR => continue,
            .CHILD => {
                // Do not retain a stale PID if ownership was violated.
                std.log.warn("spawned child {d} was already reaped", .{pid});
                _ = children.pids.swapRemove(i);
            },
            else => |err| {
                std.log.err("waitpid({d}) failed: {s}", .{ pid, @tagName(err) });
                i += 1;
            },
        }
    }
}

fn tick(children: *Children) c_int {
    children.reap();
    if (children.pids.items.len != 0) children.updateTimer(poll_ms);
    return 0;
}

fn updateTimer(children: *Children, delay: c_int) void {
    children.timer.?.timerUpdate(delay) catch |err| {
        // Continuing would silently accumulate zombies. Stop the session
        // through the normal teardown path if its event loop cannot supervise.
        std.log.err("unable to schedule child cleanup: {s}", .{@errorName(err)});
        children.stopping = true;
        children.display.terminate();
    };
}

/// Reap completed children once, but never kill or wait for running apps.
pub fn deinit(children: *Children) void {
    children.stopping = true;
    if (children.timer) |timer| timer.remove();
    children.timer = null;
    children.reap();
    children.pids.deinit(children.allocator);
    children.pids = .empty;
}

test "children: allocation and fork failures leave no registered children" {
    const display = try wl.Server.create();
    defer display.destroy();
    var buffer: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&buffer);
    var children: Children = .{};
    try children.init(allocator.allocator(), display);
    defer children.deinit();
    try std.testing.expectError(error.OutOfMemory, children.fork());
    children.allocator = std.testing.allocator;
    const failure = struct {
        fn fork() posix.pid_t {
            std.c._errno().* = @intFromEnum(posix.E.AGAIN);
            return -1;
        }
    };
    try std.testing.expectError(error.ForkFailed, children.forkUsing(failure.fork));
    try std.testing.expectEqual(0, children.pids.items.len);
}

test "children: bursts are reaped without consuming another owner's status" {
    const display = try wl.Server.create();
    defer display.destroy();
    var children: Children = .{};
    try children.init(std.testing.allocator, display);
    defer children.deinit();

    const other = posix.system.fork();
    if (posix.errno(other) != .SUCCESS) return error.ForkFailed;
    if (other == 0) posix.system.exit(23);
    defer _ = std.c.waitpid(other, null, 0);

    var pids: [32]posix.pid_t = undefined;
    for (&pids, 0..) |*pid, index| {
        pid.* = try children.fork();
        if (pid.* == 0) posix.system.exit(@intCast(index % 2));
    }
    for (0..100) |_| {
        if (children.pids.items.len == 0) break;
        try display.getEventLoop().dispatch(20);
    }
    try std.testing.expectEqual(0, children.pids.items.len);
    for (pids) |pid| {
        try std.testing.expectEqual(-1, std.c.waitpid(pid, null, posix.W.NOHANG));
        try std.testing.expectEqual(posix.E.CHILD, posix.errno(@as(c_int, -1)));
    }
    var status: c_int = 0;
    try std.testing.expectEqual(other, std.c.waitpid(other, &status, 0));
    try std.testing.expectEqual(23 << 8, status);
}

test "children: teardown leaves running apps alive and rejects new forks" {
    const display = try wl.Server.create();
    defer display.destroy();
    var children: Children = .{};
    try children.init(std.testing.allocator, display);
    defer children.deinit();
    const pid = try children.fork();
    if (pid == 0) {
        while (true) _ = std.os.linux.pause();
    }
    defer {
        posix.kill(pid, posix.SIG.KILL) catch {};
        _ = std.c.waitpid(pid, null, 0);
    }
    try display.getEventLoop().dispatch(200);
    try std.testing.expectEqual(1, children.pids.items.len);
    children.deinit();
    try std.testing.expectEqual(0, std.c.waitpid(pid, null, posix.W.NOHANG));
    try std.testing.expectError(error.ChildTrackerStopped, children.fork());
}
