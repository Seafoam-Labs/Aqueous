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

// ----------------------------------------------------------------------------
// Window position animation tuning. Frame-rate-independent exponential
// smoothing is used (factor = 1 - exp(-rate * dt)); a higher rate is snappier.
// The whole feature is compiled out with `-Danimations=false`.
// ----------------------------------------------------------------------------

/// Whether compositor-side position animations are compiled in.
pub const anim_enabled: bool = build_options.animations;

/// Exponential smoothing rate for window position animations.
pub const anim_rate: f64 = 18.0;

/// Exponential smoothing rate for the workspace-swap slide. Kept separate from
/// `anim_rate` so the full-width workspace transition can be paced (typically
/// slower) independently of ordinary window moves. Higher = snappier.
pub const workspace_slide_rate: f64 = 7.0;

/// Distance (in layout pixels) below which an animation is considered complete
/// and snapped to its target.
pub const anim_epsilon: f64 = 0.5;

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

/// Per-window content opacity. Driven by river_window_v1.set_window_opacity with the
/// global default from river_window_manager_v1.set_opacity. This uses the core
/// wlroots scene-buffer opacity, so it is available with or without SceneFX.
/// Note: wlroots' forEachBuffer skips disabled nodes, but river toggles the
/// live/saved trees disabled around transactions, so a manual recursion that
/// ignores the enabled flag is required for the value to stick in every state.
pub fn setTreeOpacity(tree: *wlr.SceneTree, opacity: f32) void {
    setNodeOpacity(&tree.node, opacity);
}

fn setNodeOpacity(node: *wlr.SceneNode, opacity: f32) void {
    switch (node.type) {
        .buffer => wlr.SceneBuffer.fromNode(node).setOpacity(opacity),
        .tree => {
            const tree: *wlr.SceneTree = @fieldParentPtr("node", node);
            var it = tree.children.iterator(.forward);
            while (it.next()) |child| setNodeOpacity(child, opacity);
        },
        else => {},
    }
}

/// Per-window blur exclusion. When `excluded` is true, the window's buffers are
/// marked fully opaque so the optimized-blur pass clips them out (no per-frame
/// backdrop blur cost behind e.g. games); when false the opaque region override is
/// cleared so the client's own opacity hints apply again.
/// Like setTreeOpacity, this recurses manually so disabled (saved/hidden)
/// trees are still updated.
pub fn setTreeBlurExcluded(tree: *wlr.SceneTree, excluded: bool) void {
    if (comptime !build_options.scenefx) return;
    setNodeBlurExcluded(&tree.node, excluded);
}

fn setNodeBlurExcluded(node: *wlr.SceneNode, excluded: bool) void {
    switch (node.type) {
        .buffer => setBufferBlurExcluded(wlr.SceneBuffer.fromNode(node), excluded),
        .tree => {
            const tree: *wlr.SceneTree = @fieldParentPtr("node", node);
            var it = tree.children.iterator(.forward);
            while (it.next()) |child| setNodeBlurExcluded(child, excluded);
        },
        else => {},
    }
}

/// Copy the SceneFX-specific attributes (corner radii and the opaque-region
/// blur-exclusion override) from one scene buffer to another. Used when cloning
/// buffers into a transaction snapshot tree, where freshly created buffers would
/// otherwise reset to square corners / default blur participation.
pub fn copyBufferFx(dst: *wlr.SceneBuffer, src: *wlr.SceneBuffer) void {
    if (comptime !build_options.scenefx) return;
    const c = @import("c");
    const s: *c.struct_wlr_scene_buffer = @ptrCast(src);
    const d: *c.struct_wlr_scene_buffer = @ptrCast(dst);
    c.wlr_scene_buffer_set_corner_radii(d, s.corners);
    c.wlr_scene_buffer_set_opaque_region(d, &s.opaque_region);
}

fn setBufferBlurExcluded(buffer: *wlr.SceneBuffer, excluded: bool) void {
    if (comptime !build_options.scenefx) return;
    const c = @import("c");
    const scene_buffer: *c.struct_wlr_scene_buffer = @ptrCast(buffer);
    if (excluded) {
        // Honor the surface's actually-advertised opaque region instead of
        // stamping the whole buffer rect. Forcing a full-buffer opaque region
        // tells the renderer it may skip alpha blending over every pixel,
        // which corrupts translucent clients (e.g. Electron/Discord: rounded
        // corners and translucent panels composite as stale garbage). Only a
        // genuinely opaque client (e.g. Steam/games) advertises a region that
        // covers the buffer, so intersecting that region with the buffer rect
        // preserves the blur-exclusion optimization for them while leaving
        // translucent pixels to blend correctly.
        var rect: c.pixman_region32_t = undefined;
        c.pixman_region32_init_rect(
            &rect,
            0,
            0,
            @intCast(scene_buffer.dst_width),
            @intCast(scene_buffer.dst_height),
        );
        defer c.pixman_region32_fini(&rect);

        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init(&region);
        defer c.pixman_region32_fini(&region);

        // Recover the backing wlr_surface (if any) to read its current opaque
        // region. Border rects and snapshot clones have no backing surface; for
        // those we leave `region` empty (do not force a full rect) so a clone is
        // never stamped with a wrong region — `copyBufferFx` already propagates
        // the correct region from the live buffer.
        // The raw `c` import exposes `wlr_surface` as an opaque type with no
        // readable fields, so go through the typed wlroots binding to reach the
        // committed opaque region (`surface.current.@"opaque"`), then reinterpret
        // it as the raw pixman type for the intersection below.
        if (wlr.SceneSurface.tryFromBuffer(buffer)) |scene_surface| {
            // surface.current.opaque is in surface-local coordinates; clamp it to
            // the buffer rect so the override never exceeds the buffer.
            const surface_opaque: *c.pixman_region32_t =
                @ptrCast(&scene_surface.surface.current.@"opaque");
            _ = c.pixman_region32_intersect(&region, surface_opaque, &rect);
        }
        c.wlr_scene_buffer_set_opaque_region(scene_buffer, &region);
    } else {
        // Clearing to an empty region restores the default (client-driven) opacity
        // behaviour so the window participates in blur again.
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init(&region);
        c.wlr_scene_buffer_set_opaque_region(scene_buffer, &region);
        c.pixman_region32_fini(&region);
    }
}
