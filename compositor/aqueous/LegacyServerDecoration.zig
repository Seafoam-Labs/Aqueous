// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Compatibility wrapper for the obsolete KDE server-decoration protocol.
//!
//! GTK 3 and GTK 4 still consult this display-wide preference on Wayland when
//! deciding whether to synthesize their default titlebar. Keep the wlroots ABI
//! details isolated here so removing or replacing the protocol when wlroots
//! eventually drops it does not leak through the compositor.

const LegacyServerDecoration = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;

const log = std.log.scoped(.xdg);

const Manager = opaque {};

const ManagerPrefix = extern struct {
    global: *wl.Global,
};

pub const Mode = enum(u32) {
    none = 0,
    client = 1,
    server = 2,
};

manager: *Manager,
mode: Mode,

extern fn wlr_server_decoration_manager_create(display: *wl.Server) ?*Manager;
extern fn wlr_server_decoration_manager_set_default_mode(manager: *Manager, mode: Mode) void;

pub fn init(display: *wl.Server, force_ssd: bool) !LegacyServerDecoration {
    const manager = wlr_server_decoration_manager_create(display) orelse return error.OutOfMemory;
    var decoration = LegacyServerDecoration{
        .manager = manager,
        .mode = .none,
    };
    decoration.setForceSsd(force_ssd);
    return decoration;
}

pub fn global(decoration: *const LegacyServerDecoration) *wl.Global {
    const prefix: *const ManagerPrefix = @ptrCast(@alignCast(decoration.manager));
    return prefix.global;
}

pub fn setForceSsd(decoration: *LegacyServerDecoration, force_ssd: bool) void {
    const next = modeForForceSsd(force_ssd);
    if (decoration.mode == next) return;
    wlr_server_decoration_manager_set_default_mode(decoration.manager, next);
    decoration.mode = next;
    log.info("default mode={s}", .{@tagName(next)});
}

fn modeForForceSsd(force_ssd: bool) Mode {
    return if (force_ssd) .server else .client;
}

test "force_ssd maps to an explicit legacy decoration side" {
    try std.testing.expectEqual(Mode.server, modeForForceSsd(true));
    try std.testing.expectEqual(Mode.client, modeForForceSsd(false));
}
