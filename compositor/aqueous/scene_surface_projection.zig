// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const wlr = @import("wlroots");

extern fn wlr_scene_surface_get_destination_scale(scene_surface: *wlr.SceneSurface) f64;
extern fn wlr_scene_surface_map_point_to_destination(
    scene_surface: *wlr.SceneSurface,
    sx: f64,
    sy: f64,
    dx: *f64,
    dy: *f64,
) void;

pub fn scale(node: *wlr.SceneNode) f64 {
    if (node.type != .buffer) return 1;
    const buffer = wlr.SceneBuffer.fromNode(node);
    const surface = wlr.SceneSurface.tryFromBuffer(buffer) orelse return 1;
    return wlr_scene_surface_get_destination_scale(surface);
}

pub fn surfaceToDestination(
    node: *wlr.SceneNode,
    sx: f64,
    sy: f64,
) struct { x: f64, y: f64 } {
    if (node.type != .buffer) return .{ .x = sx, .y = sy };
    const buffer = wlr.SceneBuffer.fromNode(node);
    const surface = wlr.SceneSurface.tryFromBuffer(buffer) orelse return .{ .x = sx, .y = sy };
    var dx: f64 = undefined;
    var dy: f64 = undefined;
    wlr_scene_surface_map_point_to_destination(surface, sx, sy, &dx, &dy);
    return .{ .x = dx, .y = dy };
}
