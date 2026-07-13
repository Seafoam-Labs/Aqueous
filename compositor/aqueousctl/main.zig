// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const aqueous = wayland.client.aqueous;

const io = Io.Threaded.global_single_threaded.io();
const allocator = std.heap.c_allocator;

const usage =
    \\usage: aqueousctl windows [--json]
    \\       aqueousctl inspect --rule
    \\
    \\List mapped windows or emit ready-to-paste rules.toml entries.
    \\
;

const Geometry = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };

const Window = struct {
    state: *State,
    handle: *ext.ForeignToplevelHandleV1,
    info: ?*aqueous.WindowInfoV1 = null,
    info_requested: bool = false,
    info_done: bool = false,
    closed: bool = false,

    identifier: ?[]u8 = null,
    title: ?[]u8 = null,
    foreign_app_id: ?[]u8 = null,
    app_id: ?[]u8 = null,
    class: ?[]u8 = null,
    output: ?[]u8 = null,
    layout: ?[]u8 = null,
    backend: aqueous.WindowInfoV1.Backend = .xdg,
    workspace: u32 = 0,
    geometry: Geometry = .{},
    states: aqueous.WindowInfoV1.State = .{},
    matched_rule: u32 = 0,
    rule_app_id: ?[]u8 = null,
    rule_class: ?[]u8 = null,
    rule_title: ?[]u8 = null,

    fn deinit(window: *Window) void {
        inline for (.{
            window.identifier,
            window.title,
            window.foreign_app_id,
            window.app_id,
            window.class,
            window.output,
            window.layout,
            window.rule_app_id,
            window.rule_class,
            window.rule_title,
        }) |value| if (value) |owned| allocator.free(owned);
        allocator.destroy(window);
    }
};

const State = struct {
    registry: *wl.Registry,
    list_name: u32 = 0,
    list_version: u32 = 0,
    info_name: u32 = 0,
    info_version: u32 = 0,
    list: ?*ext.ForeignToplevelListV1 = null,
    info_manager: ?*aqueous.WindowInfoManagerV1 = null,
    list_finished: bool = false,
    windows: std.ArrayListUnmanaged(*Window) = .empty,

    fn deinit(state: *State) void {
        for (state.windows.items) |window| window.deinit();
        state.windows.deinit(allocator);
        state.registry.destroy();
    }

    fn pending(state: *const State) bool {
        if (!state.list_finished) return true;
        for (state.windows.items) |window| {
            if (!window.closed and !window.info_done) return true;
        }
        return false;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const mode: enum { windows, json, rules } = blk: {
        if (args.len == 2 and mem.eql(u8, args[1], "windows")) break :blk .windows;
        if (args.len == 3 and mem.eql(u8, args[1], "windows") and mem.eql(u8, args[2], "--json")) break :blk .json;
        if (args.len == 3 and mem.eql(u8, args[1], "inspect") and mem.eql(u8, args[2], "--rule")) break :blk .rules;
        try stderr.writeAll(usage);
        try stderr.flush();
        std.process.exit(2);
    };

    const display = wl.Display.connect(null) catch {
        try stderr.writeAll("aqueousctl: unable to connect to the Wayland compositor\n");
        try stderr.flush();
        std.process.exit(1);
    };
    defer display.disconnect();

    const registry = try display.getRegistry();
    var state: State = .{ .registry = registry };
    defer state.deinit();
    registry.setListener(*State, registryListener, &state);
    tryRoundtrip(display, stderr);

    if (state.list_name == 0 or state.info_name == 0) {
        try stderr.writeAll("aqueousctl: compositor does not expose Aqueous window introspection\n");
        try stderr.flush();
        std.process.exit(1);
    }

    state.info_manager = try registry.bind(state.info_name, aqueous.WindowInfoManagerV1, state.info_version);
    state.list = try registry.bind(state.list_name, ext.ForeignToplevelListV1, state.list_version);
    state.list.?.setListener(*State, listListener, &state);

    // Receive the initial list. Handle done callbacks issue their corresponding
    // Aqueous snapshot requests before stop creates a race-free end marker.
    tryRoundtrip(display, stderr);
    state.list.?.stop();
    var rounds: usize = 0;
    while (state.pending() and rounds < 8) : (rounds += 1) tryRoundtrip(display, stderr);
    if (state.pending()) {
        try stderr.writeAll("aqueousctl: timed out collecting a consistent window snapshot\n");
        try stderr.flush();
        std.process.exit(1);
    }

    switch (mode) {
        .windows => try writeHuman(stdout, &state),
        .json => try writeJson(stdout, &state),
        .rules => try writeRules(stdout, &state),
    }
    try stdout.flush();
}

fn tryRoundtrip(display: *wl.Display, stderr: *Io.Writer) void {
    if (display.roundtrip() == .SUCCESS) return;
    stderr.writeAll("aqueousctl: Wayland connection failed\n") catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

fn registryListener(_: *wl.Registry, event: wl.Registry.Event, state: *State) void {
    switch (event) {
        .global => |global| {
            const name = mem.span(global.interface);
            if (mem.eql(u8, name, mem.span(ext.ForeignToplevelListV1.interface.name))) {
                state.list_name = global.name;
                state.list_version = global.version;
            } else if (mem.eql(u8, name, mem.span(aqueous.WindowInfoManagerV1.interface.name))) {
                state.info_name = global.name;
                state.info_version = global.version;
            }
        },
        .global_remove => {},
    }
}

fn listListener(_: *ext.ForeignToplevelListV1, event: ext.ForeignToplevelListV1.Event, state: *State) void {
    switch (event) {
        .toplevel => |created| {
            const window = allocator.create(Window) catch return;
            window.* = .{ .state = state, .handle = created.toplevel };
            state.windows.append(allocator, window) catch {
                allocator.destroy(window);
                return;
            };
            created.toplevel.setListener(*Window, handleListener, window);
        },
        .finished => state.list_finished = true,
    }
}

fn handleListener(_: *ext.ForeignToplevelHandleV1, event: ext.ForeignToplevelHandleV1.Event, window: *Window) void {
    switch (event) {
        .closed => window.closed = true,
        .done => {
            if (window.info_requested) return;
            const manager = window.state.info_manager orelse return;
            const info = manager.getWindowInfo(window.handle) catch return;
            window.info = info;
            window.info_requested = true;
            info.setListener(*Window, infoListener, window);
        },
        .title => |value| replaceString(&window.title, mem.span(value.title)),
        .app_id => |value| replaceString(&window.foreign_app_id, mem.span(value.app_id)),
        .identifier => |value| replaceString(&window.identifier, mem.span(value.identifier)),
    }
}

fn infoListener(_: *aqueous.WindowInfoV1, event: aqueous.WindowInfoV1.Event, window: *Window) void {
    switch (event) {
        .backend => |value| window.backend = value.backend,
        .app_id => |value| replaceString(&window.app_id, mem.span(value.app_id)),
        .class => |value| replaceString(&window.class, mem.span(value.class)),
        .output => |value| replaceString(&window.output, mem.span(value.output)),
        .workspace => |value| window.workspace = value.workspace,
        .geometry => |value| window.geometry = .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height },
        .state => |value| window.states = value.state,
        .layout => |value| replaceString(&window.layout, mem.span(value.layout)),
        .matched_rule => |value| window.matched_rule = value.index,
        .rule_matcher => |value| switch (value.matcher) {
            .app_id => replaceString(&window.rule_app_id, mem.span(value.pattern)),
            .class => replaceString(&window.rule_class, mem.span(value.pattern)),
            .title => replaceString(&window.rule_title, mem.span(value.pattern)),
            _ => {},
        },
        .done => window.info_done = true,
    }
}

fn replaceString(destination: *?[]u8, value: []const u8) void {
    const replacement = allocator.dupe(u8, value) catch return;
    if (destination.*) |old| allocator.free(old);
    destination.* = replacement;
}

fn writeHuman(writer: *Io.Writer, state: *const State) !void {
    try writer.writeAll("ID\tBACKEND\tAPP_ID/CLASS\tTITLE\tOUTPUT:WORKSPACE\tGEOMETRY\tLAYOUT\tSTATE\n");
    for (state.windows.items) |window| {
        if (window.closed or !window.info_done) continue;
        const identity = window.app_id orelse window.class orelse window.foreign_app_id orelse "";
        try writer.print("{s}\t{s}\t{s}\t{s}\t{s}:{d}\t{d},{d} {d}x{d}\t{s}\t", .{
            window.identifier orelse "",
            @tagName(window.backend),
            identity,
            window.title orelse "",
            window.output orelse "",
            window.workspace,
            window.geometry.x,
            window.geometry.y,
            window.geometry.width,
            window.geometry.height,
            window.layout orelse "",
        });
        try writeStates(writer, window.states);
        try writer.writeByte('\n');
    }
}

fn writeStates(writer: *Io.Writer, states: aqueous.WindowInfoV1.State) !void {
    var first = true;
    try writeState(writer, &first, "focused", states.focused);
    try writeState(writer, &first, "floating", states.floating);
    try writeState(writer, &first, "fullscreen", states.fullscreen);
    try writeState(writer, &first, "maximized", states.maximized);
    try writeState(writer, &first, "minimized", states.minimized);
    try writeState(writer, &first, "visible", states.visible);
}

fn writeState(writer: *Io.Writer, first: *bool, name: []const u8, enabled: bool) !void {
    if (!enabled) return;
    if (!first.*) try writer.writeByte(',');
    try writer.writeAll(name);
    first.* = false;
}

fn writeJson(writer: *Io.Writer, state: *const State) !void {
    try writer.writeAll("[\n");
    var first = true;
    for (state.windows.items) |window| {
        if (window.closed or !window.info_done) continue;
        if (!first) try writer.writeAll(",\n");
        first = false;
        try writer.writeAll("  {");
        try jsonField(writer, "id", window.identifier, true);
        try jsonField(writer, "backend", @tagName(window.backend), false);
        try jsonField(writer, "app_id", window.app_id, false);
        try jsonField(writer, "class", window.class, false);
        try jsonField(writer, "title", window.title, false);
        try jsonField(writer, "output", window.output, false);
        try writer.print(",\"workspace\":{d},\"geometry\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
            window.workspace, window.geometry.x, window.geometry.y, window.geometry.width, window.geometry.height,
        });
        try jsonField(writer, "layout", window.layout, false);
        try writer.print(",\"matched_rule\":{d},\"states\":[", .{window.matched_rule});
        var states_buffer: [128]u8 = undefined;
        var states_writer = Io.Writer.fixed(&states_buffer);
        try writeStates(&states_writer, window.states);
        var states = mem.splitScalar(u8, states_writer.buffered(), ',');
        var state_first = true;
        while (states.next()) |name| {
            if (name.len == 0) continue;
            if (!state_first) try writer.writeByte(',');
            try jsonString(writer, name);
            state_first = false;
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("\n]\n");
}

fn jsonField(writer: *Io.Writer, name: []const u8, value: ?[]const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try jsonString(writer, name);
    try writer.writeByte(':');
    if (value) |text| try jsonString(writer, text) else try writer.writeAll("null");
}

fn jsonString(writer: *Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20)
            try writer.print("\\u00{x:0>2}", .{byte})
        else
            try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn writeRules(writer: *Io.Writer, state: *const State) !void {
    for (state.windows.items) |window| {
        if (window.closed or !window.info_done) continue;
        try writer.writeAll("# ");
        try writer.writeAll(window.identifier orelse "unknown");
        try writer.writeAll(" — ");
        const title = window.title orelse "";
        for (title) |byte| try writer.writeByte(if (byte == '\n' or byte == '\r') ' ' else byte);
        if (window.matched_rule != 0) try writer.print(" (currently matches rule {d})", .{window.matched_rule});
        try writer.writeAll("\n[[window]]\n");
        if (window.backend == .xwayland) {
            try writer.writeAll("class = ");
            try jsonString(writer, window.class orelse window.foreign_app_id orelse "");
        } else {
            try writer.writeAll("app_id = ");
            try jsonString(writer, window.app_id orelse window.foreign_app_id orelse "");
        }
        try writer.writeAll("\n# title = ");
        try jsonString(writer, title);
        try writer.writeAll("\n\n");
    }
}
