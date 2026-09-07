// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

pub const Action = enum(u32) {
    window_activate,
    window_close,
    window_minimized,
    window_maximized,
    window_fullscreen,
    window_move_workspace,
    window_move_output,
    workspace_activate,
    workspace_rename,
    session_exit,
    keyboard_set,
    keyboard_next,
    overview_show,
    overview_hide,
    overview_toggle,
};

pub const Status = enum(u32) {
    applied,
    accepted,
    invalid,
    not_found,
    locked,
    unsupported,
    busy,
    ambiguous_seat,
    unavailable,
};

pub const Command = struct {
    action: Action,
    target: []const u8 = "",
    seat: []const u8 = "",
    value: []const u8 = "",
    output_by_id: bool = false,

    pub fn clone(self: Command, allocator: std.mem.Allocator) !Command {
        const target = try allocator.dupe(u8, self.target);
        errdefer allocator.free(target);
        const seat = try allocator.dupe(u8, self.seat);
        errdefer allocator.free(seat);
        const value = try allocator.dupe(u8, self.value);
        return .{ .action = self.action, .target = target, .seat = seat, .value = value, .output_by_id = self.output_by_id };
    }

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.seat);
        allocator.free(self.value);
    }
};
