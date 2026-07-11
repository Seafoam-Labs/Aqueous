// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Engine = @This();

const std = @import("std");
const glob = @import("glob.zig");

pub const Identity = struct {
    app_id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const Placement = struct {
    floating: bool = false,
    tag: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};

pub const Anchor = enum { center, top, bottom, left, right };

pub const Size = union(enum) {
    native,
    pixels: struct { width: i32, height: i32 },
    fraction: struct { width: f64, height: f64 },
};

pub const Layout = enum {
    tile,
    monocle,
    grid,
    rows,
    dwindle,
    scrolling,
    floating,
    game_mode,
};

pub const Rule = struct {
    app_id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    title: ?[]const u8 = null,
    layout: ?Layout = .game_mode,
    placement: Placement = .{},
    anchor: Anchor = .center,
    size: Size = .native,
    scale: f64 = 1,
    fullscreen: bool = false,
    ignore_struts: bool = false,
    blur: ?bool = null,
    opacity: ?f64 = null,
};

pub const GameMode = struct {
    remainder_layout: Layout = .grid,
    gaps_inner: i32 = 8,
    fallback_layout: Layout = .grid,
};

allocator: std.mem.Allocator,
rules: []Rule = &.{},
game_mode: GameMode = .{},
source_fingerprint: u64 = 0,

pub fn init(allocator: std.mem.Allocator) Engine {
    return .{ .allocator = allocator };
}

pub fn deinit(engine: *Engine) void {
    engine.clear();
}

pub fn reload(engine: *Engine, rules: []const Rule) !void {
    const replacement = try cloneRules(engine.allocator, rules);
    engine.clear();
    engine.rules = replacement;
}

pub fn reloadSnapshot(engine: *Engine, rules: []const Rule, game_mode: GameMode) !void {
    const replacement = try cloneRules(engine.allocator, rules);
    engine.clear();
    engine.rules = replacement;
    engine.game_mode = game_mode;
}

pub fn resolve(engine: *const Engine, identity: Identity) ?Rule {
    for (engine.rules) |rule| {
        if (rule.app_id == null and rule.class == null and rule.title == null) continue;
        if (rule.app_id != null and !glob.matches(rule.app_id, identity.app_id)) continue;
        if (rule.class != null and !glob.matches(rule.class, identity.class)) continue;
        if (rule.title != null and !glob.matches(rule.title, identity.title)) continue;
        return rule;
    }
    return null;
}

fn clear(engine: *Engine) void {
    for (engine.rules) |rule| {
        if (rule.app_id) |value| engine.allocator.free(value);
        if (rule.class) |value| engine.allocator.free(value);
        if (rule.title) |value| engine.allocator.free(value);
    }
    if (engine.rules.len > 0) engine.allocator.free(engine.rules);
    engine.rules = &.{};
}

fn cloneRules(allocator: std.mem.Allocator, rules: []const Rule) ![]Rule {
    const result = try allocator.alloc(Rule, rules.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |rule| {
            if (rule.app_id) |value| allocator.free(value);
            if (rule.class) |value| allocator.free(value);
            if (rule.title) |value| allocator.free(value);
        }
        allocator.free(result);
    }
    for (rules, result) |source, *destination| {
        destination.* = try cloneRule(allocator, source);
        initialized += 1;
    }
    return result;
}

fn cloneRule(allocator: std.mem.Allocator, source: Rule) !Rule {
    var result = source;
    result.app_id = if (source.app_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (result.app_id) |value| allocator.free(value);
    result.class = if (source.class) |value| try allocator.dupe(u8, value) else null;
    errdefer if (result.class) |value| allocator.free(value);
    result.title = if (source.title) |value| try allocator.dupe(u8, value) else null;
    return result;
}

test "rules are first-match-wins and require every present matcher" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    var source = [_]Rule{
        .{ .app_id = "game*", .title = "Menu", .placement = .{ .tag = 1 } },
        .{ .app_id = "game*", .placement = .{ .tag = 2 } },
        .{ .placement = .{ .tag = 3 } },
    };
    try engine.reload(&source);
    source[0].placement.tag = 99;
    try std.testing.expectEqual(@as(u32, 1), engine.resolve(.{ .app_id = "game-one", .title = "Menu" }).?.placement.tag);
    try std.testing.expectEqual(@as(u32, 2), engine.resolve(.{ .app_id = "game-one", .title = "Play" }).?.placement.tag);
    try std.testing.expect(engine.resolve(.{ .app_id = "editor" }) == null);
}
