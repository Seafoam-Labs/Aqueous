// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Pending = @This();

const std = @import("std");

pub const Handle = u64;

allocator: std.mem.Allocator,
window: Handle = 0,
shell_surface: Handle = 0,
seat: Handle = 0,
live_shell_surfaces: std.AutoHashMapUnmanaged(Handle, void) = .empty,

pub fn init(allocator: std.mem.Allocator) Pending {
    return .{ .allocator = allocator };
}

pub fn deinit(pending: *Pending) void {
    pending.live_shell_surfaces.deinit(pending.allocator);
}

pub fn setWindow(pending: *Pending, window: Handle, seat: Handle) void {
    pending.forgetShellSurface(pending.shell_surface);
    pending.window = window;
    pending.shell_surface = 0;
    pending.seat = seat;
}

pub fn setShellSurface(pending: *Pending, shell_surface: Handle, seat: Handle) !void {
    pending.shell_surface = shell_surface;
    pending.window = 0;
    pending.seat = seat;
    if (shell_surface != 0) try pending.live_shell_surfaces.put(pending.allocator, shell_surface, {});
}

pub fn clear(pending: *Pending) void {
    pending.forgetShellSurface(pending.shell_surface);
    pending.window = 0;
    pending.shell_surface = 0;
    pending.seat = 0;
}

pub fn forgetShellSurface(pending: *Pending, shell_surface: Handle) void {
    if (shell_surface != 0) _ = pending.live_shell_surfaces.remove(shell_surface);
}

pub fn isShellSurfaceLive(pending: *const Pending, shell_surface: Handle) bool {
    return shell_surface != 0 and pending.live_shell_surfaces.contains(shell_surface);
}

test "window and shell focus are mutually exclusive and clear liveness" {
    var pending = Pending.init(std.testing.allocator);
    defer pending.deinit();
    try pending.setShellSurface(11, 2);
    try std.testing.expect(pending.isShellSurfaceLive(11));
    pending.setWindow(22, 2);
    try std.testing.expectEqual(@as(Handle, 0), pending.shell_surface);
    try std.testing.expect(!pending.isShellSurfaceLive(11));
    pending.clear();
    try std.testing.expectEqual(@as(Handle, 0), pending.window);
    try std.testing.expectEqual(@as(Handle, 0), pending.seat);
}
