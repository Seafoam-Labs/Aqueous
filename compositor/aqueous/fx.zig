// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

//! Backend-neutral facade for compositor visual effects.

const build_options = @import("build_options");
const std = @import("std");
const pixman = @import("pixman");
const wlr = @import("wlroots");
const EffectMetadata = @import("render/EffectMetadata.zig");
const render_metrics = @import("render_metrics.zig");
const visual_state = @import("visual_state.zig");

/// Corner radius (in layout pixels) applied to window content and borders.
/// Builds with no effects backend retain square corners.
pub const corner_radius: u31 =
    if (build_options.vulkan_effects) 15 else 0;

pub const CornerRadii = EffectMetadata.CornerRadii;
pub const BlurAppearance = EffectMetadata.BlurAppearance;
pub const BlurUpdate = EffectMetadata.BlurUpdate;
pub const WindowBlur = EffectMetadata.WindowBlurHandle;
pub const OutputBlurCache = EffectMetadata.OutputBlurCacheHandle;

fn metadata() *EffectMetadata {
    comptime std.debug.assert(build_options.vulkan_effects);
    return &@import("main.zig").server.effect_metadata;
}

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
pub fn createRenderer(backend: *wlr.Backend) !*wlr.Renderer {
    if (comptime build_options.vulkan_effects) {
        const c = @import("c");
        if (setenv("WLR_RENDERER", "vulkan", 1) != 0) {
            std.log.err("cannot select the wlroots Vulkan renderer: setenv failed", .{});
            return error.VulkanRendererSelectionFailed;
        }
        const renderer = wlr.Renderer.autocreate(backend) catch |err| {
            std.log.err("wlroots could not create the required Vulkan renderer: {s}", .{@errorName(err)});
            return error.VulkanRendererUnavailable;
        };
        if (!c.wlr_renderer_is_vk(@ptrCast(renderer))) {
            renderer.destroy();
            std.log.err("Vulkan effects require wlroots' Vulkan renderer, but another renderer was created", .{});
            return error.VulkanRendererUnavailable;
        }
        return renderer;
    }
    return wlr.Renderer.autocreate(backend);
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Set the corner radius of a single scene buffer node.
pub fn setBufferRadius(buffer: *wlr.SceneBuffer, radius: u31) void {
    if (comptime build_options.vulkan_effects) {
        metadata().setBufferRadius(buffer, radius) catch {
            std.log.err("could not store scene-buffer effect metadata: out of memory", .{});
            return;
        };
        const c = @import("c");
        c.wlr_scene_buffer_set_force_blend(
            @ptrCast(buffer),
            @intFromBool(radius != 0),
        );
    }
}

/// Set the corner radius of a single scene rect node.
pub fn setRectRadius(rect: *wlr.SceneRect, radius: u31) void {
    if (comptime build_options.vulkan_effects) {
        metadata().setRectRadius(rect, radius) catch {
            std.log.err("could not store scene-rect effect metadata: out of memory", .{});
            return;
        };
        const c = @import("c");
        c.wlr_scene_rect_set_force_blend(
            @ptrCast(rect),
            @intFromBool(metadata().rectData(rect) != null),
        );
    }
}

/// Include or exclude a visual rectangle from scene hit-testing.
pub fn setRectInputEnabled(rect: *wlr.SceneRect, enabled: bool) void {
    if (comptime build_options.vulkan_effects) {
        const c = @import("c");
        c.wlr_scene_rect_set_input_enabled(@ptrCast(rect), @intFromBool(enabled));
    }
}

/// Cut a rounded area out of a scene rect so the filled rect is rendered as one
/// stroked rounded rectangle without seams between antialiased nodes.
pub fn setRectClippedRegion(
    rect: *wlr.SceneRect,
    area: wlr.Box,
    radii: CornerRadii,
) void {
    if (comptime build_options.vulkan_effects) {
        metadata().setRectClippedRegion(rect, area, radii) catch {
            std.log.err("could not store scene-rect clip metadata: out of memory", .{});
            return;
        };
        const c = @import("c");
        c.wlr_scene_rect_set_force_blend(@ptrCast(rect), 1);
    }
}

/// Apply the given corner radius to every buffer node in the given subtree.
pub fn setTreeRadius(tree: *wlr.SceneTree, radius: u31) void {
    if (comptime !build_options.vulkan_effects) return;
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
// Backdrop blur, all comptime-gated like the corner-radius helpers above.
// ----------------------------------------------------------------------------

/// Whether blur state is available in this build.
pub const blur_available: bool = build_options.vulkan_effects;

/// Apply the scene-wide blur parameters. Setting radius or passes to 0 disables
/// blur, so the global on/off toggle is expressed by passing 0 when disabled.
pub fn setBlurParams(scene: *wlr.Scene, radius: c_int, passes: c_int, appearance: BlurAppearance) BlurUpdate {
    _ = scene;
    if (comptime build_options.vulkan_effects) {
        return metadata().setBlurConfig(radius, passes, appearance);
    }
    return .{ .kernel_changed = false, .appearance_changed = false };
}

/// Create the metadata that describes blur directly behind one window.
pub fn createWindowBlur(tree: *wlr.SceneTree) ?WindowBlur {
    if (comptime !blur_available) return null;

    const handle = metadata().createWindowBlur(tree) catch {
        std.log.err("could not create window-blur metadata: out of memory", .{});
        return null;
    };
    return handle;
}

/// Synchronize a window-local blur node with the visible portion of the window.
pub fn configureWindowBlur(
    blur_node: WindowBlur,
    box: wlr.Box,
    radius: u31,
    enabled: bool,
) void {
    if (comptime !blur_available) return;
    _ = metadata().configureWindowBlur(blur_node, box, radius, enabled);
}

/// Create an output-sized blur-cache record in logical output dimensions.
pub fn createOptimizedBlur(
    tree: *wlr.SceneTree,
    width: c_int,
    height: c_int,
) ?OutputBlurCache {
    if (comptime !blur_available) return null;

    const handle = metadata().createOutputBlurCache(tree, width, height) catch {
        std.log.err("could not create output blur-cache metadata: out of memory", .{});
        return null;
    };
    render_metrics.recordBlurCache(.create);
    return handle;
}

/// Synchronize the output-local geometry and enabled state of an optimized blur
/// node. `dirty` should only be set when the node's backdrop may have changed;
/// regenerating an optimized blur texture every frame defeats the optimization.
pub fn configureOptimizedBlur(
    blur_node: OutputBlurCache,
    box: wlr.Box,
    enabled: bool,
    dirty: bool,
) void {
    if (comptime !blur_available) return;
    _ = metadata().configureOutputBlurCache(blur_node, box, enabled, dirty);
    if (dirty) render_metrics.recordBlurCache(.configure_dirty);
}

pub fn markOptimizedBlurDirty(blur_node: OutputBlurCache) void {
    if (comptime !blur_available) return;
    _ = metadata().markOutputBlurCacheDirty(blur_node);
    render_metrics.recordBlurCache(.damage_dirty);
}

pub fn outputBlurCacheData(
    blur_node: OutputBlurCache,
) ?EffectMetadata.OutputBlurCacheData {
    if (comptime !build_options.vulkan_effects) return null;
    return metadata().outputBlurCacheData(blur_node);
}

pub fn setOptimizedBlurEnabled(blur_node: OutputBlurCache, enabled: bool) void {
    if (comptime !blur_available) return;
    _ = metadata().setOutputBlurCacheEnabled(blur_node, enabled);
    render_metrics.recordBlurCache(if (enabled) .enable else .disable);
}

pub fn destroyOptimizedBlur(blur_node: OutputBlurCache) void {
    if (comptime !blur_available) return;
    metadata().destroyOutputBlurCache(blur_node);
    render_metrics.recordBlurCache(.destroy);
}

/// Synchronize compositor-owned visual state for every buffer in a tree.
/// Opacity below 1 invalidates the client's opaque-region hint because the
/// resulting pixels still need blending. At opacity 1, restore the backing
/// surface's authoritative hint. Recurse manually so disabled transaction trees
/// are updated too.
pub fn setTreeOpacity(tree: *wlr.SceneTree, opacity: f32) void {
    setNodeOpacity(&tree.node, opacity);
}

fn setNodeOpacity(node: *wlr.SceneNode, opacity: f32) void {
    switch (node.type) {
        .buffer => syncBufferVisualState(wlr.SceneBuffer.fromNode(node), opacity),
        .tree => {
            const tree: *wlr.SceneTree = @fieldParentPtr("node", node);
            var it = tree.children.iterator(.forward);
            while (it.next()) |child| setNodeOpacity(child, opacity);
        },
        else => {},
    }
}

fn syncBufferVisualState(buffer: *wlr.SceneBuffer, opacity: f32) void {
    buffer.setOpacity(opacity);

    switch (visual_state.opaqueRegionPolicy(opacity)) {
        .empty => {
            var empty: pixman.Region32 = undefined;
            empty.init();
            defer empty.deinit();
            buffer.setOpaqueRegion(&empty);
        },
        .client => if (wlr.SceneSurface.tryFromBuffer(buffer)) |scene_surface| {
            buffer.setOpaqueRegion(&scene_surface.surface.current.@"opaque");
        },
    }
}

/// Copy backend-specific attributes into a transaction snapshot. Fresh clone
/// buffers would otherwise reset their corners and effective opaque-region hint.
pub fn copyBufferFx(dst: *wlr.SceneBuffer, src: *wlr.SceneBuffer) void {
    if (comptime build_options.vulkan_effects) {
        const c = @import("c");
        dst.setOpaqueRegion(&src.opaque_region);
        metadata().copyBufferData(dst, src) catch {
            std.log.err("could not copy scene-buffer effect metadata: out of memory", .{});
            c.wlr_scene_buffer_set_force_blend(@ptrCast(dst), 0);
            return;
        };
        c.wlr_scene_buffer_set_force_blend(
            @ptrCast(dst),
            @intFromBool(metadata().bufferData(dst) != null),
        );
    }
}
