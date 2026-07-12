// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Engine = @import("engine.zig");
const toml = @import("../config/wm.zig");

const log = std.log.scoped(.aqueous);
const max_config_bytes = 1024 * 1024;

pub fn reloadFromDefaultPath(allocator: std.mem.Allocator, engine: *Engine) void {
    reloadDiscovered(allocator, engine, "");
}

pub fn reloadDiscovered(allocator: std.mem.Allocator, engine: *Engine, configured_path: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env_override = getenv("AQUEOUS_RULES");
    const xdg = getenv("XDG_CONFIG_HOME");
    const home = getenv("HOME");
    const path = resolveDiscoveredPath(&buffer, env_override, configured_path, xdg, home) orelse {
        engine.reloadSnapshot(&.{}, .{}) catch {};
        engine.source_fingerprint = 0;
        return;
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            engine.reloadSnapshot(&.{}, .{}) catch {};
            engine.source_fingerprint = 0;
            return;
        },
        else => {
            log.warn("unable to read {s}: {}", .{ path, err });
            return;
        },
    };
    defer allocator.free(source);
    parseAndReload(allocator, engine, source) catch |err| log.warn("unable to parse {s}: {}", .{ path, err });
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

pub fn resolvePath(buffer: []u8, xdg_config_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (xdg_config_home) |base| {
        if (base.len == 0) return null;
        return std.fmt.bufPrint(buffer, "{s}/aqueous/rules.toml", .{base}) catch null;
    }
    const base = home orelse return null;
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/aqueous/rules.toml", .{base}) catch null;
}

pub fn resolveDiscoveredPath(buffer: []u8, env_override: ?[]const u8, configured: []const u8, xdg: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (env_override) |path| return expandHome(buffer, path, home);
    if (configured.len > 0) return expandHome(buffer, configured, home);
    if (xdg) |base| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/aqueous/rules.toml", .{base}) catch return null;
        if (exists(candidate)) return candidate;
    }
    if (home) |base| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/.config/aqueous/rules.toml", .{base}) catch return null;
        if (exists(candidate)) return candidate;
    }
    return null;
}

pub fn parseAndReload(allocator: std.mem.Allocator, engine: *Engine, source: []const u8) !void {
    var parsed: std.ArrayListUnmanaged(Engine.Rule) = .empty;
    defer parsed.deinit(allocator);
    var current: ?Engine.Rule = null;
    var game_mode: Engine.GameMode = .{};
    var section: enum { none, game_mode, window } = .none;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = toml.cleanLine(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (current) |rule| try appendValid(allocator, &parsed, rule);
            current = null;
            if (std.mem.eql(u8, line, "[[window]]")) {
                current = .{};
                section = .window;
            } else if (std.mem.eql(u8, line, "[game_mode]")) {
                section = .game_mode;
            } else section = .none;
            continue;
        }
        const equal = toml.indexUnquoted(line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = toml.unquote(std.mem.trim(u8, line[equal + 1 ..], " \t"));
        switch (section) {
            .window => if (current) |*rule| applyValue(rule, key, value),
            .game_mode => applyGameMode(&game_mode, key, value),
            .none => {},
        }
    }
    if (current) |rule| try appendValid(allocator, &parsed, rule);
    try engine.reloadSnapshot(parsed.items, game_mode);
    engine.source_fingerprint = hash(source);
}

pub fn discoveredFingerprint(allocator: std.mem.Allocator, configured_path: []const u8) u64 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = resolveDiscoveredPath(&buffer, getenv("AQUEOUS_RULES"), configured_path, getenv("XDG_CONFIG_HOME"), getenv("HOME")) orelse return 0;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(max_config_bytes)) catch return 0;
    defer allocator.free(source);
    return hash(source);
}

fn hash(source: []const u8) u64 {
    var state = std.hash.Wyhash.init(0);
    state.update(source);
    return state.final();
}

fn appendValid(allocator: std.mem.Allocator, rules: *std.ArrayListUnmanaged(Engine.Rule), rule: Engine.Rule) !void {
    if (rule.app_id == null and rule.class == null and rule.title == null) return;
    try rules.append(allocator, rule);
}

fn applyGameMode(options: *Engine.GameMode, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "remainder_layout")) options.remainder_layout = parseLayout(value) orelse options.remainder_layout;
    if (std.mem.eql(u8, key, "fallback_layout")) options.fallback_layout = parseLayout(value) orelse options.fallback_layout;
    if (std.mem.eql(u8, key, "gaps_inner")) {
        const parsed = std.fmt.parseInt(i32, value, 10) catch return;
        if (parsed >= 0) options.gaps_inner = parsed;
    }
}

fn applyValue(rule: *Engine.Rule, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "app_id")) rule.app_id = value;
    if (std.mem.eql(u8, key, "class")) rule.class = value;
    if (std.mem.eql(u8, key, "title")) rule.title = value;
    if (std.mem.eql(u8, key, "floating")) rule.placement.floating = parseBool(value) orelse rule.placement.floating;
    if (std.mem.eql(u8, key, "workspace")) rule.placement.workspace = std.fmt.parseInt(u32, value, 10) catch rule.placement.workspace;
    if (std.mem.eql(u8, key, "width")) rule.placement.width = parsePositive(value) orelse rule.placement.width;
    if (std.mem.eql(u8, key, "height")) rule.placement.height = parsePositive(value) orelse rule.placement.height;
    if (std.mem.eql(u8, key, "x")) rule.placement.x = std.fmt.parseInt(i32, value, 10) catch rule.placement.x;
    if (std.mem.eql(u8, key, "y")) rule.placement.y = std.fmt.parseInt(i32, value, 10) catch rule.placement.y;
    if (std.mem.eql(u8, key, "layout")) {
        rule.layout = parseLayout(value) orelse rule.layout;
        if (rule.layout == .floating) rule.placement.floating = true;
    }
    if (std.mem.eql(u8, key, "anchor")) rule.anchor = parseAnchor(value) orelse rule.anchor;
    if (std.mem.eql(u8, key, "size")) rule.size = parseSize(value) orelse rule.size;
    if (std.mem.eql(u8, key, "scale")) rule.scale = parseScale(value) orelse rule.scale;
    if (std.mem.eql(u8, key, "fullscreen")) rule.fullscreen = parseBool(value) orelse rule.fullscreen;
    if (std.mem.eql(u8, key, "ignore_struts")) rule.ignore_struts = parseBool(value) orelse rule.ignore_struts;
    if (std.mem.eql(u8, key, "blur")) rule.blur = parseBool(value) orelse rule.blur;
    if (std.mem.eql(u8, key, "opacity")) rule.opacity = parseOpacity(value) orelse rule.opacity;
}

fn parseLayout(value: []const u8) ?Engine.Layout {
    if (std.mem.eql(u8, value, "tile")) return .tile;
    if (std.mem.eql(u8, value, "monocle")) return .monocle;
    if (std.mem.eql(u8, value, "grid")) return .grid;
    if (std.mem.eql(u8, value, "rows")) return .rows;
    if (std.mem.eql(u8, value, "dwindle")) return .dwindle;
    if (std.mem.eql(u8, value, "scrolling")) return .scrolling;
    if (std.mem.eql(u8, value, "float") or std.mem.eql(u8, value, "floating")) return .floating;
    if (std.mem.eql(u8, value, "game-mode") or std.mem.eql(u8, value, "game_mode")) return .game_mode;
    return null;
}

fn parseAnchor(value: []const u8) ?Engine.Anchor {
    inline for (.{ .center, .top, .bottom, .left, .right }) |anchor| if (std.mem.eql(u8, value, @tagName(anchor))) return anchor;
    return null;
}

fn parseSize(value: []const u8) ?Engine.Size {
    if (std.mem.eql(u8, value, "native")) return .native;
    const split = std.mem.indexOfScalar(u8, value, 'x') orelse return null;
    const left = value[0..split];
    const right = value[split + 1 ..];
    if (std.mem.indexOfScalar(u8, left, '.') != null or std.mem.indexOfScalar(u8, right, '.') != null) {
        const width = std.fmt.parseFloat(f64, left) catch return null;
        const height = std.fmt.parseFloat(f64, right) catch return null;
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or width > 1 or height <= 0 or height > 1) return null;
        return .{ .fraction = .{ .width = width, .height = height } };
    }
    const width = std.fmt.parseInt(i32, left, 10) catch return null;
    const height = std.fmt.parseInt(i32, right, 10) catch return null;
    if (width <= 0 or height <= 0) return null;
    return .{ .pixels = .{ .width = width, .height = height } };
}

fn parsePositive(value: []const u8) ?i32 {
    const parsed = std.fmt.parseInt(i32, value, 10) catch return null;
    return if (parsed > 0) parsed else null;
}
fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}
fn parseScale(value: []const u8) ?f64 {
    const result = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(result) and result > 0) result else null;
}
fn parseOpacity(value: []const u8) ?f64 {
    const result = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(result) and result >= 0 and result <= 1) result else null;
}

fn exists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
fn expandHome(buffer: []u8, path: []const u8, home: ?[]const u8) ?[]const u8 {
    if (path.len > 0 and path[0] == '~') return std.fmt.bufPrint(buffer, "{s}{s}", .{ home orelse return null, path[1..] }) catch null;
    return std.fmt.bufPrint(buffer, "{s}", .{path}) catch null;
}

test "rules parser preserves order and parses native placement behavior" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    try parseAndReload(std.testing.allocator, &engine,
        \\[game_mode]
        \\remainder_layout = "rows"
        \\fallback_layout = "tile"
        \\gaps_inner = 3
        \\[[window]]
        \\layout = "grid"
        \\[[window]]
        \\app_id = "game*"
        \\layout = "game-mode"
        \\anchor = "left"
        \\size = "0.7x0.5"
        \\scale = 1.2
        \\workspace = 9
        \\fullscreen = true
        \\ignore_struts = true
        \\opacity = 0.8
        \\[[window]]
        \\title = "Dialog #1"
        \\layout = "float"
        \\width = 800
        \\height = bad
    );
    try std.testing.expectEqual(@as(usize, 2), engine.rules.len);
    const game = engine.resolve(.{ .app_id = "game-one" }).?;
    try std.testing.expectEqual(Engine.Layout.game_mode, game.layout.?);
    try std.testing.expectEqual(@as(u32, 9), game.placement.workspace);
    try std.testing.expect(game.fullscreen and game.ignore_struts);
    try std.testing.expectEqual(Engine.Layout.rows, engine.game_mode.remainder_layout);
    try std.testing.expectEqual(Engine.Layout.tile, engine.game_mode.fallback_layout);
    try std.testing.expectEqual(@as(i32, 3), engine.game_mode.gaps_inner);
    const dialog = engine.resolve(.{ .title = "Dialog #1" }).?;
    try std.testing.expect(dialog.placement.floating);
    try std.testing.expectEqual(@as(i32, 800), dialog.placement.width);
}
