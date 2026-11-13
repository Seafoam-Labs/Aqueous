// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Engine = @This();

const std = @import("std");
const glob = @import("glob.zig");
const wp = @import("wayland").server.wp;
const scaling = @import("scaling");

pub const StackLayer = enum { below, normal, above };
pub const PlacementPolicy = enum { cascade, center, under_pointer, minimal_overlap };

pub const Scope = enum { managed, override_redirect };
// Values match enum wlr_xwayland_net_wm_window_type.
pub const X11WindowType = enum(c_int) { desktop, dock, toolbar, menu, utility, splash, dialog, dropdown_menu, popup_menu, tooltip, notification, combo, dnd, normal };

pub const Identity = struct {
    scope: Scope = .managed,
    window_types: u16 = 0,
    app_id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    title: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    content_type: wp.ContentTypeV1.Type = .none,
    /// Semantic matcher the window's policy state already owns (zero when it
    /// owns none). A timing-restricted rule still resolves for the window
    /// which claimed it so eligibility changes never evict its lifecycle.
    current_match: u64 = 0,
    /// True while the compositor is still in its startup phase. Consumed by
    /// `matching = "startup"` rules; every other timing ignores it.
    startup_phase: bool = true,
};

pub const Placement = struct {
    floating: bool = false,
    /// Exact connector name reported by `aqueousctl outputs`. Null keeps the
    /// window on its admission output.
    output: ?[]const u8 = null,
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

/// When a rule is eligible to match. `once` binds to the first window which
/// claims it; `startup` applies only while the compositor is in its startup
/// phase. Ineligible rules keep resolving for the window which already owns
/// their matcher so an eligibility change never rolls back claimed state.
pub const Matching = enum {
    always,
    once,
    startup,

    pub fn parse(value: []const u8) ?Matching {
        if (std.mem.eql(u8, value, "always")) return .always;
        if (std.mem.eql(u8, value, "once") or std.mem.eql(u8, value, "match-once") or std.mem.eql(u8, value, "match_once")) return .once;
        if (std.mem.eql(u8, value, "startup") or std.mem.eql(u8, value, "at-startup") or std.mem.eql(u8, value, "at_startup")) return .startup;
        return null;
    }
};

pub const OverlayPreference = enum {
    off,
    prefer,

    pub fn parse(value: []const u8) ?OverlayPreference {
        if (std.mem.eql(u8, value, "off")) return .off;
        if (std.mem.eql(u8, value, "prefer")) return .prefer;
        return null;
    }
};

pub const Rule = struct {
    scope: Scope = .managed,
    window_type: ?X11WindowType = null,
    // Presence matters for popup placement: zero is an explicit coordinate.
    position_x: ?i32 = null,
    position_y: ?i32 = null,
    app_id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    title: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    /// Matches the wp_content_type_v1 state committed by the client. Rules
    /// with this matcher only apply visual/client-buffer effects (blur,
    /// opacity, buffer_scale_policy, hdr_expand, and keep_render); layout and
    /// placement edits are deliberately dropped at resolve time because the
    /// content type commonly arrives long after map and must never move an
    /// already-arranged window.
    content_type: ?wp.ContentTypeV1.Type = null,
    /// Null preserves the workspace layout; game mode must be explicit.
    layout: ?Layout = null,
    placement: Placement = .{},
    anchor: Anchor = .center,
    size: Size = .native,
    scale: f64 = 1,
    fullscreen: bool = false,
    /// Initial scrolling column preset; null leaves the user's width alone.
    scrolling_full_width: ?bool = null,
    /// Base scrolling column footprint as a fraction of its usable viewport.
    scrolling_width: ?f64 = null,
    ignore_struts: bool = false,
    blur: ?bool = null,
    opacity: ?f64 = null,
    /// Override the global client-buffer scaling strategy for this window.
    buffer_scale_policy: ?scaling.BufferScalePolicy = null,
    /// Auto HDR expansion override for matching windows on HDR outputs with
    /// `auto_hdr` enabled. Null follows the default (fullscreen windows and
    /// game content).
    hdr_expand: ?bool = null,
    /// Request zero-copy promotion when the output/backend accepts it.
    overlay_plane: OverlayPreference = .off,
    stack_layer: ?StackLayer = null,
    placement_policy: ?PlacementPolicy = null,
    focus: ?bool = null,
    fixed_position: bool = false,
    skip_switcher: bool = false,
    skip_taskbar: bool = false,
    /// Keep delivering frame callbacks while the window is hidden so
    /// callback-driven clients (games) keep rendering in the background. This
    /// is a client-buffer effect, not a visibility change: the scene nodes stay
    /// disabled and the window is never composited.
    keep_render: bool = false,
    /// When this rule is eligible to match. See `Matching`.
    matching: Matching = .always,

    /// Stable semantic identity used by per-window lifecycle reconciliation.
    /// It deliberately excludes source addresses and struct padding.
    pub fn fingerprint(rule: Rule) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&rule.scope));
        hashOptionalEnum(&hash, rule.window_type);
        hashOptionalString(&hash, rule.app_id);
        hashOptionalString(&hash, rule.class);
        hashOptionalString(&hash, rule.title);
        hashOptionalString(&hash, rule.tag);
        hashOptionalContentType(&hash, rule.content_type);
        hashOptionalEnum(&hash, rule.layout);
        hash.update(std.mem.asBytes(&rule.placement.floating));
        hashOptionalString(&hash, rule.placement.output);
        hash.update(std.mem.asBytes(&rule.placement.workspace));
        hash.update(std.mem.asBytes(&rule.placement.width));
        hash.update(std.mem.asBytes(&rule.placement.height));
        hash.update(std.mem.asBytes(&rule.placement.x));
        hash.update(std.mem.asBytes(&rule.placement.y));
        if (rule.scope == .override_redirect) {
            hashOptionalInt(&hash, rule.position_x);
            hashOptionalInt(&hash, rule.position_y);
        }
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
        hashOptionalBool(&hash, rule.scrolling_full_width);
        hashOptionalFloat(&hash, rule.scrolling_width);
        hash.update(std.mem.asBytes(&rule.ignore_struts));
        hashOptionalBool(&hash, rule.blur);
        hashOptionalFloat(&hash, rule.opacity);
        hashOptionalEnum(&hash, rule.buffer_scale_policy);
        hashOptionalBool(&hash, rule.hdr_expand);
        hash.update(std.mem.asBytes(&rule.overlay_plane));
        hashOptionalEnum(&hash, rule.stack_layer);
        hashOptionalEnum(&hash, rule.placement_policy);
        hashOptionalBool(&hash, rule.focus);
        hash.update(std.mem.asBytes(&rule.fixed_position));
        hash.update(std.mem.asBytes(&rule.skip_switcher));
        hash.update(std.mem.asBytes(&rule.skip_taskbar));
        hash.update(std.mem.asBytes(&rule.keep_render));
        hash.update(std.mem.asBytes(&rule.matching));
        const value = hash.final();
        return if (value == 0) 1 else value;
    }

    /// Identity of the matching clause only. Placement and visual edits do not
    /// create a new match and therefore cannot discard user overrides. The
    /// matching timing is part of the clause: editing `always` to `once` (or
    /// back) opens a fresh ownership lifecycle on reload.
    pub fn matcherFingerprint(rule: Rule) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&rule.scope));
        hashOptionalEnum(&hash, rule.window_type);
        hashOptionalString(&hash, rule.app_id);
        hashOptionalString(&hash, rule.class);
        hashOptionalString(&hash, rule.title);
        hashOptionalString(&hash, rule.tag);
        hashOptionalContentType(&hash, rule.content_type);
        hash.update(std.mem.asBytes(&rule.matching));
        const value = hash.final();
        return if (value == 0) 1 else value;
    }

    pub fn floatingFingerprint(rule: Rule) u64 {
        var placement_only = rule;
        placement_only.app_id = null;
        placement_only.class = null;
        placement_only.title = null;
        placement_only.tag = null;
        placement_only.content_type = null;
        placement_only.layout = null;
        placement_only.fullscreen = false;
        placement_only.scrolling_full_width = null;
        placement_only.scrolling_width = null;
        placement_only.blur = null;
        placement_only.opacity = null;
        placement_only.hdr_expand = null;
        placement_only.overlay_plane = .off;
        placement_only.stack_layer = null;
        placement_only.focus = null;
        placement_only.fixed_position = false;
        placement_only.skip_switcher = false;
        placement_only.skip_taskbar = false;
        placement_only.keep_render = false;
        placement_only.matching = .always;
        return placement_only.fingerprint();
    }

    /// Identity of the composite output/workspace target. Zero means normal
    /// admission placement with neither field configured.
    pub fn placementFingerprint(rule: Rule) u64 {
        if (rule.placement.output == null and rule.placement.workspace == 0) return 0;
        var hash = std.hash.Wyhash.init(0);
        hashOptionalString(&hash, rule.placement.output);
        hash.update(std.mem.asBytes(&rule.placement.workspace));
        const value = hash.final();
        return if (value == 0) 1 else value;
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
/// Matcher fingerprints of `matching = "once"` rules which a window has
/// already claimed. Preserved across reloads for unchanged matchers so a
/// hot-reload never re-arms a rule another window owns.
consumed_once: std.AutoHashMapUnmanaged(u64, void) = .empty,

pub fn init(allocator: std.mem.Allocator) Engine {
    return .{ .allocator = allocator };
}

pub fn deinit(engine: *Engine) void {
    engine.clear();
    engine.consumed_once.deinit(engine.allocator);
}

pub fn reload(engine: *Engine, rules: []const Rule) !void {
    const replacement = try cloneRules(engine.allocator, rules);
    engine.clear();
    engine.rules = replacement;
    engine.pruneConsumedOnce();
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
    engine.pruneConsumedOnce();
}

/// True when a timing-restricted rule remains eligible for `identity`. A
/// window which already owns the matcher always keeps eligibility: the once
/// budget being spent or the startup phase ending must never evict the rule
/// lifecycle its window is still living under.
fn matchingEligible(engine: *const Engine, rule: Rule, identity: Identity) bool {
    if (rule.matching == .always) return true;
    if (identity.current_match != 0 and identity.current_match == rule.matcherFingerprint()) return true;
    return switch (rule.matching) {
        .always => true,
        .startup => identity.startup_phase,
        .once => !engine.consumed_once.contains(rule.matcherFingerprint()),
    };
}

/// Record that a `matching = "once"` rule was accepted for a window so every
/// later window falls through to the next rule. Other timings are unaffected.
pub fn claimMatching(engine: *Engine, rule: Rule) void {
    if (rule.matching != .once) return;
    engine.consumed_once.put(engine.allocator, rule.matcherFingerprint(), {}) catch return;
}

/// Drop once-budgets whose matcher no longer exists in the ruleset. Editing a
/// matcher legitimately re-arms the rule; keeping budgets for matchers which
/// returned verbatim re-arms nothing.
fn pruneConsumedOnce(engine: *Engine) void {
    var stale = std.ArrayListUnmanaged(u64).empty;
    defer stale.deinit(engine.allocator);
    var keys = engine.consumed_once.keyIterator();
    while (keys.next()) |key| {
        var live = false;
        for (engine.rules) |rule| {
            if (rule.matching == .once and rule.matcherFingerprint() == key.*) {
                live = true;
                break;
            }
        }
        if (!live) stale.append(engine.allocator, key.*) catch {};
    }
    for (stale.items) |key| _ = engine.consumed_once.remove(key);
}

/// True when `rule`'s matchers accept `identity`. A rule with no matcher never
/// matches; each present matcher must match its corresponding identity field.
fn matchesIdentity(engine: *const Engine, rule: Rule, identity: Identity) bool {
    if (rule.scope != identity.scope) return false;
    if (rule.matching != .always and identity.current_match != 0 and identity.current_match == rule.matcherFingerprint()) return true;
    if (!engine.matchingEligible(rule, identity)) return false;
    if (rule.window_type) |kind| if (identity.window_types & (@as(u16, 1) << @intCast(@backingInt(kind))) == 0) return false;
    if (rule.app_id == null and rule.class == null and rule.title == null and rule.tag == null and rule.content_type == null and rule.window_type == null) return false;
    if (rule.app_id != null and !glob.matches(rule.app_id, identity.app_id)) return false;
    if (rule.class != null and !glob.matches(rule.class, identity.class)) return false;
    if (rule.title != null and !glob.matches(rule.title, identity.title)) return false;
    if (rule.tag) |pattern| if (!glob.matchesTag(pattern, identity.tag)) return false;
    if (rule.content_type) |expected| if (expected != identity.content_type) return false;
    return true;
}

pub fn resolve(engine: *const Engine, identity: Identity) ?Rule {
    // A claimed timing rule is bound to this window until removed or its
    // matching clause changes. Title/tag updates and newly matching earlier
    // rules must not replace it or discard its manual overrides.
    var candidates = engine.rules;
    if (identity.current_match != 0) {
        for (engine.rules, 0..) |rule, index| {
            if (rule.scope == identity.scope and rule.matching != .always and rule.matcherFingerprint() == identity.current_match) {
                candidates = engine.rules[index .. index + 1];
                break;
            }
        }
    }
    for (candidates) |rule| {
        if (!engine.matchesIdentity(rule, identity)) continue;
        if (rule.content_type == null) return rule;
        // Content-type rules are visual-only: drop every layout and placement
        // edit so a late-arriving content type can never move a window.
        var visual = rule;
        visual.layout = null;
        visual.placement = .{};
        visual.anchor = .center;
        visual.size = .native;
        visual.scale = 1;
        visual.fullscreen = false;
        visual.scrolling_full_width = null;
        visual.scrolling_width = null;
        visual.ignore_struts = false;
        visual.stack_layer = null;
        visual.placement_policy = null;
        visual.focus = null;
        visual.fixed_position = false;
        visual.skip_switcher = false;
        visual.skip_taskbar = false;
        return visual;
    }
    // No user rule claimed this window. Fall back to the built-in picker
    // default, which is intentionally absent from engine.rules and therefore
    // never listed nor able to override a user rule.
    for (picker_fallback) |rule| {
        if (engine.matchesIdentity(rule, identity)) return rule;
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
        if (rule.tag) |value| allocator.free(value);
        if (rule.placement.output) |value| allocator.free(value);
    }
    if (rules.len > 0) allocator.free(rules);
}

/// Built-in fallback: present the screen-sharing picker as a centered floating
/// overlay. It is deliberately kept OUT of `engine.rules` and consulted by
/// resolve() only after no user rule matched, so any user `[[window]]` rule for
/// the picker fully replaces it and it never appears in the user ruleset or rule
/// inspection. The glob covers every instance channel
/// (org.aqueous[.Git|.IntelGit].PortalPicker).
const picker_fallback = [_]Rule{.{
    .app_id = "*PortalPicker",
    .placement = .{ .floating = true },
    .placement_policy = .center,
}};

fn cloneRules(allocator: std.mem.Allocator, rules: []const Rule) ![]Rule {
    const result = try allocator.alloc(Rule, rules.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |rule| {
            if (rule.app_id) |value| allocator.free(value);
            if (rule.class) |value| allocator.free(value);
            if (rule.title) |value| allocator.free(value);
            if (rule.tag) |value| allocator.free(value);
            if (rule.placement.output) |value| allocator.free(value);
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
    errdefer if (result.title) |value| allocator.free(value);
    result.tag = if (source.tag) |value| try allocator.dupe(u8, value) else null;
    errdefer if (result.tag) |value| allocator.free(value);
    result.placement.output = if (source.placement.output) |value| try allocator.dupe(u8, value) else null;
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

fn hashOptionalInt(hash: *std.hash.Wyhash, value: ?i32) void {
    hash.update(&.{@intFromBool(value != null)});
    if (value) |v| hash.update(std.mem.asBytes(&v));
}

fn hashOptionalString(hash: *std.hash.Wyhash, value: ?[]const u8) void {
    if (value) |text| {
        hash.update(&.{1});
        hash.update(text);
    } else hash.update(&.{0});
}

fn hashOptionalEnum(hash: *std.hash.Wyhash, value: anytype) void {
    const encoded: u8 = if (value) |item| @as(u8, @intCast(@backingInt(item))) + 1 else 0;
    hash.update(std.mem.asBytes(&encoded));
}

fn hashOptionalContentType(hash: *std.hash.Wyhash, value: ?wp.ContentTypeV1.Type) void {
    const encoded: u8 = if (value) |item| @as(u8, @intCast(@backingInt(item))) + 1 else 0;
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
    try std.testing.expectEqual(@as(?Layout, null), engine.resolve(.{ .app_id = "game-one", .title = "Menu" }).?.layout);
    try std.testing.expectEqual(@as(u32, 2), engine.resolve(.{ .app_id = "game-one", .title = "Play" }).?.placement.workspace);
    try std.testing.expect(engine.resolve(.{ .app_id = "editor" }) == null);
}

test "content type rules match committed state and keep only visual effects" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    var source = [_]Rule{
        .{ .content_type = .game, .layout = .game_mode, .placement = .{ .output = "DP-2", .workspace = 4 }, .fullscreen = true, .blur = false, .buffer_scale_policy = .integer_ceil, .hdr_expand = true, .overlay_plane = .prefer, .keep_render = true },
        .{ .app_id = "player*", .placement = .{ .workspace = 2 } },
    };
    try engine.reload(&source);

    // No committed content type: the content-type rule is skipped entirely.
    try std.testing.expectEqual(@as(u32, 2), engine.resolve(.{ .app_id = "player-one" }).?.placement.workspace);

    // Matching content type: layout and placement edits are dropped, visuals survive.
    const game = engine.resolve(.{ .app_id = "player-one", .content_type = .game }).?;
    try std.testing.expect(game.layout == null);
    try std.testing.expect(game.placement.output == null);
    try std.testing.expectEqual(@as(u32, 0), game.placement.workspace);
    try std.testing.expect(!game.fullscreen);
    try std.testing.expect(!game.ignore_struts);
    try std.testing.expectEqual(@as(?bool, false), game.blur);
    try std.testing.expectEqual(scaling.BufferScalePolicy.integer_ceil, game.buffer_scale_policy.?);
    try std.testing.expectEqual(@as(?bool, true), game.hdr_expand);
    try std.testing.expectEqual(OverlayPreference.prefer, game.overlay_plane);
    try std.testing.expect(game.keep_render);

    // A different committed type does not match.
    try std.testing.expectEqual(@as(u32, 2), engine.resolve(.{ .app_id = "player-one", .content_type = .video }).?.placement.workspace);
}

test "scrolling presets affect semantic identity but not placement or visual-only rules" {
    const unset: Rule = .{ .app_id = "browser" };
    var enabled = unset;
    enabled.scrolling_full_width = true;
    enabled.scrolling_width = 0.65;
    var disabled = unset;
    disabled.scrolling_full_width = false;
    try std.testing.expect(unset.fingerprint() != enabled.fingerprint());
    try std.testing.expect(unset.fingerprint() != disabled.fingerprint());
    try std.testing.expect(enabled.fingerprint() != disabled.fingerprint());
    try std.testing.expectEqual(unset.matcherFingerprint(), enabled.matcherFingerprint());
    try std.testing.expectEqual(unset.floatingFingerprint(), enabled.floatingFingerprint());
    try std.testing.expectEqual(unset.placementFingerprint(), enabled.placementFingerprint());

    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    enabled.content_type = .video;
    enabled.opacity = 0.8;
    try engine.reload(&.{enabled});
    const visual = engine.resolve(.{ .app_id = "browser", .content_type = .video }).?;
    try std.testing.expectEqual(@as(?bool, null), visual.scrolling_full_width);
    try std.testing.expectEqual(@as(?f64, null), visual.scrolling_width);
    try std.testing.expectEqual(@as(?Layout, null), visual.layout);
    try std.testing.expectEqual(@as(?f64, 0.8), visual.opacity);
}

test "matcher fingerprints include the content type matcher" {
    const plain: Rule = .{ .app_id = "term*" };
    const with_content: Rule = .{ .app_id = "term*", .content_type = .game };
    try std.testing.expect(plain.matcherFingerprint() != with_content.matcherFingerprint());
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
    const scale_edit: Rule = .{ .app_id = "term*", .placement = .{ .floating = true }, .buffer_scale_policy = .integer_ceil };
    try std.testing.expect(first.fingerprint() != scale_edit.fingerprint());
}

test "placement fingerprints cover output and workspace without changing the matcher" {
    const none: Rule = .{ .app_id = "term*" };
    const first: Rule = .{ .app_id = "term*", .placement = .{ .output = "DP-1", .workspace = 2 } };
    const same: Rule = .{ .app_id = "term*", .placement = .{ .output = "DP-1", .workspace = 2 } };
    const other_output: Rule = .{ .app_id = "term*", .placement = .{ .output = "DP-2", .workspace = 2 } };
    const other_workspace: Rule = .{ .app_id = "term*", .placement = .{ .output = "DP-1", .workspace = 3 } };

    try std.testing.expectEqual(@as(u64, 0), none.placementFingerprint());
    try std.testing.expectEqual(first.matcherFingerprint(), other_output.matcherFingerprint());
    try std.testing.expectEqual(first.placementFingerprint(), same.placementFingerprint());
    try std.testing.expect(first.placementFingerprint() != other_output.placementFingerprint());
    try std.testing.expect(first.placementFingerprint() != other_workspace.placementFingerprint());
}

test "matching timing restricts once and startup rules to eligible windows" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.reload(&.{
        .{ .app_id = "term*", .placement = .{ .workspace = 5 }, .matching = .once },
        .{ .app_id = "term*", .placement = .{ .workspace = 7 } },
    });

    // The first eligible window resolves the once rule and claims its budget.
    const first = engine.resolve(.{ .app_id = "term-one" }).?;
    try std.testing.expectEqual(@as(u32, 5), first.placement.workspace);
    engine.claimMatching(first);

    // Later windows fall through to the broader rule.
    try std.testing.expectEqual(@as(u32, 7), engine.resolve(.{ .app_id = "term-two" }).?.placement.workspace);

    // The owning window keeps the rule even though the budget is spent.
    try std.testing.expectEqual(
        @as(u32, 5),
        engine.resolve(.{ .app_id = "term-one", .current_match = first.matcherFingerprint() }).?.placement.workspace,
    );

    // Consumption survives reloads which keep the matcher and resets when it
    // is edited into a different matcher.
    try engine.reload(&.{
        .{ .app_id = "term*", .placement = .{ .workspace = 5 }, .matching = .once },
        .{ .app_id = "term*", .placement = .{ .workspace = 7 } },
    });
    try std.testing.expectEqual(@as(u32, 7), engine.resolve(.{ .app_id = "term-three" }).?.placement.workspace);
    try engine.reload(&.{.{ .app_id = "termx*", .placement = .{ .workspace = 5 }, .matching = .once }});
    try std.testing.expectEqual(@as(u32, 5), engine.resolve(.{ .app_id = "termx-one" }).?.placement.workspace);
}

test "claimed timing rules survive identity changes and earlier rules until removed" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    inline for (.{ Matching.once, Matching.startup }) |timing| {
        const bound: Rule = .{ .app_id = "editor", .title = "Loading", .matching = timing, .opacity = 0.6 };
        try engine.reload(&.{ .{ .title = "Ready", .opacity = 0.9 }, bound });
        const first = engine.resolve(.{ .app_id = "editor", .title = "Loading" }).?;
        engine.claimMatching(first);
        const identity: Identity = .{ .app_id = "editor", .title = "Ready", .current_match = first.matcherFingerprint(), .startup_phase = false };
        try std.testing.expectEqual(@as(?f64, 0.6), engine.resolve(identity).?.opacity);
        var edited = bound;
        edited.opacity = 0.7;
        try engine.reload(&.{ .{ .title = "Ready", .opacity = 0.9 }, edited });
        try std.testing.expectEqual(@as(?f64, 0.7), engine.resolve(identity).?.opacity);
        try engine.reload(&.{.{ .title = "Ready", .opacity = 0.9 }});
        try std.testing.expectEqual(@as(?f64, 0.9), engine.resolve(identity).?.opacity);
    }
}

test "startup rules stop matching after the startup phase ends" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.reload(&.{
        .{ .app_id = "firefox", .placement = .{ .workspace = 9 }, .matching = .startup },
        .{ .app_id = "firefox", .placement = .{ .workspace = 1 } },
    });

    // Windows admitted during startup use the startup rule; later windows do
    // not, unless they already own the matcher.
    const startup = engine.resolve(.{ .app_id = "firefox" }).?;
    try std.testing.expectEqual(@as(u32, 9), startup.placement.workspace);
    const owned = startup.matcherFingerprint();
    const later = engine.resolve(.{ .app_id = "firefox", .startup_phase = false }).?;
    try std.testing.expectEqual(@as(u32, 1), later.placement.workspace);
    try std.testing.expectEqual(
        @as(u32, 9),
        engine.resolve(.{ .app_id = "firefox", .startup_phase = false, .current_match = owned }).?.placement.workspace,
    );
}

test "matching timing changes rule and matcher identity but not floating placement" {
    const always: Rule = .{ .app_id = "term*", .placement = .{ .floating = true } };
    var once = always;
    once.matching = .once;
    var startup = always;
    startup.matching = .startup;
    try std.testing.expect(always.fingerprint() != once.fingerprint());
    try std.testing.expect(always.matcherFingerprint() != once.matcherFingerprint());
    try std.testing.expect(once.matcherFingerprint() != startup.matcherFingerprint());
    try std.testing.expectEqual(always.floatingFingerprint(), once.floatingFingerprint());

    for ([_][]const u8{ "once", "match-once", "match_once" }) |spelling| {
        try std.testing.expectEqual(Matching.once, Matching.parse(spelling).?);
    }
    for ([_][]const u8{ "startup", "at-startup", "at_startup" }) |spelling| {
        try std.testing.expectEqual(Matching.startup, Matching.parse(spelling).?);
    }
    try std.testing.expectEqual(Matching.always, Matching.parse("always").?);
    try std.testing.expect(Matching.parse("sometimes") == null);
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

test "keep_render is a semantic effect outside matcher and placement identity" {
    const plain: Rule = .{ .app_id = "steam_app_*", .placement = .{ .output = "DP-1", .workspace = 2 } };
    var kept = plain;
    kept.keep_render = true;
    try std.testing.expect(!plain.keep_render);
    try std.testing.expect(plain.fingerprint() != kept.fingerprint());
    try std.testing.expectEqual(plain.matcherFingerprint(), kept.matcherFingerprint());
    try std.testing.expectEqual(plain.placementFingerprint(), kept.placementFingerprint());
    try std.testing.expectEqual(plain.floatingFingerprint(), kept.floatingFingerprint());
}

test "tag identity composes matchers, owns strings and preserves visual-only policy" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.reload(&.{
        .{ .app_id = "editor", .tag = "settings", .placement = .{ .floating = true } },
        .{ .tag = "game*", .content_type = .game, .placement = .{ .workspace = 4 }, .skip_taskbar = true, .blur = false },
        .{ .tag = "*", .skip_switcher = true },
    });
    try std.testing.expect(engine.resolve(.{ .app_id = "editor" }) == null);
    try std.testing.expect(engine.resolve(.{ .app_id = "editor", .tag = "settings" }).?.placement.floating);
    try std.testing.expect(engine.resolve(.{ .app_id = "other", .tag = "settings" }).?.skip_switcher);
    const visual = engine.resolve(.{ .tag = "game window", .content_type = .game }).?;
    try std.testing.expectEqual(@as(u32, 0), visual.placement.workspace);
    try std.testing.expect(!visual.skip_taskbar);
    try std.testing.expectEqual(@as(?bool, false), visual.blur);
    const original = engine.rules[0];
    var changed = original;
    changed.tag = "other";
    try std.testing.expect(original.fingerprint() != changed.fingerprint());
    try std.testing.expect(original.matcherFingerprint() != changed.matcherFingerprint());
    try std.testing.expectEqual(original.floatingFingerprint(), changed.floatingFingerprint());
}

test "fraction edits change semantics without changing matcher or placement" {
    const unset: Rule = .{ .app_id = "browser" };
    var rule = unset;
    rule.scrolling_width = 0.65;
    try std.testing.expect(unset.fingerprint() != rule.fingerprint());
    try std.testing.expectEqual(unset.matcherFingerprint(), rule.matcherFingerprint());
    try std.testing.expectEqual(unset.floatingFingerprint(), rule.floatingFingerprint());
    try std.testing.expectEqual(unset.placementFingerprint(), rule.placementFingerprint());
    const old = rule.fingerprint();
    rule.scrolling_width = 0.25;
    try std.testing.expect(old != rule.fingerprint());
}

test "unmanaged rules are explicit, first-match and match any advertised X11 type" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.reload(&.{
        .{ .class = "Steam*", .opacity = 0.2 },
        .{ .scope = .override_redirect, .class = "Steam*", .window_type = .notification, .opacity = 0.7 },
        .{ .scope = .override_redirect, .class = "Steam*", .opacity = 0.9 },
    });
    try std.testing.expectEqual(@as(?f64, 0.2), engine.resolve(.{ .class = "Steam" }).?.opacity);
    try std.testing.expectEqual(@as(?f64, 0.7), engine.resolve(.{ .scope = .override_redirect, .class = "Steam", .window_types = (1 << 10) | (1 << 13) }).?.opacity);
    try std.testing.expectEqual(@as(?f64, 0.9), engine.resolve(.{ .scope = .override_redirect, .class = "Steam", .window_types = 1 << 8 }).?.opacity);
    const base: Rule = .{ .class = "Steam" };
    var popup = base;
    popup.scope = .override_redirect;
    try std.testing.expect(base.matcherFingerprint() != popup.matcherFingerprint());
    const before = popup.fingerprint();
    popup.position_x = 0;
    try std.testing.expect(before != popup.fingerprint());
}

test "built-in picker fallback floats centered unless a user rule replaces it" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    // No user rules: the picker still floats and centers, and the fallback is
    // not part of the enumerable ruleset.
    try engine.reload(&.{});
    try std.testing.expectEqual(@as(usize, 0), engine.rules.len);
    const picker = engine.resolve(.{
        .app_id = "org.aqueous.PortalPicker",
        .title = "Select a source to share",
    }).?;
    try std.testing.expect(picker.placement.floating);
    try std.testing.expectEqual(PlacementPolicy.center, picker.placement_policy.?);
    // Every instance channel matches; unrelated windows never do.
    try std.testing.expect(engine.resolve(.{ .app_id = "org.aqueous.Git.PortalPicker" }).?.placement.floating);
    try std.testing.expect(engine.resolve(.{ .app_id = "org.aqueous.IntelGit.PortalPicker" }).?.placement.floating);
    try std.testing.expect(engine.resolve(.{ .app_id = "org.aqueous.Editor", .title = "Select a source to share" }) == null);

    // A user rule keyed on the app id fully replaces the fallback.
    try engine.reload(&.{.{ .app_id = "org.aqueous.PortalPicker", .placement = .{ .workspace = 2 } }});
    const custom = engine.resolve(.{ .app_id = "org.aqueous.PortalPicker" }).?;
    try std.testing.expect(!custom.placement.floating);
    try std.testing.expectEqual(@as(u32, 2), custom.placement.workspace);
    try std.testing.expectEqual(@as(?PlacementPolicy, null), custom.placement_policy);

    // A rule keyed on the title also replaces it, covering every channel.
    try engine.reload(&.{.{ .title = "Select a source to share", .placement = .{ .floating = true, .workspace = 5 } }});
    try std.testing.expectEqual(
        @as(u32, 5),
        engine.resolve(.{ .app_id = "org.aqueous.IntelGit.PortalPicker", .title = "Select a source to share" }).?.placement.workspace,
    );
}
