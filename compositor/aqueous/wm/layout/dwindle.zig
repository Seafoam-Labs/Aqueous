// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const math = @import("math.zig");
const order = @import("order.zig");
const types = @import("types.zig");

pub const State = struct {
    order: order.State = .{},
    /// Split tree used by `split_focused`. Ordinary dwindle derives its
    /// geometry from `order` alone and leaves this empty.
    root: ?*Node = null,
    /// Most recent focus that was already part of the tree. A window that
    /// takes focus as it opens is not in the tree yet, so new windows split
    /// this one instead.
    last_focused: ?types.Handle = null,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.order.deinit(allocator);
        if (state.root) |root| destroyTree(allocator, root);
        state.root = null;
    }
};

pub const Options = struct {
    start_vertical: bool = true,
    split_ratio: f64 = 0.5,
    reverse: bool = false,
    /// Insert each new window by splitting the window that had focus, instead
    /// of always splitting the last window in the order.
    split_focused: bool = false,
    focused: ?types.Handle = null,
};

/// A leaf holds one window; a branch divides its rectangle between two
/// children. `first` is the window that was split and keeps `split_ratio` of
/// the space, `second` is the window that arrived later.
const Node = struct {
    parent: ?*Node = null,
    kind: union(enum) {
        leaf: types.Handle,
        branch: struct { vertical: bool, first: *Node, second: *Node },
    },
};

pub fn arrange(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, options: types.Options, dwindle_options: Options) ![]types.Placement {
    if (dwindle_options.split_focused) return arrangeTree(allocator, state, usable_area, windows, options, dwindle_options);
    if (state.root) |root| destroyTree(allocator, root);
    state.root = null;
    try state.order.sync(allocator, windows);
    const handles = state.order.items.items;
    const result = try allocator.alloc(types.Placement, handles.len);
    var area = math.shrink(usable_area, options.gaps_outer);
    var vertical = dwindle_options.start_vertical;
    for (result, handles, 0..) |*placement, handle, index| {
        if (index == handles.len - 1) {
            placement.* = makePlacement(handle, area, options.border);
            break;
        }
        const pair = split(area, vertical, if (index == 0) options.master_ratio else dwindle_options.split_ratio, options.gaps_inner, dwindle_options.reverse);
        placement.* = makePlacement(handle, pair.primary, options.border);
        area = pair.remainder;
        vertical = !vertical;
    }
    return result;
}

const Split = struct { primary: types.Rect, remainder: types.Rect };

fn split(area: types.Rect, vertical: bool, ratio: f64, gap: i32, reverse: bool) Split {
    if (vertical) {
        const available = @max(1, area.width - gap);
        const primary_width = @min(available, @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(available)) * ratio)))));
        const remainder_width = @max(1, available - primary_width);
        const ordinary: Split = .{
            .primary = .{ .x = area.x, .y = area.y, .width = primary_width, .height = area.height },
            .remainder = .{ .x = area.x + primary_width + gap, .y = area.y, .width = remainder_width, .height = area.height },
        };
        if (!reverse) return ordinary;
        return .{
            .primary = mirrorHorizontally(area, ordinary.primary),
            .remainder = mirrorHorizontally(area, ordinary.remainder),
        };
    }
    const available = @max(1, area.height - gap);
    const primary_height = @min(available, @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(available)) * ratio)))));
    return .{
        .primary = .{ .x = area.x, .y = area.y, .width = area.width, .height = primary_height },
        .remainder = .{ .x = area.x, .y = area.y + primary_height + gap, .width = area.width, .height = @max(1, available - primary_height) },
    };
}

fn mirrorHorizontally(area: types.Rect, rect: types.Rect) types.Rect {
    var mirrored = rect;
    mirrored.x = area.x + area.width - (rect.x - area.x) - rect.width;
    return mirrored;
}

fn makePlacement(handle: types.Handle, geometry: types.Rect, border: types.Border) types.Placement {
    return .{ .handle = handle, .geometry = geometry, .z_order = 0, .visible = true, .border = border };
}

/// Swap two windows in both the order and the split tree, so a keyboard or
/// pointer reorder exchanges their positions without reshaping the tree.
pub fn swap(state: *State, a: types.Handle, b: types.Handle) bool {
    const changed = state.order.swap(a, b);
    const root = state.root orelse return changed;
    const leaf_a = findLeaf(root, a) orelse return changed;
    const leaf_b = findLeaf(root, b) orelse return changed;
    leaf_a.kind = .{ .leaf = b };
    leaf_b.kind = .{ .leaf = a };
    return true;
}

fn arrangeTree(allocator: std.mem.Allocator, state: *State, usable_area: types.Rect, windows: []const types.Window, options: types.Options, dwindle_options: Options) ![]types.Placement {
    const area = math.shrink(usable_area, options.gaps_outer);

    // Drop windows that left this layout; each sibling takes over the space.
    while (state.root) |root| {
        const stale = findStale(root, windows) orelse break;
        removeLeaf(allocator, state, stale);
    }

    if (state.root) |root| {
        for ([_]?types.Handle{ dwindle_options.focused, options.new_window_anchor }) |candidate| {
            const handle = candidate orelse continue;
            if (findLeaf(root, handle) != null) state.last_focused = handle;
        }
    }

    // A fresh tree (for example after switching layouts) is built as a
    // spiral in window order. Otherwise the first new window splits the
    // window that last had focus, and any others arriving in the same cycle
    // split the window inserted just before them.
    var anchor: ?types.Handle = if (state.root == null) null else state.last_focused;
    for (windows) |window| {
        if (state.root != null and findLeaf(state.root.?, window.handle) != null) continue;
        try insert(allocator, state, window.handle, anchor, area, options.gaps_inner, dwindle_options);
        anchor = window.handle;
    }

    var placements: std.ArrayListUnmanaged(types.Placement) = .empty;
    errdefer placements.deinit(allocator);
    try placements.ensureTotalCapacity(allocator, windows.len);
    if (state.root) |root| place(root, area, options, dwindle_options, &placements);

    // Keep the published order in tree order so order-based queries and
    // swaps agree with what is on screen.
    state.order.items.clearRetainingCapacity();
    try state.order.items.ensureTotalCapacity(allocator, placements.items.len);
    for (placements.items) |placement| state.order.items.appendAssumeCapacity(placement.handle);
    return placements.toOwnedSlice(allocator);
}

fn insert(allocator: std.mem.Allocator, state: *State, handle: types.Handle, anchor: ?types.Handle, area: types.Rect, gap: i32, dwindle_options: Options) !void {
    const leaf = try allocator.create(Node);
    errdefer allocator.destroy(leaf);
    leaf.* = .{ .kind = .{ .leaf = handle } };
    const root = state.root orelse {
        state.root = leaf;
        return;
    };
    const target = (if (anchor) |value| findLeaf(root, value) else null) orelse lastLeaf(root);
    const rect = rectOf(root, target, area, gap, dwindle_options) orelse area;
    // Split along the longer side so both halves stay as square as possible.
    const vertical = if (rect.width != rect.height) rect.width > rect.height else dwindle_options.start_vertical;
    const branch = try allocator.create(Node);
    branch.* = .{ .parent = target.parent, .kind = .{ .branch = .{ .vertical = vertical, .first = target, .second = leaf } } };
    replaceChild(state, target.parent, target, branch);
    target.parent = branch;
    leaf.parent = branch;
}

fn removeLeaf(allocator: std.mem.Allocator, state: *State, leaf: *Node) void {
    const parent = leaf.parent orelse {
        state.root = null;
        allocator.destroy(leaf);
        return;
    };
    const branch = parent.kind.branch;
    const sibling = if (branch.first == leaf) branch.second else branch.first;
    sibling.parent = parent.parent;
    replaceChild(state, parent.parent, parent, sibling);
    allocator.destroy(leaf);
    allocator.destroy(parent);
}

fn replaceChild(state: *State, parent: ?*Node, old: *Node, new: *Node) void {
    const owner = parent orelse {
        state.root = new;
        return;
    };
    const branch = &owner.kind.branch;
    if (branch.first == old) branch.first = new else branch.second = new;
}

fn place(node: *Node, area: types.Rect, options: types.Options, dwindle_options: Options, out: *std.ArrayListUnmanaged(types.Placement)) void {
    switch (node.kind) {
        .leaf => |handle| out.appendAssumeCapacity(makePlacement(handle, area, options.border)),
        .branch => |branch| {
            const pair = split(area, branch.vertical, dwindle_options.split_ratio, options.gaps_inner, dwindle_options.reverse);
            place(branch.first, pair.primary, options, dwindle_options, out);
            place(branch.second, pair.remainder, options, dwindle_options, out);
        },
    }
}

fn rectOf(node: *Node, target: *Node, area: types.Rect, gap: i32, dwindle_options: Options) ?types.Rect {
    if (node == target) return area;
    return switch (node.kind) {
        .leaf => null,
        .branch => |branch| blk: {
            const pair = split(area, branch.vertical, dwindle_options.split_ratio, gap, dwindle_options.reverse);
            break :blk rectOf(branch.first, target, pair.primary, gap, dwindle_options) orelse
                rectOf(branch.second, target, pair.remainder, gap, dwindle_options);
        },
    };
}

fn findLeaf(node: *Node, handle: types.Handle) ?*Node {
    return switch (node.kind) {
        .leaf => |value| if (value == handle) node else null,
        .branch => |branch| findLeaf(branch.first, handle) orelse findLeaf(branch.second, handle),
    };
}

fn findStale(node: *Node, windows: []const types.Window) ?*Node {
    return switch (node.kind) {
        .leaf => |handle| for (windows) |window| {
            if (window.handle == handle) break null;
        } else node,
        .branch => |branch| findStale(branch.first, windows) orelse findStale(branch.second, windows),
    };
}

fn lastLeaf(node: *Node) *Node {
    var current = node;
    while (true) switch (current.kind) {
        .leaf => return current,
        .branch => |branch| current = branch.second,
    };
}

fn destroyTree(allocator: std.mem.Allocator, node: *Node) void {
    switch (node.kind) {
        .leaf => {},
        .branch => |branch| {
            destroyTree(allocator, branch.first);
            destroyTree(allocator, branch.second);
        },
    }
    allocator.destroy(node);
}

test "dwindle alternates split axes" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const placements = try arrange(std.testing.allocator, &state, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, &.{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 },
    }, .{ .gaps_outer = 0, .gaps_inner = 4, .master_ratio = 0.5 }, .{});
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .width = 48, .height = 80 }, placements[0].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 52, .y = 0, .width = 48, .height = 38 }, placements[1].geometry);
    try std.testing.expectEqual(types.Rect{ .x = 52, .y = 42, .width = 48, .height = 38 }, placements[2].geometry);
}

fn expectGeometry(placements: []const types.Placement, handle: types.Handle, expected: types.Rect) !void {
    for (placements) |placement| if (placement.handle == handle) return std.testing.expectEqual(expected, placement.geometry);
    return error.TestExpectedEqual;
}

test "split focused inserts new windows beside the focused window" {
    const a = std.testing.allocator;
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4 };
    const w = [_]types.Window{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 } };

    inline for (.{ @as(types.Handle, 1), @as(types.Handle, 2) }) |focused| {
        var state: State = .{};
        defer state.deinit(a);
        const split_options: Options = .{ .split_focused = true, .focused = focused };
        a.free(try arrange(a, &state, area, w[0..2], options, split_options));
        var anchored = options;
        anchored.new_window_anchor = focused;
        const result = try arrange(a, &state, area, w[0..3], anchored, split_options);
        defer a.free(result);
        // The untouched half keeps its full height; the focused half is
        // divided top/bottom with the new window below it.
        const left: types.Rect = .{ .x = 0, .y = 0, .width = 48, .height = 80 };
        const right: types.Rect = .{ .x = 52, .y = 0, .width = 48, .height = 80 };
        const half = if (focused == 1) left else right;
        try expectGeometry(result, if (focused == 1) 2 else 1, if (focused == 1) right else left);
        try expectGeometry(result, focused, .{ .x = half.x, .y = 0, .width = 48, .height = 38 });
        try expectGeometry(result, 3, .{ .x = half.x, .y = 42, .width = 48, .height = 38 });
    }
}

test "split focused uses the previous focus when the new window takes focus as it opens" {
    const a = std.testing.allocator;
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    var options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4 };
    var state: State = .{};
    defer state.deinit(a);
    a.free(try arrange(a, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, options, .{ .split_focused = true }));
    options.new_window_anchor = 1;
    a.free(try arrange(a, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, options, .{ .split_focused = true, .focused = 1 }));
    // Window 3 is focused (and is the anchor) by the time it is placed.
    options.new_window_anchor = 3;
    const result = try arrange(a, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } }, options, .{ .split_focused = true, .focused = 3 });
    defer a.free(result);
    try expectGeometry(result, 1, .{ .x = 0, .y = 0, .width = 48, .height = 38 });
    try expectGeometry(result, 3, .{ .x = 0, .y = 42, .width = 48, .height = 38 });
    try expectGeometry(result, 2, .{ .x = 52, .y = 0, .width = 48, .height = 80 });
}

test "split focused gives a closed window's space to its sibling and supports swaps" {
    const a = std.testing.allocator;
    const area: types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    var options: types.Options = .{ .gaps_outer = 0, .gaps_inner = 4 };
    const split_options: Options = .{ .split_focused = true };
    var state: State = .{};
    defer state.deinit(a);
    a.free(try arrange(a, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 } }, options, split_options));
    options.new_window_anchor = 1;
    a.free(try arrange(a, &state, area, &.{ .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 } }, options, split_options));
    try std.testing.expectEqualSlices(types.Handle, &.{ 1, 3, 2 }, state.order.items.items);

    // Closing 1 hands the whole left half back to 3.
    const closed = try arrange(a, &state, area, &.{ .{ .handle = 2 }, .{ .handle = 3 } }, options, split_options);
    defer a.free(closed);
    try expectGeometry(closed, 3, .{ .x = 0, .y = 0, .width = 48, .height = 80 });
    try expectGeometry(closed, 2, .{ .x = 52, .y = 0, .width = 48, .height = 80 });

    try std.testing.expect(swap(&state, 2, 3));
    const swapped = try arrange(a, &state, area, &.{ .{ .handle = 2 }, .{ .handle = 3 } }, options, split_options);
    defer a.free(swapped);
    try expectGeometry(swapped, 2, .{ .x = 0, .y = 0, .width = 48, .height = 80 });
    try expectGeometry(swapped, 3, .{ .x = 52, .y = 0, .width = 48, .height = 80 });

    // Turning the option off drops the tree and returns to ordinary dwindle.
    a.free(try arrange(a, &state, area, &.{ .{ .handle = 2 }, .{ .handle = 3 } }, options, .{}));
    try std.testing.expectEqual(@as(?*Node, null), state.root);
}

test "reverse dwindle horizontally mirrors placements" {
    const usable_area: types.Rect = .{ .x = 11, .y = 7, .width = 113, .height = 91 };
    const windows = [_]types.Window{
        .{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 }, .{ .handle = 5 },
    };
    const layout_options: types.Options = .{ .gaps_outer = 3, .gaps_inner = 5, .master_ratio = 0.61 };

    inline for (.{ true, false }) |start_vertical| {
        var normal_state: State = .{};
        defer normal_state.deinit(std.testing.allocator);
        var reverse_state: State = .{};
        defer reverse_state.deinit(std.testing.allocator);

        const normal = try arrange(std.testing.allocator, &normal_state, usable_area, &windows, layout_options, .{
            .start_vertical = start_vertical,
            .split_ratio = 0.37,
        });
        defer std.testing.allocator.free(normal);
        const reverse = try arrange(std.testing.allocator, &reverse_state, usable_area, &windows, layout_options, .{
            .start_vertical = start_vertical,
            .split_ratio = 0.37,
            .reverse = true,
        });
        defer std.testing.allocator.free(reverse);

        const bounds = math.shrink(usable_area, layout_options.gaps_outer);
        try expectHorizontalMirrors(bounds, normal, reverse);

        try std.testing.expect(normal_state.order.swap(1, 4));
        try std.testing.expect(reverse_state.order.swap(1, 4));
        const normal_reordered = try arrange(std.testing.allocator, &normal_state, usable_area, &windows, layout_options, .{
            .start_vertical = start_vertical,
            .split_ratio = 0.37,
        });
        defer std.testing.allocator.free(normal_reordered);
        const reverse_reordered = try arrange(std.testing.allocator, &reverse_state, usable_area, &windows, layout_options, .{
            .start_vertical = start_vertical,
            .split_ratio = 0.37,
            .reverse = true,
        });
        defer std.testing.allocator.free(reverse_reordered);
        try expectHorizontalMirrors(bounds, normal_reordered, reverse_reordered);
    }
}

fn expectHorizontalMirrors(bounds: types.Rect, normal: []const types.Placement, reverse: []const types.Placement) !void {
    for (normal, reverse) |ordinary, mirrored| {
        try std.testing.expectEqual(ordinary.handle, mirrored.handle);
        try std.testing.expectEqual(ordinary.geometry.width, mirrored.geometry.width);
        try std.testing.expectEqual(ordinary.geometry.height, mirrored.geometry.height);
        try std.testing.expectEqual(ordinary.geometry.y, mirrored.geometry.y);
        try std.testing.expectEqual(
            bounds.x + bounds.width - (ordinary.geometry.x - bounds.x) - ordinary.geometry.width,
            mirrored.geometry.x,
        );
        try std.testing.expectEqual(ordinary.border, mirrored.border);
        try std.testing.expectEqual(ordinary.visible, mirrored.visible);
    }
}
