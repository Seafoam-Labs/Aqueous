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
    workspace: u32 = 0,
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
    reverse_dwindle,
    scrolling,
    floating,
    game_mode,
    composable,
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
    /// Auto HDR expansion override for matching windows on HDR outputs with
    /// `auto_hdr` enabled. Null follows the default (fullscreen windows).
    hdr_expand: ?bool = null,

    /// Stable semantic identity used by per-window lifecycle reconciliation.
    /// It deliberately excludes source addresses and struct padding.
    pub fn fingerprint(rule: Rule) u64 {
        var hash = std.hash.Wyhash.init(0);
        hashOptionalString(&hash, rule.app_id);
        hashOptionalString(&hash, rule.class);
        hashOptionalString(&hash, rule.title);
        hashOptionalEnum(&hash, rule.layout);
        hash.update(std.mem.asBytes(&rule.placement.floating));
        hash.update(std.mem.asBytes(&rule.placement.workspace));
        hash.update(std.mem.asBytes(&rule.placement.width));
        hash.update(std.mem.asBytes(&rule.placement.height));
        hash.update(std.mem.asBytes(&rule.placement.x));
        hash.update(std.mem.asBytes(&rule.placement.y));
        hash.update(std.mem.asBytes(&rule.anchor));
        switch (rule.size) {
            .native => hash.update(&.{0}),
            .pixels => |size| {
                hash.update(&.{1});
                hash.update(std.mem.asBytes(&size.width));
                hash.update(std.mem.asBytes(&size.height));
            },
            .fraction => |size| {
                hash.update(&.{2});
                hash.update(std.mem.asBytes(&size.width));
                hash.update(std.mem.asBytes(&size.height));
            },
        }
        hash.update(std.mem.asBytes(&rule.scale));
        hash.update(std.mem.asBytes(&rule.fullscreen));
        hash.update(std.mem.asBytes(&rule.ignore_struts));
        hashOptionalBool(&hash, rule.blur);
        hashOptionalFloat(&hash, rule.opacity);
        hashOptionalBool(&hash, rule.hdr_expand);
        const value = hash.final();
        return if (value == 0) 1 else value;
    }

    /// Identity of the matching clause only. Placement and visual edits do not
    /// create a new match and therefore cannot discard user overrides.
    pub fn matcherFingerprint(rule: Rule) u64 {
        var hash = std.hash.Wyhash.init(0);
        hashOptionalString(&hash, rule.app_id);
        hashOptionalString(&hash, rule.class);
        hashOptionalString(&hash, rule.title);
        const value = hash.final();
        return if (value == 0) 1 else value;
    }

    pub fn floatingFingerprint(rule: Rule) u64 {
        var placement_only = rule;
        placement_only.app_id = null;
        placement_only.class = null;
        placement_only.title = null;
        placement_only.layout = null;
        placement_only.fullscreen = false;
        placement_only.blur = null;
        placement_only.opacity = null;
        placement_only.hdr_expand = null;
        return placement_only.fingerprint();
    }
};

pub const LayerRule = struct {
    namespace: ?[]const u8 = null,
    blur: bool = false,
    blur_popups: bool = false,
};

pub const GameMode = struct {
    remainder_layout: Layout = .grid,
    gaps_inner: i32 = 8,
    fallback_layout: Layout = .grid,
};

allocator: std.mem.Allocator,
rules: []Rule = &.{},
layer_rules: []LayerRule = &.{},
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

pub fn reloadSnapshot(
    engine: *Engine,
    rules: []const Rule,
    layer_rules: []const LayerRule,
    game_mode: GameMode,
) !void {
    const replacement = try cloneRules(engine.allocator, rules);
    errdefer freeRules(engine.allocator, replacement);
    const layer_replacement = try cloneLayerRules(engine.allocator, layer_rules);
    engine.clear();
    engine.rules = replacement;
    engine.layer_rules = layer_replacement;
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

pub fn resolveLayer(engine: *const Engine, namespace: []const u8) ?LayerRule {
    for (engine.layer_rules) |rule| {
        const pattern = rule.namespace orelse continue;
        if (glob.matches(pattern, namespace)) return rule;
    }
    return null;
}

fn clear(engine: *Engine) void {
    freeRules(engine.allocator, engine.rules);
    freeLayerRules(engine.allocator, engine.layer_rules);
    engine.rules = &.{};
    engine.layer_rules = &.{};
}

fn freeRules(allocator: std.mem.Allocator, rules: []Rule) void {
    for (rules) |rule| {
        if (rule.app_id) |value| allocator.free(value);
        if (rule.class) |value| allocator.free(value);
        if (rule.title) |value| allocator.free(value);
    }
    if (rules.len > 0) allocator.free(rules);
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

fn cloneLayerRules(allocator: std.mem.Allocator, rules: []const LayerRule) ![]LayerRule {
    const result = try allocator.alloc(LayerRule, rules.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |rule| {
            if (rule.namespace) |value| allocator.free(value);
        }
        allocator.free(result);
    }
    for (rules, result) |source, *destination| {
        destination.* = source;
        destination.namespace = if (source.namespace) |value|
            try allocator.dupe(u8, value)
        else
            null;
        initialized += 1;
    }
    return result;
}

fn freeLayerRules(allocator: std.mem.Allocator, rules: []LayerRule) void {
    for (rules) |rule| {
        if (rule.namespace) |value| allocator.free(value);
    }
    if (rules.len > 0) allocator.free(rules);
}

fn hashOptionalString(hash: *std.hash.Wyhash, value: ?[]const u8) void {
    if (value) |text| {
        hash.update(&.{1});
        hash.update(text);
    } else hash.update(&.{0});
}

fn hashOptionalEnum(hash: *std.hash.Wyhash, value: ?Layout) void {
    const encoded: u8 = if (value) |item| @as(u8, @intFromEnum(item)) + 1 else 0;
    hash.update(std.mem.asBytes(&encoded));
}

fn hashOptionalBool(hash: *std.hash.Wyhash, value: ?bool) void {
    const encoded: u8 = if (value) |item| if (item) 2 else 1 else 0;
    hash.update(std.mem.asBytes(&encoded));
}

fn hashOptionalFloat(hash: *std.hash.Wyhash, value: ?f64) void {
    if (value) |item| {
        hash.update(&.{1});
        hash.update(std.mem.asBytes(&item));
    } else hash.update(&.{0});
}

test "rules are first-match-wins and require every present matcher" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    var source = [_]Rule{
        .{ .app_id = "game*", .title = "Menu", .placement = .{ .workspace = 1 } },
        .{ .app_id = "game*", .placement = .{ .workspace = 2 } },
        .{ .placement = .{ .workspace = 3 } },
    };
    try engine.reload(&source);
    source[0].placement.workspace = 99;
    try std.testing.expectEqual(@as(u32, 1), engine.resolve(.{ .app_id = "game-one", .title = "Menu" }).?.placement.workspace);
    try std.testing.expectEqual(@as(u32, 2), engine.resolve(.{ .app_id = "game-one", .title = "Play" }).?.placement.workspace);
    try std.testing.expect(engine.resolve(.{ .app_id = "editor" }) == null);
}

test "layer rules are first-match-wins namespace globs" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.reloadSnapshot(&.{}, &.{
        .{ .namespace = "panel-*", .blur = true, .blur_popups = true },
        .{ .namespace = "*", .blur = false },
    }, .{});
    const panel = engine.resolveLayer("panel-main").?;
    try std.testing.expect(panel.blur);
    try std.testing.expect(panel.blur_popups);
    try std.testing.expect(!engine.resolveLayer("launcher").?.blur);
    try std.testing.expect(!engine.resolveLayer("launcher").?.blur_popups);
}

test "rule fingerprints are semantic and detect behavior changes" {
    const first: Rule = .{ .app_id = "term*", .placement = .{ .floating = true } };
    const same: Rule = .{ .app_id = "term*", .placement = .{ .floating = true } };
    const changed: Rule = .{ .app_id = "term*", .fullscreen = true };
    try std.testing.expectEqual(first.fingerprint(), same.fingerprint());
    try std.testing.expect(first.fingerprint() != changed.fingerprint());
    try std.testing.expect(first.fingerprint() != 0);
}

test "matcher fingerprints ignore unrelated property edits" {
    const first: Rule = .{ .app_id = "term*", .fullscreen = true };
    const visual_edit: Rule = .{ .app_id = "term*", .fullscreen = true, .opacity = 0.8 };
    const different_match: Rule = .{ .app_id = "term*", .title = "Preferences" };
    try std.testing.expectEqual(first.matcherFingerprint(), visual_edit.matcherFingerprint());
    try std.testing.expect(first.matcherFingerprint() != different_match.matcherFingerprint());
}

test "floating fingerprints ignore visual edits but detect geometry edits" {
    const first: Rule = .{ .placement = .{ .floating = true, .width = 500 }, .opacity = 0.8 };
    const visual_edit: Rule = .{ .placement = .{ .floating = true, .width = 500 }, .opacity = 0.5 };
    const geometry_edit: Rule = .{ .placement = .{ .floating = true, .width = 700 }, .opacity = 0.5 };
    try std.testing.expectEqual(first.floatingFingerprint(), visual_edit.floatingFingerprint());
    try std.testing.expect(first.floatingFingerprint() != geometry_edit.floatingFingerprint());
}
