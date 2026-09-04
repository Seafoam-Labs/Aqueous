// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const aqueous = wayland.client.aqueous;
const zwlr = wayland.client.zwlr;

const io = Io.Threaded.global_single_threaded.io();
const allocator = std.heap.c_allocator;

const usage =
    \\usage: aqueousctl windows [--json]
    \\       aqueousctl inspect --rule
    \\       aqueousctl scene [--dot]
    \\       aqueousctl outputs [--json]
    \\       aqueousctl overlay-planes [--json]
    \\       aqueousctl layout --output NAME [--set LAYOUT] --json
    \\       aqueousctl cursor [--json]
    \\       aqueousctl cursor set --theme NAME --size SIZE [--json]
    \\
    \\Inspect compositor state or change layout and cursor settings.
    \\
;

const Geometry = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };

const Mode = enum {
    windows,
    json,
    rules,
    scene,
    scene_dot,
    outputs,
    outputs_json,
    overlay_planes,
    overlay_planes_json,
    layout_query,
    layout_set,
    cursor_query,
    cursor_query_json,
    cursor_set,
    cursor_set_json,
};

const OutputMode = struct {
    handle: *zwlr.OutputModeV1,
    width: i32 = 0,
    height: i32 = 0,
    refresh_mhz: i32 = 0,
    preferred: bool = false,
    removed: bool = false,

    fn deinit(mode: *OutputMode) void {
        if (mode.handle.getVersion() >= zwlr.OutputModeV1.release_since_version) {
            mode.handle.release();
        } else {
            mode.handle.destroy();
        }
        allocator.destroy(mode);
    }
};

const DisplayOutput = struct {
    handle: *zwlr.OutputHeadV1,
    name: ?[]u8 = null,
    make: ?[]u8 = null,
    model: ?[]u8 = null,
    serial: ?[]u8 = null,
    description: ?[]u8 = null,
    physical_width_mm: i32 = 0,
    physical_height_mm: i32 = 0,
    has_physical_size: bool = false,
    enabled: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    transform: wl.Output.Transform = .normal,
    scale: f64 = 1.0,
    adaptive_sync: bool = false,
    current_mode: ?*OutputMode = null,
    removed: bool = false,
    modes: std.ArrayListUnmanaged(*OutputMode) = .empty,

    fn deinit(output: *DisplayOutput) void {
        inline for (.{ output.name, output.make, output.model, output.serial, output.description }) |value| {
            if (value) |owned| allocator.free(owned);
        }
        for (output.modes.items) |mode| mode.deinit();
        output.modes.deinit(allocator);
        if (output.handle.getVersion() >= zwlr.OutputHeadV1.release_since_version) {
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

const OverlayPlane = struct {
    output: []u8,
    enabled: bool = false,
    capability: aqueous.OverlayPlaneSnapshotV1.Capability = .unknown,
    phase: aqueous.OverlayPlaneSnapshotV1.Phase = .disabled,
    rejection_reason: aqueous.OverlayPlaneSnapshotV1.RejectionReason = .none,
    candidate_id: u64 = 0,
    geometry: Geometry = .{},
    format: u32 = 0,
    modifier: u64 = 0,
    backoff_ms: u32 = 0,
    attempts: u64 = 0,
    accepted: u64 = 0,
    rejected: u64 = 0,
    backoff_skips: u64 = 0,
    fallback_retries: u64 = 0,
    promotions: u64 = 0,
    demotions: u64 = 0,
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
    /// Static string owned by the binary; never freed. Null when the client
    /// has not committed a content type.
    content_type: ?[]const u8 = null,
    backend: aqueous.WindowInfoV1.Backend = .xdg,
    workspace: u32 = 0,
    geometry: Geometry = .{},
    states: aqueous.WindowInfoV1.State = .{},
    matched_rule: u32 = 0,
    decoration_capability: aqueous.WindowInfoV1.DecorationCapability = .unavailable,
    decoration_requested: aqueous.WindowInfoV1.DecorationMode = .client_side,
    decoration_effective: aqueous.WindowInfoV1.DecorationMode = .client_side,
    decoration_configure_pending: bool = false,
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
    output_manager_name: u32 = 0,
    output_manager_version: u32 = 0,
    output_manager: ?*zwlr.OutputManagerV1 = null,
    outputs_done: bool = false,
    output_manager_finished: bool = false,
    list_name: u32 = 0,
    list_version: u32 = 0,
    info_name: u32 = 0,
    info_version: u32 = 0,
    list: ?*ext.ForeignToplevelListV1 = null,
    info_manager: ?*aqueous.WindowInfoManagerV1 = null,
    scene_snapshot: ?*aqueous.SceneSnapshotV1 = null,
    scene_done: bool = false,
    scene_nodes: std.ArrayListUnmanaged(SceneNode) = .empty,
    overlay_snapshot: ?*aqueous.OverlayPlaneSnapshotV1 = null,
    overlay_done: bool = false,
    overlay_planes: std.ArrayListUnmanaged(OverlayPlane) = .empty,
    outputs: std.ArrayListUnmanaged(*DisplayOutput) = .empty,
    list_finished: bool = false,
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    layout_done: bool = false,
    layout_status: aqueous.WindowInfoManagerV1.LayoutStatus = .unavailable,
    layout_output: ?[]u8 = null,
    layout_workspace: u32 = 0,
    layout_name: ?[]u8 = null,
    cursor_done: bool = false,
    cursor_status: aqueous.WindowInfoManagerV1.CursorStatus = .success,
    cursor_theme: ?[]u8 = null,
    cursor_size: u32 = 0,

    fn deinit(state: *State) void {
        for (state.windows.items) |window| window.deinit();
        state.windows.deinit(allocator);
        for (state.scene_nodes.items) |node| allocator.free(node.label);
        state.scene_nodes.deinit(allocator);
        for (state.overlay_planes.items) |plane| allocator.free(plane.output);
        state.overlay_planes.deinit(allocator);
        for (state.outputs.items) |output| output.deinit();
        state.outputs.deinit(allocator);
        if (state.output_manager) |manager| {
            if (!state.output_manager_finished) manager.destroy();
        }
        if (state.layout_output) |value| allocator.free(value);
        if (state.layout_name) |value| allocator.free(value);
        if (state.cursor_theme) |value| allocator.free(value);
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

    fn overlayPending(state: *const State) bool {
        return !state.overlay_done;
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
    const output_mode = mode == .outputs or mode == .outputs_json;
    var state: State = .{ .registry = registry, .collect_outputs = output_mode };
    defer state.deinit();
    registry.setListener(*State, registryListener, &state);
    tryRoundtrip(display, stderr);

    if (output_mode) {
        if (state.output_manager == null) {
            try stderr.writeAll("aqueousctl: compositor does not expose wlr output management\n");
            try stderr.flush();
            std.process.exit(1);
        }
        var rounds: usize = 0;
        while (!state.outputs_done and !state.output_manager_finished and rounds < 8) : (rounds += 1) {
            tryRoundtrip(display, stderr);
        }
        if (!state.outputs_done) {
            try stderr.writeAll("aqueousctl: timed out collecting a consistent output snapshot\n");
            try stderr.flush();
            std.process.exit(1);
        }
        if (mode == .outputs_json) {
            try writeOutputsJson(stdout, &state);
        } else {
            try writeOutputs(stdout, &state);
        }
        try stdout.flush();
        return;
    }

    const scene_mode = mode == .scene or mode == .scene_dot;
    const overlay_mode = mode == .overlay_planes or mode == .overlay_planes_json;
    const cursor_mode = mode == .cursor_query or mode == .cursor_query_json or
        mode == .cursor_set or mode == .cursor_set_json;
    if (state.info_name == 0 or (!scene_mode and !overlay_mode and !cursor_mode and state.list_name == 0)) {
        try stderr.writeAll("aqueousctl: compositor does not expose Aqueous window introspection\n");
        try stderr.flush();
        std.process.exit(1);
    }

    state.info_manager = try registry.bind(state.info_name, aqueous.WindowInfoManagerV1, state.info_version);
    if (cursor_mode) {
        if (state.info_version < 7) {
            try stderr.writeAll("aqueousctl: compositor does not expose live cursor control\n");
            try stderr.flush();
            std.process.exit(1);
        }
        state.info_manager.?.setListener(*State, managerListener, &state);
        if (mode == .cursor_set or mode == .cursor_set_json) {
            const theme = cursorTheme(args) orelse unreachable;
            const size = cursorSize(args) orelse {
                try stderr.writeAll("aqueousctl: SIZE must be an integer from 1 through 512\n");
                try stderr.flush();
                std.process.exit(2);
            };
            const theme_z = try allocator.dupeZ(u8, theme);
            defer allocator.free(theme_z);
            state.info_manager.?.setCursorTheme(theme_z.ptr, size);
        } else {
            state.info_manager.?.getCursorTheme();
        }
        var cursor_rounds: usize = 0;
        while (!state.cursor_done and cursor_rounds < 8) : (cursor_rounds += 1) tryRoundtrip(display, stderr);
        if (!state.cursor_done) {
            try stderr.writeAll("aqueousctl: timed out waiting for cursor state\n");
            try stderr.flush();
            std.process.exit(1);
        }
        if (mode == .cursor_query_json or mode == .cursor_set_json) {
            try writeCursorJson(stdout, &state);
        } else {
            try stdout.print("Theme: {s}\nSize: {d}\n", .{ state.cursor_theme orelse "", state.cursor_size });
        }
        try stdout.flush();
        if (state.cursor_status != .success) {
            try stderr.print("aqueousctl: cursor update failed: {s}\n", .{@tagName(state.cursor_status)});
            try stderr.flush();
            std.process.exit(1);
        }
        return;
    }
    if (overlay_mode) {
        if (state.info_version < 5) {
            try stderr.writeAll("aqueousctl: compositor does not expose overlay-plane diagnostics\n");
            try stderr.flush();
            std.process.exit(1);
        }
        state.overlay_snapshot = try state.info_manager.?.getOverlayPlaneSnapshot();
        state.overlay_snapshot.?.setListener(*State, overlayPlaneListener, &state);
        var overlay_rounds: usize = 0;
        while (state.overlayPending() and overlay_rounds < 8) : (overlay_rounds += 1) tryRoundtrip(display, stderr);
        if (state.overlayPending()) {
            try stderr.writeAll("aqueousctl: timed out collecting overlay-plane state\n");
            try stderr.flush();
            std.process.exit(1);
        }
        if (mode == .overlay_planes_json) {
            try writeOverlayPlanesJson(stdout, &state);
        } else {
            try writeOverlayPlanes(stdout, &state);
        }
        try stdout.flush();
        return;
    }
    if (mode == .layout_query or mode == .layout_set) {
        if (state.info_version < 3) {
            try stderr.writeAll("aqueousctl: compositor does not expose workspace layout control\n");
            try stderr.flush();
            std.process.exit(1);
        }
        state.info_manager.?.setListener(*State, managerListener, &state);
        const output = layoutOutput(args) orelse unreachable;
        const output_z = try allocator.dupeZ(u8, output);
        if (mode == .layout_set) {
            const layout = layoutValue(args) orelse unreachable;
            const layout_z = try allocator.dupeZ(u8, layout);
            state.info_manager.?.setActiveWorkspaceLayout(output_z.ptr, layout_z.ptr);
        } else {
            state.info_manager.?.getActiveWorkspaceLayout(output_z.ptr);
        }
        var layout_rounds: usize = 0;
        while (!state.layout_done and layout_rounds < 8) : (layout_rounds += 1) tryRoundtrip(display, stderr);
        if (!state.layout_done) {
            try stderr.writeAll("aqueousctl: timed out waiting for workspace layout state\n");
            try stderr.flush();
            std.process.exit(1);
        }
        try writeLayoutJson(stdout, &state);
        try stdout.flush();
        if (state.layout_status != .success) std.process.exit(1);
        return;
    }
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
        .scene, .scene_dot, .outputs, .outputs_json, .overlay_planes, .overlay_planes_json, .layout_query, .layout_set, .cursor_query, .cursor_query_json, .cursor_set, .cursor_set_json => unreachable,
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
    if (args.len == 3 and mem.eql(u8, args[1], "outputs") and mem.eql(u8, args[2], "--json")) return .outputs_json;
    if (args.len == 2 and mem.eql(u8, args[1], "overlay-planes")) return .overlay_planes;
    if (args.len == 3 and mem.eql(u8, args[1], "overlay-planes") and mem.eql(u8, args[2], "--json")) return .overlay_planes_json;
    if (args.len == 5 and mem.eql(u8, args[1], "layout") and
        mem.eql(u8, args[2], "--output") and mem.eql(u8, args[4], "--json")) return .layout_query;
    if (args.len == 7 and mem.eql(u8, args[1], "layout") and
        mem.eql(u8, args[2], "--output") and mem.eql(u8, args[4], "--set") and
        mem.eql(u8, args[6], "--json")) return .layout_set;
    if (args.len == 2 and mem.eql(u8, args[1], "cursor")) return .cursor_query;
    if (args.len == 3 and mem.eql(u8, args[1], "cursor") and mem.eql(u8, args[2], "--json")) return .cursor_query_json;
    if (args.len == 7 and mem.eql(u8, args[1], "cursor") and
        mem.eql(u8, args[2], "set") and mem.eql(u8, args[3], "--theme") and
        mem.eql(u8, args[5], "--size")) return .cursor_set;
    if (args.len == 8 and mem.eql(u8, args[1], "cursor") and
        mem.eql(u8, args[2], "set") and mem.eql(u8, args[3], "--theme") and
        mem.eql(u8, args[5], "--size") and mem.eql(u8, args[7], "--json")) return .cursor_set_json;
    return null;
}

fn cursorTheme(args: []const []const u8) ?[]const u8 {
    return if (args.len == 7 or args.len == 8) args[4] else null;
}

fn cursorSize(args: []const []const u8) ?u32 {
    if (args.len != 7 and args.len != 8) return null;
    const size = std.fmt.parseInt(u32, args[6], 10) catch return null;
    return if (size >= 1 and size <= 512) size else null;
}

fn writeCursorJson(writer: *Io.Writer, state: *const State) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (state.cursor_status == .success) "true" else "false");
    try writer.writeAll(",\"status\":");
    try jsonString(writer, @tagName(state.cursor_status));
    try writer.writeAll(",\"theme\":");
    try jsonString(writer, state.cursor_theme orelse "");
    try writer.print(",\"size\":{d}}}\n", .{state.cursor_size});
}

fn layoutOutput(args: []const []const u8) ?[]const u8 {
    return if (args.len >= 4) args[3] else null;
}

fn layoutValue(args: []const []const u8) ?[]const u8 {
    return if (args.len >= 6) args[5] else null;
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
            } else if (state.collect_outputs and mem.eql(u8, name, mem.span(zwlr.OutputManagerV1.interface.name))) {
                state.output_manager_name = global.name;
                state.output_manager_version = @min(global.version, zwlr.OutputManagerV1.generated_version);
                const manager = state.registry.bind(
                    global.name,
                    zwlr.OutputManagerV1,
                    state.output_manager_version,
                ) catch return;
                state.output_manager = manager;
                manager.setListener(*State, outputManagerListener, state);
            }
        },
        .global_remove => |removed| if (removed.name == state.output_manager_name) {
            state.output_manager_finished = true;
        },
    }
}

fn managerListener(
    _: *aqueous.WindowInfoManagerV1,
    event: aqueous.WindowInfoManagerV1.Event,
    state: *State,
) void {
    switch (event) {
        .active_workspace_layout => |value| {
            state.layout_status = value.status;
            state.layout_workspace = value.workspace;
            replaceString(&state.layout_output, mem.span(value.output));
            replaceString(&state.layout_name, mem.span(value.layout));
            state.layout_done = true;
        },
        .cursor_theme => |value| {
            state.cursor_status = value.status;
            replaceString(&state.cursor_theme, mem.span(value.name));
            state.cursor_size = value.size;
            state.cursor_done = true;
        },
    }
}

fn joinU64(high: u32, low: u32) u64 {
    return (@as(u64, high) << 32) | low;
}

fn overlayPlaneByName(state: *State, name: []const u8, create: bool) ?*OverlayPlane {
    for (state.overlay_planes.items) |*plane| {
        if (mem.eql(u8, plane.output, name)) return plane;
    }
    if (!create) return null;
    const owned = allocator.dupe(u8, name) catch return null;
    state.overlay_planes.append(allocator, .{ .output = owned }) catch {
        allocator.free(owned);
        return null;
    };
    return &state.overlay_planes.items[state.overlay_planes.items.len - 1];
}

fn overlayPlaneListener(
    _: *aqueous.OverlayPlaneSnapshotV1,
    event: aqueous.OverlayPlaneSnapshotV1.Event,
    state: *State,
) void {
    switch (event) {
        .output_state => |value| {
            const plane = overlayPlaneByName(state, mem.span(value.output), true) orelse return;
            plane.enabled = value.enabled != 0;
            plane.capability = value.capability;
            plane.phase = value.phase;
            plane.rejection_reason = value.rejection_reason;
            plane.candidate_id = joinU64(value.candidate_hi, value.candidate_lo);
            plane.geometry = .{
                .x = value.x,
                .y = value.y,
                .width = value.width,
                .height = value.height,
            };
            plane.format = value.format;
            plane.modifier = joinU64(value.modifier_hi, value.modifier_lo);
            plane.backoff_ms = value.backoff_ms;
        },
        .output_counters => |value| {
            const plane = overlayPlaneByName(state, mem.span(value.output), false) orelse return;
            plane.attempts = joinU64(value.attempts_hi, value.attempts_lo);
            plane.accepted = joinU64(value.accepted_hi, value.accepted_lo);
            plane.rejected = joinU64(value.rejected_hi, value.rejected_lo);
            plane.backoff_skips = joinU64(value.backoff_skips_hi, value.backoff_skips_lo);
            plane.fallback_retries = joinU64(value.fallback_hi, value.fallback_lo);
            plane.promotions = joinU64(value.promotions_hi, value.promotions_lo);
            plane.demotions = joinU64(value.demotions_hi, value.demotions_lo);
        },
        .done => state.overlay_done = true,
    }
}

fn writeOverlayPlanes(writer: *Io.Writer, state: *const State) !void {
    if (state.overlay_planes.items.len == 0) {
        try writer.writeAll("No outputs.\n");
        return;
    }
    for (state.overlay_planes.items) |plane| {
        try writer.print("{s}:\n", .{plane.output});
        try writer.print("  Enabled: {s}\n", .{if (plane.enabled) "yes" else "no"});
        try writer.print("  Capability: {s}\n", .{@tagName(plane.capability)});
        try writer.print("  Phase: {s}\n", .{@tagName(plane.phase)});
        try writer.print("  Reason: {s}\n", .{@tagName(plane.rejection_reason)});
        if (plane.candidate_id == 0) {
            try writer.writeAll("  Candidate: none\n");
        } else {
            try writer.print("  Candidate: 0x{x}\n", .{plane.candidate_id});
        }
        try writer.print(
            "  Destination: {d},{d} {d}x{d}\n  Format: 0x{x:0>8} modifier 0x{x}\n",
            .{ plane.geometry.x, plane.geometry.y, plane.geometry.width, plane.geometry.height, plane.format, plane.modifier },
        );
        try writer.print(
            "  Backoff: {d} ms\n  Counters: attempts={d} accepted={d} rejected={d} skips={d} fallback={d} promotions={d} demotions={d}\n",
            .{ plane.backoff_ms, plane.attempts, plane.accepted, plane.rejected, plane.backoff_skips, plane.fallback_retries, plane.promotions, plane.demotions },
        );
    }
}

fn writeOverlayPlanesJson(writer: *Io.Writer, state: *const State) !void {
    try writer.writeByte('[');
    for (state.overlay_planes.items, 0..) |plane, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"output\":");
        try jsonString(writer, plane.output);
        try writer.print(
            ",\"enabled\":{s},\"capability\":",
            .{if (plane.enabled) "true" else "false"},
        );
        try jsonString(writer, @tagName(plane.capability));
        try writer.writeAll(",\"phase\":");
        try jsonString(writer, @tagName(plane.phase));
        try writer.writeAll(",\"rejection_reason\":");
        try jsonString(writer, @tagName(plane.rejection_reason));
        try writer.print(
            ",\"candidate_id\":{d},\"destination\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"format\":{d},\"modifier\":{d},\"backoff_ms\":{d},\"counters\":{{\"attempts\":{d},\"accepted\":{d},\"rejected\":{d},\"backoff_skips\":{d},\"fallback_retries\":{d},\"promotions\":{d},\"demotions\":{d}}}}}",
            .{
                plane.candidate_id,
                plane.geometry.x,
                plane.geometry.y,
                plane.geometry.width,
                plane.geometry.height,
                plane.format,
                plane.modifier,
                plane.backoff_ms,
                plane.attempts,
                plane.accepted,
                plane.rejected,
                plane.backoff_skips,
                plane.fallback_retries,
                plane.promotions,
                plane.demotions,
            },
        );
    }
    try writer.writeAll("]\n");
}

fn writeLayoutJson(writer: *Io.Writer, state: *const State) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (state.layout_status == .success) "true" else "false");
    try writer.writeAll(",\"status\":");
    try jsonString(writer, @tagName(state.layout_status));
    try writer.writeAll(",\"output\":");
    try jsonString(writer, state.layout_output orelse "");
    try writer.print(",\"workspace\":{d},\"layout\":", .{state.layout_workspace});
    try jsonString(writer, state.layout_name orelse "");
    try writer.writeAll("}\n");
}

fn outputManagerListener(
    _: *zwlr.OutputManagerV1,
    event: zwlr.OutputManagerV1.Event,
    state: *State,
) void {
    switch (event) {
        .head => |created| {
            const output = allocator.create(DisplayOutput) catch {
                if (created.head.getVersion() >= zwlr.OutputHeadV1.release_since_version) {
                    created.head.release();
                } else {
                    created.head.destroy();
                }
                return;
            };
            output.* = .{ .handle = created.head };
            state.outputs.append(allocator, output) catch {
                output.deinit();
                return;
            };
            created.head.setListener(*DisplayOutput, outputHeadListener, output);
        },
        .done => state.outputs_done = true,
        .finished => {
            state.output_manager_finished = true;
            state.output_manager = null;
        },
    }
}

fn outputHeadListener(_: *zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event, output: *DisplayOutput) void {
    switch (event) {
        .name => |value| replaceString(&output.name, mem.span(value.name)),
        .description => |value| replaceString(&output.description, mem.span(value.description)),
        .physical_size => |value| {
            output.physical_width_mm = value.width;
            output.physical_height_mm = value.height;
            output.has_physical_size = true;
        },
        .mode => |created| {
            const mode = allocator.create(OutputMode) catch {
                if (created.mode.getVersion() >= zwlr.OutputModeV1.release_since_version) {
                    created.mode.release();
                } else {
                    created.mode.destroy();
                }
                return;
            };
            mode.* = .{ .handle = created.mode };
            output.modes.append(allocator, mode) catch {
                mode.deinit();
                return;
            };
            created.mode.setListener(*OutputMode, outputModeListener, mode);
        },
        .enabled => |value| output.enabled = value.enabled != 0,
        .current_mode => |value| {
            output.current_mode = null;
            const current = value.mode orelse return;
            for (output.modes.items) |mode| {
                if (mode.handle == current) {
                    output.current_mode = mode;
                    break;
                }
            }
        },
        .position => |value| {
            output.x = value.x;
            output.y = value.y;
        },
        .transform => |value| output.transform = value.transform,
        .scale => |value| output.scale = value.scale.toDouble(),
        .finished => output.removed = true,
        .make => |value| replaceString(&output.make, mem.span(value.make)),
        .model => |value| replaceString(&output.model, mem.span(value.model)),
        .serial_number => |value| replaceString(&output.serial, mem.span(value.serial_number)),
        .adaptive_sync => |value| output.adaptive_sync = value.state == .enabled,
    }
}

fn outputModeListener(_: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, mode: *OutputMode) void {
    switch (event) {
        .size => |value| {
            mode.width = value.width;
            mode.height = value.height;
        },
        .refresh => |value| mode.refresh_mhz = value.refresh,
        .preferred => mode.preferred = true,
        .finished => mode.removed = true,
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
        .content_type => |value| window.content_type = contentTypeName(value.content_type),
        .matched_rule => |value| window.matched_rule = value.index,
        .decoration => |value| {
            window.decoration_capability = value.capability;
            window.decoration_requested = value.requested;
            window.decoration_effective = value.effective;
            window.decoration_configure_pending = value.configure_pending != 0;
        },
        .rule_matcher => |value| switch (value.matcher) {
            .app_id => replaceString(&window.rule_app_id, mem.span(value.pattern)),
            .class => replaceString(&window.rule_class, mem.span(value.pattern)),
            .title => replaceString(&window.rule_title, mem.span(value.pattern)),
            .content_type => {},
            _ => {},
        },
        .done => window.info_done = true,
    }
}

fn contentTypeName(value: u32) ?[]const u8 {
    return switch (value) {
        1 => "photo",
        2 => "video",
        3 => "game",
        else => null,
    };
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

        try writeSingleLine(writer, output.name orelse "unknown");
        if (output.description) |text| {
            try writer.writeAll(" \"");
            try writeSingleLine(writer, text);
            try writer.writeByte('"');
        }
        try writer.writeByte('\n');

        if (output.make) |value| try writer.print("  Make: {s}\n", .{value});
        if (output.model) |value| try writer.print("  Model: {s}\n", .{value});
        if (output.serial) |value| try writer.print("  Serial: {s}\n", .{value});
        var edid_buffer: [71]u8 = undefined;
        if (identityHash(output, &edid_buffer)) |value| {
            try writer.print("  EDID Identifier: \"{s}\"\n", .{value});
        }
        if (output.has_physical_size) {
            try writer.print("  Physical size: {d}x{d} mm\n", .{ output.physical_width_mm, output.physical_height_mm });
        }
        try writer.print("  Enabled: {s}\n", .{if (output.enabled) "yes" else "no"});
        try writer.writeAll("  Modes:\n");
        var mode_count: usize = 0;
        for (output.modes.items) |available| {
            if (available.removed) continue;
            mode_count += 1;
            try writer.print("    {d}x{d} px", .{ available.width, available.height });
            if (available.refresh_mhz > 0) {
                try writer.writeAll(", ");
                try writeRefreshRate(writer, available.refresh_mhz);
            }
            const current = output.current_mode == available;
            if (current or available.preferred) {
                try writer.writeAll(" (");
                if (current) try writer.writeAll("current");
                if (current and available.preferred) try writer.writeAll(", ");
                if (available.preferred) try writer.writeAll("preferred");
                try writer.writeByte(')');
            }
            try writer.writeByte('\n');
        }
        if (mode_count == 0) try writer.writeAll("    (none)\n");
        if (output.enabled) {
            try writer.print("  Position: {d},{d}\n", .{ output.x, output.y });
            try writer.print("  Transform: {s}\n", .{transformName(output.transform)});
            try writer.print("  Scale: {d:.6}\n", .{output.scale});
            try writer.print("  Adaptive Sync: {s}\n", .{if (output.adaptive_sync) "enabled" else "disabled"});
        }
    }
    if (rendered == 0) try writer.writeAll("No outputs found.\n");
}

fn writeRefreshRate(writer: *Io.Writer, refresh_mhz: i32) !void {
    if (refresh_mhz <= 0) return;
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

fn transformName(transform: wl.Output.Transform) []const u8 {
    return switch (transform) {
        .normal => "normal",
        .@"90" => "90",
        .@"180" => "180",
        .@"270" => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped-90",
        .flipped_180 => "flipped-180",
        .flipped_270 => "flipped-270",
        else => "unknown",
    };
}

fn writeOutputsJson(writer: *Io.Writer, state: *const State) !void {
    try writer.writeAll("[\n");
    var first_output = true;
    for (state.outputs.items) |output| {
        if (output.removed) continue;
        if (!first_output) try writer.writeAll(",\n");
        first_output = false;
        try writer.writeAll("  {");
        try jsonField(writer, "name", output.name, true);
        try jsonField(writer, "description", output.description, false);
        try jsonField(writer, "make", output.make, false);
        try jsonField(writer, "model", output.model, false);
        try jsonField(writer, "serial", output.serial, false);
        var edid_buffer: [71]u8 = undefined;
        try jsonField(writer, "edid_sha256", identityHash(output, &edid_buffer), false);
        try writer.print(",\"physical_size\":{{\"width\":{d},\"height\":{d}}}", .{
            output.physical_width_mm,
            output.physical_height_mm,
        });
        try writer.writeAll(",\"enabled\":");
        try writer.writeAll(if (output.enabled) "true" else "false");
        try writer.writeAll(",\"modes\":[");
        var first_mode = true;
        for (output.modes.items) |available| {
            if (available.removed) continue;
            if (!first_mode) try writer.writeByte(',');
            first_mode = false;
            try writer.print("{{\"width\":{d},\"height\":{d},\"refresh\":{d:.6},\"preferred\":{s},\"current\":{s}}}", .{
                available.width,
                available.height,
                @as(f64, @floatFromInt(available.refresh_mhz)) / 1000.0,
                if (available.preferred) "true" else "false",
                if (output.current_mode == available) "true" else "false",
            });
        }
        try writer.print("],\"position\":{{\"x\":{d},\"y\":{d}}},\"transform\":", .{ output.x, output.y });
        try jsonString(writer, transformName(output.transform));
        try writer.print(",\"scale\":{d:.6},\"adaptive_sync\":{s}}}", .{
            output.scale,
            if (output.adaptive_sync) "true" else "false",
        });
    }
    try writer.writeAll("\n]\n");
}

fn identityHash(output: *const DisplayOutput, buffer: *[71]u8) ?[]const u8 {
    if (output.make == null and output.model == null and output.serial == null) return null;

    var identity: [768]u8 = undefined;
    const source = std.fmt.bufPrint(&identity, "{s}|{s}|{s}", .{
        output.make orelse "",
        output.model orelse "",
        output.serial orelse "",
    }) catch return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buffer, "sha256:{s}", .{hex}) catch null;
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
    try writer.writeAll("ID\tBACKEND\tAPP_ID/CLASS\tTITLE\tOUTPUT:WORKSPACE\tGEOMETRY\tLAYOUT\tCONTENT\tSTATE\n");
    for (state.windows.items) |window| {
        if (window.closed or !window.info_done) continue;
        const identity = window.app_id orelse window.class orelse window.foreign_app_id orelse "";
        try writer.print("{s}\t{s}\t{s}\t{s}\t{s}:{d}\t{d},{d} {d}x{d}\t{s}\t{s}\t", .{
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
            window.content_type orelse "",
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
    try writeState(writer, &first, "always_above", states.always_above);
    try writeState(writer, &first, "always_below", states.always_below);
    try writeState(writer, &first, "snapped", states.snapped);
    try writeState(writer, &first, "fixed_position", states.fixed_position);
    try writeState(writer, &first, "skip_switcher", states.skip_switcher);
    try writeState(writer, &first, "skip_taskbar", states.skip_taskbar);
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
        try jsonField(writer, "content_type", window.content_type, false);
        try writer.writeAll(",\"decoration\":{\"capability\":");
        try jsonString(writer, decorationCapabilityName(window.decoration_capability));
        try writer.writeAll(",\"requested\":");
        try jsonString(writer, decorationModeName(window.decoration_requested));
        try writer.writeAll(",\"effective\":");
        try jsonString(writer, decorationModeName(window.decoration_effective));
        try writer.print(",\"configure_pending\":{s}}}", .{if (window.decoration_configure_pending) "true" else "false"});
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

fn decorationCapabilityName(capability: aqueous.WindowInfoV1.DecorationCapability) []const u8 {
    return switch (capability) {
        .unavailable => "unavailable",
        .xdg_decoration => "xdg-decoration",
        _ => "unknown",
    };
}

fn decorationModeName(mode: aqueous.WindowInfoV1.DecorationMode) []const u8 {
    return switch (mode) {
        .none => "none",
        .client_side => "client-side",
        .server_side => "server-side",
        _ => "unknown",
    };
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
    try testing.expectEqual(Mode.outputs_json, parseMode(&.{ "aqueousctl", "outputs", "--json" }).?);
    try testing.expectEqual(Mode.overlay_planes, parseMode(&.{ "aqueousctl", "overlay-planes" }).?);
    try testing.expectEqual(Mode.overlay_planes_json, parseMode(&.{ "aqueousctl", "overlay-planes", "--json" }).?);
    try testing.expectEqual(Mode.layout_query, parseMode(&.{ "aqueousctl", "layout", "--output", "DP-1", "--json" }).?);
    try testing.expectEqual(Mode.layout_set, parseMode(&.{ "aqueousctl", "layout", "--output", "DP-1", "--set", "grid", "--json" }).?);
    try testing.expectEqual(Mode.cursor_query, parseMode(&.{ "aqueousctl", "cursor" }).?);
    try testing.expectEqual(Mode.cursor_query_json, parseMode(&.{ "aqueousctl", "cursor", "--json" }).?);
    try testing.expectEqual(Mode.cursor_set, parseMode(&.{ "aqueousctl", "cursor", "set", "--theme", "Bibata-Modern-Ice", "--size", "32" }).?);
    try testing.expectEqual(Mode.cursor_set_json, parseMode(&.{ "aqueousctl", "cursor", "set", "--theme", "Bibata Modern Ice", "--size", "32", "--json" }).?);
    try testing.expectEqual(@as(?u32, 32), cursorSize(&.{ "aqueousctl", "cursor", "set", "--theme", "Bibata-Modern-Ice", "--size", "32" }));

    try testing.expect(parseMode(&.{"aqueousctl"}) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "windows", "--dot" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "scene", "--json" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "outputs", "--dot" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "inspect" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "layout", "--output", "DP-1" }) == null);
    try testing.expect(parseMode(&.{ "aqueousctl", "cursor", "set", "--theme", "default" }) == null);
    try testing.expect(cursorSize(&.{ "aqueousctl", "cursor", "set", "--theme", "default", "--size", "0" }) == null);
    try testing.expect(cursorSize(&.{ "aqueousctl", "cursor", "set", "--theme", "default", "--size", "513" }) == null);
}

test "outputs render advertised refresh rates and mode flags" {
    var state: State = .{ .registry = undefined };
    var first: DisplayOutput = .{
        .handle = undefined,
        .name = @constCast("DP-1"),
        .description = @constCast("Example Display\n27-inch"),
        .make = @constCast("Acme"),
        .model = @constCast("Panel"),
        .serial = @constCast("ABC123"),
        .physical_width_mm = 600,
        .physical_height_mm = 340,
        .has_physical_size = true,
        .enabled = true,
        .x = -10,
        .y = 20,
        .transform = .flipped_90,
        .scale = 1.25,
        .adaptive_sync = true,
    };
    var mode_one: OutputMode = .{ .handle = undefined, .width = 3840, .height = 2160, .refresh_mhz = 59_997, .preferred = true };
    var mode_two: OutputMode = .{ .handle = undefined, .width = 2560, .height = 1440, .refresh_mhz = 120_000 };
    var mode_three: OutputMode = .{ .handle = undefined, .width = 1920, .height = 1080 };
    var first_modes = [_]*OutputMode{
        &mode_one,
        &mode_two,
        &mode_three,
    };
    first.modes = .{ .items = &first_modes, .capacity = first_modes.len };
    first.current_mode = &mode_one;
    var second: DisplayOutput = .{
        .handle = undefined,
        .name = @constCast("HEADLESS-1"),
    };
    var outputs = [_]*DisplayOutput{ &first, &second };
    state.outputs = .{ .items = &outputs, .capacity = outputs.len };

    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeOutputs(&writer, &state);

    try std.testing.expectEqualStrings(
        "DP-1 \"Example Display 27-inch\"\n" ++
            "  Make: Acme\n" ++
            "  Model: Panel\n" ++
            "  Serial: ABC123\n" ++
            "  EDID Identifier: \"sha256:daf5f59252c5a28c00c8f13b516d7ccb8afdce47b8f664ff18f3059e18f3057e\"\n" ++
            "  Physical size: 600x340 mm\n" ++
            "  Enabled: yes\n" ++
            "  Modes:\n" ++
            "    3840x2160 px, 59.997 Hz (current, preferred)\n" ++
            "    2560x1440 px, 120.000 Hz\n" ++
            "    1920x1080 px\n" ++
            "  Position: -10,20\n" ++
            "  Transform: flipped-90\n" ++
            "  Scale: 1.250000\n" ++
            "  Adaptive Sync: enabled\n" ++
            "\n" ++
            "HEADLESS-1\n" ++
            "  Enabled: no\n" ++
            "  Modes:\n" ++
            "    (none)\n",
        writer.buffered(),
    );

    var json_buffer: [4096]u8 = undefined;
    var json_writer = Io.Writer.fixed(&json_buffer);
    try writeOutputsJson(&json_writer, &state);
    try std.testing.expectEqualStrings(
        "[\n" ++
            "  {\"name\":\"DP-1\",\"description\":\"Example Display\\n27-inch\",\"make\":\"Acme\",\"model\":\"Panel\",\"serial\":\"ABC123\",\"edid_sha256\":\"sha256:daf5f59252c5a28c00c8f13b516d7ccb8afdce47b8f664ff18f3059e18f3057e\",\"physical_size\":{\"width\":600,\"height\":340},\"enabled\":true,\"modes\":[{\"width\":3840,\"height\":2160,\"refresh\":59.997000,\"preferred\":true,\"current\":true},{\"width\":2560,\"height\":1440,\"refresh\":120.000000,\"preferred\":false,\"current\":false},{\"width\":1920,\"height\":1080,\"refresh\":0.000000,\"preferred\":false,\"current\":false}],\"position\":{\"x\":-10,\"y\":20},\"transform\":\"flipped-90\",\"scale\":1.250000,\"adaptive_sync\":true},\n" ++
            "  {\"name\":\"HEADLESS-1\",\"description\":null,\"make\":null,\"model\":null,\"serial\":null,\"edid_sha256\":null,\"physical_size\":{\"width\":0,\"height\":0},\"enabled\":false,\"modes\":[],\"position\":{\"x\":0,\"y\":0},\"transform\":\"normal\",\"scale\":1.000000,\"adaptive_sync\":false}\n" ++
            "]\n",
        json_writer.buffered(),
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
        .content_type = "game",
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
        "ID\tBACKEND\tAPP_ID/CLASS\tTITLE\tOUTPUT:WORKSPACE\tGEOMETRY\tLAYOUT\tCONTENT\tSTATE\n" ++
            "window-1\txdg\tEditorClass\tEditor\tDP-1:4\t-10,20 1280x720\tdwindle\tgame\tfocused,fullscreen,visible\n",
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
        .states = .{ .floating = true, .minimized = true, .always_above = true, .snapped = true },
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
            "  {\"id\":\"id\\\"\\\\\\n\",\"backend\":\"xdg\",\"app_id\":\"org.test\\tapp\",\"class\":null,\"title\":\"line\\rtitle\",\"output\":null,\"workspace\":2,\"geometry\":{\"x\":1,\"y\":-2,\"width\":3,\"height\":4},\"layout\":null,\"content_type\":null,\"decoration\":{\"capability\":\"unavailable\",\"requested\":\"client-side\",\"effective\":\"client-side\",\"configure_pending\":false},\"matched_rule\":7,\"states\":[\"floating\",\"minimized\",\"always_above\",\"snapped\"]}\n" ++
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
