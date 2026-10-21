// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const allocator = std.heap.c_allocator;
pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("xcb/xcb.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("spawn.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});
const resource_limit = 256 * 1024;
const base_dpi = @import("xwayland_dpi_policy.zig").base_dpi;
pub const State = enum(u32) { starting, applied, external, failed };
pub const Status = struct { state: State = .starting, dpi: u32 = 0, pid: std.c.pid_t = 0 };
const Reply = extern struct { state: u32, dpi: u32 };

pub fn nowMs() i64 {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + @divTrunc(t.tv_nsec, 1000000);
}
fn errno() c_int {
    return c.__errno_location().*;
}
fn transientError() bool {
    return errno() == c.EAGAIN or errno() == c.EWOULDBLOCK or errno() == c.EINTR;
}

/// The compositor only touches a nonblocking private socket and its owned child.
/// Re-exec keeps XCB out of a forked renderer's address space, without requiring
/// a separate executable or packaging lookup.
pub const Supervisor = struct {
    display: [:0]u8,
    pid: std.c.pid_t = 0,
    fd: c_int = -1,
    retry: i64 = 0,
    deadline: i64 = 0,
    next_send: i64 = 0,
    pending: bool = false,
    status: Status = .{},

    pub fn create(display: [*:0]const u8) !*Supervisor {
        const self = try allocator.create(Supervisor);
        errdefer allocator.destroy(self);
        self.* = .{ .display = try allocator.dupeZ(u8, std.mem.span(display)) };
        return self;
    }

    fn spawn(self: *Supervisor) !void {
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC, 0, &pair) < 0) return error.Socket;
        errdefer _ = c.close(pair[0]);
        defer _ = c.close(pair[1]);
        var actions: c.posix_spawn_file_actions_t = undefined;
        if (c.posix_spawn_file_actions_init(&actions) != 0) return error.Spawn;
        defer _ = c.posix_spawn_file_actions_destroy(&actions);
        var attr: c.posix_spawnattr_t = undefined;
        if (c.posix_spawnattr_init(&attr) != 0) return error.Spawn;
        defer _ = c.posix_spawnattr_destroy(&attr);
        var empty: c.sigset_t = undefined;
        var defaults: c.sigset_t = undefined;
        _ = c.sigemptyset(&empty);
        _ = c.sigemptyset(&defaults);
        for ([_]c_int{ c.SIGTERM, c.SIGALRM, c.SIGPIPE }) |signal| _ = c.sigaddset(&defaults, signal);
        // closefrom also closes non-CLOEXEC rendering descriptors.
        if (c.posix_spawn_file_actions_adddup2(&actions, pair[1], c.STDIN_FILENO) != 0 or
            c.posix_spawn_file_actions_addclosefrom_np(&actions, 3) != 0 or
            c.posix_spawnattr_setsigmask(&attr, &empty) != 0 or
            c.posix_spawnattr_setsigdefault(&attr, &defaults) != 0 or
            c.posix_spawnattr_setflags(&attr, c.POSIX_SPAWN_SETSIGMASK | c.POSIX_SPAWN_SETSIGDEF) != 0) return error.Spawn;
        const argv = [_:null]?[*:0]const u8{ "aqueous", "-xwayland-dpi-worker", self.display.ptr };
        if (c.posix_spawn(&self.pid, "/proc/self/exe", &actions, &attr, @ptrCast(@constCast(&argv)), c.environ) != 0) return error.Spawn;
        self.fd = pair[0];
        self.status = .{ .pid = self.pid };
        self.pending = false;
        self.next_send = 0;
    }

    fn failed(self: *Supervisor, now: i64) void {
        if (self.pid > 0) _ = c.kill(self.pid, c.SIGKILL);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.status.state = .failed;
        self.status.dpi = 0;
        self.retry = now + 5000;
    }

    pub fn restart(self: *Supervisor) void {
        self.failed(nowMs());
        self.retry = 0;
    }

    pub fn tick(self: *Supervisor, dpi: u32) Status {
        const now = nowMs();
        if (self.pid > 0) {
            const result = c.waitpid(self.pid, null, c.WNOHANG);
            if (result == self.pid or (result < 0 and errno() == c.ECHILD)) {
                self.pid = 0;
                if (self.fd >= 0) self.failed(now);
            }
        }
        if (self.pid == 0 and now >= self.retry) self.spawn() catch self.failed(now);
        self.status.pid = self.pid;
        if (self.fd < 0) return self.status;
        var reply: Reply = undefined;
        const n = c.recv(self.fd, &reply, @sizeOf(Reply), c.MSG_DONTWAIT);
        if (n == @sizeOf(Reply) and reply.state <= @intFromEnum(State.failed)) {
            self.status.state = @enumFromInt(reply.state);
            self.status.dpi = reply.dpi;
            self.pending = false;
            self.next_send = now + 500;
        } else if (n >= 0 or !transientError()) {
            self.failed(now);
            return self.status;
        }
        if (self.pending and now >= self.deadline) {
            self.failed(now);
        } else if (!self.pending and (now >= self.next_send or (self.status.state == .applied and self.status.dpi != dpi))) {
            if (c.send(self.fd, &dpi, @sizeOf(u32), c.MSG_DONTWAIT | c.MSG_NOSIGNAL) == @sizeOf(u32)) {
                self.pending = true;
                self.deadline = now + 3000;
            } else if (!transientError()) self.failed(now);
        }
        return self.status;
    }

    pub fn destroy(self: *Supervisor) void {
        // EOF requests resource restoration. Only shutdown may wait; normal
        // rendering never does. The worker bounds X requests with a 2s alarm.
        if (self.fd >= 0) {
            _ = c.shutdown(self.fd, c.SHUT_WR);
            _ = c.close(self.fd);
        }
        const until = nowMs() + 2500;
        while (self.pid > 0) {
            const result = c.waitpid(self.pid, null, c.WNOHANG);
            if (result == self.pid or (result < 0 and errno() == c.ECHILD)) break;
            if (nowMs() >= until) {
                _ = c.kill(self.pid, c.SIGKILL);
                while (c.waitpid(self.pid, null, 0) < 0 and errno() == c.EINTR) {}
                break;
            }
            _ = c.poll(null, 0, 10);
        }
        allocator.free(self.display);
        allocator.destroy(self);
    }
};

pub const Worker = struct {
    connection: *c.xcb_connection_t,
    root: c.xcb_window_t = 0,
    window: c.xcb_window_t = 0,
    selection: c.xcb_atom_t = 0,
    settings: c.xcb_atom_t = 0,
    manager: c.xcb_atom_t = 0,
    resource: c.xcb_atom_t = c.XCB_ATOM_RESOURCE_MANAGER,
    backup: c.xcb_atom_t = 0,
    last: c.xcb_atom_t = 0,
    dpi: u32 = 0,
    serial: u32 = 0,
    timestamp: u32 = 0,
    owned: bool = false,

    pub fn atom(self: *Worker, name: []const u8) !c.xcb_atom_t {
        const reply = c.xcb_intern_atom_reply(self.connection, c.xcb_intern_atom(self.connection, 0, @intCast(name.len), name.ptr), null);
        if (reply == null) return error.X11;
        defer c.free(reply);
        if (reply.*.atom == c.XCB_ATOM_NONE) return error.X11;
        return reply.*.atom;
    }
    pub fn owner(self: *Worker) !c.xcb_window_t {
        const reply = c.xcb_get_selection_owner_reply(self.connection, c.xcb_get_selection_owner(self.connection, self.selection), null);
        if (reply == null) return error.X11;
        defer c.free(reply);
        return reply.*.owner;
    }
    pub fn checked(self: *Worker, cookie: c.xcb_void_cookie_t) !void {
        const err = c.xcb_request_check(self.connection, cookie);
        defer c.free(err);
        if (err != null or c.xcb_connection_has_error(self.connection) != 0) return error.X11;
    }
    pub fn createWindow(self: *Worker) !void {
        self.window = c.xcb_generate_id(self.connection);
        try self.checked(c.xcb_create_window_checked(self.connection, c.XCB_COPY_FROM_PARENT, self.window, self.root, 0, 0, 1, 1, 0, c.XCB_WINDOW_CLASS_INPUT_ONLY, c.XCB_COPY_FROM_PARENT, 0, null));
    }
    fn serverTimestamp(self: *Worker) !u32 {
        const mask: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
        _ = c.xcb_change_window_attributes(self.connection, self.window, c.XCB_CW_EVENT_MASK, &mask);
        _ = c.xcb_change_property(self.connection, c.XCB_PROP_MODE_REPLACE, self.window, self.last, c.XCB_ATOM_STRING, 8, 0, "");
        _ = c.xcb_flush(self.connection);
        while (true) {
            const event = c.xcb_wait_for_event(self.connection);
            if (event == null) return error.X11;
            defer c.free(event);
            if ((event.*.response_type & 127) == c.XCB_PROPERTY_NOTIFY) {
                const property_event: *c.xcb_property_notify_event_t = @ptrCast(event);
                if (property_event.atom == self.last) return property_event.time;
            }
        }
    }
    /// Owned bytes, bounded to prevent an unexpected root property consuming
    /// unbounded memory. An absent property is an empty string.
    pub fn property(self: *Worker, name: c.xcb_atom_t) ![]u8 {
        const reply = c.xcb_get_property_reply(self.connection, c.xcb_get_property(self.connection, 0, self.root, name, c.XCB_GET_PROPERTY_TYPE_ANY, 0, resource_limit / 4), null);
        if (reply == null) return error.X11;
        defer c.free(reply);
        const size: usize = @intCast(c.xcb_get_property_value_length(reply));
        if (reply.*.bytes_after != 0 or (reply.*.type != c.XCB_ATOM_NONE and (reply.*.format != 8 or reply.*.type != c.XCB_ATOM_STRING))) return error.InvalidProperty;
        if (size == 0) return allocator.alloc(u8, 0);
        const bytes = @as([*]const u8, @ptrCast(c.xcb_get_property_value(reply)))[0..size];
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidProperty;
        return allocator.dupe(u8, bytes);
    }
    pub fn put(self: *Worker, window: c.xcb_window_t, name: c.xcb_atom_t, kind: c.xcb_atom_t, data: []const u8) !void {
        try self.checked(c.xcb_change_property_checked(self.connection, c.XCB_PROP_MODE_REPLACE, window, name, kind, 8, @intCast(data.len), data.ptr));
    }
    fn restore(self: *Worker) !void {
        const last = try self.property(self.last);
        defer allocator.free(last);
        const backup = try self.property(self.backup);
        defer allocator.free(backup);
        const current = try self.property(self.resource);
        defer allocator.free(current);
        if (last.len > 0) {
            // External edits, including resource continuation syntax, take
            // precedence over restoring our original DPI entry.
            const entries = resources(allocator, current, "", true) catch null;
            if (entries) |bytes| {
                defer allocator.free(bytes);
                if (std.mem.eql(u8, bytes, last)) {
                    const restored = try resources(allocator, current, backup, false);
                    defer allocator.free(restored);
                    try self.put(self.root, self.resource, c.XCB_ATOM_STRING, restored);
                }
            }
        }
        _ = c.xcb_delete_property(self.connection, self.root, self.backup);
        _ = c.xcb_delete_property(self.connection, self.root, self.last);
    }
    fn publish(self: *Worker, dpi: u32) !void {
        const current = try self.property(self.resource);
        defer allocator.free(current);
        var buffer: [64]u8 = undefined;
        const text = dpiText(&buffer, dpi);
        const updated = try resources(allocator, current, text, false);
        defer allocator.free(updated);
        if (updated.len > resource_limit) return error.ResourceTooLarge;
        if (self.dpi == 0) {
            const saved = try resources(allocator, current, "", true);
            defer allocator.free(saved);
            try self.put(self.root, self.backup, c.XCB_ATOM_STRING, saved);
        }
        try self.put(self.root, self.last, c.XCB_ATOM_STRING, text);
        try self.put(self.root, self.resource, c.XCB_ATOM_STRING, updated);
        var data = [_]u8{0} ** 160; // XSettings LSBFirst
        self.serial +%= 1;
        std.mem.writeInt(u32, data[4..8], self.serial, .little);
        std.mem.writeInt(u32, data[8..12], 3, .little);
        const integer_scale = @max(1, (dpi + base_dpi - 1) / base_dpi);
        var n: usize = 12;
        n += setting(data[n..], "Xft/DPI", dpi, self.serial);
        n += setting(data[n..], "Gdk/WindowScalingFactor", integer_scale, self.serial);
        n += setting(data[n..], "Gdk/UnscaledDPI", dpi / integer_scale, self.serial);
        try self.put(self.window, self.settings, self.settings, data[0..n]);
        self.dpi = dpi;
    }
    fn update(self: *Worker, dpi: u32) !State {
        // Atomic with other X clients. Blocking roundtrips only run in this
        // process and are covered by the worker watchdog.
        _ = c.xcb_grab_server(self.connection);
        defer {
            _ = c.xcb_ungrab_server(self.connection);
            _ = c.xcb_flush(self.connection);
        }
        const existing = try self.owner();
        if (existing != c.XCB_WINDOW_NONE and existing != self.window) {
            if (self.owned) {
                try self.restore();
                // DestroyNotify releases this owner's settings in subscribers.
                _ = c.xcb_destroy_window(self.connection, self.window);
                self.window = c.XCB_WINDOW_NONE;
            }
            self.owned = false;
            self.dpi = 0;
            return .external;
        }
        if (!self.owned) {
            try self.restore();
            if (self.window == 0) try self.createWindow();
            self.timestamp = try self.serverTimestamp();
            if (self.timestamp == 0) return error.X11;
            try self.checked(c.xcb_set_selection_owner_checked(self.connection, self.window, self.selection, self.timestamp));
            if (try self.owner() != self.window) return error.X11;
            self.owned = true;
            self.dpi = 0;
        }
        const first = self.dpi == 0;
        if (self.dpi != dpi) try self.publish(dpi);
        if (first) {
            var event = std.mem.zeroes(c.xcb_client_message_event_t);
            event.response_type = c.XCB_CLIENT_MESSAGE;
            event.format = 32;
            event.window = self.root;
            event.type = self.manager;
            event.data.data32[0] = self.timestamp;
            event.data.data32[1] = self.selection;
            event.data.data32[2] = self.window;
            _ = c.xcb_send_event(self.connection, 0, self.root, c.XCB_EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&event));
        }
        return .applied;
    }
};

fn dpiLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "Xft.dpi")) return false;
    return std.mem.startsWith(u8, std.mem.trimStart(u8, trimmed[7..], " \t"), ":");
}

/// Preserve unrelated resource bytes. Refuse continuation syntax rather than
/// treating a physical line inside a multiline resource as an independent entry.
pub fn resources(gpa: std.mem.Allocator, source: []const u8, dpi_source: []const u8, only_dpi: bool) ![]u8 {
    if (std.mem.indexOf(u8, source, "\\\n") != null or std.mem.indexOf(u8, dpi_source, "\\\n") != null) return error.ContinuedResource;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for ([_][]const u8{ source, dpi_source }, 0..) |input, i| {
        var remaining = input;
        while (remaining.len > 0) {
            const n = if (std.mem.indexOfScalar(u8, remaining, '\n')) |end| end + 1 else remaining.len;
            const line = remaining[0..n];
            if (dpiLine(line) == (i == 1 or only_dpi)) {
                if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
                try out.appendSlice(gpa, line);
            }
            remaining = remaining[n..];
        }
    }
    return out.toOwnedSlice(gpa);
}
pub fn dpiText(buffer: *[64]u8, dpi: u32) []const u8 {
    // Locale independent, preserving all ten binary fractional digits.
    return std.fmt.bufPrint(buffer, "Xft.dpi: {d}.{d:0>10}\n", .{ dpi / 1024, @as(u64, dpi % 1024) * 9765625 }) catch unreachable;
}
pub fn setting(data: []u8, name: []const u8, value: u32, serial: u32) usize {
    const padded = std.mem.alignForward(usize, name.len, 4);
    @memset(data[0 .. 12 + padded], 0);
    std.mem.writeInt(u16, data[2..4], @intCast(name.len), .little);
    @memcpy(data[4..][0..name.len], name);
    std.mem.writeInt(u32, data[4 + padded ..][0..4], serial, .little);
    std.mem.writeInt(u32, data[8 + padded ..][0..4], value, .little);
    return 12 + padded;
}

pub fn run(display: [*:0]const u8) u8 {
    // Only a compositor-provided private socket can drive this entry point.
    var kind: c_int = 0;
    var length: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(c.STDIN_FILENO, c.SOL_SOCKET, c.SO_TYPE, &kind, &length) < 0 or kind != c.SOCK_SEQPACKET) return 2;
    _ = c.alarm(2);
    defer _ = c.alarm(0);
    var screen_number: c_int = 0;
    const connection = c.xcb_connect(display, &screen_number) orelse return 1;
    defer c.xcb_disconnect(connection);
    if (c.xcb_connection_has_error(connection) != 0) return 1;
    var screens = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection));
    var i: c_int = 0;
    while (i < screen_number and screens.rem != 0) : (i += 1) c.xcb_screen_next(&screens);
    if (screens.rem == 0) return 1;
    var w: Worker = .{ .connection = connection, .root = screens.data.*.root };
    w.createWindow() catch return 1;
    var buffer: [48]u8 = undefined;
    const selection = std.fmt.bufPrint(&buffer, "_XSETTINGS_S{d}", .{screen_number}) catch return 1;
    w.selection = w.atom(selection) catch return 1;
    w.settings = w.atom("_XSETTINGS_SETTINGS") catch return 1;
    w.manager = w.atom("MANAGER") catch return 1;
    w.backup = w.atom("_AQUEOUS_XWAYLAND_DPI_BACKUP") catch return 1;
    w.last = w.atom("_AQUEOUS_XWAYLAND_DPI_LAST") catch return 1;
    _ = c.alarm(0);
    while (true) {
        var dpi: u32 = undefined;
        const n = c.recv(c.STDIN_FILENO, &dpi, @sizeOf(u32), 0);
        if (n < 0 and errno() == c.EINTR) continue;
        if (n != @sizeOf(u32) or dpi < 24 * 1024 or dpi > 1536 * 1024) break;
        _ = c.alarm(2);
        const state = w.update(dpi) catch State.failed;
        const reply: Reply = .{ .state = @intFromEnum(state), .dpi = if (state == .applied) w.dpi else 0 };
        _ = c.alarm(0);
        if (c.send(c.STDIN_FILENO, &reply, @sizeOf(Reply), c.MSG_NOSIGNAL) != @sizeOf(Reply)) break;
        if (state == .failed or c.xcb_connection_has_error(connection) != 0) break;
    }
    _ = c.alarm(2);
    if (w.owned and c.xcb_connection_has_error(connection) == 0) {
        _ = c.xcb_grab_server(connection);
        w.restore() catch {};
        if ((w.owner() catch c.XCB_WINDOW_NONE) == w.window) _ = c.xcb_set_selection_owner(connection, c.XCB_WINDOW_NONE, w.selection, c.XCB_CURRENT_TIME);
        _ = c.xcb_ungrab_server(connection);
        _ = c.xcb_flush(connection);
    }
    return 0;
}
