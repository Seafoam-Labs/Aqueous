// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const ShellManager = @This();
const std = @import("std");
const wl = @import("wayland").server.wl;
const protocol = @import("wayland").server.aqueous.ShellManagerV1;
const server = &@import("main.zig").server;
const util = @import("util.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const KeyboardGroup = @import("KeyboardGroup.zig");
const Map = std.StringHashMapUnmanaged([]const u8);
const limit = 4 * 1024 * 1024;

pub const Status = protocol.Status;
global: *wl.Global = undefined,
initialized: bool = false,
idle: ?*wl.EventSource = null,
clients: wl.list.Head(Client, .link) = undefined,
client_count: usize = 0,
sequence: u64 = 0,
session: [32:0]u8 = undefined,
state: Map = .empty,
server_destroy: wl.Listener(*wl.Server) = .init(destroy),

const Client = struct {
    resource: *protocol,
    link: wl.list.Link = undefined,
    subscribed: bool = false,
    initial: bool = true,
    inflight: bool = false,
    serial: u32 = 0,
    sequence: u64 = 0,
    previous: Map = .empty,
    pending: ?u32 = null,
    queued: ?Command = null,
};

const Command = struct {
    id: u32,
    action: protocol.Action,
    target: []const u8,
    seat: []const u8,
    value: []const u8,
    fn deinit(self: Command) void {
        util.gpa.free(self.target);
        util.gpa.free(self.seat);
        util.gpa.free(self.value);
    }
};

pub fn init(manager: *ShellManager) !void {
    manager.* = .{};
    manager.clients.init();
    var random: [16]u8 = undefined;
    std.Io.random(std.Io.Threaded.global_single_threaded.io(), &random);
    const hex = std.fmt.bytesToHex(random, .lower);
    @memcpy(manager.session[0..32], &hex);
    manager.session[32] = 0;
    manager.global = try wl.Global.create(server.wl_server, protocol, 1, *ShellManager, manager, bind);
    manager.initialized = true;
    server.wl_server.addDestroyListener(&manager.server_destroy);
}

fn clear(map: *Map) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        util.gpa.free(entry.key_ptr.*);
        util.gpa.free(entry.value_ptr.*);
    }
    map.deinit(util.gpa);
    map.* = .empty;
}

fn destroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const manager: *ShellManager = @fieldParentPtr("server_destroy", listener);
    manager.initialized = false;
    if (manager.idle) |idle| idle.remove();
    manager.global.destroy();
    clear(&manager.state);
}

fn bind(client: *wl.Client, manager: *ShellManager, version: u32, id: u32) void {
    if (manager.client_count >= 16) {
        client.postImplementationError("Aqueous shell client limit exceeded");
        return;
    }
    const resource = protocol.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const state = util.gpa.create(Client) catch {
        resource.destroy();
        client.postNoMemory();
        return;
    };
    state.* = .{ .resource = resource };
    manager.clients.append(state);
    manager.client_count += 1;
    resource.setHandler(*Client, request, clientDestroy, state);
    var arena = std.heap.ArenaAllocator.init(util.gpa);
    defer arena.deinit();
    const json = std.json.Stringify.valueAlloc(arena.allocator(), .{
        .schema = 1,
        .session = manager.session[0..32],
        .max_batch_bytes = limit,
        .state = true,
        .commands = server.aqueous.mode == .internal,
        .keyboard = server.aqueous.mode == .internal,
        .overview = server.aqueous.mode == .internal,
        .shortcut_inhibition = true,
        .geometry = "committed-content-global-logical",
    }, .{}) catch {
        client.postNoMemory();
        return;
    };
    const z = arena.allocator().dupeZ(u8, json) catch {
        client.postNoMemory();
        return;
    };
    resource.sendCapabilities(z);
}

fn clientDestroy(_: *protocol, client: *Client) void {
    client.link.remove();
    server.shell_manager.client_count -= 1;
    clear(&client.previous);
    if (client.queued) |cmd| cmd.deinit();
    util.gpa.destroy(client);
}

pub fn dirty(manager: *ShellManager) void {
    if (!manager.initialized or manager.client_count == 0 or manager.idle != null) return;
    manager.idle = server.wl_server.getEventLoop().addIdle(*ShellManager, publish, manager) catch return;
}

fn settled() bool {
    return server.wm.state == .idle and !server.wm.scheduled.dirty and
        !server.wm.scheduled.dirty_lazy and !server.wm.rendering_scheduled.dirty and
        server.workspace_manager.publish_idle == null;
}

fn publish(manager: *ShellManager) void {
    manager.idle = null;
    // Transaction completion and workspace publication schedule us again.
    if (!settled()) return;
    var queued = manager.clients.iterator(.forward);
    while (queued.next()) |client| {
        const cmd = client.queued orelse continue;
        client.queued = null;
        defer cmd.deinit();
        const status = execute(cmd.action, cmd.target, cmd.seat, cmd.value);
        if (status != .applied) {
            result(client, cmd.id, status);
        } else if (cmd.action == .session_exit) {
            result(client, cmd.id, .accepted);
            server.wl_server.flushClients();
            server.wl_server.terminate();
            return;
        } else client.pending = cmd.id;
        if (!settled()) return;
    }
    manager.refresh() catch {
        var clients = manager.clients.iterator(.forward);
        while (clients.next()) |client| client.resource.getClient().postImplementationError("Aqueous shell state exceeds limits or allocation failed");
        return;
    };
    var clients = manager.clients.iterator(.forward);
    while (clients.next()) |client| {
        if (client.subscribed and !client.inflight and (client.initial or client.sequence != manager.sequence)) {
            manager.sendBatch(client) catch {
                client.resource.getClient().postImplementationError("Aqueous shell batch exceeds limits or allocation failed");
                continue;
            };
        }
        if (client.pending) |id| {
            result(client, id, .applied);
            client.pending = null;
        }
    }
}

fn idString(a: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{id});
}
fn optionalId(a: std.mem.Allocator, id: ?u64) !?[]const u8 {
    return if (id) |value| try idString(a, value) else null;
}
fn span(value: ?[*:0]const u8) ?[]const u8 {
    return if (value) |v| std.mem.span(v) else null;
}
fn windowId(window: *Window) ?[]const u8 {
    return if (window.foreign_toplevel_handle) |h| std.mem.span(h.identifier) else null;
}
fn add(map: *Map, total: *usize, kind: []const u8, id: []const u8, value: anytype) !void {
    const key = try std.fmt.allocPrint(util.gpa, "{s}:{s}", .{ kind, id });
    errdefer util.gpa.free(key);
    const json = try std.json.Stringify.valueAlloc(util.gpa, value, .{});
    errdefer util.gpa.free(json);
    const size = key.len + json.len + 64;
    if (size > limit / 2 - total.*) return error.StateTooLarge;
    try map.put(util.gpa, key, json);
    total.* += size;
}

fn refresh(manager: *ShellManager) !void {
    var next: Map = .empty;
    var total: usize = 0;
    errdefer clear(&next);
    var arena = std.heap.ArenaAllocator.init(util.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        const id = try idString(a, output.shell_id);
        try add(&next, &total, "output", id, .{ .kind = "output", .id = id, .name = output.policyName(), .enabled = output.current.state == .enabled or output.current.state == .disabled_soft, .powered = output.current.state == .enabled, .bounds = output.current.box(), .usable_bounds = output.policyUsableBox(), .scale = output.current.scale, .transform = @tagName(output.current.transform), .active_workspace = try optionalId(a, if (output.active_workspace) |ws| ws.id else null) });
        var workspaces = output.workspaces.iterator(.forward);
        while (workspaces.next()) |ws| {
            const ws_id = try idString(a, ws.id);
            const number = ws.policyNumber();
            try add(&next, &total, "workspace", ws_id, .{ .kind = "workspace", .id = ws_id, .output = id, .name = if (ws.name.len > 0) ws.name else try idString(a, number), .number = number, .active = ws.isActive(), .urgent = ws.urgent });
        }
    }
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        if (window.state != .mapped) continue;
        const id = windowId(window) orelse continue;
        const info = window.infoSnapshot();
        const ws = window.workspace;
        const border = window.rendering_requested.border;
        const left: i32 = if (!info.fullscreen and border.edges.left) @intCast(border.width) else 0;
        const right: i32 = if (!info.fullscreen and border.edges.right) @intCast(border.width) else 0;
        const top: i32 = if (!info.fullscreen and border.edges.top) @intCast(border.width) else 0;
        const bottom: i32 = if (!info.fullscreen and border.edges.bottom) @intCast(border.width) else 0;
        const outer = .{ .x = @as(i64, info.geometry.x) - left, .y = @as(i64, info.geometry.y) - top, .width = @as(i64, info.geometry.width) + left + right, .height = @as(i64, info.geometry.height) + top + bottom };
        const freeform = window.policy_state.presentation == .floating or server.aqueous.clientWindowUsesFloatingLayout(@bitCast(window.ref));
        try add(&next, &total, "window", id, .{ .kind = "window", .id = id, .backend = @tagName(info.backend), .app_id = span(info.app_id), .class = span(info.class), .title = span(info.title), .workspace = try optionalId(a, if (ws) |v| v.id else null), .output = try optionalId(a, if (ws) |v| v.output.shell_id else null), .geometry = info.geometry, .outer_geometry = outer, .focused = info.focused, .visible = info.visible, .floating = info.floating, .minimized = info.minimized, .maximized = info.maximized, .fullscreen = info.fullscreen, .skip_taskbar = info.skip_taskbar, .skip_switcher = info.skip_switcher, .always_above = info.always_above, .always_below = info.always_below, .snapped = info.snapped, .fixed_position = info.fixed_position, .layout = info.layout, .can_minimize = freeform, .can_maximize = freeform, .can_activate = window.wm_scheduled.accepts_focus and window.policy_state.focus_allowed });
    }
    var devices = server.input_manager.devices.iterator(.forward);
    while (devices.next()) |device| {
        if (device.wlr_device.type != .keyboard) continue;
        const keyboard: *@import("Keyboard.zig") = @fieldParentPtr("device", device);
        const id = try idString(a, device.shell_id);
        try add(&next, &total, "keyboard_device", id, .{ .kind = "keyboard_device", .id = id, .name = span(device.wlr_device.name), .seat = std.mem.span(device.seat.wlr_seat.name), .group = try optionalId(a, if (keyboard.group) |g| g.shell_id else null), .virtual = device.virtual });
    }
    var seat_count: usize = 0;
    var default_seat: ?[]const u8 = null;
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| {
        const name = std.mem.span(seat.wlr_seat.name);
        seat_count += 1;
        default_seat = name;
        var active_group: ?u64 = null;
        var groups = seat.keyboard_groups.iterator(.forward);
        while (groups.next()) |group| {
            if (seat.wlr_seat.getKeyboard() == &group.state) active_group = group.shell_id;
            const keymap = group.state.keymap orelse continue;
            const names = try a.alloc([]const u8, keymap.numLayouts());
            for (names, 0..) |*name_ptr, i| name_ptr.* = span(keymap.layoutGetName(@intCast(i))) orelse "";
            const id = try idString(a, group.shell_id);
            try add(&next, &total, "keyboard", id, .{ .kind = "keyboard", .id = id, .seat = name, .layouts = names, .index = if (group.state.xkb_state) |state| state.serializeLayout(@enumFromInt(1 << 7)) else 0 });
        }
        try add(&next, &total, "seat", name, .{ .kind = "seat", .id = name, .output = try optionalId(a, if (seat.selected_output) |o| o.shell_id else null), .window = if (seat.focused == .window) windowId(seat.focused.window) else null, .focus_kind = @tagName(seat.focused), .keyboard = try optionalId(a, active_group) });
    }
    var overview_output: ?u64 = null;
    var overview_window: ?[]const u8 = null;
    if (server.aqueous.overview) |overview| {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| if (output.policyId() == overview.output_id) {
            overview_output = output.shell_id;
            break;
        };
        const ref: Window.Ref = @bitCast(overview.selected);
        if (ref.get()) |window| overview_window = windowId(window);
    }
    try add(&next, &total, "session", "session", .{ .kind = "session", .id = "session", .locked = server.lock_manager.state != .unlocked, .default_seat = if (seat_count == 1) default_seat else null, .overview_output = try optionalId(a, overview_output), .overview_window = overview_window });
    var changed = next.count() != manager.state.count();
    var it = next.iterator();
    while (it.next()) |entry| {
        const old = manager.state.get(entry.key_ptr.*);
        if (old == null or !std.mem.eql(u8, old.?, entry.value_ptr.*)) changed = true;
    }
    if (changed or manager.sequence == 0) {
        clear(&manager.state);
        manager.state = next;
        manager.sequence += 1;
    } else clear(&next);
}

fn sendBatch(manager: *ShellManager, client: *Client) !void {
    var buffer: std.Io.Writer.Allocating = .init(util.gpa);
    defer buffer.deinit();
    const w = &buffer.writer;
    try w.print("{{\"schema\":1,\"session\":\"{s}\",\"sequence\":\"{d}\",\"base_sequence\":", .{ manager.session, manager.sequence });
    if (client.initial) try w.writeAll("null") else try w.print("\"{d}\"", .{client.sequence});
    try w.print(",\"type\":\"{s}\",\"upsert\":[", .{if (client.initial) @as([]const u8, "snapshot") else "delta"});
    var first = true;
    var it = manager.state.iterator();
    while (it.next()) |entry| {
        const old = client.previous.get(entry.key_ptr.*);
        if (!client.initial and old != null and std.mem.eql(u8, old.?, entry.value_ptr.*)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll(entry.value_ptr.*);
    }
    try w.writeAll("],\"removed\":[");
    first = true;
    it = client.previous.iterator();
    while (it.next()) |entry| if (!manager.state.contains(entry.key_ptr.*)) {
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
    };
    try w.writeAll("]}");
    const bytes = buffer.written();
    if (bytes.len > limit) return error.StateTooLarge;
    // Retain only one bounded baseline and one unacknowledged wire batch.
    clear(&client.previous);
    it = manager.state.iterator();
    while (it.next()) |entry| {
        const key = try util.gpa.dupe(u8, entry.key_ptr.*);
        errdefer util.gpa.free(key);
        const value = try util.gpa.dupe(u8, entry.value_ptr.*);
        errdefer util.gpa.free(value);
        try client.previous.put(util.gpa, key, value);
    }
    client.serial +%= 1;
    client.resource.sendBegin(client.serial);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk = bytes[offset..@min(bytes.len, offset + 3000)];
        var array: wl.Array = .{ .size = chunk.len, .alloc = chunk.len, .data = @constCast(chunk.ptr) };
        client.resource.sendData(&array);
        offset += chunk.len;
    }
    client.resource.sendDone(client.serial);
    client.sequence = manager.sequence;
    client.initial = false;
    client.inflight = true;
}

fn result(client: *Client, id: u32, status: Status) void {
    var buf: [32]u8 = undefined;
    const sequence = std.fmt.bufPrintZ(&buf, "{d}", .{server.shell_manager.sequence}) catch unreachable;
    client.resource.sendResult(id, status, sequence);
}

fn request(resource: *protocol, req: protocol.Request, client: *Client) void {
    switch (req) {
        .destroy => resource.destroy(),
        .subscribe => {
            if (client.subscribed) {
                resource.getClient().postImplementationError("duplicate shell subscription");
                return;
            }
            client.subscribed = true;
            server.shell_manager.dirty();
        },
        .ack => |args| {
            if (!client.inflight or args.serial != client.serial) {
                resource.getClient().postImplementationError("invalid shell acknowledgement");
                return;
            }
            client.inflight = false;
            server.shell_manager.dirty();
        },
        .identify_workspace => |args| {
            var buf: [32]u8 = undefined;
            const ws = @import("WorkspaceManager.zig").workspaceForResource(args.workspace);
            const id = if (ws) |value| std.fmt.bufPrintZ(&buf, "{d}", .{value.id}) catch unreachable else "";
            resource.sendWorkspaceId(args.request_id, id);
        },
        .command => |args| {
            // These decisions do not require a settled policy transaction.
            // An absent external controller must not turn unsupported into a timeout.
            if (server.lock_manager.state != .unlocked) {
                result(client, args.request_id, .locked);
                return;
            }
            if (server.aqueous.mode != .internal) {
                result(client, args.request_id, .unsupported);
                return;
            }
            if (client.pending != null or client.queued != null) {
                result(client, args.request_id, .busy);
                return;
            }
            const target = std.mem.span(args.target);
            const seat = std.mem.span(args.seat);
            const value = std.mem.span(args.value);
            if (target.len > 1024 or seat.len > 1024 or value.len > 1024) {
                result(client, args.request_id, .invalid);
                return;
            }
            client.queued = copyCommand(args.request_id, args.action, target, seat, value) catch {
                result(client, args.request_id, .unavailable);
                return;
            };
            server.shell_manager.dirty();
        },
    }
}

fn copyCommand(id: u32, action: protocol.Action, target: []const u8, seat: []const u8, value: []const u8) !Command {
    const t = try util.gpa.dupe(u8, target);
    errdefer util.gpa.free(t);
    const s = try util.gpa.dupe(u8, seat);
    errdefer util.gpa.free(s);
    const v = try util.gpa.dupe(u8, value);
    return .{ .id = id, .action = action, .target = t, .seat = s, .value = v };
}

fn findWindow(id: []const u8) ?*Window {
    var it = server.wm.windows.iterator();
    while (it.next()) |window| {
        if (window.state != .mapped) continue;
        if (windowId(window)) |value| if (std.mem.eql(u8, id, value)) return window;
    }
    return null;
}
fn findOutput(name: []const u8) ?*Output {
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| if (std.mem.eql(u8, name, output.policyName())) return output;
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

fn execute(action: protocol.Action, target: []const u8, seat_name: []const u8, value: []const u8) Status {
    if (target.len > 1024 or seat_name.len > 1024 or value.len > 1024) return .invalid;
    if (server.lock_manager.state != .unlocked) return .locked;
    if (server.aqueous.mode != .internal) return .unsupported;
    switch (action) {
        .session_exit => return .applied,
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
            const ws = if (action == .window_move_workspace) findWorkspace(value) orelse return .not_found else (findOutput(value) orelse return .not_found).active_workspace orelse return .unavailable;
            if (!ws.output.policyExposed()) return .unavailable;
            server.aqueous.cancelOverview();
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
                const output = findOutput(value) orelse return .not_found;
                if (server.aqueous.overview) |overview| {
                    if (overview.output_id == output.policyId()) return .applied;
                    server.aqueous.cancelOverview();
                }
                server.aqueous.openOverviewOnOutput(output.policyId());
                if (server.aqueous.overview == null) return .unavailable;
            }
        },
        else => return .invalid,
    }
    return .applied;
}
