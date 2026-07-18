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
    \\       aqueousctl scene [--dot]
    \\       aqueousctl outputs
    \\
    \\Inspect mapped windows and outputs, author rules, or visualize the compositor scene graph.
    \\
;

const Geometry = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };

const Mode = enum { windows, json, rules, scene, scene_dot, outputs };

const OutputMode = struct {
    width: i32,
    height: i32,
    refresh_mhz: i32,
    current: bool,
    preferred: bool,
};

const DisplayOutput = struct {
    handle: *wl.Output,
    global_name: u32,
    name: ?[]u8 = null,
    make: ?[]u8 = null,
    model: ?[]u8 = null,
    description: ?[]u8 = null,
    removed: bool = false,
    modes: std.ArrayListUnmanaged(OutputMode) = .empty,

    fn deinit(output: *DisplayOutput) void {
        inline for (.{ output.name, output.make, output.model, output.description }) |value| {
            if (value) |owned| allocator.free(owned);
        }
        output.modes.deinit(allocator);
        if (output.handle.getVersion() >= wl.Output.release_since_version) {
            output.handle.release();
        } else {
            output.handle.destroy();
        }
        allocator.destroy(output);
    }
};

const SceneNode = struct {
    id: u32,
    parent: u32,
    label: []u8,
    node_type: aqueous.SceneSnapshotV1.NodeType,
    enabled: bool,
    geometry: Geometry,
};

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
    collect_outputs: bool = false,
    list_name: u32 = 0,
    list_version: u32 = 0,
    info_name: u32 = 0,
    info_version: u32 = 0,
    list: ?*ext.ForeignToplevelListV1 = null,
    info_manager: ?*aqueous.WindowInfoManagerV1 = null,
    scene_snapshot: ?*aqueous.SceneSnapshotV1 = null,
    scene_done: bool = false,
    scene_nodes: std.ArrayListUnmanaged(SceneNode) = .empty,
    outputs: std.ArrayListUnmanaged(*DisplayOutput) = .empty,
    list_finished: bool = false,
    windows: std.ArrayListUnmanaged(*Window) = .empty,

    fn deinit(state: *State) void {
        for (state.windows.items) |window| window.deinit();
        state.windows.deinit(allocator);
        for (state.scene_nodes.items) |node| allocator.free(node.label);
        state.scene_nodes.deinit(allocator);
        for (state.outputs.items) |output| output.deinit();
        state.outputs.deinit(allocator);
        state.registry.destroy();
    }

    fn pending(state: *const State) bool {
        if (!state.list_finished) return true;
        for (state.windows.items) |window| {
            if (!window.closed and !window.info_done) return true;
        }
        return false;
    }

    fn scenePending(state: *const State) bool {
        return !state.scene_done;
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

    const mode = parseMode(args) orelse {
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
    var state: State = .{ .registry = registry, .collect_outputs = mode == .outputs };
    defer state.deinit();
    registry.setListener(*State, registryListener, &state);
    tryRoundtrip(display, stderr);

    if (mode == .outputs) {
        // Output globals are bound while dispatching the registry roundtrip.
        // Complete one more roundtrip to receive their initial geometry, name,
        // and advertised mode batches before rendering the snapshot.
        tryRoundtrip(display, stderr);
        try writeOutputs(stdout, &state);
        try stdout.flush();
        return;
    }

    const scene_mode = mode == .scene or mode == .scene_dot;
    if (state.info_name == 0 or (!scene_mode and state.list_name == 0)) {
        try stderr.writeAll("aqueousctl: compositor does not expose Aqueous window introspection\n");
        try stderr.flush();
        std.process.exit(1);
    }

    state.info_manager = try registry.bind(state.info_name, aqueous.WindowInfoManagerV1, state.info_version);
    if (scene_mode) {
        if (state.info_version < 2) {
            try stderr.writeAll("aqueousctl: compositor does not expose scene graph snapshots\n");
            try stderr.flush();
            std.process.exit(1);
        }
        state.scene_snapshot = try state.info_manager.?.getSceneSnapshot();
        state.scene_snapshot.?.setListener(*State, sceneListener, &state);
        var rounds: usize = 0;
        while (state.scenePending() and rounds < 8) : (rounds += 1) tryRoundtrip(display, stderr);
        if (state.scenePending()) {
            try stderr.writeAll("aqueousctl: timed out collecting the scene graph snapshot\n");
            try stderr.flush();
            std.process.exit(1);
        }
        if (mode == .scene) try writeSceneTree(stdout, &state) else try writeSceneDot(stdout, &state);
        try stdout.flush();
        return;
    }

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
        .scene, .scene_dot, .outputs => unreachable,
    }
    try stdout.flush();
}

fn parseMode(args: anytype) ?Mode {
    if (args.len == 2 and mem.eql(u8, args[1], "windows")) return .windows;
    if (args.len == 3 and mem.eql(u8, args[1], "windows") and mem.eql(u8, args[2], "--json")) return .json;
    if (args.len == 3 and mem.eql(u8, args[1], "inspect") and mem.eql(u8, args[2], "--rule")) return .rules;
    if (args.len == 2 and mem.eql(u8, args[1], "scene")) return .scene;
    if (args.len == 3 and mem.eql(u8, args[1], "scene") and mem.eql(u8, args[2], "--dot")) return .scene_dot;
    if (args.len == 2 and mem.eql(u8, args[1], "outputs")) return .outputs;
    return null;
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
            } else if (state.collect_outputs and mem.eql(u8, name, mem.span(wl.Output.interface.name))) {
                const version = @min(global.version, wl.Output.generated_version);
                const handle = state.registry.bind(global.name, wl.Output, version) catch return;
                const output = allocator.create(DisplayOutput) catch {
                    if (version >= wl.Output.release_since_version) handle.release() else handle.destroy();
                    return;
                };
                output.* = .{ .handle = handle, .global_name = global.name };
                state.outputs.append(allocator, output) catch {
                    output.deinit();
                    return;
                };
                handle.setListener(*DisplayOutput, outputListener, output);
            }
        },
        .global_remove => |removed| for (state.outputs.items) |output| {
            if (output.global_name == removed.name) {
                output.removed = true;
                break;
            }
        },
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, output: *DisplayOutput) void {
    switch (event) {
        .geometry => |value| {
            replaceString(&output.make, mem.span(value.make));
            replaceString(&output.model, mem.span(value.model));
        },
        .mode => |value| {
            if (value.flags.current) {
                for (output.modes.items) |*existing| existing.current = false;
            }
            for (output.modes.items) |*existing| {
                if (existing.width != value.width or
                    existing.height != value.height or
                    existing.refresh_mhz != value.refresh) continue;
                existing.current = value.flags.current;
                existing.preferred = value.flags.preferred;
                return;
            }
            output.modes.append(allocator, .{
                .width = value.width,
                .height = value.height,
                .refresh_mhz = value.refresh,
                .current = value.flags.current,
                .preferred = value.flags.preferred,
            }) catch {};
        },
        .name => |value| replaceString(&output.name, mem.span(value.name)),
        .description => |value| replaceString(&output.description, mem.span(value.description)),
        .done, .scale => {},
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

fn sceneListener(_: *aqueous.SceneSnapshotV1, event: aqueous.SceneSnapshotV1.Event, state: *State) void {
    switch (event) {
        .node => |value| {
            const label = allocator.dupe(u8, mem.span(value.label)) catch return;
            state.scene_nodes.append(allocator, .{
                .id = value.id,
                .parent = value.parent,
                .label = label,
                .node_type = value.node_type,
                .enabled = value.enabled != 0,
                .geometry = .{
                    .x = value.x,
                    .y = value.y,
                    .width = value.width,
                    .height = value.height,
                },
            }) catch allocator.free(label);
        },
        .done => state.scene_done = true,
    }
}

fn replaceString(destination: *?[]u8, value: []const u8) void {
    const replacement = allocator.dupe(u8, value) catch return;
    if (destination.*) |old| allocator.free(old);
    destination.* = replacement;
}

fn writeSceneTree(writer: *Io.Writer, state: *const State) !void {
    for (state.scene_nodes.items, 0..) |node, index| {
        var chain: [256]usize = undefined;
        var chain_len: usize = 0;
        var cursor: ?usize = index;
        while (cursor) |node_index| {
            if (chain_len == chain.len) break;
            chain[chain_len] = node_index;
            chain_len += 1;
            const parent = state.scene_nodes.items[node_index].parent;
            cursor = if (parent == 0) null else sceneNodeIndex(state, parent);
        }

        if (chain_len > 1) {
            var level = chain_len - 1;
            while (level > 1) : (level -= 1) {
                const ancestor_index = chain[level - 1];
                try writer.writeAll(if (hasLaterSceneSibling(state, ancestor_index)) "│  " else "   ");
            }
            try writer.writeAll(if (hasLaterSceneSibling(state, index)) "├─ " else "└─ ");
        }

        try writeSingleLine(writer, node.label);
        try writer.print(" [{s}]", .{@tagName(node.node_type)});
        if (!node.enabled) try writer.writeAll(" disabled");
        if (node.geometry.x != 0 or node.geometry.y != 0 or
            node.geometry.width != 0 or node.geometry.height != 0)
        {
            try writer.print(" ({d},{d} {d}x{d})", .{
                node.geometry.x,
                node.geometry.y,
                node.geometry.width,
                node.geometry.height,
            });
        }
        try writer.writeByte('\n');
    }
}

fn sceneNodeIndex(state: *const State, id: u32) ?usize {
    for (state.scene_nodes.items, 0..) |node, index| if (node.id == id) return index;
    return null;
}

fn hasLaterSceneSibling(state: *const State, index: usize) bool {
    const parent = state.scene_nodes.items[index].parent;
    for (state.scene_nodes.items[index + 1 ..]) |candidate| {
        if (candidate.parent == parent) return true;
    }
    return false;
}

fn writeSingleLine(writer: *Io.Writer, value: []const u8) !void {
    for (value) |byte| try writer.writeByte(if (byte == '\n' or byte == '\r') ' ' else byte);
}

fn writeOutputs(writer: *Io.Writer, state: *const State) !void {
    var rendered: usize = 0;
    for (state.outputs.items) |output| {
        if (output.removed) continue;
        if (rendered != 0) try writer.writeByte('\n');
        rendered += 1;

        if (output.name) |name| {
            try writeSingleLine(writer, name);
        } else {
            try writer.print("output-{d}", .{output.global_name});
        }

        if (output.description) |text| {
            try writer.writeAll(" — ");
            try writeSingleLine(writer, text);
        } else if (output.make != null or output.model != null) {
            var identity_buffer: [512]u8 = undefined;
            const identity = std.fmt.bufPrint(&identity_buffer, "{s}{s}{s}", .{
                output.make orelse "",
                if (output.make != null and output.model != null) " " else "",
                output.model orelse "",
            }) catch "";
            if (identity.len != 0) {
                try writer.writeAll(" — ");
                try writeSingleLine(writer, identity);
            }
        }
        try writer.writeByte('\n');

        if (output.modes.items.len == 0) {
            try writer.writeAll("  (no modes advertised)\n");
            continue;
        }
        for (output.modes.items) |available| {
            try writer.print("  {d}x{d} @ ", .{ available.width, available.height });
            try writeRefreshRate(writer, available.refresh_mhz);
            if (available.current or available.preferred) {
                try writer.writeAll(" [");
                if (available.current) try writer.writeAll("current");
                if (available.current and available.preferred) try writer.writeAll(", ");
                if (available.preferred) try writer.writeAll("preferred");
                try writer.writeByte(']');
            }
            try writer.writeByte('\n');
        }
    }
    if (rendered == 0) try writer.writeAll("No outputs found.\n");
}

fn writeRefreshRate(writer: *Io.Writer, refresh_mhz: i32) !void {
    if (refresh_mhz <= 0) return writer.writeAll("unknown refresh");
    const fractional = @mod(refresh_mhz, 1000);
    try writer.print("{d}.", .{@divTrunc(refresh_mhz, 1000)});
    if (fractional < 10) {
        try writer.print("00{d}", .{fractional});
    } else if (fractional < 100) {
        try writer.print("0{d}", .{fractional});
    } else {
        try writer.print("{d}", .{fractional});
    }
    try writer.writeAll(" Hz");
}

fn writeSceneDot(writer: *Io.Writer, state: *const State) !void {
    try writer.writeAll(
        \\digraph aqueous_scene {
        \\  graph [rankdir=LR, bgcolor="#111827", fontname="monospace"];
        \\  node [shape=box, style="rounded,filled", fontname="monospace", color="#475569", fontcolor="#0f172a"];
        \\  edge [color="#64748b"];
        \\
    );
    for (state.scene_nodes.items) |node| {
        try writer.print("  n{d} [label=\"", .{node.id});
        try writeDotEscaped(writer, node.label);
        try writer.print("\\n{s}", .{@tagName(node.node_type)});
        if (!node.enabled) try writer.writeAll(" · disabled");
        if (node.geometry.x != 0 or node.geometry.y != 0 or
            node.geometry.width != 0 or node.geometry.height != 0)
        {
            try writer.print("\\n{d},{d} {d}x{d}", .{
                node.geometry.x,
                node.geometry.y,
                node.geometry.width,
                node.geometry.height,
            });
        }
        const fill = if (!node.enabled) "#94a3b8" else switch (node.node_type) {
            .tree => "#93c5fd",
            .rect => "#fcd34d",
            .buffer => "#86efac",
            _ => "#e2e8f0",
        };
        try writer.print("\", fillcolor=\"{s}\"", .{fill});
        if (!node.enabled) try writer.writeAll(", style=\"rounded,filled,dashed\"");
        try writer.writeAll("];\n");
    }
    for (state.scene_nodes.items) |node| {
        if (node.parent != 0) try writer.print("  n{d} -> n{d};\n", .{ node.parent, node.id });
    }
    try writer.writeAll("}\n");
}

fn writeDotEscaped(writer: *Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n', '\r' => try writer.writeAll("\\n"),
        else => if (byte < 0x20)
            try writer.writeByte('?')
        else
            try writer.writeByte(byte),
    };
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

test "command modes accept only documented argument forms" {
    const testing = std.testing;

    try testing.expectEqual(Mode.windows, parseMode(&.{ "aqueousctl", "windows" }).?);
    try testing.expectEqual(Mode.json, parseMode(&.{ "aqueousctl", "windows", "--json" }).?);
    try testing.expectEqual(Mode.rules, parseMode(&.{ "aqueousctl", "inspect", "--rule" }).?);
    try testing.expectEqual(Mode.scene, parseMode(&.{ "aqueousctl", "scene" }).?);
    try testing.expectEqual(Mode.scene_dot, parseMode(&.{ "aqueousctl", "scene", "--dot" }).?);
    try testing.expectEqual(Mode.outputs, parseMode(&.{ "aqueousctl", "outputs" }).?);

    try testing.expect(parseMode(&.{"aqueousctl"}) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "windows", "--dot" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "scene", "--json" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "outputs", "--json" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "inspect" }) == null);
}

test "outputs render advertised refresh rates and mode flags" {
    var state: State = .{ .registry = undefined };
    var first: DisplayOutput = .{
        .handle = undefined,
        .global_name = 7,
        .name = @constCast("DP-1"),
        .description = @constCast("Example Display\n27-inch"),
    };
    var first_modes = [_]OutputMode{
        .{ .width = 3840, .height = 2160, .refresh_mhz = 59_997, .current = true, .preferred = true },
        .{ .width = 2560, .height = 1440, .refresh_mhz = 120_000, .current = false, .preferred = false },
        .{ .width = 1920, .height = 1080, .refresh_mhz = 0, .current = false, .preferred = false },
    };
    first.modes = .{ .items = &first_modes, .capacity = first_modes.len };
    var second: DisplayOutput = .{
        .handle = undefined,
        .global_name = 9,
        .make = @constCast("Acme"),
        .model = @constCast("Panel"),
    };
    var outputs = [_]*DisplayOutput{ &first, &second };
    state.outputs = .{ .items = &outputs, .capacity = outputs.len };

    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeOutputs(&writer, &state);

    try std.testing.expectEqualStrings(
        "DP-1 — Example Display 27-inch\n" ++
            "  3840x2160 @ 59.997 Hz [current, preferred]\n" ++
            "  2560x1440 @ 120.000 Hz\n" ++
            "  1920x1080 @ unknown refresh\n" ++
            "\n" ++
            "output-9 — Acme Panel\n" ++
            "  (no modes advertised)\n",
        writer.buffered(),
    );
}

test "pending waits for the list and every live window snapshot" {
    var state: State = .{ .registry = undefined };
    var window: Window = .{
        .state = &state,
        .handle = undefined,
    };
    var windows = [_]*Window{&window};
    state.windows = .{ .items = &windows, .capacity = windows.len };

    try std.testing.expect(state.pending());
    state.list_finished = true;
    try std.testing.expect(state.pending());
    window.info_done = true;
    try std.testing.expect(!state.pending());
    window.info_done = false;
    window.closed = true;
    try std.testing.expect(!state.pending());
}

test "human output selects identity fallback and ordered states" {
    var state: State = .{ .registry = undefined };
    var window: Window = .{
        .state = &state,
        .handle = undefined,
        .info_done = true,
        .identifier = @constCast("window-1"),
        .title = @constCast("Editor"),
        .foreign_app_id = @constCast("foreign-editor"),
        .class = @constCast("EditorClass"),
        .output = @constCast("DP-1"),
        .layout = @constCast("dwindle"),
        .workspace = 4,
        .geometry = .{ .x = -10, .y = 20, .width = 1280, .height = 720 },
        .states = .{ .focused = true, .fullscreen = true, .visible = true },
    };
    var windows = [_]*Window{&window};
    state.windows = .{ .items = &windows, .capacity = windows.len };

    var buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeHuman(&writer, &state);

    try std.testing.expectEqualStrings(
        "ID\tBACKEND\tAPP_ID/CLASS\tTITLE\tOUTPUT:WORKSPACE\tGEOMETRY\tLAYOUT\tSTATE\n" ++
            "window-1\txdg\tEditorClass\tEditor\tDP-1:4\t-10,20 1280x720\tdwindle\tfocused,fullscreen,visible\n",
        writer.buffered(),
    );
}

test "json output escapes values, emits nulls, and filters unusable windows" {
    var state: State = .{ .registry = undefined };
    var included: Window = .{
        .state = &state,
        .handle = undefined,
        .info_done = true,
        .identifier = @constCast("id\"\\\n"),
        .app_id = @constCast("org.test\tapp"),
        .title = @constCast("line\rtitle"),
        .workspace = 2,
        .geometry = .{ .x = 1, .y = -2, .width = 3, .height = 4 },
        .matched_rule = 7,
        .states = .{ .floating = true, .minimized = true },
    };
    var closed: Window = .{
        .state = &state,
        .handle = undefined,
        .info_done = true,
        .closed = true,
        .identifier = @constCast("closed"),
    };
    var incomplete: Window = .{
        .state = &state,
        .handle = undefined,
        .identifier = @constCast("incomplete"),
    };
    var windows = [_]*Window{ &included, &closed, &incomplete };
    state.windows = .{ .items = &windows, .capacity = windows.len };

    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeJson(&writer, &state);

    try std.testing.expectEqualStrings(
        "[\n" ++
            "  {\"id\":\"id\\\"\\\\\\n\",\"backend\":\"xdg\",\"app_id\":\"org.test\\tapp\",\"class\":null,\"title\":\"line\\rtitle\",\"output\":null,\"workspace\":2,\"geometry\":{\"x\":1,\"y\":-2,\"width\":3,\"height\":4},\"layout\":null,\"matched_rule\":7,\"states\":[\"floating\",\"minimized\"]}\n" ++
            "]\n",
        writer.buffered(),
    );
}

test "rule suggestions use backend identity and sanitize titles" {
    var state: State = .{ .registry = undefined };
    var xdg: Window = .{
        .state = &state,
        .handle = undefined,
        .info_done = true,
        .identifier = @constCast("xdg-window"),
        .foreign_app_id = @constCast("foreign.xdg"),
        .app_id = @constCast("org.example.App"),
        .title = @constCast("First\nTitle"),
        .matched_rule = 3,
    };
    var xwayland: Window = .{
        .state = &state,
        .handle = undefined,
        .info_done = true,
        .backend = .xwayland,
        .identifier = @constCast("x11-window"),
        .foreign_app_id = @constCast("fallback-class"),
        .title = @constCast("Quoted \"title\""),
    };
    var windows = [_]*Window{ &xdg, &xwayland };
    state.windows = .{ .items = &windows, .capacity = windows.len };

    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeRules(&writer, &state);

    try std.testing.expectEqualStrings(
        "# xdg-window — First Title (currently matches rule 3)\n" ++
            "[[window]]\napp_id = \"org.example.App\"\n# title = \"First\\nTitle\"\n\n" ++
            "# x11-window — Quoted \"title\"\n" ++
            "[[window]]\nclass = \"fallback-class\"\n# title = \"Quoted \\\"title\\\"\"\n\n",
        writer.buffered(),
    );
}

test "scene tree renders hierarchy, status, geometry, and single-line labels" {
    var state: State = .{ .registry = undefined };
    var nodes = [_]SceneNode{
        .{ .id = 1, .parent = 0, .label = @constCast("root"), .node_type = .tree, .enabled = true, .geometry = .{} },
        .{ .id = 2, .parent = 1, .label = @constCast("alpha"), .node_type = .tree, .enabled = true, .geometry = .{} },
        .{ .id = 3, .parent = 2, .label = @constCast("leaf\nname"), .node_type = .buffer, .enabled = false, .geometry = .{ .x = 1, .y = 2, .width = 3, .height = 4 } },
        .{ .id = 4, .parent = 1, .label = @constCast("beta"), .node_type = .rect, .enabled = true, .geometry = .{} },
    };
    state.scene_nodes = .{ .items = &nodes, .capacity = nodes.len };

    var buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeSceneTree(&writer, &state);

    try std.testing.expectEqualStrings(
        "root [tree]\n" ++
            "├─ alpha [tree]\n" ++
            "│  └─ leaf name [buffer] disabled (1,2 3x4)\n" ++
            "└─ beta [rect]\n",
        writer.buffered(),
    );
}

test "scene dot escapes labels and styles node types" {
    var state: State = .{ .registry = undefined };
    var nodes = [_]SceneNode{
        .{ .id = 1, .parent = 0, .label = @constCast("root\"\\\n"), .node_type = .tree, .enabled = true, .geometry = .{} },
        .{ .id = 2, .parent = 1, .label = @constCast("leaf"), .node_type = .buffer, .enabled = false, .geometry = .{ .width = 10, .height = 20 } },
    };
    state.scene_nodes = .{ .items = &nodes, .capacity = nodes.len };

    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeSceneDot(&writer, &state);
    const output = writer.buffered();

    try std.testing.expect(mem.indexOf(u8, output, "n1 [label=\"root\\\"\\\\\\n\\ntree\"") != null);
    try std.testing.expect(mem.indexOf(u8, output, "fillcolor=\"#93c5fd\"") != null);
    try std.testing.expect(mem.indexOf(u8, output, "leaf\\nbuffer · disabled\\n0,0 10x20") != null);
    try std.testing.expect(mem.indexOf(u8, output, "fillcolor=\"#94a3b8\", style=\"rounded,filled,dashed\"") != null);
    try std.testing.expect(mem.indexOf(u8, output, "n1 -> n2;") != null);
}
