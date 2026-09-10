// SPDX-License-Identifier: GPL-3.0-only
const Overlay = @This();
const wlr = @import("wlroots");
tree: *wlr.SceneTree,
rects: [4]*wlr.SceneRect,

pub fn init(parent: *wlr.SceneTree) !Overlay {
    const tree = try parent.createSceneTree();
    errdefer tree.node.destroy();
    tree.node.setEnabled(false);
    var rects: [4]*wlr.SceneRect = undefined;
    for (&rects) |*rect| rect.* = try tree.createSceneRect(1, 1, &.{ 0.24, 0.48, 0.56, 0.7 });
    return .{ .tree = tree, .rects = rects };
}

pub fn show(overlay: *Overlay, box: wlr.Box) void {
    const thickness = @min(3, @min(box.width, box.height));
    const boxes = [_]wlr.Box{
        .{ .x = 0, .y = 0, .width = box.width, .height = thickness },
        .{ .x = 0, .y = box.height - thickness, .width = box.width, .height = thickness },
        .{ .x = 0, .y = thickness, .width = thickness, .height = @max(0, box.height - 2 * thickness) },
        .{ .x = box.width - thickness, .y = thickness, .width = thickness, .height = @max(0, box.height - 2 * thickness) },
    };
    overlay.tree.node.setPosition(box.x, box.y);
    for (overlay.rects, boxes) |rect, b| {
        rect.node.setPosition(b.x, b.y);
        rect.setSize(b.width, b.height);
    }
    overlay.tree.node.setEnabled(true);
}

pub fn hide(overlay: *Overlay) void {
    overlay.tree.node.setEnabled(false);
}

pub fn deinit(overlay: *Overlay) void {
    overlay.tree.node.destroy();
}
