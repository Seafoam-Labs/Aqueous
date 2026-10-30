// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Owned layout snapshots for speculative workspace admission. A rejected
//! admission must not change ordering, focused split trees, or scroll offsets.
const std = @import("std");
const engine = @import("engine.zig");
const leaf = @import("leaf.zig");
const game = @import("game_mode.zig");
const scrolling = @import("scrolling.zig");

pub fn layout(a: std.mem.Allocator, source: *const engine.State) !engine.State {
    var result: engine.State = .{ .active_layout = source.active_layout };
    errdefer result.deinit(a);
    result.standalone = try cloneLeaf(a, &source.standalone);
    const composite = &source.composite;
    result.composite.enabled = composite.enabled;
    result.composite.layouts = composite.layouts;
    result.composite.active = composite.active;
    result.composite.last_focused = composite.last_focused;
    result.composite.first_member = composite.first_member;
    result.composite.membership = try composite.membership.clone(a);
    for (&result.composite.children, &composite.children) |*child, *original| child.* = try cloneLeaf(a, original);
    return result;
}

fn cloneLeaf(a: std.mem.Allocator, source: *const leaf.State) !leaf.State {
    var result: leaf.State = .{ .active_layout = source.active_layout };
    errdefer result.deinit(a);
    try copyLayouts(a, &result, source);
    result.game_mode = try cloneGame(a, &source.game_mode);
    return result;
}

fn cloneGame(a: std.mem.Allocator, source: *const game.State) !game.State {
    var result: game.State = .{
        .rule_layout_owned = source.rule_layout_owned,
        .anchor = source.anchor,
        .rule_anchor = source.rule_anchor,
        .rule_options = source.rule_options,
        .active_remainder = source.active_remainder,
    };
    errdefer result.deinit(a);
    inline for (.{ "fallback", "left", "right" }) |field| try copyLayouts(a, &@field(result, field), &@field(source, field));
    return result;
}

fn copyLayouts(a: std.mem.Allocator, result: anytype, source: anytype) !void {
    inline for (.{ "tile", "grid", "rows", "monocle" }) |field| {
        @field(result, field) = @field(source, field);
        @field(result, field).order = .{};
        if (comptime std.mem.eql(u8, field, "tile")) result.tile.height_overrides = .empty;
        try @field(result, field).order.items.appendSlice(a, @field(source, field).order.items.items);
    }
    result.tile.height_overrides = try source.tile.height_overrides.clone(a);
    result.dwindle = try source.dwindle.clone(a);
    result.reverse_dwindle = try source.reverse_dwindle.clone(a);
    result.floating.next_cascade = source.floating.next_cascade;
    result.floating.rects = try source.floating.rects.clone(a);
    result.scrolling = try cloneScrolling(a, &source.scrolling);
}

fn cloneScrolling(a: std.mem.Allocator, source: *const scrolling.State) !scrolling.State {
    var result = source.*;
    result.columns = .empty;
    result.height_overrides = .empty;
    errdefer result.deinit(a);
    result.height_overrides = try source.height_overrides.clone(a);
    try result.columns.ensureTotalCapacity(a, source.columns.items.len);
    for (source.columns.items) |column| {
        var copy = column;
        copy.windows = .empty;
        try copy.windows.appendSlice(a, column.windows.items);
        result.columns.appendAssumeCapacity(copy);
    }
    return result;
}
