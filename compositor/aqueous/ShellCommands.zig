// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const server = &@import("main.zig").server;
const util = @import("util.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const KeyboardGroup = @import("KeyboardGroup.zig");
const Types = @import("ShellCommand.zig");
fn windowId(window: *Window) ?[]const u8 {
    return if (window.foreign_toplevel_handle) |h| std.mem.span(h.identifier) else null;
}

fn findWindow(id: []const u8) ?*Window {
    var it = server.wm.windows.iterator();
    while (it.next()) |window| {
        if (window.state != .mapped) continue;
        if (windowId(window)) |value| if (std.mem.eql(u8, id, value)) return window;
    }
    return null;
}
fn findOutput(name: []const u8, by_id: bool) ?*Output {
    const id = if (by_id) std.fmt.parseInt(u64, name, 10) catch return null else 0;
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| if (if (by_id) output.shell_id == id else std.mem.eql(u8, name, output.policyName())) return output;
    return null;
}
fn findWorkspace(id: []const u8) ?*Workspace {
    const number = std.fmt.parseInt(u32, id, 10) catch return null;
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        var it = output.workspaces.iterator(.forward);
        while (it.next()) |ws| if (ws.id == number) return ws;
    }
    return null;
}
fn findSeat(name: []const u8) ?*Seat {
    var it = server.input_manager.seats.iterator(.forward);
    const first = it.next() orelse return null;
    if (name.len == 0) return if (it.next() == null) first else null;
    if (std.mem.eql(u8, name, std.mem.span(first.wlr_seat.name))) return first;
    while (it.next()) |seat| if (std.mem.eql(u8, name, std.mem.span(seat.wlr_seat.name))) return seat;
    return null;
}

pub fn execute(cmd: Types.Command) Types.Status {
    const action = cmd.action;
    const target = cmd.target;
    const seat_name = cmd.seat;
    const value = cmd.value;
    if (target.len > 1024 or seat_name.len > 1024 or value.len > 1024) return .invalid;
    if (server.lock_manager.state != .unlocked) return .locked;
    if (server.aqueous.mode != .internal) return .unsupported;
    switch (action) {
        .session_exit => return .applied,
        .session_reload => {
            if (target.len != 0 or seat_name.len != 0 or value.len != 0) return .invalid;
            server.aqueous.reloadConfig();
        },
        .window_activate, .workspace_activate => {
            const seat = findSeat(seat_name) orelse return if (seat_name.len == 0) .ambiguous_seat else .not_found;
            if (action == .window_activate) {
                const window = findWindow(target) orelse return .not_found;
                if (!window.wm_scheduled.accepts_focus or !window.policy_state.focus_allowed) return .unsupported;
                if (window.workspace) |ws| if (!ws.output.policyExposed()) return .unavailable;
                server.aqueous.cancelOverview();
                if (!server.aqueous.activateShellWindow(@bitCast(window.ref), std.mem.span(seat.wlr_seat.name))) return .unavailable;
            } else {
                const ws = findWorkspace(target) orelse return .not_found;
                if (!ws.output.policyExposed()) return .unavailable;
                server.aqueous.cancelOverview();
                seat.policySelectOutput(ws.output);
                ws.output.activateWorkspace(ws);
            }
            server.wm.dirtyWindowing();
        },
        .window_close => {
            const window = findWindow(target) orelse return .not_found;
            window.close();
            return .accepted;
        },
        .window_minimized, .window_maximized, .window_fullscreen => {
            const window = findWindow(target) orelse return .not_found;
            const enabled = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return .invalid;
            const info = window.infoSnapshot();
            const current = switch (action) {
                .window_minimized => info.minimized,
                .window_maximized => info.maximized,
                else => info.fullscreen,
            };
            if (enabled == current) return .applied;
            if (action == .window_minimized and !server.aqueous.clientMinimizeAllowed(@bitCast(window.ref), enabled)) return .unsupported;
            if (action == .window_maximized) {
                if (enabled and window.policy_state.presentation != .floating and !server.aqueous.clientWindowUsesFloatingLayout(@bitCast(window.ref))) return .unsupported;
                if (!enabled and window.policy_state.client_maximize_origin == .none) return .unsupported;
            }
            server.aqueous.cancelOverview();
            switch (action) {
                .window_minimized => window.requestMinimized(enabled),
                .window_maximized => window.requestMaximized(enabled),
                .window_fullscreen => window.requestFullscreen(enabled, null),
                else => unreachable,
            }
            server.wm.dirtyWindowing();
        },
        .window_move_workspace, .window_move_output => {
            const window = findWindow(target) orelse return .not_found;
            const ws = if (action == .window_move_workspace) findWorkspace(value) orelse return .not_found else (findOutput(value, cmd.output_by_id) orelse return .not_found).active_workspace orelse return .unavailable;
            if (!ws.output.policyExposed()) return .unavailable;
            server.aqueous.cancelOverview();
            window.policy_state.overrideWorkspace();
            window.setWorkspace(ws);
        },
        .workspace_rename => {
            const ws = findWorkspace(target) orelse return .not_found;
            if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, '\n') != null) return .invalid;
            const name = util.gpa.dupeZ(u8, value) catch return .unavailable;
            util.gpa.free(ws.name);
            ws.name = name;
            server.workspace_manager.dirty();
        },
        .keyboard_set, .keyboard_next => {
            const seat = findSeat(seat_name) orelse return if (seat_name.len == 0) .ambiguous_seat else .not_found;
            var groups = seat.keyboard_groups.iterator(.forward);
            var found: ?*KeyboardGroup = null;
            const id = if (target.len > 0) std.fmt.parseInt(u64, target, 10) catch return .invalid else 0;
            while (groups.next()) |group| {
                if ((id == 0 and seat.wlr_seat.getKeyboard() == &group.state) or (id != 0 and group.shell_id == id)) {
                    found = group;
                    break;
                }
            }
            const group = found orelse return .not_found;
            const keymap = group.state.keymap orelse return .unavailable;
            const count = keymap.numLayouts();
            if (count == 0) return .unavailable;
            const current = if (group.state.xkb_state) |state| state.serializeLayout(@enumFromInt(1 << 7)) else 0;
            const index = if (action == .keyboard_next) (current + 1) % count else std.fmt.parseInt(u32, value, 10) catch return .invalid;
            if (index >= count) return .invalid;
            var modifiers = group.state.modifiers;
            modifiers.group = index;
            group.processModifiers(modifiers);
        },
        .overview_show, .overview_hide, .overview_toggle => {
            if (action == .overview_hide or (action == .overview_toggle and server.aqueous.overview != null)) {
                server.aqueous.cancelOverview();
            } else {
                const output = findOutput(value, cmd.output_by_id) orelse return .not_found;
                if (server.aqueous.overview) |overview| {
                    if (overview.output_id == output.policyId()) return .applied;
                    server.aqueous.cancelOverview();
                }
                server.aqueous.openOverviewOnOutput(output.policyId());
                if (server.aqueous.overview == null) return .unavailable;
            }
        },
    }
    return .applied;
}
