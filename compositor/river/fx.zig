// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

//! Thin, comptime-gated wrappers around the SceneFX corner-radius API.
//!
//! Every function in this file is guarded by `comptime build_options.scenefx`.
//! When SceneFX is not compiled in (`-Dscenefx=false`), the bodies (and the
//! `@import("c")` symbols that only exist when the SceneFX headers are present)
//! are completely compiled out, leaving the stock `wlr_scene` behavior with
//! square corners and no reference to any SceneFX symbol.

const build_options = @import("build_options");
const wlr = @import("wlroots");

/// Corner radius (in layout pixels) applied to window content and borders.
/// When SceneFX is unavailable this is always 0, i.e. square corners.
pub const corner_radius: u31 = if (build_options.scenefx) 12 else 0;

/// Set the corner radius of a single scene buffer node.
pub fn setBufferRadius(buffer: *wlr.SceneBuffer, radius: u31) void {
    if (comptime !build_options.scenefx) return;
    const c = @import("c");
    c.wlr_scene_buffer_set_corner_radius(@ptrCast(buffer), @intCast(radius));
}

/// Set the corner radius of a single scene rect node.
pub fn setRectRadius(rect: *wlr.SceneRect, radius: u31) void {
    if (comptime !build_options.scenefx) return;
    const c = @import("c");
    c.wlr_scene_rect_set_corner_radius(@ptrCast(rect), @intCast(radius));
}

/// Apply the given corner radius to every buffer node in the given subtree.
pub fn setTreeRadius(tree: *wlr.SceneTree, radius: u31) void {
    if (comptime !build_options.scenefx) return;
    // forEachBuffer passes the user data through as an opaque pointer, so the
    // radius is forwarded by reference.
    var r = radius;
    tree.node.forEachBuffer(*u31, setBufferRadiusIter, &r);
}

fn setBufferRadiusIter(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, radius: *u31) void {
    _ = sx;
    _ = sy;
    setBufferRadius(buffer, radius.*);
}
