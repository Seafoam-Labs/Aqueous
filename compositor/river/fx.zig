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

/// Create the renderer appropriate for the current build.
///
/// A SceneFX-backed scene (created by `wlr.Scene.create()` once SceneFX is
/// linked) requires the SceneFX FX renderer; driving it with a stock
/// autocreated GLES2/Vulkan renderer crashes on the first scene-output commit.
/// When SceneFX is not compiled in, fall back to the normal autocreated
/// wlroots renderer.
pub fn createRenderer(backend: *wlr.Backend) !*wlr.Renderer {
    if (comptime build_options.scenefx) {
        const c = @import("c");
        const r = c.fx_renderer_create(@ptrCast(backend)) orelse
            return error.RendererCreateFailed;
        return @ptrCast(@alignCast(r));
    }
    return wlr.Renderer.autocreate(backend);
}

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

// ----------------------------------------------------------------------------
// Backdrop blur (SceneFX optimized blur), all comptime-gated like the corner
// radius helpers above. Global blur parameters arrive from Aqueous via
// river_window_manager_v1.set_blur; per-window exclusion via
// river_window_v1.set_window_blur.
// ----------------------------------------------------------------------------

/// Whether blur is available in this build. Mirrors the corner_radius gate so
/// callers can branch without referencing any SceneFX symbol.
pub const blur_available: bool = build_options.scenefx;

/// Apply the scene-wide blur parameters. The noise/brightness/contrast/saturation
/// values are taken from the SceneFX defaults; only the radius and pass count are
/// driven by the user's `[blur]` config. Setting radius or passes to 0 disables
/// blur (`is_scene_blur_enabled` returns false), so the global on/off toggle is
/// expressed by passing 0 when disabled.
pub fn setBlurParams(scene: *wlr.Scene, radius: c_int, passes: c_int) void {
    if (comptime !build_options.scenefx) return;
    const c = @import("c");
    const defaults = c.blur_data_get_default();
    c.wlr_scene_set_blur_data(
        @ptrCast(scene),
        passes,
        radius,
        defaults.noise,
        defaults.brightness,
        defaults.contrast,
        defaults.saturation,
    );
}

/// Ensure the optimized (backdrop) blur node exists as a child of `tree`, creating
/// it on first use. The node is created once and kept; the global on/off state is
/// expressed through `setBlurParams` (radius/passes 0 == no blur) rather than by
/// destroying the node. Returns the node as an opaque pointer so callers in
/// non-SceneFX builds need not name any SceneFX type. Width/height of 0 makes the
/// node track the full output size.
pub fn ensureOptimizedBlur(tree: *wlr.SceneTree, existing: ?*anyopaque) ?*anyopaque {
    if (comptime !build_options.scenefx) return null;
    if (existing != null) return existing;
    const c = @import("c");
    const node = c.wlr_scene_optimized_blur_create(@ptrCast(tree), 0, 0);
    if (node) |n| {
        // Keep the blur backdrop at the bottom of its tree so it only blurs the
        // content behind it (background / bottom layers), never the windows above.
        c.wlr_scene_node_lower_to_bottom(&n.*.node);
    }
    return @ptrCast(node);
}

/// Per-window blur exclusion. When `excluded` is true, the window's buffers are
/// marked fully opaque so the optimized-blur pass clips them out (no per-frame
/// backdrop blur cost behind e.g. games); when false the opaque region override is
/// cleared so the client's own opacity hints apply again.
pub fn setTreeBlurExcluded(tree: *wlr.SceneTree, excluded: bool) void {
    if (comptime !build_options.scenefx) return;
    var ex = excluded;
    tree.node.forEachBuffer(*bool, setBufferBlurExcludedIter, &ex);
}

fn setBufferBlurExcludedIter(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, excluded: *bool) void {
    _ = sx;
    _ = sy;
    if (comptime !build_options.scenefx) return;
    const c = @import("c");
    const scene_buffer: *c.struct_wlr_scene_buffer = @ptrCast(buffer);
    if (excluded.*) {
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init_rect(
            &region,
            0,
            0,
            @intCast(scene_buffer.dst_width),
            @intCast(scene_buffer.dst_height),
        );
        c.wlr_scene_buffer_set_opaque_region(scene_buffer, &region);
        c.pixman_region32_fini(&region);
    } else {
        // Clearing to an empty region restores the default (client-driven) opacity
        // behaviour so the window participates in blur again.
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init(&region);
        c.wlr_scene_buffer_set_opaque_region(scene_buffer, &region);
        c.pixman_region32_fini(&region);
    }
}
