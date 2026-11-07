// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Input-inert stacking snap-zone preview.

const SnapOverlay = @This();

const wlr = @import("wlroots");
const fx = @import("fx.zig");

pub const max_zones = 16;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Premultiplied RGBA fill colors for the preview rects. Callers derive
/// these from the configured window border colors.
pub const Colors = struct {
    normal: [4]f32,
    selected: [4]f32,
};

tree: *wlr.SceneTree,
rects: [max_zones]*wlr.SceneRect,
output_id: u64 = 0,
visible_count: u8 = 0,

/// Fallback used until the first `show` supplies border-derived colors.
const default_colors: Colors = .{
    .normal = .{ 0.12, 0.55, 1.0, 0.18 },
    .selected = .{ 0.25, 0.72, 1.0, 0.32 },
};

pub fn init(parent: *wlr.SceneTree) !SnapOverlay {
    const tree = try parent.createSceneTree();
    tree.node.setEnabled(false);
    var rects: [max_zones]*wlr.SceneRect = undefined;
    for (&rects) |*slot| {
        slot.* = try tree.createSceneRect(1, 1, &default_colors.normal);
        slot.*.node.setEnabled(false);
        fx.setRectInputEnabled(slot.*, false);
        fx.setRectRadius(slot.*, 12);
    }
    return .{ .tree = tree, .rects = rects };
}

pub fn show(overlay: *SnapOverlay, output_id: u64, rects: []const Rect, selected: ?usize, colors: Colors) void {
    overlay.hideRects();
    const count = @min(rects.len, max_zones);
    for (rects[0..count], 0..) |rect, index| {
        if (rect.width <= 0 or rect.height <= 0) continue;
        const node = overlay.rects[index];
        node.node.setPosition(rect.x, rect.y);
        node.setSize(rect.width, rect.height);
        node.setColor(if (selected != null and selected.? == index) &colors.selected else &colors.normal);
        node.node.setEnabled(true);
    }
    overlay.output_id = output_id;
    overlay.visible_count = @intCast(count);
    overlay.tree.node.raiseToTop();
    overlay.tree.node.setEnabled(count != 0);
}

pub fn hide(overlay: *SnapOverlay) void {
    overlay.hideRects();
    overlay.output_id = 0;
    overlay.visible_count = 0;
    overlay.tree.node.setEnabled(false);
}

pub fn deinit(overlay: *SnapOverlay) void {
    overlay.tree.node.destroy();
    overlay.* = undefined;
}

pub fn activeFor(overlay: *const SnapOverlay, output_id: u64) bool {
    return overlay.tree.node.enabled and overlay.output_id == output_id;
}

fn hideRects(overlay: *SnapOverlay) void {
    for (overlay.rects) |rect| rect.node.setEnabled(false);
}
