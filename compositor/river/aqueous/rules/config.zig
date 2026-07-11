// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Engine = @import("engine.zig");

const log = std.log.scoped(.aqueous);
const max_config_bytes = 1024 * 1024;

pub fn reloadFromDefaultPath(allocator: std.mem.Allocator, engine: *Engine) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const xdg = if (std.c.getenv("XDG_CONFIG_HOME")) |value| std.mem.span(value) else null;
    const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else null;
    const path = resolvePath(&buffer, xdg, home) orelse {
        engine.reload(&.{}) catch {};
        return;
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            engine.reload(&.{}) catch {};
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

pub fn resolvePath(buffer: []u8, xdg_config_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (xdg_config_home) |base| {
        if (base.len == 0) return null;
        return std.fmt.bufPrint(buffer, "{s}/aqueous/rules.toml", .{base}) catch null;
    }
    const base = home orelse return null;
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/aqueous/rules.toml", .{base}) catch null;
}

pub fn parseAndReload(allocator: std.mem.Allocator, engine: *Engine, source: []const u8) !void {
    var parsed: std.ArrayListUnmanaged(Engine.Rule) = .empty;
    defer parsed.deinit(allocator);
    var current: ?Engine.Rule = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = raw_line[0 .. std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len];
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[[window]]")) {
            if (current) |rule| try appendValid(allocator, &parsed, rule);
            current = .{};
            continue;
        }
        if (line[0] == '[') continue;
        if (current == null) continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        applyValue(&current.?, key, value);
    }
    if (current) |rule| try appendValid(allocator, &parsed, rule);
    try engine.reload(parsed.items);
}

fn appendValid(allocator: std.mem.Allocator, rules: *std.ArrayListUnmanaged(Engine.Rule), rule: Engine.Rule) !void {
    if (rule.app_id == null and rule.class == null and rule.title == null) return;
    try rules.append(allocator, rule);
}

fn applyValue(rule: *Engine.Rule, key: []const u8, raw_value: []const u8) void {
    const value = unquote(raw_value);
    if (std.mem.eql(u8, key, "app_id")) rule.app_id = value;
    if (std.mem.eql(u8, key, "class")) rule.class = value;
    if (std.mem.eql(u8, key, "title")) rule.title = value;
    if (std.mem.eql(u8, key, "floating")) rule.placement.floating = parseBool(value) orelse rule.placement.floating;
    if (std.mem.eql(u8, key, "tag")) rule.placement.tag = std.fmt.parseInt(u32, value, 10) catch rule.placement.tag;
    if (std.mem.eql(u8, key, "width")) rule.placement.width = parsePositive(value) orelse rule.placement.width;
    if (std.mem.eql(u8, key, "height")) rule.placement.height = parsePositive(value) orelse rule.placement.height;
    if (std.mem.eql(u8, key, "x")) rule.placement.x = std.fmt.parseInt(i32, value, 10) catch rule.placement.x;
    if (std.mem.eql(u8, key, "y")) rule.placement.y = std.fmt.parseInt(i32, value, 10) catch rule.placement.y;
    if (std.mem.eql(u8, key, "layout")) rule.layout = parseLayout(value) orelse rule.layout;
}

fn parseLayout(value: []const u8) ?Engine.Layout {
    if (std.mem.eql(u8, value, "tile")) return .tile;
    if (std.mem.eql(u8, value, "monocle")) return .monocle;
    if (std.mem.eql(u8, value, "grid")) return .grid;
    if (std.mem.eql(u8, value, "rows")) return .rows;
    if (std.mem.eql(u8, value, "dwindle")) return .dwindle;
    if (std.mem.eql(u8, value, "scrolling")) return .scrolling;
    if (std.mem.eql(u8, value, "float") or std.mem.eql(u8, value, "floating")) return .floating;
    if (std.mem.eql(u8, value, "game-mode")) return .game_mode;
    return null;
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

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

test "rules parser preserves order and drops matcher-less entries" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    try parseAndReload(std.testing.allocator, &engine,
        \\[[window]]
        \\layout = "grid"
        \\[[window]]
        \\app_id = "game*"
        \\layout = "game-mode"
        \\tag = 9
        \\[[window]]
        \\title = "Dialog"
        \\floating = true
        \\width = 800
        \\height = bad
    );
    try std.testing.expectEqual(@as(usize, 2), engine.rules.len);
    try std.testing.expectEqual(Engine.Layout.game_mode, engine.resolve(.{ .app_id = "game-one" }).?.layout.?);
    const dialog = engine.resolve(.{ .title = "Dialog" }).?;
    try std.testing.expect(dialog.placement.floating);
    try std.testing.expectEqual(@as(i32, 800), dialog.placement.width);
    try std.testing.expectEqual(@as(i32, 0), dialog.placement.height);
}