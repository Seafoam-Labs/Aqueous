// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("../layout/types.zig");

pub const LayoutId = enum {
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

pub const layout_count = std.meta.fields(LayoutId).len;
pub const max_composable_regions = 4;

/// Normalized coordinate in the strut-adjusted usable output area.
pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const CompositeRegion = struct {
    layout: LayoutId = .tile,
    layout_set: bool = false,
    /// Clockwise top-left, top-right, bottom-right, and bottom-left corners.
    points: [4]Point = .{ .{}, .{}, .{}, .{} },
    point_set: [4]bool = .{ false, false, false, false },

    pub fn configured(region: *const CompositeRegion) bool {
        if (region.layout_set) return true;
        for (region.point_set) |set| if (set) return true;
        return false;
    }

    pub fn valid(region: *const CompositeRegion) bool {
        if (!region.layout_set or region.layout == .composable or region.layout == .game_mode) return false;
        for (region.point_set) |set| if (!set) return false;
        const p1 = region.points[0];
        const p2 = region.points[1];
        const p3 = region.points[2];
        const p4 = region.points[3];
        for (region.points) |point| {
            if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return false;
            if (point.x < 0 or point.x > 1 or point.y < 0 or point.y > 1) return false;
        }
        return p1.x < p2.x and p1.y < p4.y and
            approximatelyEqual(p1.y, p2.y) and approximatelyEqual(p2.x, p3.x) and
            approximatelyEqual(p3.y, p4.y) and approximatelyEqual(p4.x, p1.x);
    }
};

pub const Snapshot = struct {
    default: LayoutId = .tile,
    slots: [4]LayoutId = .{ .tile, .floating, .monocle, .grid },
    options: [layout_count]types.Options = [_]types.Options{.{ .border = .{
        .width = 2,
        .focused = 0xFF88C0D0,
        .normal = 0xFF3B4252,
        .urgent = 0xFFBF616A,
    } }} ** layout_count,
    composable: [max_composable_regions]CompositeRegion = .{ .{}, .{}, .{}, .{} },
    scrolling_column_fraction: f64 = 0.5,
    scrolling_center_focused: bool = true,
    scrolling_follow_new: bool = true,
    scrolling_prefer_vertical_on_portrait: bool = false,
    scrolling_snap: bool = false,
    scrolling_overscroll: bool = true,
    scrolling_focus_follows_mouse_delay_ms: i32 = 0,
    dwindle_split_ratio: f64 = 0.5,
    dwindle_start_vertical: bool = true,
    reverse_dwindle_split_ratio: f64 = 0.5,
    reverse_dwindle_start_vertical: bool = true,
    monocle_hide_others: bool = true,
    monocle_show_borders: bool = false,

    pub fn layoutOptions(snapshot: *const Snapshot, id: LayoutId) types.Options {
        return snapshot.options[@intFromEnum(id)];
    }

    pub fn composableValid(snapshot: *const Snapshot) bool {
        var count: usize = 0;
        for (snapshot.composable, 0..) |region, index| {
            if (!region.configured()) continue;
            if (!region.valid()) return false;
            count += 1;
            for (snapshot.composable[0..index]) |prior| {
                if (prior.configured() and regionsOverlap(prior, region)) return false;
            }
        }
        return count > 0;
    }

    pub fn firstComposableRegion(snapshot: *const Snapshot) ?u8 {
        if (!snapshot.composableValid()) return null;
        for (snapshot.composable, 0..) |region, index| {
            if (region.configured()) return @intCast(index);
        }
        return null;
    }
};

const Section = union(enum) {
    none,
    layout,
    slots,
    options: LayoutId,
    composable: usize,
};

/// Apply a validated TOML overlay to a snapshot. Unknown sections and keys are
/// intentionally ignored so newer configuration files remain forwards-compatible.
pub fn apply(snapshot: *Snapshot, source: []const u8) void {
    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = raw_line[0 .. std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len];
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = parseSection(std.mem.trim(u8, line[1 .. line.len - 1], " \t"));
            continue;
        }
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        switch (section) {
            .none => {},
            .layout => applyLayout(snapshot, key, value),
            .slots => applySlot(snapshot, key, value),
            .options => |id| applyOptions(snapshot, id, key, value),
            .composable => |index| applyComposable(&snapshot.composable[index], key, value),
        }
    }
}

fn parseSection(name: []const u8) Section {
    if (std.mem.eql(u8, name, "layout")) return .layout;
    if (std.mem.eql(u8, name, "layout.slots")) return .slots;
    const composable_prefix = "layout.composable.";
    if (std.mem.startsWith(u8, name, composable_prefix)) {
        const slot = name[composable_prefix.len..];
        if (slot.len == 1 and slot[0] >= 'a' and slot[0] <= 'd') {
            return .{ .composable = slot[0] - 'a' };
        }
    }
    const prefix = "layout.options.";
    if (std.mem.startsWith(u8, name, prefix)) {
        if (parseLayoutId(name[prefix.len..])) |id| return .{ .options = id };
    }
    return .none;
}

fn applyComposable(region: *CompositeRegion, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "layout")) {
        const id = parseLayoutId(unquote(value)) orelse return;
        if (id == .composable or id == .game_mode) return;
        region.layout = id;
        region.layout_set = true;
        return;
    }
    if (key.len != 2 or key[0] != 'p' or key[1] < '1' or key[1] > '4') return;
    const point = parsePoint(value) orelse return;
    const index: usize = key[1] - '1';
    region.points[index] = point;
    region.point_set[index] = true;
}

fn applySlot(snapshot: *Snapshot, key: []const u8, value: []const u8) void {
    const id = parseLayoutId(unquote(value)) orelse return;
    if (std.mem.eql(u8, key, "primary")) snapshot.slots[0] = id;
    if (std.mem.eql(u8, key, "secondary")) snapshot.slots[1] = id;
    if (std.mem.eql(u8, key, "tertiary")) snapshot.slots[2] = id;
    if (std.mem.eql(u8, key, "quaternary")) snapshot.slots[3] = id;
}

fn applyLayout(snapshot: *Snapshot, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "default")) {
        if (parseLayoutId(unquote(value))) |id| snapshot.default = id;
        return;
    }
    for (&snapshot.options) |*options| applyCommon(options, key, value);
}

fn applyOptions(snapshot: *Snapshot, id: LayoutId, key: []const u8, value: []const u8) void {
    applyCommon(&snapshot.options[@intFromEnum(id)], key, value);
    const plain = unquote(value);
    switch (id) {
        .scrolling => {
            if (std.mem.eql(u8, key, "column_fraction")) snapshot.scrolling_column_fraction = parseRatio(plain) orelse snapshot.scrolling_column_fraction;
            if (std.mem.eql(u8, key, "center_focused")) snapshot.scrolling_center_focused = parseBool(plain) orelse snapshot.scrolling_center_focused;
            if (std.mem.eql(u8, key, "follow_new_windows")) snapshot.scrolling_follow_new = parseBool(plain) orelse snapshot.scrolling_follow_new;
            if (std.mem.eql(u8, key, "prefer_vertical_on_portrait")) snapshot.scrolling_prefer_vertical_on_portrait = parseBool(plain) orelse snapshot.scrolling_prefer_vertical_on_portrait;
            if (std.mem.eql(u8, key, "snap_to_columns")) snapshot.scrolling_snap = parseBool(plain) orelse snapshot.scrolling_snap;
            if (std.mem.eql(u8, key, "allow_overscroll")) snapshot.scrolling_overscroll = parseBool(plain) orelse snapshot.scrolling_overscroll;
            if (std.mem.eql(u8, key, "focus_follows_mouse_delay_ms")) snapshot.scrolling_focus_follows_mouse_delay_ms = parseNonNegative(plain) orelse snapshot.scrolling_focus_follows_mouse_delay_ms;
        },
        .dwindle => {
            if (std.mem.eql(u8, key, "split_ratio")) snapshot.dwindle_split_ratio = parseRatio(plain) orelse snapshot.dwindle_split_ratio;
            if (std.mem.eql(u8, key, "start_axis")) {
                if (std.mem.eql(u8, plain, "vertical")) snapshot.dwindle_start_vertical = true;
                if (std.mem.eql(u8, plain, "horizontal")) snapshot.dwindle_start_vertical = false;
            }
        },
        .reverse_dwindle => {
            if (std.mem.eql(u8, key, "split_ratio")) snapshot.reverse_dwindle_split_ratio = parseRatio(plain) orelse snapshot.reverse_dwindle_split_ratio;
            if (std.mem.eql(u8, key, "start_axis")) {
                if (std.mem.eql(u8, plain, "vertical")) snapshot.reverse_dwindle_start_vertical = true;
                if (std.mem.eql(u8, plain, "horizontal")) snapshot.reverse_dwindle_start_vertical = false;
            }
        },
        .monocle => {
            if (std.mem.eql(u8, key, "hide_others")) snapshot.monocle_hide_others = parseBool(plain) orelse snapshot.monocle_hide_others;
            if (std.mem.eql(u8, key, "show_borders")) snapshot.monocle_show_borders = parseBool(plain) orelse snapshot.monocle_show_borders;
        },
        else => {},
    }
}

fn applyCommon(options: *types.Options, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "gaps_outer")) options.gaps_outer = parseNonNegative(value) orelse options.gaps_outer;
    if (std.mem.eql(u8, key, "gaps_inner")) options.gaps_inner = parseNonNegative(value) orelse options.gaps_inner;
    if (std.mem.eql(u8, key, "master_count")) {
        const parsed = std.fmt.parseInt(u32, value, 10) catch return;
        if (parsed > 0) options.master_count = parsed;
    }
    if (std.mem.eql(u8, key, "master_ratio")) options.master_ratio = parseRatio(value) orelse options.master_ratio;
    if (std.mem.eql(u8, key, "border_width")) options.border.width = parseNonNegative(value) orelse options.border.width;
    if (std.mem.eql(u8, key, "border_focused")) options.border.focused = parseColor(value) orelse options.border.focused;
    if (std.mem.eql(u8, key, "border_normal")) options.border.normal = parseColor(value) orelse options.border.normal;
    if (std.mem.eql(u8, key, "border_urgent")) options.border.urgent = parseColor(value) orelse options.border.urgent;
}

fn parseLayoutId(value: []const u8) ?LayoutId {
    if (std.mem.eql(u8, value, "tile")) return .tile;
    if (std.mem.eql(u8, value, "monocle")) return .monocle;
    if (std.mem.eql(u8, value, "grid")) return .grid;
    if (std.mem.eql(u8, value, "rows")) return .rows;
    if (std.mem.eql(u8, value, "dwindle")) return .dwindle;
    if (std.mem.eql(u8, value, "reverse-dwindle") or std.mem.eql(u8, value, "reverse_dwindle")) return .reverse_dwindle;
    if (std.mem.eql(u8, value, "scrolling")) return .scrolling;
    if (std.mem.eql(u8, value, "float") or std.mem.eql(u8, value, "floating")) return .floating;
    if (std.mem.eql(u8, value, "game-mode") or std.mem.eql(u8, value, "game_mode")) return .game_mode;
    if (std.mem.eql(u8, value, "composable")) return .composable;
    return null;
}

fn parsePoint(value: []const u8) ?Point {
    const plain = std.mem.trim(u8, value, " \t");
    if (plain.len < 5 or plain[0] != '[' or plain[plain.len - 1] != ']') return null;
    const body = plain[1 .. plain.len - 1];
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return null;
    if (std.mem.indexOfScalar(u8, body[comma + 1 ..], ',') != null) return null;
    const x = std.fmt.parseFloat(f64, std.mem.trim(u8, body[0..comma], " \t")) catch return null;
    const y = std.fmt.parseFloat(f64, std.mem.trim(u8, body[comma + 1 ..], " \t")) catch return null;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or x > 1 or y < 0 or y > 1) return null;
    return .{ .x = x, .y = y };
}

fn approximatelyEqual(a: f64, b: f64) bool {
    return @abs(a - b) <= 0.000000001;
}

fn regionsOverlap(a: CompositeRegion, b: CompositeRegion) bool {
    if (!a.valid() or !b.valid()) return false;
    return a.points[0].x < b.points[2].x and a.points[2].x > b.points[0].x and
        a.points[0].y < b.points[2].y and a.points[2].y > b.points[0].y;
}

fn parseNonNegative(value: []const u8) ?i32 {
    const result = std.fmt.parseInt(i32, value, 10) catch return null;
    return if (result >= 0) result else null;
}

fn parseRatio(value: []const u8) ?f64 {
    const result = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(result) and result > 0 and result < 1) result else null;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn parseColor(value: []const u8) ?u32 {
    var plain = unquote(value);
    if (plain.len > 0 and (plain[plain.len - 1] == 'u' or plain[plain.len - 1] == 'U')) plain = plain[0 .. plain.len - 1];
    if (std.mem.startsWith(u8, plain, "0x") or std.mem.startsWith(u8, plain, "0X")) plain = plain[2..];
    return std.fmt.parseInt(u32, plain, 16) catch null;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        return value[1 .. value.len - 1];
    }
    return value;
}

test "layout config parses defaults, aliases, extras, and colors" {
    var snapshot: Snapshot = .{};
    apply(&snapshot,
        \\[layout]
        \\default = "game-mode"
        \\gaps_outer = 12
        \\master_ratio = 0.6
        \\border_normal = 0xFF112233u
        \\[layout.slots]
        \\secondary = "scrolling"
        \\[layout.options.scrolling]
        \\column_fraction = "0.4"
        \\center_focused = "false"
        \\focus_follows_mouse_delay_ms = 150
        \\[layout.options.dwindle]
        \\start_axis = "horizontal"
        \\[layout.options.reverse-dwindle]
        \\split_ratio = "0.3"
        \\start_axis = "horizontal"
    );
    try std.testing.expectEqual(LayoutId.game_mode, snapshot.default);
    try std.testing.expectEqual(@as(i32, 12), snapshot.layoutOptions(.tile).gaps_outer);
    try std.testing.expectEqual(@as(f64, 0.6), snapshot.layoutOptions(.grid).master_ratio);
    try std.testing.expectEqual(@as(u32, 0xFF112233), snapshot.layoutOptions(.tile).border.normal);
    try std.testing.expectEqual(LayoutId.scrolling, snapshot.slots[1]);
    try std.testing.expectEqual(@as(f64, 0.4), snapshot.scrolling_column_fraction);
    try std.testing.expect(!snapshot.scrolling_center_focused);
    try std.testing.expectEqual(@as(i32, 150), snapshot.scrolling_focus_follows_mouse_delay_ms);
    try std.testing.expect(!snapshot.dwindle_start_vertical);
    try std.testing.expectEqual(@as(f64, 0.3), snapshot.reverse_dwindle_split_ratio);
    try std.testing.expect(!snapshot.reverse_dwindle_start_vertical);
}

test "reverse dwindle accepts canonical and underscore layout ids" {
    var snapshot: Snapshot = .{};
    apply(&snapshot,
        \\[layout]
        \\default = "reverse-dwindle"
        \\[layout.slots]
        \\primary = "reverse_dwindle"
        \\[layout.composable.a]
        \\layout = "reverse-dwindle"
        \\p1 = [0.0, 0.0]
        \\p2 = [1.0, 0.0]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.0, 1.0]
    );
    try std.testing.expectEqual(LayoutId.reverse_dwindle, snapshot.default);
    try std.testing.expectEqual(LayoutId.reverse_dwindle, snapshot.slots[0]);
    try std.testing.expectEqual(LayoutId.reverse_dwindle, snapshot.composable[0].layout);
    try std.testing.expect(snapshot.composableValid());
}

test "scrolling focus delay rejects negative and malformed overlays" {
    var snapshot: Snapshot = .{};
    apply(&snapshot,
        \\[layout.options.scrolling]
        \\focus_follows_mouse_delay_ms = 175
    );
    apply(&snapshot,
        \\[layout.options.scrolling]
        \\focus_follows_mouse_delay_ms = -1
    );
    apply(&snapshot,
        \\[layout.options.scrolling]
        \\focus_follows_mouse_delay_ms = "soon"
    );
    try std.testing.expectEqual(@as(i32, 175), snapshot.scrolling_focus_follows_mouse_delay_ms);
}

test "scrolling portrait placement preference parses booleans and malformed values retain validated base" {
    var snapshot: Snapshot = .{};
    try std.testing.expect(!snapshot.scrolling_prefer_vertical_on_portrait);

    apply(&snapshot,
        \\[layout.options.scrolling]
        \\prefer_vertical_on_portrait = true
    );
    try std.testing.expect(snapshot.scrolling_prefer_vertical_on_portrait);

    // A plausible-looking non-boolean keeps the last validated value instead
    // of resetting the option.
    apply(&snapshot,
        \\[layout.options.scrolling]
        \\prefer_vertical_on_portrait = "portrait"
    );
    try std.testing.expect(snapshot.scrolling_prefer_vertical_on_portrait);

    apply(&snapshot,
        \\[layout.options.scrolling]
        \\prefer_vertical_on_portrait = false
    );
    try std.testing.expect(!snapshot.scrolling_prefer_vertical_on_portrait);
}

test "layout sidecar overlay wins and malformed values retain validated base" {
    var snapshot: Snapshot = .{};
    apply(&snapshot,
        \\[layout]
        \\default = "tile"
        \\gaps_inner = 7
        \\master_ratio = 0.65
    );
    apply(&snapshot,
        \\[layout]
        \\default = "grid"
        \\gaps_inner = -2
        \\master_ratio = 5.0
        \\[layout.options.grid]
        \\gaps_inner = 3
    );
    try std.testing.expectEqual(LayoutId.grid, snapshot.default);
    try std.testing.expectEqual(@as(i32, 7), snapshot.layoutOptions(.tile).gaps_inner);
    try std.testing.expectEqual(@as(f64, 0.65), snapshot.layoutOptions(.tile).master_ratio);
    try std.testing.expectEqual(@as(i32, 3), snapshot.layoutOptions(.grid).gaps_inner);
}

test "composable config accepts non-overlapping normalized rectangles" {
    var snapshot: Snapshot = .{};
    apply(&snapshot,
        \\[layout]
        \\default = "composable"
        \\[layout.composable.a]
        \\layout = "tile"
        \\p1 = [0.0, 0.0]
        \\p2 = [0.5, 0.0]
        \\p3 = [0.5, 1.0]
        \\p4 = [0.0, 1.0]
        \\[layout.composable.b]
        \\layout = "scrolling"
        \\p1 = [0.5, 0.0]
        \\p2 = [1.0, 0.0]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.5, 1.0]
    );

    try std.testing.expectEqual(LayoutId.composable, snapshot.default);
    try std.testing.expect(snapshot.composableValid());
    try std.testing.expectEqual(@as(?u8, 0), snapshot.firstComposableRegion());
    try std.testing.expectEqual(LayoutId.scrolling, snapshot.composable[1].layout);
    try std.testing.expectEqual(@as(f64, 0.5), snapshot.composable[1].points[0].x);
}

test "composable config rejects overlap incomplete slots and recursive children" {
    var overlapping: Snapshot = .{};
    apply(&overlapping,
        \\[layout.composable.a]
        \\layout = "tile"
        \\p1 = [0.0, 0.0]
        \\p2 = [0.75, 0.0]
        \\p3 = [0.75, 1.0]
        \\p4 = [0.0, 1.0]
        \\[layout.composable.b]
        \\layout = "rows"
        \\p1 = [0.5, 0.0]
        \\p2 = [1.0, 0.0]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.5, 1.0]
    );
    try std.testing.expect(!overlapping.composableValid());

    var incomplete: Snapshot = .{};
    apply(&incomplete,
        \\[layout.composable.a]
        \\layout = "tile"
        \\p1 = [0.0, 0.0]
    );
    try std.testing.expect(!incomplete.composableValid());

    var recursive: Snapshot = .{};
    apply(&recursive,
        \\[layout.composable.a]
        \\layout = "composable"
        \\p1 = [0.0, 0.0]
        \\p2 = [1.0, 0.0]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.0, 1.0]
    );
    try std.testing.expect(!recursive.composableValid());
}

test "composable sidecar can complete a base slot one field at a time" {
    var snapshot: Snapshot = .{};
    apply(&snapshot,
        \\[layout.composable.a]
        \\layout = "rows"
        \\p1 = [0.0, 0.0]
        \\p2 = [1.0, 0.0]
    );
    apply(&snapshot,
        \\[layout.composable.a]
        \\p3 = [1.0, 1.0]
        \\p4 = [0.0, 1.0]
    );
    try std.testing.expect(snapshot.composableValid());
    try std.testing.expectEqual(LayoutId.rows, snapshot.composable[0].layout);
}
