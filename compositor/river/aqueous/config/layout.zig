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
    scrolling,
    floating,
    game_mode,
};

pub const Snapshot = struct {
    default: LayoutId = .tile,
    options: [8]types.Options = [_]types.Options{.{}} ** 8,
    scrolling_column_fraction: f64 = 0.5,
    scrolling_center_focused: bool = true,
    scrolling_follow_new: bool = true,
    scrolling_snap: bool = false,
    scrolling_overscroll: bool = true,
    dwindle_split_ratio: f64 = 0.5,
    dwindle_start_vertical: bool = true,
    monocle_hide_others: bool = true,
    monocle_show_borders: bool = false,

    pub fn layoutOptions(snapshot: *const Snapshot, id: LayoutId) types.Options {
        return snapshot.options[@intFromEnum(id)];
    }
};

const Section = union(enum) {
    none,
    layout,
    options: LayoutId,
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
            .options => |id| applyOptions(snapshot, id, key, value),
        }
    }
}

fn parseSection(name: []const u8) Section {
    if (std.mem.eql(u8, name, "layout")) return .layout;
    const prefix = "layout.options.";
    if (std.mem.startsWith(u8, name, prefix)) {
        if (parseLayoutId(name[prefix.len..])) |id| return .{ .options = id };
    }
    return .none;
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
            if (std.mem.eql(u8, key, "snap_to_columns")) snapshot.scrolling_snap = parseBool(plain) orelse snapshot.scrolling_snap;
            if (std.mem.eql(u8, key, "allow_overscroll")) snapshot.scrolling_overscroll = parseBool(plain) orelse snapshot.scrolling_overscroll;
        },
        .dwindle => {
            if (std.mem.eql(u8, key, "split_ratio")) snapshot.dwindle_split_ratio = parseRatio(plain) orelse snapshot.dwindle_split_ratio;
            if (std.mem.eql(u8, key, "start_axis")) {
                if (std.mem.eql(u8, plain, "vertical")) snapshot.dwindle_start_vertical = true;
                if (std.mem.eql(u8, plain, "horizontal")) snapshot.dwindle_start_vertical = false;
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
    if (std.mem.eql(u8, value, "scrolling")) return .scrolling;
    if (std.mem.eql(u8, value, "float") or std.mem.eql(u8, value, "floating")) return .floating;
    if (std.mem.eql(u8, value, "game-mode") or std.mem.eql(u8, value, "game_mode")) return .game_mode;
    return null;
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
        \\[layout.options.scrolling]
        \\column_fraction = "0.4"
        \\center_focused = "false"
        \\[layout.options.dwindle]
        \\start_axis = "horizontal"
    );
    try std.testing.expectEqual(LayoutId.game_mode, snapshot.default);
    try std.testing.expectEqual(@as(i32, 12), snapshot.layoutOptions(.tile).gaps_outer);
    try std.testing.expectEqual(@as(f64, 0.6), snapshot.layoutOptions(.grid).master_ratio);
    try std.testing.expectEqual(@as(u32, 0xFF112233), snapshot.layoutOptions(.tile).border.normal);
    try std.testing.expectEqual(@as(f64, 0.4), snapshot.scrolling_column_fraction);
    try std.testing.expect(!snapshot.scrolling_center_focused);
    try std.testing.expect(!snapshot.dwindle_start_vertical);
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