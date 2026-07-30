// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const layout = @import("layout.zig");
const wm = @import("wm.zig");
const actions = @import("actions.zig");

const log = std.log.scoped(.aqueous);
const max_config_bytes = 1024 * 1024;

pub const Snapshot = struct {
    layout: layout.Snapshot = .{},
    wm: wm.Snapshot = .{},
    actions: actions.Snapshot = .{},
    fingerprint: u64 = 0,
};

/// Build a complete replacement snapshot. Callers publish it only after this
/// function returns, so a manage cycle never observes a half-applied reload.
pub fn load(allocator: std.mem.Allocator) Snapshot {
    var snapshot: Snapshot = .{};
    actions.initDefaults(&snapshot.actions);
    var wm_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env = Environment.read();
    const wm_path = resolveWmPath(&wm_path_buffer, env) orelse return snapshot;
    if (readFile(allocator, wm_path)) |wm_source| {
        defer allocator.free(wm_source);
        snapshot.fingerprint = hashSource(snapshot.fingerprint, wm_source);
        wm.apply(&snapshot.wm, &snapshot.layout, wm_source);
        applyActions(&snapshot.actions, wm_source);
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (resolveLayoutPath(&path_buffer, env, snapshot.wm.layout_path.slice(), dirname(wm_path))) |path| {
        applyLayoutFile(allocator, &snapshot, path);
    }
    if (resolveInputPath(&path_buffer, env, snapshot.wm.input_path.slice())) |path| {
        applyInputFile(allocator, &snapshot, path);
    }
    return snapshot;
}

fn applyActions(snapshot: *actions.Snapshot, source: []const u8) void {
    const Section = enum { none, action, keybinds, custom, gestures, exec };
    var section: Section = .none;
    var pending: ?actions.Exec = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = wm.cleanLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (pending) |entry| {
                if (!entry.name.empty() and !entry.command.empty() and snapshot.exec_count < actions.max_exec) {
                    snapshot.exec[snapshot.exec_count] = entry;
                    snapshot.exec_count += 1;
                }
                pending = null;
            }
            if (std.mem.eql(u8, line, "[[exec]]")) {
                section = .exec;
                pending = .{};
            } else if (std.mem.eql(u8, line, "[actions]")) section = .action else if (std.mem.eql(u8, line, "[keybinds]")) section = .keybinds else if (std.mem.eql(u8, line, "[keybinds.custom]")) section = .custom else if (std.mem.eql(u8, line, "[gestures]")) section = .gestures else section = .none;
            continue;
        }
        const equal = wm.indexUnquoted(line, '=') orelse continue;
        const raw_key = std.mem.trim(u8, line[0..equal], " \t");
        const key = wm.unquote(raw_key);
        const raw_value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        const value = wm.unquote(raw_value);
        switch (section) {
            .action => {
                if (std.mem.eql(u8, key, "toggle_start_menu")) _ = snapshot.toggle_start_menu.set(value);
                if (std.mem.eql(u8, key, "spawn_terminal")) _ = snapshot.spawn_terminal.set(value);
                if (std.mem.eql(u8, key, "screenshot")) _ = snapshot.screenshot.set(value);
                if (std.mem.eql(u8, key, "lock_screen")) _ = snapshot.lock_screen.set(value);
            },
            .keybinds => actions.addBuiltinList(snapshot, key, raw_value),
            .custom => {
                var decoded: [256]u8 = undefined;
                actions.addBinding(snapshot, key, decodeBasic(value, &decoded) orelse value);
            },
            .exec => if (pending) |*entry| {
                if (std.mem.eql(u8, key, "name")) _ = entry.name.set(value);
                if (std.mem.eql(u8, key, "command")) _ = entry.command.set(value);
                if (std.mem.eql(u8, key, "when")) entry.when = if (std.mem.eql(u8, value, "reload")) .reload else if (std.mem.eql(u8, value, "always")) .always else .startup;
                if (std.mem.eql(u8, key, "once")) entry.once = parseBool(value) orelse entry.once;
                if (std.mem.eql(u8, key, "restart")) entry.restart = parseBool(value) orelse entry.restart;
                if (std.mem.eql(u8, key, "log")) _ = entry.log_path.set(value);
                if (std.mem.eql(u8, key, "env")) _ = entry.env.set(raw_value);
            },
            .gestures => {
                const gesture = parseGestureKey(key) orelse continue;
                var decoded: [256]u8 = undefined;
                actions.addGesture(snapshot, gesture.kind, gesture.direction, gesture.fingers, decodeBasic(value, &decoded) orelse value);
            },
            .none => {},
        }
    }
    if (pending) |entry| if (!entry.name.empty() and !entry.command.empty() and snapshot.exec_count < actions.max_exec) {
        snapshot.exec[snapshot.exec_count] = entry;
        snapshot.exec_count += 1;
    };
}

fn applyGestures(snapshot: *actions.Snapshot, source: []const u8) void {
    var in_gestures = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = wm.cleanLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_gestures = std.mem.eql(u8, line, "[gestures]");
            continue;
        }
        if (!in_gestures) continue;

        const equal = wm.indexUnquoted(line, '=') orelse continue;
        const key = wm.unquote(std.mem.trim(u8, line[0..equal], " \t"));
        const gesture = parseGestureKey(key) orelse continue;
        const raw_value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        const value = wm.unquote(raw_value);
        var decoded: [256]u8 = undefined;
        actions.addGesture(snapshot, gesture.kind, gesture.direction, gesture.fingers, decodeBasic(value, &decoded) orelse value);
    }
}

const ParsedGestureKey = struct {
    kind: actions.GestureKind,
    direction: actions.GestureDirection,
    fingers: u8,
};

fn parseGestureKey(key: []const u8) ?ParsedGestureKey {
    var parts = std.mem.splitScalar(u8, key, '_');

    const kind_text = parts.next() orelse return null;
    const fingers_text = parts.next() orelse return null;
    const direction_text = parts.next() orelse return null;

    // Reject extra components such as swipe_3_left_extra.
    if (parts.next() != null) return null;

    const kind = std.meta.stringToEnum(
        actions.GestureKind,
        kind_text,
    ) orelse return null;

    const direction = std.meta.stringToEnum(
        actions.GestureDirection,
        direction_text,
    ) orelse return null;

    const fingers = std.fmt.parseInt(
        u8,
        fingers_text,
        10,
    ) catch return null;

    if (fingers == 0) return null;

    // Only accept directions meaningful for each gesture type.
    switch (kind) {
        .swipe => switch (direction) {
            .left, .right, .up, .down => {},
            .in, .out => return null,
        },
        .pinch => switch (direction) {
            .in, .out => {},
            .left, .right, .up, .down => return null,
        },
    }

    return .{
        .kind = kind,
        .direction = direction,
        .fingers = fingers,
    };
}

fn decodeBasic(value: []const u8, buffer: []u8) ?[]const u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < value.len) : (read += 1) {
        if (write == buffer.len) return null;
        if (value[read] == '\\' and read + 1 < value.len) {
            read += 1;
            buffer[write] = switch (value[read]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => value[read],
            };
        } else buffer[write] = value[read];
        write += 1;
    }
    return buffer[0..write];
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

test "actions custom bindings and exec are immutable snapshot data" {
    var snapshot: actions.Snapshot = .{};
    actions.initDefaults(&snapshot);
    applyActions(&snapshot,
        \\[actions]
        \\spawn_terminal = "foot"
        \\screenshot = "shot-region"
        \\[keybinds]
        \\screenshot = "PrintScreen"
        \\cycle_focus = []
        \\[keybinds.custom]
        \\"Super+E" = "spawn:nemo"
        \\"CapsLock" = "spawn:wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        \\[gestures]
        \\swipe_3_left = "builtin:focus_workspace_down"
        \\swipe_3_right = "builtin:focus_workspace_up"
        \\pinch_4_in = "builtin:toggle_start_menu"
        \\[[exec]]
        \\name = "agent"
        \\command = "agent --daemon"
        \\when = "always"
        \\restart = true
        \\log = "/tmp/agent.log"
        \\env = { MODE = "native" }
    );
    try std.testing.expectEqualStrings("foot", snapshot.spawn_terminal.slice());
    try std.testing.expectEqualStrings("shot-region", snapshot.screenshot.slice());
    const print = actions.parseChord("Print").?;
    try std.testing.expectEqualStrings("builtin:screenshot", snapshot.find(print.keysym, print.modifiers).?);
    try std.testing.expectEqualStrings("spawn:nemo", snapshot.find('e', 64).?);
    const caps_lock = actions.parseChord("CapsLock").?;
    try std.testing.expectEqualStrings(
        "spawn:wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
        snapshot.find(caps_lock.keysym, caps_lock.modifiers).?,
    );
    try std.testing.expectEqual(@as(u8, 1), snapshot.exec_count);
    try std.testing.expectEqual(actions.ExecWhen.always, snapshot.exec[0].when);
    try std.testing.expect(snapshot.exec[0].restart);
    try std.testing.expectEqualStrings("/tmp/agent.log", snapshot.exec[0].log_path.slice());
    try std.testing.expectEqualStrings("{ MODE = \"native\" }", snapshot.exec[0].env.slice());
    try std.testing.expectEqual(@as(u8, 3), snapshot.gestures_count);

    try std.testing.expectEqual(
        actions.GestureKind.swipe,
        snapshot.gestures[0].kind,
    );
    try std.testing.expectEqual(
        actions.GestureDirection.left,
        snapshot.gestures[0].direction,
    );
    try std.testing.expectEqual(@as(u8, 3), snapshot.gestures[0].fingers);
    try std.testing.expectEqualStrings(
        "builtin:focus_workspace_down",
        snapshot.gestures[0].verb.slice(),
    );

    try std.testing.expectEqual(
        actions.GestureKind.pinch,
        snapshot.gestures[2].kind,
    );
    try std.testing.expectEqual(
        actions.GestureDirection.in,
        snapshot.gestures[2].direction,
    );
    try std.testing.expectEqual(@as(u8, 4), snapshot.gestures[2].fingers);
}

test "overview binding supports defaults overrides unbinds and duplicate chords" {
    var snapshot: actions.Snapshot = .{};
    actions.initDefaults(&snapshot);
    const default = actions.parseChord("Super+W").?;
    try std.testing.expectEqualStrings(
        "builtin:toggle_overview",
        snapshot.find(default.keysym, default.modifiers).?,
    );

    applyActions(&snapshot,
        \\[keybinds]
        \\toggle_overview = ["Alt+W", "Super+O"]
    );
    try std.testing.expect(snapshot.find(default.keysym, default.modifiers) == null);
    const alternate = actions.parseChord("Alt+W").?;
    const second = actions.parseChord("Super+O").?;
    try std.testing.expectEqualStrings(
        "builtin:toggle_overview",
        snapshot.find(alternate.keysym, alternate.modifiers).?,
    );
    try std.testing.expectEqualStrings(
        "builtin:toggle_overview",
        snapshot.find(second.keysym, second.modifiers).?,
    );

    applyActions(&snapshot,
        \\[keybinds]
        \\toggle_overview = []
    );
    try std.testing.expect(snapshot.find(alternate.keysym, alternate.modifiers) == null);
    try std.testing.expect(snapshot.find(second.keysym, second.modifiers) == null);

    applyActions(&snapshot,
        \\[keybinds]
        \\toggle_overview = "Super+W"
        \\close_focused = "Super+W"
    );
    try std.testing.expectEqualStrings(
        "builtin:close_focused",
        snapshot.find(default.keysym, default.modifiers).?,
    );
}

test "gesture parser rejects malformed and incompatible keys" {
    try std.testing.expect(parseGestureKey("swipe_3_left") != null);
    try std.testing.expect(parseGestureKey("pinch_4_in") != null);

    try std.testing.expect(parseGestureKey("swipe_3_in") == null);
    try std.testing.expect(parseGestureKey("pinch_4_left") == null);
    try std.testing.expect(parseGestureKey("swipe_0_left") == null);
    try std.testing.expect(parseGestureKey("swipe_three_left") == null);
    try std.testing.expect(parseGestureKey("swipe_3_left_extra") == null);
}

pub const Environment = struct {
    xdg: ?[]const u8,
    home: ?[]const u8,
    wm_override: ?[]const u8,
    layout_override: ?[]const u8,
    input_override: ?[]const u8,

    fn read() Environment {
        return .{
            .xdg = getenv("XDG_CONFIG_HOME"),
            .home = getenv("HOME"),
            .wm_override = getenv("AQUEOUS_CONFIG"),
            .layout_override = getenv("AQUEOUS_LAYOUT"),
            .input_override = getenv("AQUEOUS_INPUT"),
        };
    }
};

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const result = std.mem.span(value);
    return if (result.len == 0) null else result;
}

pub fn resolveWmPath(buffer: []u8, env: Environment) ?[]const u8 {
    return resolveWmPathWithExists(buffer, env, exists);
}

fn resolveWmPathWithExists(buffer: []u8, env: Environment, path_exists: *const fn ([]const u8) bool) ?[]const u8 {
    if (env.wm_override) |path| return expandHome(buffer, path, env.home);
    if (env.xdg) |xdg| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/aqueous/wm.toml", .{xdg}) catch return null;
        if (path_exists(candidate)) return candidate;
    }
    if (env.home) |home| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/.config/aqueous/wm.toml", .{home}) catch return null;
        if (path_exists(candidate)) return candidate;
    }
    if (path_exists("/etc/xdg/aqueous/wm.toml")) return std.fmt.bufPrint(buffer, "/etc/xdg/aqueous/wm.toml", .{}) catch null;
    return null;
}

/// Kept as the stable pure helper used by existing tests and downstream code.
pub fn resolvePath(buffer: []u8, xdg_config_home: ?[]const u8, home: ?[]const u8, filename: []const u8) ?[]const u8 {
    if (xdg_config_home) |base| {
        if (base.len == 0) return null;
        return std.fmt.bufPrint(buffer, "{s}/aqueous/{s}", .{ base, filename }) catch null;
    }
    const base = home orelse return null;
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/aqueous/{s}", .{ base, filename }) catch null;
}

pub fn resolveLayoutPath(buffer: []u8, env: Environment, configured: []const u8, wm_dir: []const u8) ?[]const u8 {
    // Preserve the C# reader's unusual compatibility order: the traditional
    // HOME location wins before explicit sidecar overrides when it exists.
    if (env.home) |home| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/.config/aqueous/layout.toml", .{home}) catch return null;
        if (exists(candidate)) return candidate;
    }
    if (env.layout_override) |path| return expandHome(buffer, path, env.home);
    if (configured.len > 0) {
        if (std.fs.path.isAbsolute(configured)) return expandHome(buffer, configured, env.home);
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ wm_dir, configured }) catch null;
    }
    if (env.xdg) |xdg| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/aqueous/layout.toml", .{xdg}) catch return null;
        if (exists(candidate)) return candidate;
    }
    if (exists("/etc/xdg/aqueous/layout.toml")) return std.fmt.bufPrint(buffer, "/etc/xdg/aqueous/layout.toml", .{}) catch null;
    return null;
}

pub fn resolveInputPath(buffer: []u8, env: Environment, configured: []const u8) ?[]const u8 {
    if (env.input_override) |path| return expandHome(buffer, path, env.home);
    if (configured.len > 0) return expandHome(buffer, configured, env.home);
    if (env.xdg) |xdg| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/aqueous/input.toml", .{xdg}) catch return null;
        if (exists(candidate)) return candidate;
    }
    if (env.home) |home| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/.config/aqueous/input.toml", .{home}) catch return null;
        if (exists(candidate)) return candidate;
    }
    if (exists("/etc/xdg/aqueous/input.toml")) return std.fmt.bufPrint(buffer, "/etc/xdg/aqueous/input.toml", .{}) catch null;
    return null;
}

fn applyLayoutFile(allocator: std.mem.Allocator, snapshot: *Snapshot, path: []const u8) void {
    const source = readFile(allocator, path) orelse return;
    defer allocator.free(source);
    snapshot.fingerprint = hashSource(snapshot.fingerprint, source);
    applyLayoutSource(snapshot, source);
}

fn applyLayoutSource(snapshot: *Snapshot, source: []const u8) void {
    // The sidecar contains more than engine options: existing configurations
    // also place [[output]] and [[workspace]] layout mappings here. Route it
    // through the combined parser so those mappings and [layout] flags such as
    // force_ssd are retained; wm.apply delegates the layout-specific tables to
    // layout.apply at the end.
    wm.apply(&snapshot.wm, &snapshot.layout, source);
}

fn applyInputFile(allocator: std.mem.Allocator, snapshot: *Snapshot, path: []const u8) void {
    const source = readFile(allocator, path) orelse return;
    defer allocator.free(source);
    snapshot.fingerprint = hashSource(snapshot.fingerprint, source);
    applyInputSource(snapshot, source);
}

fn applyInputSource(snapshot: *Snapshot, source: []const u8) void {
    // Parse into a temporary default and merge only fields actually represented
    // by the input sidecar's sections. The parser ignores all unrelated tables.
    var overlay_wm: wm.Snapshot = .{};
    var ignored_layout: layout.Snapshot = .{};
    wm.apply(&overlay_wm, &ignored_layout, source);
    mergeInput(&snapshot.wm.input, overlay_wm.input);
    applyGestures(&snapshot.actions, source);
}

fn mergeInput(base: *wm.Input, overlay: wm.Input) void {
    const defaults: wm.Input = .{};
    if (overlay.focus_follows_mouse != defaults.focus_follows_mouse) base.focus_follows_mouse = overlay.focus_follows_mouse;
    if (overlay.focus_new_windows_set) {
        base.focus_new_windows = overlay.focus_new_windows;
        base.focus_new_windows_set = true;
    }
    if (overlay.pointer_acceleration != defaults.pointer_acceleration) base.pointer_acceleration = overlay.pointer_acceleration;
    if (overlay.pointer_acceleration_factor != defaults.pointer_acceleration_factor) base.pointer_acceleration_factor = overlay.pointer_acceleration_factor;
    if (overlay.repeat_rate_set) {
        base.repeat_rate = overlay.repeat_rate;
        base.repeat_rate_set = true;
    }
    if (overlay.repeat_delay_set) {
        base.repeat_delay = overlay.repeat_delay;
        base.repeat_delay_set = true;
    }
    mergeDevice(&base.mouse, overlay.mouse);
    mergeDevice(&base.touchpad, overlay.touchpad);
    mergeDevice(&base.trackpoint, overlay.trackpoint);
    if (!overlay.xkb_layout.empty()) base.xkb_layout = overlay.xkb_layout;
    if (!overlay.xkb_variant.empty()) base.xkb_variant = overlay.xkb_variant;
    if (!overlay.xkb_options.empty()) base.xkb_options = overlay.xkb_options;
}

fn mergeDevice(base: *wm.Device, overlay: wm.Device) void {
    if (overlay.accel_profile != .unset) base.accel_profile = overlay.accel_profile;
    if (overlay.accel_speed != null) base.accel_speed = overlay.accel_speed;
    if (overlay.natural_scroll != null) base.natural_scroll = overlay.natural_scroll;
    if (overlay.tap != null) base.tap = overlay.tap;
    if (overlay.dwt != null) base.dwt = overlay.dwt;
    if (overlay.left_handed != null) base.left_handed = overlay.left_handed;
    if (overlay.click_method != .unset) base.click_method = overlay.click_method;
    if (overlay.scroll_method != .unset) base.scroll_method = overlay.scroll_method;
    if (overlay.middle_emulation != null) base.middle_emulation = overlay.middle_emulation;
}

test "input sidecar repeat settings override inherited values including defaults" {
    var base: wm.Input = .{
        .repeat_rate = 75,
        .repeat_rate_set = true,
        .repeat_delay = 150,
        .repeat_delay_set = true,
    };
    var overlay_wm: wm.Snapshot = .{};
    var ignored_layout: layout.Snapshot = .{};
    wm.apply(&overlay_wm, &ignored_layout,
        \\[input]
        \\repeat_rate = 40
        \\repeat_delay = 400
    );
    mergeInput(&base, overlay_wm.input);

    try std.testing.expectEqual(@as(u31, 40), base.repeat_rate);
    try std.testing.expectEqual(@as(u31, 400), base.repeat_delay);
}

test "input sidecar can explicitly disable new-window focus" {
    var base: wm.Input = .{ .focus_new_windows = true, .focus_new_windows_set = true };
    var overlay_wm: wm.Snapshot = .{};
    var ignored_layout: layout.Snapshot = .{};
    wm.apply(&overlay_wm, &ignored_layout,
        \\[input]
        \\focus_new_windows = false
    );

    mergeInput(&base, overlay_wm.input);

    try std.testing.expect(!base.focus_new_windows);
    try std.testing.expect(base.focus_new_windows_set);
}

test "input sidecar applies gestures and overrides matching wm bindings" {
    var snapshot: Snapshot = .{};
    actions.initDefaults(&snapshot.actions);
    applyActions(&snapshot.actions,
        \\[gestures]
        \\swipe_3_left = "builtin:focus_workspace_down"
    );

    applyInputSource(&snapshot,
        \\[input]
        \\repeat_rate = 55
        \\[gestures]
        \\swipe_3_left = "builtin:focus_workspace_up"
        \\pinch_4_in = "builtin:toggle_start_menu"
        \\[keybinds.custom]
        \\"Super+E" = "spawn:nemo"
    );

    try std.testing.expectEqual(@as(u31, 55), snapshot.wm.input.repeat_rate);
    try std.testing.expectEqual(@as(u8, 2), snapshot.actions.gestures_count);
    try std.testing.expectEqualStrings(
        "builtin:focus_workspace_up",
        snapshot.actions.findGesture(.swipe, .left, 3).?,
    );
    try std.testing.expectEqualStrings(
        "builtin:toggle_start_menu",
        snapshot.actions.findGesture(.pinch, .in, 4).?,
    );
    try std.testing.expect(snapshot.actions.find('e', 64) == null);
}

test "layout sidecar applies workspace mappings as well as layout engines" {
    var snapshot: Snapshot = .{};
    applyLayoutSource(&snapshot,
        \\[layout]
        \\default = "game-mode"
        \\force_ssd = true
        \\[layout.slots]
        \\primary = "tile"
        \\[[workspace]]
        \\workspace = 2
        \\layout = "dwindle"
        \\[[workspace]]
        \\workspace = 3
        \\layout = "tile"
    );

    try std.testing.expectEqual(layout.LayoutId.game_mode, snapshot.layout.default);
    try std.testing.expectEqual(layout.LayoutId.tile, snapshot.layout.slots[0]);
    try std.testing.expect(snapshot.wm.force_ssd);
    try std.testing.expectEqual(layout.LayoutId.dwindle, snapshot.wm.resolveWorkspace(null, 2).?);
    try std.testing.expectEqual(layout.LayoutId.tile, snapshot.wm.resolveWorkspace(null, 3).?);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            log.warn("unable to read {s}: {}", .{ path, err });
            return null;
        },
    };
}

fn exists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn expandHome(buffer: []u8, path: []const u8, home: ?[]const u8) ?[]const u8 {
    if (path.len > 0 and path[0] == '~') {
        const base = home orelse return null;
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ base, path[1..] }) catch null;
    }
    return std.fmt.bufPrint(buffer, "{s}", .{path}) catch null;
}

fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn hashSource(seed: u64, source: []const u8) u64 {
    var hash = std.hash.Wyhash.init(seed);
    hash.update(source);
    return hash.final();
}

test "config paths prefer XDG and fall back to HOME" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/xdg/aqueous/wm.toml", resolvePath(&buffer, "/xdg", "/home/test", "wm.toml").?);
    try std.testing.expectEqualStrings("/home/test/.config/aqueous/layout.toml", resolvePath(&buffer, null, "/home/test", "layout.toml").?);
    try std.testing.expectEqual(@as(?[]const u8, null), resolvePath(&buffer, null, null, "wm.toml"));
}

test "explicit config path expands home" {
    var buffer: [256]u8 = undefined;
    const env: Environment = .{ .xdg = null, .home = "/home/test", .wm_override = "~/wm.toml", .layout_override = null, .input_override = null };
    try std.testing.expectEqualStrings("/home/test/wm.toml", resolveWmPath(&buffer, env).?);
}

fn xdgAndHomeWmExist(path: []const u8) bool {
    return std.mem.eql(u8, path, "/xdg/aqueous/wm.toml") or
        std.mem.eql(u8, path, "/home/test/.config/aqueous/wm.toml");
}

fn homeWmExists(path: []const u8) bool {
    return std.mem.eql(u8, path, "/home/test/.config/aqueous/wm.toml");
}

fn systemWmExists(path: []const u8) bool {
    return std.mem.eql(u8, path, "/etc/xdg/aqueous/wm.toml");
}

test "wm config discovery checks XDG HOME and system fallback in order" {
    const env: Environment = .{ .xdg = "/xdg", .home = "/home/test", .wm_override = null, .layout_override = null, .input_override = null };
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/xdg/aqueous/wm.toml", resolveWmPathWithExists(&buffer, env, xdgAndHomeWmExist).?);
    try std.testing.expectEqualStrings("/home/test/.config/aqueous/wm.toml", resolveWmPathWithExists(&buffer, env, homeWmExists).?);
    try std.testing.expectEqualStrings("/etc/xdg/aqueous/wm.toml", resolveWmPathWithExists(&buffer, env, systemWmExists).?);
}
