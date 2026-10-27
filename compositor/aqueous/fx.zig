// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Backend-neutral facade for compositor visual effects.

const build_options = @import("build_options");
const std = @import("std");
const wlr = @import("wlroots");
const EffectMetadata = @import("render/EffectMetadata.zig");
const render_metrics = @import("render_metrics.zig");
const scene_opacity = @import("scene_opacity.zig");

/// Default corner radius (in layout pixels) for window content and borders.
/// Integrated policy supplies the configured radius on each placement.
/// Builds with no effects backend retain square corners.
pub const default_corner_radius: u31 =
    if (build_options.vulkan_effects) 15 else 0;

pub const CornerRadii = EffectMetadata.CornerRadii;
pub const BufferClip = EffectMetadata.BufferClip;
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

/// Apply a window mask expressed relative to this buffer's destination origin.
pub fn setBufferClip(buffer: *wlr.SceneBuffer, clip: ?BufferClip) void {
    if (comptime build_options.vulkan_effects) {
        const changed = metadata().setBufferClip(buffer, clip) catch {
            std.log.err("could not store scene-buffer effect metadata: out of memory", .{});
            return;
        };
        if (!changed) return;
        const c = @import("c");
        c.wlr_scene_buffer_set_force_blend(
            @ptrCast(buffer),
            @intFromBool(clip != null),
        );
        // Updating an existing mask doesn't change force_blend, so wlroots
        // cannot otherwise observe this appearance-only scene change.
        var outputs = @import("main.zig").server.om.outputs.iterator(.forward);
        while (outputs.next()) |output| output.damageBufferEffects(buffer);
    }
}

pub fn bufferClip(buffer: *wlr.SceneBuffer) ?BufferClip {
    if (comptime !build_options.vulkan_effects) return null;
    return if (metadata().bufferData(buffer)) |data| data.clip else null;
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

/// Each surface sees the same window silhouette, including offset subsurfaces.
pub fn setTreeClip(tree: *wlr.SceneTree, clip: ?BufferClip) void {
    if (comptime !build_options.vulkan_effects) return;
    // Walk disabled staging trees too: transaction snapshots must retain their
    // own frozen mask, and newly enabled buffers must already have metadata.
    setNodeClip(&tree.node, clip, 0, 0);
}

fn setNodeClip(node: *wlr.SceneNode, clip: ?BufferClip, x: i32, y: i32) void {
    const sx = x + node.x;
    const sy = y + node.y;
    switch (node.type) {
        .tree => {
            const tree = wlr.SceneTree.fromNode(node);
            var it = tree.children.iterator(.forward);
            while (it.next()) |child| setNodeClip(child, clip, sx, sy);
        },
        .buffer => setBufferClip(wlr.SceneBuffer.fromNode(node), if (clip) |mask|
            mask.translated(-@as(f64, @floatFromInt(sx)), -@as(f64, @floatFromInt(sy)))
        else
            null),
        .rect => {},
    }
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

pub fn destroyWindowBlur(blur_node: WindowBlur) void {
    if (comptime !blur_available) return;
    metadata().destroyWindowBlur(blur_node);
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

/// Apply opacity while preserving wlroots' format-, clip- and scale-adjusted
/// opaque region. wlroots already excludes translucent buffers from occlusion.
pub fn setTreeOpacity(tree: *wlr.SceneTree, opacity: f32) void {
    scene_opacity.apply(&tree.node, opacity);
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
        // Snapshot HDR policy alone does not require rounded-edge blending.
        const rounded = if (metadata().bufferData(dst)) |effect|
            effect.clip != null
        else
            false;
        c.wlr_scene_buffer_set_force_blend(@ptrCast(dst), @intFromBool(rounded));
    }
}
