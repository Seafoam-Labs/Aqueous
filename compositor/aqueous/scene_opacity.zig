// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const wlr = @import("wlroots");
const pixman = @import("pixman");

/// Visit disabled transaction/snapshot trees too. Changing opacity must not
/// discard the derived opaque region: wlroots handles occlusion at opacity < 1,
/// and needs the original region again when the buffer becomes fully opaque.
pub fn apply(node: *wlr.SceneNode, opacity: f32) void {
    switch (node.type) {
        .buffer => wlr.SceneBuffer.fromNode(node).setOpacity(opacity),
        .tree => {
            const tree: *wlr.SceneTree = @fieldParentPtr("node", node);
            var it = tree.children.iterator(.forward);
            while (it.next()) |child| apply(child, opacity);
        },
        else => {},
    }
}

test "opacity preserves partial occlusion through disabled snapshot trees" {
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    const behind = try scene.tree.createSceneRect(64, 64, &.{ 1, 0, 0, 1 });
    const tree = try scene.tree.createSceneTree();
    const nested = try tree.createSceneTree();

    // An alpha-capable buffer with an opaque hint covering only its left half.
    // This is also how clipped/scaled regions and frozen snapshots are stored.
    var buffer: wlr.Buffer = undefined;
    const implementation: wlr.Buffer.Impl = .{
        .destroy = struct {
            fn destroy(_: *wlr.Buffer) callconv(.c) void {}
        }.destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = null,
        .end_data_ptr_access = null,
    };
    buffer.init(&implementation, 64, 64);
    const front = try nested.createSceneBuffer(&buffer);
    buffer.drop(); // The scene owns the remaining reference.
    var opaque_region: pixman.Region32 = undefined;
    opaque_region.initRect(0, 0, 32, 64);
    defer opaque_region.deinit();
    front.setOpaqueRegion(&opaque_region);
    try std.testing.expect(!behind.node.private.visible.containsPoint(16, 32, null));
    try std.testing.expect(behind.node.private.visible.containsPoint(48, 32, null));

    for ([_]f32{ 0.5, 0, 1 }) |opacity| {
        tree.node.setEnabled(false);
        apply(&tree.node, opacity);
        try std.testing.expectEqual(opacity, front.opacity);
        try std.testing.expect(front.opaque_region.equal(&opaque_region));
        tree.node.setEnabled(true);
        try std.testing.expectEqual(opacity < 1, behind.node.private.visible.containsPoint(16, 32, null));
        try std.testing.expect(behind.node.private.visible.containsPoint(48, 32, null));
    }
}
