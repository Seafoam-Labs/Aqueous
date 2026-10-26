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
