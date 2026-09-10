// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const types = @import("types.zig");

// Layout engines use the small z-order range around zero for local semantics.
// Policy overlays live in disjoint bands so engine focus cannot overtake a
// floating or fullscreen window.
pub const maximized_band: i32 = 100;
pub const floating_band: i32 = 200;
pub const transient_band: i32 = 300;
pub const below_band: i32 = -200;
pub const above_band: i32 = 350;
pub const fullscreen_band: i32 = 400;

pub fn floatingZ(parent_depth: u32) i32 {
    if (parent_depth == 0) return floating_band;
    return transient_band + @as(i32, @intCast(@min(parent_depth, 99)));
}

/// Resolve a window's compositor-wide layer after its layout has supplied a
/// local z-order. Transient depth is a constraint within the selected layer,
/// not a global band that can overtake an unrelated always-above window.
pub fn layeredZ(local_z: i32, layer: types.StackLayer, parent_depth: u32) i32 {
    const depth: i32 = @intCast(@min(parent_depth, 49));
    return switch (layer) {
        .below => below_band + depth,
        .normal => if (parent_depth == 0) local_z else transient_band + depth,
        .above => above_band + depth,
    };
}

pub fn lessThan(_: void, left: types.Placement, right: types.Placement) bool {
    if (left.z_order != right.z_order) return left.z_order < right.z_order;
    if (left.stack_order != right.stack_order) return left.stack_order < right.stack_order;
    return left.handle < right.handle;
}

/// Count the declared transient-parent chain. A missing parent still gives the
/// child transient priority, while the window-count bound makes malformed
/// parent cycles harmless.
pub fn transientDepth(windows: []const types.Window, window: types.Window) u32 {
    var parent = window.parent;
    var depth: u32 = 0;
    var remaining = windows.len;
    while (parent != null and remaining > 0) : (remaining -= 1) {
        depth += 1;
        const ancestor = findWindow(windows, parent.?) orelse break;
        parent = ancestor.parent;
    }
    return depth;
}

fn findWindow(windows: []const types.Window, handle: types.Handle) ?types.Window {
    for (windows) |window| if (window.handle == handle) return window;
    return null;
}

fn dialogParent(windows: []const types.Window, placements: []const types.Placement, handle: types.Handle) ?types.Handle {
    const window = findWindow(windows, handle) orelse return null;
    if (!window.dialog) return null;
    const parent = window.parent orelse return null;
    if (parent == handle) return null;
    for (placements) |placement| {
        if (placement.handle == parent and placement.visible) return parent;
    }
    return null;
}

fn fullscreenDialogParent(windows: []const types.Window, placements: []const types.Placement, handle: types.Handle) ?types.Handle {
    const parent = dialogParent(windows, placements, handle) orelse return null;
    var current = parent;
    for (0..windows.len) |_| {
        const ancestor = findWindow(windows, current) orelse return null;
        if (ancestor.fullscreen) return parent;
        current = dialogParent(windows, placements, current) orelse return null;
    }
    return null;
}

/// Keep fullscreen dialog groups contiguous at their root's stacking position.
/// Ordinary dialogs retain existing transient bands and raise-on-focus rules;
/// grouping those at a tiled parent's rank would bury them under floating peers.
/// This prevents a dialog from jumping above unrelated fullscreen groups.
/// Iterate breadth-first without recursion; malformed cycles retain their
/// original order and cannot exhaust the compositor's stack.
pub fn orderDialogs(allocator: std.mem.Allocator, windows: []const types.Window, placements: []types.Placement) !void {
    const has_dialog = for (windows) |window| {
        if (window.dialog) break true;
    } else false;
    if (!has_dialog) return;
    var ordered: std.ArrayListUnmanaged(types.Placement) = .empty;
    defer ordered.deinit(allocator);
    try ordered.ensureTotalCapacity(allocator, placements.len);
    for (placements) |root| {
        if (fullscreenDialogParent(windows, placements, root.handle) != null) continue;
        var next = ordered.items.len;
        ordered.appendAssumeCapacity(root);
        while (next < ordered.items.len) : (next += 1) {
            const parent = ordered.items[next].handle;
            for (placements) |child| {
                if (fullscreenDialogParent(windows, placements, child.handle) == parent) {
                    ordered.appendAssumeCapacity(child);
                }
            }
        }
    }
    // A cycle has no root. Each node has at most one parent, so it cannot also
    // have been reached from a valid root above.
    for (placements) |placement| {
        var found = false;
        for (ordered.items) |item| if (item.handle == placement.handle) {
            found = true;
            break;
        };
        if (!found) ordered.appendAssumeCapacity(placement);
    }
    @memcpy(placements, ordered.items);
}

test "dialogs stay above their own fullscreen group without overtaking another" {
    const windows = [_]types.Window{
        .{ .handle = 1, .fullscreen = true },
        .{ .handle = 2, .parent = 1, .dialog = true },
        .{ .handle = 3, .parent = 2, .dialog = true },
        .{ .handle = 4, .fullscreen = true },
    };
    var placements = [_]types.Placement{
        .{ .handle = 2, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
        .{ .handle = 3, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
        .{ .handle = 1, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
        .{ .handle = 4, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
    };
    try orderDialogs(std.testing.allocator, &windows, &placements);
    for (placements, [_]types.Handle{ 1, 2, 3, 4 }) |p, expected| try std.testing.expectEqual(expected, p.handle);
}

test "dialog stacking tolerates cycles and missing parents" {
    const windows = [_]types.Window{
        .{ .handle = 1, .parent = 2, .dialog = true },
        .{ .handle = 2, .parent = 1, .dialog = true },
        .{ .handle = 3, .parent = 99, .dialog = true },
    };
    var placements = [_]types.Placement{
        .{ .handle = 1, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
        .{ .handle = 2, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
        .{ .handle = 3, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
    };
    try orderDialogs(std.testing.allocator, &windows, &placements);
    for (placements, [_]types.Handle{ 1, 2, 3 }) |p, expected| try std.testing.expectEqual(expected, p.handle);
}

test "ordinary dialogs retain transient stacking over unrelated floating windows" {
    const windows = [_]types.Window{
        .{ .handle = 1 }, .{ .handle = 2, .parent = 1, .dialog = true }, .{ .handle = 3 },
    };
    var placements = [_]types.Placement{
        .{ .handle = 1, .geometry = .empty, .z_order = 0, .visible = true, .border = .none },
        .{ .handle = 3, .geometry = .empty, .z_order = floating_band, .visible = true, .border = .none },
        .{ .handle = 2, .geometry = .empty, .z_order = transient_band, .visible = true, .border = .none },
    };
    try orderDialogs(std.testing.allocator, &windows, &placements);
    for (placements, [_]types.Handle{ 1, 3, 2 }) |p, expected| try std.testing.expectEqual(expected, p.handle);
}

test "semantic bands sort tiled, maximized, floating, transient, and fullscreen" {
    var placements = [_]types.Placement{
        .{ .handle = 5, .geometry = .empty, .z_order = fullscreen_band, .visible = true, .border = .none },
        .{ .handle = 3, .geometry = .empty, .z_order = floating_band, .stack_order = 8, .visible = true, .border = .none },
        .{ .handle = 1, .geometry = .empty, .z_order = 1, .visible = true, .border = .none },
        .{ .handle = 4, .geometry = .empty, .z_order = floatingZ(1), .visible = true, .border = .none },
        .{ .handle = 2, .geometry = .empty, .z_order = maximized_band, .visible = true, .border = .none },
        .{ .handle = 6, .geometry = .empty, .z_order = floating_band, .stack_order = 12, .visible = true, .border = .none },
    };
    std.mem.sort(types.Placement, &placements, {}, lessThan);
    const expected = [_]types.Handle{ 1, 2, 3, 6, 4, 5 };
    for (placements, expected) |placement, handle| {
        try std.testing.expectEqual(handle, placement.handle);
    }
}

test "maximized-on-floating shares floating band so focus decides stacking" {
    // On a floating workspace, maximized windows share the floating band with
    // ordinary floating peers, so the most recently focused one (higher
    // stack_order) sorts on top. Transient and fullscreen peers still win via
    // their higher bands.

    // Focused maximized window sorts above a floating peer.
    {
        var placements = [_]types.Placement{
            .{ .handle = 1, .geometry = .empty, .z_order = floating_band, .stack_order = 9, .visible = true, .border = .none },
            .{ .handle = 2, .geometry = .empty, .z_order = floating_band, .stack_order = 3, .visible = true, .border = .none },
            .{ .handle = 3, .geometry = .empty, .z_order = floatingZ(1), .visible = true, .border = .none },
        };
        std.mem.sort(types.Placement, &placements, {}, lessThan);
        const expected = [_]types.Handle{ 2, 1, 3 };
        for (placements, expected) |placement, handle| {
            try std.testing.expectEqual(handle, placement.handle);
        }
    }

    // Focused floating window sorts above the maximized one.
    {
        var placements = [_]types.Placement{
            .{ .handle = 1, .geometry = .empty, .z_order = floating_band, .stack_order = 3, .visible = true, .border = .none },
            .{ .handle = 2, .geometry = .empty, .z_order = floating_band, .stack_order = 9, .visible = true, .border = .none },
            .{ .handle = 3, .geometry = .empty, .z_order = floatingZ(1), .visible = true, .border = .none },
        };
        std.mem.sort(types.Placement, &placements, {}, lessThan);
        const expected = [_]types.Handle{ 1, 2, 3 };
        for (placements, expected) |placement, handle| {
            try std.testing.expectEqual(handle, placement.handle);
        }
    }
}

test "persistent raise order wins within a floating band" {
    var placements = [_]types.Placement{
        .{ .handle = 20, .geometry = .empty, .z_order = floating_band, .stack_order = 9, .visible = true, .border = .none },
        .{ .handle = 10, .geometry = .empty, .z_order = floating_band, .stack_order = 15, .visible = true, .border = .none },
    };
    std.mem.sort(types.Placement, &placements, {}, lessThan);
    try std.testing.expectEqual(@as(types.Handle, 20), placements[0].handle);
    try std.testing.expectEqual(@as(types.Handle, 10), placements[1].handle);
}

test "semantic layers retain transient constraints below fullscreen" {
    try std.testing.expect(layeredZ(1, .below, 2) < layeredZ(1, .normal, 0));
    try std.testing.expect(layeredZ(1, .normal, 2) < layeredZ(1, .above, 0));
    try std.testing.expect(layeredZ(1, .above, 30) < fullscreen_band);
    try std.testing.expect(layeredZ(1, .above, 2) > layeredZ(1, .above, 1));
}

test "transient depth follows parent chains and bounds cycles" {
    const windows = [_]types.Window{
        .{ .handle = 1 },
        .{ .handle = 2, .parent = 1 },
        .{ .handle = 3, .parent = 2 },
        .{ .handle = 4, .parent = 99 },
    };
    try std.testing.expectEqual(@as(u32, 0), transientDepth(&windows, windows[0]));
    try std.testing.expectEqual(@as(u32, 1), transientDepth(&windows, windows[1]));
    try std.testing.expectEqual(@as(u32, 2), transientDepth(&windows, windows[2]));
    try std.testing.expectEqual(@as(u32, 1), transientDepth(&windows, windows[3]));

    const cycle = [_]types.Window{
        .{ .handle = 7, .parent = 8 },
        .{ .handle = 8, .parent = 7 },
    };
    try std.testing.expectEqual(@as(u32, cycle.len), transientDepth(&cycle, cycle[0]));
}
