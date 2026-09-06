// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const wlr = @import("wlroots");

// These public wlroots setters are not yet exposed by the pinned Zig binding.
extern fn wlr_scene_buffer_set_transfer_function(buffer: *wlr.SceneBuffer, value: wlr.color.TransferFunction) void;
extern fn wlr_scene_buffer_set_primaries(buffer: *wlr.SceneBuffer, value: wlr.color.NamedPrimaries) void;
extern fn wlr_scene_buffer_set_color_encoding(buffer: *wlr.SceneBuffer, value: wlr.color.Encoding) void;
extern fn wlr_scene_buffer_set_color_range(buffer: *wlr.SceneBuffer, value: wlr.color.Range) void;

/// Copy the frozen buffer's rendering state, without borrowing surface identity
/// or listeners. Compositor-specific effects are attached by the caller.
pub fn clone(target: *wlr.SceneTree, source: *wlr.SceneBuffer, x: i32, y: i32) !*wlr.SceneBuffer {
    const snapshot = try target.createSceneBuffer(source.buffer);
    snapshot.node.setPosition(x, y);
    snapshot.setDestSize(source.dst_width, source.dst_height);
    snapshot.setSourceBox(&source.src_box);
    snapshot.setTransform(source.transform);
    snapshot.setOpacity(source.opacity);
    snapshot.setOpaqueRegion(&source.opaque_region);
    snapshot.setFilterMode(source.filter_mode);
    wlr_scene_buffer_set_transfer_function(snapshot, source.transfer_function);
    wlr_scene_buffer_set_primaries(snapshot, source.primaries);
    wlr_scene_buffer_set_color_encoding(snapshot, source.color_encoding);
    wlr_scene_buffer_set_color_range(snapshot, source.color_range);
    return snapshot;
}

test "snapshot preserves non-default color state and sampling independently of source lifetime" {
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    const live_tree = try scene.tree.createSceneTree();
    const snapshot_tree = try scene.tree.createSceneTree();
    const source = try live_tree.createSceneBuffer(null);
    var live_identity: u8 = 0;
    source.node.data = &live_identity;
    source.setDestSize(240, 160);
    source.setSourceBox(&.{ .x = 2, .y = 3, .width = 120, .height = 80 });
    source.setTransform(.@"90");
    source.setOpacity(0.95);
    source.setFilterMode(.nearest);
    wlr_scene_buffer_set_primaries(source, .bt2020);
    wlr_scene_buffer_set_color_encoding(source, .bt2020);
    wlr_scene_buffer_set_color_range(source, .limited);

    for ([_]wlr.color.TransferFunction{ .gamma22, .st2084_pq, .ext_linear, .bt1886 }) |tf| {
        wlr_scene_buffer_set_transfer_function(source, tf);
        const snapshot = try clone(snapshot_tree, source, 11, 17);
        defer snapshot.node.destroy();
        try std.testing.expectEqual(tf, snapshot.transfer_function);
        try std.testing.expectEqual(wlr.color.NamedPrimaries.bt2020, snapshot.primaries);
        try std.testing.expectEqual(wlr.color.Encoding.bt2020, snapshot.color_encoding);
        try std.testing.expectEqual(wlr.color.Range.limited, snapshot.color_range);
        try std.testing.expectEqual(source.filter_mode, snapshot.filter_mode);
        try std.testing.expectEqual(source.opacity, snapshot.opacity);
        try std.testing.expectEqual(source.transform, snapshot.transform);
        try std.testing.expectEqualDeep(source.src_box, snapshot.src_box);
        try std.testing.expectEqual(source.dst_width, snapshot.dst_width);
        try std.testing.expectEqual(source.dst_height, snapshot.dst_height);
        try std.testing.expectEqual(@as(c_int, 11), snapshot.node.x);
        try std.testing.expectEqual(@as(c_int, 17), snapshot.node.y);
        try std.testing.expect(snapshot.node.data == null);
        try std.testing.expect(wlr.SceneSurface.tryFromBuffer(snapshot) == null);
        wlr_scene_buffer_set_transfer_function(source, .srgb);
        try std.testing.expectEqual(tf, snapshot.transfer_function);
    }

    wlr_scene_buffer_set_transfer_function(source, .gamma22);
    const survivor = try clone(snapshot_tree, source, 0, 0);
    source.node.destroy();
    try std.testing.expectEqual(wlr.color.TransferFunction.gamma22, survivor.transfer_function);
    survivor.node.destroy();
    try std.testing.expect(live_tree.children.empty());
    try std.testing.expect(snapshot_tree.children.empty());
}

test "snapshot preserves default SDR properties and destroying it leaves the source intact" {
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    const source = try scene.tree.createSceneBuffer(null);
    const snapshot = try clone(&scene.tree, source, 0, 0);
    try std.testing.expectEqual(source.transfer_function, snapshot.transfer_function);
    try std.testing.expectEqual(source.primaries, snapshot.primaries);
    try std.testing.expectEqual(source.color_encoding, snapshot.color_encoding);
    try std.testing.expectEqual(source.color_range, snapshot.color_range);
    try std.testing.expectEqual(source.filter_mode, snapshot.filter_mode);
    try std.testing.expectEqual(@as(f32, 1), snapshot.opacity);
    snapshot.node.destroy();
    source.setOpacity(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), source.opacity);
}
