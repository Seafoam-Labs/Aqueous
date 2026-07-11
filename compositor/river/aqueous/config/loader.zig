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
    const Section = enum { none, action, keybinds, custom, exec };
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
            } else if (std.mem.eql(u8, line, "[actions]")) section = .action else if (std.mem.eql(u8, line, "[keybinds]")) section = .keybinds else if (std.mem.eql(u8, line, "[keybinds.custom]")) section = .custom else section = .none;
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
            .none => {},
        }
    }
    if (pending) |entry| if (!entry.name.empty() and !entry.command.empty() and snapshot.exec_count < actions.max_exec) {
        snapshot.exec[snapshot.exec_count] = entry;
        snapshot.exec_count += 1;
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
        \\[keybinds]
        \\cycle_focus = []
        \\[keybinds.custom]
        \\"Super+E" = "spawn:nemo"
        \\[[exec]]
        \\name = "agent"
        \\command = "agent --daemon"
        \\when = "always"
        \\restart = true
        \\log = "/tmp/agent.log"
        \\env = { MODE = "native" }
    );
    try std.testing.expectEqualStrings("foot", snapshot.spawn_terminal.slice());
    try std.testing.expectEqualStrings("spawn:nemo", snapshot.find('e', 64).?);
    try std.testing.expectEqual(@as(u8, 1), snapshot.exec_count);
    try std.testing.expectEqual(actions.ExecWhen.always, snapshot.exec[0].when);
    try std.testing.expect(snapshot.exec[0].restart);
    try std.testing.expectEqualStrings("/tmp/agent.log", snapshot.exec[0].log_path.slice());
    try std.testing.expectEqualStrings("{ MODE = \"native\" }", snapshot.exec[0].env.slice());
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
    layout.apply(&snapshot.layout, source);
}

fn applyInputFile(allocator: std.mem.Allocator, snapshot: *Snapshot, path: []const u8) void {
    const source = readFile(allocator, path) orelse return;
    defer allocator.free(source);
    snapshot.fingerprint = hashSource(snapshot.fingerprint, source);
    // Parse into a temporary default and merge only fields actually represented
    // by the input sidecar's sections. The parser ignores all unrelated tables.
    var overlay_wm: wm.Snapshot = .{};
    var ignored_layout: layout.Snapshot = .{};
    wm.apply(&overlay_wm, &ignored_layout, source);
    mergeInput(&snapshot.wm.input, overlay_wm.input);
}

fn mergeInput(base: *wm.Input, overlay: wm.Input) void {
    const defaults: wm.Input = .{};
    if (overlay.focus_follows_mouse != defaults.focus_follows_mouse) base.focus_follows_mouse = overlay.focus_follows_mouse;
    if (overlay.pointer_acceleration != defaults.pointer_acceleration) base.pointer_acceleration = overlay.pointer_acceleration;
    if (overlay.pointer_acceleration_factor != defaults.pointer_acceleration_factor) base.pointer_acceleration_factor = overlay.pointer_acceleration_factor;
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
