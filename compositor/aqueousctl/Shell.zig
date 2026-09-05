// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const wl = @import("wayland").client.wl;
const Protocol = @import("wayland").client.aqueous.ShellManagerV1;
const a = std.heap.c_allocator;
const Mode = enum { capabilities, snapshot, watch, command };
const Options = struct {
    mode: Mode,
    action: Protocol.Action = .session_exit,
    target: [:0]const u8 = "",
    seat: [:0]const u8 = "",
    value: [:0]const u8 = "",
};

pub fn handles(args: []const [:0]const u8) bool {
    if (args.len < 2) return false;
    for ([_][]const u8{ "shell", "window", "workspace", "session", "keyboard", "overview" }) |name|
        if (std.mem.eql(u8, args[1], name)) return true;
    return false;
}

fn parse(args: []const [:0]const u8) !Options {
    if (args.len < 3) return error.InvalidArguments;
    const family = args[1];
    const verb = args[2];
    var opts: Options = .{ .mode = .command };
    if (std.mem.eql(u8, family, "shell") or (std.mem.eql(u8, family, "keyboard") and std.mem.eql(u8, verb, "query"))) {
        if (args.len != 4 or !std.mem.eql(u8, args[3], "--json")) return error.InvalidArguments;
        opts.mode = if (std.mem.eql(u8, verb, "capabilities")) .capabilities else if (std.mem.eql(u8, verb, "snapshot") or std.mem.eql(u8, verb, "query")) .snapshot else if (std.mem.eql(u8, verb, "watch")) .watch else return error.InvalidArguments;
        return opts;
    }
    var flags: std.StringHashMapUnmanaged([:0]const u8) = .empty;
    defer flags.deinit(a);
    var json = false;
    var i: usize = 3;
    while (i < args.len) {
        const key = args[i];
        if (std.mem.eql(u8, key, "--json")) {
            if (json) return error.InvalidArguments;
            json = true;
            i += 1;
        } else {
            if (i + 1 >= args.len or !std.mem.startsWith(u8, key, "--") or flags.contains(key)) return error.InvalidArguments;
            if (args[i + 1].len == 0 or args[i + 1].len > 1024) return error.InvalidArguments;
            try flags.put(a, key, args[i + 1]);
            i += 2;
        }
    }
    if (!json) return error.InvalidArguments;
    if (std.mem.eql(u8, family, "window")) {
        opts.target = take(&flags, "--id") orelse return error.InvalidArguments;
        if (std.mem.eql(u8, verb, "activate")) {
            opts.action = .window_activate;
            opts.seat = take(&flags, "--seat") orelse "";
        } else if (std.mem.eql(u8, verb, "close")) {
            opts.action = .window_close;
        } else if (std.mem.eql(u8, verb, "state")) {
            if (take(&flags, "--minimized")) |v| {
                opts.action = .window_minimized;
                opts.value = v;
            } else if (take(&flags, "--maximized")) |v| {
                opts.action = .window_maximized;
                opts.value = v;
            } else if (take(&flags, "--fullscreen")) |v| {
                opts.action = .window_fullscreen;
                opts.value = v;
            } else return error.InvalidArguments;
            if (!std.mem.eql(u8, opts.value, "true") and !std.mem.eql(u8, opts.value, "false")) return error.InvalidArguments;
        } else if (std.mem.eql(u8, verb, "move")) {
            if (take(&flags, "--workspace-id")) |v| {
                opts.action = .window_move_workspace;
                opts.value = v;
            } else if (take(&flags, "--output")) |v| {
                opts.action = .window_move_output;
                opts.value = v;
            } else return error.InvalidArguments;
        } else return error.InvalidArguments;
    } else if (std.mem.eql(u8, family, "workspace")) {
        opts.target = take(&flags, "--id") orelse return error.InvalidArguments;
        if (std.mem.eql(u8, verb, "activate")) {
            opts.action = .workspace_activate;
            opts.seat = take(&flags, "--seat") orelse "";
        } else if (std.mem.eql(u8, verb, "rename")) {
            opts.action = .workspace_rename;
            opts.value = take(&flags, "--name") orelse return error.InvalidArguments;
        } else return error.InvalidArguments;
    } else if (std.mem.eql(u8, family, "session") and std.mem.eql(u8, verb, "exit")) {
        opts.action = .session_exit;
    } else if (std.mem.eql(u8, family, "keyboard")) {
        opts.seat = take(&flags, "--seat") orelse "";
        opts.target = take(&flags, "--group") orelse "";
        if (std.mem.eql(u8, verb, "set")) {
            opts.action = .keyboard_set;
            opts.value = take(&flags, "--index") orelse return error.InvalidArguments;
            _ = std.fmt.parseInt(u32, opts.value, 10) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, verb, "next")) opts.action = .keyboard_next else return error.InvalidArguments;
    } else if (std.mem.eql(u8, family, "overview")) {
        if (std.mem.eql(u8, verb, "hide")) opts.action = .overview_hide else {
            opts.value = take(&flags, "--output") orelse return error.InvalidArguments;
            if (std.mem.eql(u8, verb, "show")) opts.action = .overview_show else if (std.mem.eql(u8, verb, "toggle")) opts.action = .overview_toggle else return error.InvalidArguments;
        }
    } else return error.InvalidArguments;
    if (flags.count() != 0) return error.InvalidArguments;
    return opts;
}
fn take(flags: *std.StringHashMapUnmanaged([:0]const u8), key: []const u8) ?[:0]const u8 {
    return if (flags.fetchRemove(key)) |entry| entry.value else null;
}

const State = struct {
    manager: ?*Protocol = null,
    output: *std.Io.Writer,
    mode: Mode,
    ready: bool = false,
    registry_done: bool = false,
    done: bool = false,
    failure: ?anyerror = null,
    serial: ?u32 = null,
    buffer: std.ArrayList(u8) = .empty,
    sequence: ?[]u8 = null,
    session: ?[]u8 = null,
};

pub fn run(args: []const [:0]const u8, output: *std.Io.Writer) !void {
    const options = try parse(args);
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();
    var state: State = .{ .mode = options.mode, .output = output };
    defer {
        state.buffer.deinit(a);
        if (state.sequence) |v| a.free(v);
        if (state.session) |v| a.free(v);
    }
    registry.setListener(*State, onRegistry, &state);
    const deadline = now() + 5000;
    const sync = try display.sync();
    sync.setListener(*State, struct {
        fn callback(cb: *wl.Callback, _: wl.Callback.Event, st: *State) void {
            st.registry_done = true;
            cb.destroy();
        }
    }.callback, &state);
    while (!state.registry_done or (!state.ready and state.manager != null)) {
        try pump(display, deadline);
        if (state.failure) |err| return err;
    }
    const manager = state.manager orelse return error.UnsupportedCompositor;
    defer manager.destroy();
    if (!state.ready) return error.MissingCapabilities;
    if (options.mode == .capabilities) return;
    if (options.mode == .command) manager.command(1, options.action, options.target, options.seat, options.value) else manager.subscribe();
    while (!state.done and state.failure == null) {
        try pump(display, if (options.mode == .watch and state.sequence != null) null else deadline);
    }
    if (state.failure) |err| return err;
}
fn now() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}
fn pump(display: *wl.Display, deadline: ?i64) !void {
    if (!display.prepareRead()) {
        if (display.dispatchPending() != .SUCCESS) return error.Disconnected;
        return;
    }
    var prepared = true;
    defer if (prepared) display.cancelRead();
    var events: i16 = std.c.POLL.IN;
    switch (display.flush()) {
        .SUCCESS => {},
        .AGAIN => events |= std.c.POLL.OUT,
        else => return error.Disconnected,
    }
    const timeout: i32 = if (deadline) |end| @intCast(@max(0, end - now())) else -1;
    var fd: [1]std.c.pollfd = .{.{ .fd = display.getFd(), .events = events, .revents = 0 }};
    const ready = std.c.poll(&fd, 1, timeout);
    if (ready == 0) return error.TimedOut;
    if (ready < 0) {
        if (std.posix.errno(ready) == .INTR) return;
        return error.Disconnected;
    }
    if (fd[0].revents & std.c.POLL.IN != 0) {
        prepared = false;
        if (display.readEvents() != .SUCCESS or display.dispatchPending() != .SUCCESS) return error.Disconnected;
    } else if (fd[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL) != 0) return error.Disconnected;
}

fn onRegistry(registry: *wl.Registry, event: wl.Registry.Event, state: *State) void {
    switch (event) {
        .global => |g| {
            if (!std.mem.eql(u8, std.mem.span(g.interface), std.mem.span(Protocol.interface.name))) return;
            state.manager = registry.bind(g.name, Protocol, 1) catch {
                state.failure = error.OutOfMemory;
                return;
            };
            state.manager.?.setListener(*State, onEvent, state);
        },
        else => {},
    }
}
fn onEvent(manager: *Protocol, event: Protocol.Event, state: *State) void {
    handleEvent(manager, event, state) catch |err| {
        state.failure = err;
    };
}
fn handleEvent(manager: *Protocol, event: Protocol.Event, state: *State) !void {
    switch (event) {
        .capabilities => |v| {
            const json = std.mem.span(v.json);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidCapabilities;
            const schema = parsed.value.object.get("schema") orelse return error.InvalidCapabilities;
            if (schema != .integer or schema.integer != 1) return error.UnsupportedSchema;
            state.ready = true;
            if (state.mode == .capabilities) {
                try state.output.writeAll(json);
                try state.output.writeByte('\n');
                try state.output.flush();
            }
        },
        .begin => |v| {
            if (state.serial != null) return error.InvalidBatch;
            state.serial = v.serial;
            state.buffer.clearRetainingCapacity();
        },
        .data => |v| {
            if (state.serial == null or v.bytes.size > 4 * 1024 * 1024 - state.buffer.items.len) return error.InvalidBatch;
            if (v.bytes.size == 0) return;
            const bytes: [*]const u8 = @ptrCast(v.bytes.data);
            try state.buffer.appendSlice(a, bytes[0..v.bytes.size]);
        },
        .done => |v| {
            if (state.serial == null or state.serial.? != v.serial) return error.InvalidBatch;
            try validateBatch(state);
            try state.output.writeAll(state.buffer.items);
            try state.output.writeByte('\n');
            try state.output.flush();
            state.serial = null;
            manager.ack(v.serial);
            if (state.mode == .snapshot) state.done = true;
        },
        .result => |v| {
            if (state.mode != .command or v.request_id != 1) return error.InvalidResult;
            const ok = v.status == .applied or v.status == .accepted;
            try std.json.Stringify.value(.{ .ok = ok, .status = @tagName(v.status), .sequence = std.mem.span(v.sequence) }, .{}, state.output);
            try state.output.writeByte('\n');
            try state.output.flush();
            state.done = true;
            if (!ok) return error.CommandFailed;
        },
        .workspace_id => {},
    }
}
fn string(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = object.get(key) orelse return error.InvalidBatch;
    return if (v == .string) v.string else error.InvalidBatch;
}
fn validateBatch(state: *State) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, state.buffer.items, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBatch;
    const obj = parsed.value.object;
    const schema = obj.get("schema") orelse return error.InvalidBatch;
    if (schema != .integer or schema.integer != 1) return error.UnsupportedSchema;
    const sequence = try string(obj, "sequence");
    _ = try std.fmt.parseInt(u64, sequence, 10);
    const session = try string(obj, "session");
    const kind = try string(obj, "type");
    const base = obj.get("base_sequence") orelse return error.InvalidBatch;
    if (state.sequence) |previous| {
        if (!std.mem.eql(u8, kind, "delta") or base != .string or !std.mem.eql(u8, base.string, previous) or
            !std.mem.eql(u8, session, state.session.?) or (try std.fmt.parseInt(u64, sequence, 10)) <= (try std.fmt.parseInt(u64, previous, 10))) return error.InvalidBatch;
    } else if (!std.mem.eql(u8, kind, "snapshot") or base != .null) return error.InvalidBatch;
    for ([_][]const u8{ "upsert", "removed" }) |key| {
        const v = obj.get(key) orelse return error.InvalidBatch;
        if (v != .array) return error.InvalidBatch;
    }
    const next = try a.dupe(u8, sequence);
    errdefer a.free(next);
    const next_session = try a.dupe(u8, session);
    if (state.sequence) |v| a.free(v);
    if (state.session) |v| a.free(v);
    state.sequence = next;
    state.session = next_session;
}

test "shell CLI rejects ambiguous or unknown mutation arguments" {
    const t = std.testing;
    try t.expectError(error.InvalidArguments, parse(&.{ "aqueousctl", "window", "move", "--id", "x", "--output", "DP-1", "--workspace-id", "1", "--json" }));
    try t.expectError(error.InvalidArguments, parse(&.{ "aqueousctl", "window", "state", "--id", "x", "--minimized", "yes", "--json" }));
    try t.expectError(error.InvalidArguments, parse(&.{ "aqueousctl", "session", "exit", "--force", "true", "--json" }));
    const opts = try parse(&.{ "aqueousctl", "workspace", "rename", "--id", "7", "--name", "quoted \"name\"", "--json" });
    try t.expectEqual(Protocol.Action.workspace_rename, opts.action);
    try t.expectEqualStrings("quoted \"name\"", opts.value);
}

test "batch continuity requires exact base and session" {
    var state: State = .{ .mode = .watch, .output = undefined };
    defer {
        state.buffer.deinit(a);
        if (state.sequence) |v| a.free(v);
        if (state.session) |v| a.free(v);
    }
    try state.buffer.appendSlice(a, "{\"schema\":1,\"session\":\"a\",\"sequence\":\"1\",\"base_sequence\":null,\"type\":\"snapshot\",\"upsert\":[],\"removed\":[]}");
    try validateBatch(&state);
    state.buffer.clearRetainingCapacity();
    try state.buffer.appendSlice(a, "{\"schema\":1,\"session\":\"a\",\"sequence\":\"4\",\"base_sequence\":\"2\",\"type\":\"delta\",\"upsert\":[],\"removed\":[]}");
    try std.testing.expectError(error.InvalidBatch, validateBatch(&state));
}
