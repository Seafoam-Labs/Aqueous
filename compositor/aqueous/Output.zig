// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Output = @This();

const std = @import("std");
const build_options = @import("build_options");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;
const pixman = @import("pixman");
const wlr = @import("wlroots");
const c = if (build_options.vulkan_effects) @import("c") else struct {
    const struct_wlr_box = opaque {};
    const struct_wlr_render_pass = opaque {};
    const struct_wlr_scene_buffer = opaque {};
    const struct_wlr_scene_node = opaque {};
    const struct_wlr_scene_rect = opaque {};
    const struct_wlr_render_texture_options = opaque {};
    const struct_wlr_render_rect_options = opaque {};
    const struct_wlr_vk_render_texture_attribs = opaque {};
};
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const scaling = @import("scaling");
const render_metrics = @import("render_metrics.zig");
const visual_state = @import("visual_state.zig");
pub const hdr = @import("output_hdr.zig");
const auto_hdr = @import("auto_hdr.zig");
const color_management = @import("color_management.zig");

const fx = @import("fx.zig");
const BlurPipeline = @import("render/BlurPipeline.zig");
const EffectMetadata = @import("render/EffectMetadata.zig");
const LayerSurface = @import("LayerSurface.zig");
const LayerShellOutput = @import("LayerShellOutput.zig");
const LockSurface = @import("LockSurface.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.output);

pub const State = struct {
    pub const PositionSource = enum {
        automatic,
        configuration,
        output_management,
    };

    state: enum {
        /// Powered on and exposed to the window manager
        enabled,
        /// Powered off and exposed to the window manager
        disabled_soft,
        /// Powered off and hidden from the window manager
        disabled_hard,
        /// Corresponding hardware no longer present
        destroying,
    },
    /// Logical coordinate space
    x: i32,
    /// Logical coordinate space
    y: i32,
    /// The width/height of modes is in physical pixels, not in the
    /// compositors logical coordinate space.
    mode: union(enum) {
        standard: *wlr.Output.Mode,
        custom: struct {
            width: i32,
            height: i32,
            refresh: i32,
        },
        /// Used before the initial modeset and after the wlr_output is destroyed.
        none,
    },
    scale: f32,
    transform: wl.Output.Transform,
    adaptive_sync: bool,
    /// Enable the BT.2020/PQ HDR10 output profile.
    hdr_enabled: bool,
    /// Target peak luminance preset for the HDR10 mastering metadata.
    hdr_level: hdr.HdrLevel,
    /// SDR diffuse white luminance on the HDR output, in cd/m².
    sdr_white_level: f64,
    /// Expand SDR highlights toward the HDR peak (Auto HDR). Takes effect
    /// only while HDR is active and the effects build can draw the buffer.
    auto_hdr: bool,
    /// Auto HDR expansion strength, 0..1.
    auto_hdr_boost: f64,
    position_source: PositionSource,

    pub fn fromHeadState(state: *const wlr.OutputHeadV1.State) State {
        assert(state.enabled);
        const requested_scale: f32 = @floatCast(state.scale);
        const normalized_scale = scaling.normalizeScale(requested_scale);
        if (normalized_scale != requested_scale) {
            std.log.scoped(.output).info(
                "output {s}: scale {d} adjusted to {d}",
                .{ state.output.name, requested_scale, normalized_scale },
            );
        }
        return .{
            .state = .enabled,
            .mode = blk: {
                if (state.mode) |mode| {
                    break :blk .{ .standard = mode };
                } else {
                    break :blk .{ .custom = .{
                        .width = state.custom_mode.width,
                        .height = state.custom_mode.height,
                        .refresh = state.custom_mode.refresh,
                    } };
                }
            },
            .x = state.x,
            .y = state.y,
            .scale = normalized_scale,
            .transform = state.transform,
            .adaptive_sync = state.adaptive_sync_enabled,
            // wlr-output-management-v1 has no HDR field. Callers replacing
            // existing state through that protocol preserve this separately.
            .hdr_enabled = false,
            .hdr_level = .l1000,
            .sdr_white_level = hdr.default_sdr_white_level,
            .auto_hdr = false,
            .auto_hdr_boost = auto_hdr.default_boost,
            .position_source = .output_management,
        };
    }

    /// Width/height in the logical coordinate space
    pub fn dimensions(state: *const State) struct { u31, u31 } {
        var w: i32, var h: i32 = switch (state.mode) {
            .standard => |mode| .{ mode.width, mode.height },
            .custom => |mode| .{ mode.width, mode.height },
            .none => .{ 0, 0 },
        };
        if (@mod(@intFromEnum(state.transform), 2) != 0) {
            mem.swap(i32, &w, &h);
        }
        return .{
            scaling.logicalDimension(w, state.scale),
            scaling.logicalDimension(h, state.scale),
        };
    }

    pub fn box(state: *const State) wlr.Box {
        const w, const h = state.dimensions();
        return .{ .x = state.x, .y = state.y, .width = w, .height = h };
    }

    pub fn applyNoModeset(state: *const State, wlr_state: *wlr.Output.State) void {
        wlr_state.setScale(state.scale);
        wlr_state.setTransform(state.transform);
    }

    pub fn applyModeset(state: *const State, wlr_output: *wlr.Output, wlr_state: *wlr.Output.State) bool {
        const enabled = state.state == .enabled;
        wlr_state.setEnabled(enabled);
        if (!enabled) return true;
        state.applyNoModeset(wlr_state);
        switch (state.mode) {
            .standard => |mode| wlr_state.setMode(mode),
            .custom => |mode| wlr_state.setCustomMode(mode.width, mode.height, mode.refresh),
            .none => {},
        }
        wlr_state.setAdaptiveSyncEnabled(state.adaptive_sync);
        return hdr.apply(wlr_output, state.hdr_enabled, state.hdr_level, state.sdr_white_level, wlr_state);
    }
};

const RenderingState = struct {
    tearing: bool,
    const init: RenderingState = .{
        .tearing = false,
    };
};

/// Set to null when the wlr_output is destroyed.
wlr_output: ?*wlr.Output,
scene_output: ?*wlr.SceneOutput,

object: ?*river.OutputV1 = null,
layer_shell: LayerShellOutput = .{},

/// Tracks the currently presented frame on the output as it pertains to ext-session-lock.
/// The output is initially considered blanked:
/// If using the DRM backend it will be blanked with the initial modeset.
/// If using the Wayland or X11 backend nothing will be visible until the first frame is rendered.
lock_render_state: enum {
    /// Submitted an unlocked buffer but the buffer has not yet been presented.
    pending_unlock,
    /// Normal, "unlocked" content may be visible.
    unlocked,
    /// Submitted a blank buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_blank,
    /// A blank buffer has been presented.
    blanked,
    /// Submitted the lock surface buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_lock_surface,
    /// The lock surface buffer has been presented.
    lock_surface,
} = .blanked,

/// Root.outputs
link: wl.list.Link,

/// Ordered list of workspaces belonging to this output.
workspaces: wl.list.Head(Workspace, .link),
/// The single workspace currently visible on this output.
active_workspace: ?*Workspace = null,

/// Workspace currently sliding out during a switch (null when not
/// transitioning). A non-null value is the single source of truth that a
/// workspace-swap slide animation is in flight on this output.
prev_workspace: ?*Workspace = null,
/// Sign of the slide direction during a transition: +1 means the incoming
/// workspace enters from the right (outgoing exits left), -1 the reverse.
transition_dir: i32 = 0,
/// True once `renderFinish` has actually armed the current workspace-swap
/// slide. Guards `finalizeTransition` against running before the (async)
/// windowing transaction has seeded/armed the participating windows, which
/// would otherwise cancel the transition before it visibly begins.
transition_armed: bool = false,

/// State to be sent to the wm in the next manage sequence.
scheduled: State,
/// State sent to the wm in the latest manage sequence.
sent: State,
link_sent: wl.list.Link,
sent_wl_output: bool = false,
/// The wl_output global for which `river_output_v1.wl_output` was last sent.
/// Tracked so the event is re-sent if wlroots destroys and recreates the
/// global (e.g. on hotplug/modeset), which would otherwise leave the wm
/// client referencing a stale global name.
sent_wl_output_global: ?*wl.Global = null,
/// Rendering state requested by the window manager.
rendering_requested: RenderingState = .init,
/// State applied to the wlr_output and rendered.
current: State,
rendering_current: RenderingState = .init,

/// Monotonic timestamp (nanoseconds) of the previous frame, used to compute the
/// frame-rate-independent delta time for window position animations. 0 means no
/// previous frame has been recorded yet.
anim_last_ns: i64 = 0,

/// Backend-specific backdrop blur cache for this output. `blur_box` records
/// the geometry used to produce the cached texture so moves and modesets can
/// invalidate it without forcing regeneration on every frame.
blur_node: ?fx.OutputBlurCache = null,
blur_box: ?wlr.Box = null,
render_metric_sample: ?render_metrics.SceneSample = null,
effects_swapchain_path: bool = false,
blur_last_key: ?u64 = null,
blur_cache: if (build_options.vulkan_effects) BlurPipeline.OutputCache else void =
    if (build_options.vulkan_effects) .{} else {},

destroy: wl.Listener(*wlr.Output) = .init(handleDestroy),
request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
frame: wl.Listener(*wlr.Output) = .init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = .init(handlePresent),
commit: wl.Listener(*wlr.Output.event.Commit) = .init(handleCommit),
bind: wl.Listener(*wlr.Output.event.Bind) = .init(handleBind),

/// Stable identity used by the in-process policy. This is deliberately derived from the
/// output object's address only for the lifetime of the output; policy state is discarded
/// when the output no longer appears in a manage-cycle snapshot.
pub fn policyId(output: *const Output) u64 {
    return @intFromPtr(output);
}

fn boxesEqual(a: wlr.Box, b: wlr.Box) bool {
    return a.x == b.x and a.y == b.y and
        a.width == b.width and a.height == b.height;
}

/// Synchronize the output-local optimized blur node with the current output
/// state. Scene graph coordinates are logical, matching State.box().
pub fn syncBlur(output: *Output, force_dirty: bool) void {
    if (comptime !fx.blur_available) return;

    const active = server.wm.blur.enabled and
        server.wm.blur.radius > 0 and
        server.wm.blur.passes > 0 and
        output.current.state == .enabled and
        output.current.mode != .none;
    if (!active) {
        if (output.blur_node) |node| fx.setOptimizedBlurEnabled(node, false);
        if (comptime build_options.vulkan_effects) {
            output.blur_cache.clear(&server.vulkan_context.blur_pipeline);
        }
        // Re-enabling must regenerate the cached backdrop even if the output
        // returns with identical geometry.
        output.blur_box = null;
        return;
    }

    const box = output.current.box();
    if (box.width == 0 or box.height == 0) return;

    var created = false;
    if (output.blur_node == null) {
        output.blur_node = fx.createOptimizedBlur(
            server.scene.layers.wm,
            box.width,
            box.height,
        );
        created = output.blur_node != null;
    }

    const node = output.blur_node orelse return;
    const geometry_changed = if (output.blur_box) |old| !boxesEqual(old, box) else true;
    fx.configureOptimizedBlur(node, box, true, force_dirty or created or geometry_changed);
    output.blur_box = box;

    if (created or geometry_changed) {
        const name = if (output.wlr_output) |wlr_output| std.mem.span(wlr_output.name) else "unknown";
        log.debug("blur node for {s}: {d}x{d} at {d},{d}", .{
            name,
            box.width,
            box.height,
            box.x,
            box.y,
        });
    }
}

/// Propagate a background/bottom layer change to the active effects backend.
pub fn markBlurDirty(output: *Output) void {
    if (comptime !fx.blur_available) return;
    if (!server.wm.blur.enabled or output.current.state != .enabled) return;
    if (comptime build_options.vulkan_effects) {
        const wlr_output = output.wlr_output orelse return;
        wlr_output.scheduleFrame();
        return;
    }
    if (output.blur_node) |node| fx.markOptimizedBlurDirty(node);
}

/// Repaint appearance-only blur changes while retaining the cached blur source.
pub fn damageBlurAppearance(output: *Output) void {
    if (comptime !fx.blur_available) return;
    const scene_output = output.scene_output orelse return;
    scene_output.damage_ring.addWhole();
}

fn destroyBlur(output: *Output) void {
    if (comptime build_options.vulkan_effects) {
        output.blur_cache.deinit(&server.vulkan_context.blur_pipeline);
    }
    if (comptime !fx.blur_available) return;
    if (output.blur_node) |node| fx.destroyOptimizedBlur(node);
    output.blur_node = null;
    output.blur_box = null;
}

pub fn releaseVulkanBlurCache(output: *Output) void {
    if (comptime build_options.vulkan_effects) {
        output.blur_cache.clear(&server.vulkan_context.blur_pipeline);
    }
}

/// Scene-order changes alter which previously rendered windows are present at
/// each blur checkpoint even when every blur box is unchanged. Advance the
/// shared source generation so a focus-driven restack cannot reuse a cache
/// image captured under the old ordering.
pub fn invalidateBlurSources(output: *Output) void {
    if (comptime !fx.blur_available) return;
    if (!server.wm.blur.enabled or output.current.state != .enabled) return;
    const node = output.blur_node orelse return;

    // A generation mismatch rebuilds each complete cache domain. Damage those
    // same domains so the offscreen source is reconstructed under the new
    // scene order instead of sampling untouched pixels from the prior frame.
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        output.damageBlurOwnerDomain(.{ .window = window });
    }
    var layers = server.layer_shell.surfaces.iterator();
    while (layers.next()) |surface| {
        output.damageBlurOwnerDomain(.{ .layer_surface = surface });
    }
    var popups = server.layer_shell.popups.iterator();
    while (popups.next()) |popup| {
        output.damageBlurOwnerDomain(.{ .popup = popup });
    }

    fx.markOptimizedBlurDirty(node);
}

fn damageBlurOwnerDomain(output: *Output, owner: BlurOwner) void {
    const blur = blurOwnerData(owner) orelse return;
    const effect = blurOwnerEffect(
        owner,
        blur,
        output.effectRenderState(),
    ) orelse return;
    var box: wlr.Box = .{
        .x = effect.box.x,
        .y = effect.box.y,
        .width = effect.box.width,
        .height = effect.box.height,
    };
    output.scene_output.?.damage_ring.addBox(&box);
}

fn finishRenderMetric(output: *Output) void {
    const wlr_output = output.wlr_output orelse return;
    if (output.render_metric_sample) |*sample| {
        sample.finish(std.mem.span(wlr_output.name));
        output.render_metric_sample = null;
    }
}

fn discardRenderMetric(output: *Output) void {
    if (output.render_metric_sample) |*sample| {
        sample.discard();
        output.render_metric_sample = null;
    }
}

/// Full output geometry exposed to the in-process policy.
pub fn policyFullBox(output: *const Output) wlr.Box {
    return output.scheduled.box();
}

/// Hard-disabled and destroyed outputs are absent from integrated-policy
/// snapshots. Soft-disabled outputs intentionally remain exposed to preserve
/// their workspace model while powered off.
pub fn policyExposed(output: *const Output) bool {
    return output.scheduled.state == .enabled or output.scheduled.state == .disabled_soft;
}

/// A pointer drag may only enter a visible, powered output.
pub fn policyTransferTarget(output: *const Output) bool {
    return output.scheduled.state == .enabled and output.active_workspace != null;
}

/// Output geometry remaining after layer-shell exclusive zones are reserved.
pub fn policyUsableBox(output: *const Output) wlr.Box {
    const usable = output.layer_shell.scheduled.non_exclusive_area;
    if (usable.width > 0 and usable.height > 0) return usable;
    return output.policyFullBox();
}

pub fn policyName(output: *const Output) []const u8 {
    return if (output.wlr_output) |wlr_output| std.mem.span(wlr_output.name) else "";
}

pub const PolicyIdentity = struct {
    name: []const u8,
    make: ?[]const u8,
    model: ?[]const u8,
    serial: ?[]const u8,
};

pub fn policyIdentity(output: *const Output) PolicyIdentity {
    const wlr_output = output.wlr_output orelse return .{ .name = "", .make = null, .model = null, .serial = null };
    return .{
        .name = std.mem.span(wlr_output.name),
        .make = if (wlr_output.make) |value| std.mem.span(value) else null,
        .model = if (wlr_output.model) |value| std.mem.span(value) else null,
        .serial = if (wlr_output.serial) |value| std.mem.span(value) else null,
    };
}

pub fn policyActiveWorkspaceNumber(output: *Output) u32 {
    const active = output.active_workspace orelse return 0;
    var number: u32 = 1;
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| : (number += 1) if (workspace == active) return number;
    return 0;
}

pub fn policyWorkspaceAt(output: *Output, requested: u32) ?*Workspace {
    if (requested == 0) return null;
    var number: u32 = 1;
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| : (number += 1) if (number == requested) return workspace;
    return null;
}

pub fn policyWorkspaceActive(output: *const Output, workspace: ?*const Workspace) bool {
    return workspace == null or workspace == output.active_workspace;
}

pub fn policyTrace(output: *const Output, hasher: *std.hash.Wyhash) void {
    const name = if (output.wlr_output) |wlr_output| std.mem.span(wlr_output.name) else "";
    hasher.update(name);
    const workspace_id: u32 = if (output.active_workspace) |workspace| workspace.policyId() else 0;
    hasher.update(std.mem.asBytes(&workspace_id));
}

pub fn create(wlr_output: *wlr.Output) !void {
    const output = try util.gpa.create(Output);
    errdefer util.gpa.destroy(output);

    {
        const title = try fmt.allocPrintSentinel(util.gpa, "river - {s}", .{wlr_output.name}, 0);
        defer util.gpa.free(title);
        if (wlr_output.isWl()) {
            wlr_output.wlSetAppId("river");
            wlr_output.wlSetTitle(title);
        } else if (wlr.config.has_x11_backend and wlr_output.isX11()) {
            wlr_output.x11SetTitle(title);
        }
    }

    if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

    const scene_output = try server.scene.wlr_scene.createSceneOutput(wlr_output);
    errdefer comptime unreachable;

    const initial: State = .{
        .state = .disabled_hard,
        .x = 0,
        .y = 0,
        .mode = .none,
        .scale = 1,
        .transform = .normal,
        .adaptive_sync = wlr_output.adaptive_sync_status == .enabled,
        .hdr_enabled = false,
        .hdr_level = .l1000,
        .sdr_white_level = hdr.default_sdr_white_level,
        .auto_hdr = false,
        .auto_hdr_boost = auto_hdr.default_boost,
        .position_source = .automatic,
    };
    output.* = .{
        .wlr_output = wlr_output,
        .scene_output = scene_output,
        .scheduled = initial,
        .sent = initial,
        .current = initial,
        .link = undefined,
        .link_sent = undefined,
        .workspaces = undefined,
    };
    wlr_output.data = output;
    if (comptime build_options.vulkan_effects) {
        c.wlr_scene_output_set_buffer_render_hook(
            @ptrCast(scene_output),
            roundedBufferHook,
            output,
        );
        c.wlr_scene_output_set_buffer_needs_composition(
            @ptrCast(scene_output),
            roundedBufferNeedsComposition,
        );
        c.wlr_scene_output_set_rect_render_hook(
            @ptrCast(scene_output),
            roundedRectHook,
        );
        c.wlr_scene_output_set_render_hooks(
            @ptrCast(scene_output),
            effectsRenderBegin,
            effectsNodeRender,
        );
    }

    server.om.outputs.append(output);
    output.link_sent.init();
    output.workspaces.init();
    output.ensureWorkspaces();

    wlr_output.events.destroy.add(&output.destroy);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);
    wlr_output.events.commit.add(&output.commit);
    wlr_output.events.bind.add(&output.bind);

    output.scheduled.state = .enabled;
    if (wlr_output.preferredMode()) |preferred_mode| {
        output.scheduled.mode = .{ .standard = preferred_mode };
    } else {
        // The output does not support modes (i.e. we are not using the DRM backend)
        // Currently, wlroots does not make it possible for us know the dimensions
        // requested by the host compositor in the first configure event. Therefore,
        // we can't do anything but guess until the second configure is sent and
        // wlroots emits the wlr_output request_state event.
        // TODO(wlroots): fix this API limitation, for context see
        // https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/4963
        output.scheduled.mode = .{ .custom = .{ .width = 1280, .height = 720, .refresh = 0 } };
    }

    server.wm.dirtyWindowing();
}

fn roundedBufferHook(
    c_scene_buffer: ?*c.struct_wlr_scene_buffer,
    options: ?*const c.struct_wlr_render_texture_options,
    attributes: ?*const c.struct_wlr_vk_render_texture_attribs,
    data: ?*anyopaque,
) callconv(.c) bool {
    if (comptime !build_options.vulkan_effects) return false;
    const output: *Output = @ptrCast(@alignCast(data orelse return false));
    const scene_buffer: *wlr.SceneBuffer =
        @ptrCast(@alignCast(c_scene_buffer orelse return false));
    const effect = server.effect_metadata.bufferData(scene_buffer);
    const itm = output.autoHdrExpansion(scene_buffer);
    if (effect == null and itm == null) return false;
    // Corner clipping with zero radii degenerates to full coverage, so an
    // Auto-HDR-only buffer can share the rounded texture draw.
    const radii: EffectMetadata.CornerRadii =
        if (effect) |entry| entry.radii else EffectMetadata.CornerRadii.uniform(0);
    return server.vulkan_context.rounded_pipeline.drawTexture(
        attributes orelse return false,
        options orelse return false,
        radii,
        output.effectRenderState().scale,
        output.effects_swapchain_path,
        itm,
    ) catch |err| {
        log.err("Vulkan rounded texture draw failed: {s}", .{@errorName(err)});
        return false;
    };
}

/// Resolve the Auto HDR expansion for one buffer draw, or null when the
/// buffer keeps the stock SDR path. Expansion applies to relative-luminance
/// (SDR) content owned by policy-eligible windows on an HDR output;
/// absolute-luminance PQ content and non-window surfaces are untouched.
fn autoHdrExpansion(output: *Output, scene_buffer: *wlr.SceneBuffer) ?auto_hdr.ItmParams {
    const wlr_output = output.wlr_output orelse return null;
    if (!hdr.active(wlr_output)) return null;
    const state = output.effectRenderState();
    if (!state.auto_hdr) return null;
    const native_windows_hdr = if (comptime build_options.vulkan_effects)
        if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface|
            color_management.surfaceHasWindowsHdrDescription(scene_surface.surface)
        else
            false
    else
        false;
    if (!auto_hdr.shouldExpandContent(
        scene_buffer.transfer_function == .st2084_pq,
        native_windows_hdr,
    )) return null;
    const window = windowForNode(&scene_buffer.node) orelse return null;
    const eligible = window.hdr_expand_rule orelse (window.wm_requested.fullscreen != null);
    if (!eligible) return null;
    const peak_nits: f64 = @floatFromInt(state.hdr_level.nits());
    return .{
        .peak = @floatCast(peak_nits / 203.0),
        .boost = @floatCast(std.math.clamp(state.auto_hdr_boost, 0.0, 1.0)),
    };
}

fn windowForNode(node: *wlr.SceneNode) ?*Window {
    const scene_node_data = SceneNodeData.fromNode(node) orelse return null;
    return switch (scene_node_data.data) {
        .window => |window| window,
        else => null,
    };
}

fn roundedBufferNeedsComposition(
    c_scene_buffer: ?*c.struct_wlr_scene_buffer,
    _: ?*anyopaque,
) callconv(.c) bool {
    if (comptime !build_options.vulkan_effects) return false;
    const scene_buffer: *wlr.SceneBuffer =
        @ptrCast(@alignCast(c_scene_buffer orelse return false));
    const rounded = if (server.effect_metadata.bufferData(scene_buffer)) |effect|
        hasRadius(effect.radii)
    else
        false;
    return visual_state.effectsRequireComposition(
        rounded,
        bufferNeedsBackdropBlur(scene_buffer),
    );
}

fn bufferNeedsBackdropBlur(scene_buffer: *wlr.SceneBuffer) bool {
    return blurOwnerForNode(&scene_buffer.node) != null;
}

fn roundedRectHook(
    render_pass: ?*c.struct_wlr_render_pass,
    c_scene_rect: ?*c.struct_wlr_scene_rect,
    options: ?*const c.struct_wlr_render_rect_options,
    data: ?*anyopaque,
) callconv(.c) bool {
    if (comptime !build_options.vulkan_effects) return false;
    const output: *Output = @ptrCast(@alignCast(data orelse return false));
    const scene_rect: *wlr.SceneRect =
        @ptrCast(@alignCast(c_scene_rect orelse return false));
    if (isBlurMarker(scene_rect)) return true;
    const effect = server.effect_metadata.rectData(scene_rect) orelse
        return false;
    const rect_options = options orelse return false;
    const geometry = output.rectEffect(scene_rect, rect_options, effect) orelse
        return false;
    return server.vulkan_context.rounded_pipeline.drawRect(
        render_pass orelse return false,
        rect_options,
        geometry,
        output.effects_swapchain_path,
    ) catch |err| {
        log.err("Vulkan rounded rect draw failed: {s}", .{@errorName(err)});
        return false;
    };
}

fn isBlurMarker(scene_rect: *wlr.SceneRect) bool {
    const owner = blurOwnerForNode(&scene_rect.node) orelse return false;
    return scene_rect == blurOwnerMarker(owner);
}

fn effectRenderState(output: *const Output) *const State {
    return if (output.effects_swapchain_path) &output.sent else &output.current;
}

fn effectsRenderBegin(
    _: ?*c.struct_wlr_render_pass,
    content_damage: ?*const c.pixman_region32_t,
    data: ?*anyopaque,
) callconv(.c) u32 {
    if (comptime !build_options.vulkan_effects) return 0;
    const output: *Output = @ptrCast(@alignCast(data orelse return 0));
    output.blur_last_key = null;
    if (uncachedBlurRequested()) return 0;
    output.blur_cache.beginFrame(content_damage);
    const config = server.effect_metadata.blurConfig();
    const kernel = BlurPipeline.resolveKernel(
        config.radius,
        config.passes,
        output.effectRenderState().scale,
    ) orelse return 0;
    var preserved: u32 = 0;
    var affected = false;
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        prepareBlurOwner(
            output,
            .{ .window = window },
            content_damage,
            kernel,
            &preserved,
            &affected,
        );
    }
    var layer_surfaces = server.layer_shell.surfaces.iterator();
    while (layer_surfaces.next()) |layer_surface| {
        prepareBlurOwner(
            output,
            .{ .layer_surface = layer_surface },
            content_damage,
            kernel,
            &preserved,
            &affected,
        );
    }
    var popups = server.layer_shell.popups.iterator();
    while (popups.next()) |popup| {
        prepareBlurOwner(
            output,
            .{ .popup = popup },
            content_damage,
            kernel,
            &preserved,
            &affected,
        );
    }
    output.blur_cache.removeInvisible(
        &server.vulkan_context.blur_pipeline,
    );
    server.vulkan_context.blur_pipeline.recordCacheHits(
        &output.blur_cache,
        preserved,
    );
    return if (affected)
        EffectMetadata.cachedBlurRenderReach(kernel)
    else
        0;
}

fn prepareBlurOwner(
    output: *Output,
    owner: BlurOwner,
    content_damage: ?*const c.pixman_region32_t,
    kernel: BlurPipeline.Kernel,
    preserved: *u32,
    affected: *bool,
) void {
    const handle = blurOwnerHandle(owner) orelse return;
    const blur = blurOwnerData(owner) orelse return;
    const effect = blurOwnerEffect(
        owner,
        blur,
        output.effectRenderState(),
    ) orelse return;
    const ready = output.blur_cache.markVisible(@bitCast(handle.key));
    if (expandedRenderRegionIntersects(
        content_damage,
        effect.box,
        kernel.reach,
    )) {
        affected.* = true;
    } else if (ready) {
        preserved.* += 1;
    }
}

fn effectsNodeRender(
    render_pass: ?*c.struct_wlr_render_pass,
    c_node: ?*c.struct_wlr_scene_node,
    render_region: ?*const c.pixman_region32_t,
    data: ?*anyopaque,
) callconv(.c) void {
    if (comptime !build_options.vulkan_effects) return;
    const output: *Output = @ptrCast(@alignCast(data orelse return));
    const node: *wlr.SceneNode =
        @ptrCast(@alignCast(c_node orelse return));
    const owner = blurOwnerForNode(node) orelse return;
    if (node != &blurOwnerMarker(owner).node) return;
    const handle = blurOwnerHandle(owner) orelse return;
    const key: u64 = @bitCast(handle.key);
    if (output.blur_last_key == key) return;
    output.blur_last_key = key;

    const blur = blurOwnerData(owner) orelse return;
    const state = output.effectRenderState();
    const effect = blurOwnerEffect(owner, blur, state) orelse return;
    const config = server.effect_metadata.blurConfig();
    const pass = render_pass orelse return;
    const clip = render_region orelse return;
    const rendered = if (uncachedBlurRequested())
        server.vulkan_context.blur_pipeline.render(
            pass,
            effect,
            clip,
            config.radius,
            config.passes,
            state.scale,
            config.appearance,
        )
    else blk: {
        const output_cache = if (output.blur_node) |cache_node|
            fx.outputBlurCacheData(cache_node)
        else
            null;
        break :blk server.vulkan_context.blur_pipeline.renderCached(
            &output.blur_cache,
            pass,
            key,
            effect,
            clip,
            blur.generation,
            config.generation,
            if (output_cache) |cache| cache.invalidation_generation else 0,
            config.radius,
            config.passes,
            state.scale,
            config.appearance,
        );
    };
    _ = rendered catch |err| {
        log.err("Vulkan backdrop blur failed: {s}", .{@errorName(err)});
        return;
    };
}

const BlurOwner = union(enum) {
    window: *Window,
    layer_surface: *LayerSurface,
    popup: *XdgPopup,
};

fn blurOwnerHandle(owner: BlurOwner) ?EffectMetadata.WindowBlurHandle {
    return switch (owner) {
        .window => |window| window.backdrop_blur,
        .layer_surface => |surface| surface.backdrop_blur,
        .popup => |popup| popup.backdrop_blur,
    };
}

fn blurOwnerTree(owner: BlurOwner) *wlr.SceneTree {
    return switch (owner) {
        .window => |window| if (window.anim_snapshot)
            window.anim_tree
        else
            window.tree,
        .layer_surface => |surface| surface.scene_layer_surface.tree,
        .popup => |popup| popup.tree,
    };
}

fn blurOwnerMarker(owner: BlurOwner) *wlr.SceneRect {
    return switch (owner) {
        .window => |window| if (window.anim_snapshot)
            window.anim_blur_marker
        else
            window.blur_marker,
        .layer_surface => |surface| surface.blur_marker,
        .popup => |popup| popup.blur_marker,
    };
}

/// Animation snapshots are deliberately input-inert and therefore carry no
/// SceneNodeData. Fall back to the window registry only for those snapshots.
fn blurOwnerForNode(node: *wlr.SceneNode) ?BlurOwner {
    if (SceneNodeData.fromNode(node)) |owner| {
        switch (owner.data) {
            .window => |window| if (nodeInTree(node, windowBlurTree(window)) and
                windowBlurData(window) != null)
                return .{ .window = window },
            .layer_surface => |surface| if (nodeInTree(
                node,
                surface.scene_layer_surface.tree,
            ) and blurOwnerData(.{ .layer_surface = surface }) != null)
                return .{ .layer_surface = surface },
            else => {},
        }
    }
    var popup_match: ?BlurOwner = null;
    var popup_distance: usize = math.maxInt(usize);
    var popups = server.layer_shell.popups.iterator();
    while (popups.next()) |popup| {
        const popup_owner: BlurOwner = .{ .popup = popup };
        if (blurOwnerData(popup_owner) == null) continue;
        const distance = nodeDistanceInTree(node, popup.tree) orelse continue;
        if (distance >= popup_distance) continue;
        popup_match = popup_owner;
        popup_distance = distance;
    }
    if (popup_match) |owner| return owner;
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        if (windowBlurData(window) != null and
            nodeInTree(node, windowBlurTree(window)))
        {
            return .{ .window = window };
        }
    }
    return null;
}

fn windowBlurTree(window: *Window) *wlr.SceneTree {
    return blurOwnerTree(.{ .window = window });
}

fn windowBlurData(window: *Window) ?EffectMetadata.WindowBlurData {
    return blurOwnerData(.{ .window = window });
}

fn blurOwnerData(owner: BlurOwner) ?EffectMetadata.WindowBlurData {
    const handle = blurOwnerHandle(owner) orelse return null;
    const data = server.effect_metadata.windowBlurData(handle) orelse
        return null;
    const config = server.effect_metadata.blurConfig();
    if (!data.enabled or data.box.width <= 0 or data.box.height <= 0 or
        config.radius <= 0 or config.passes <= 0)
    {
        return null;
    }
    return data;
}

fn uncachedBlurRequested() bool {
    if (comptime !build_options.vulkan_effects) return false;
    const raw = std.c.getenv("AQUEOUS_VULKAN_BLUR_UNCACHED") orelse return false;
    const value = mem.span(raw);
    return mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true");
}

fn nodeInTree(node: *wlr.SceneNode, tree: *wlr.SceneTree) bool {
    return nodeDistanceInTree(node, tree) != null;
}

fn nodeDistanceInTree(
    node: *wlr.SceneNode,
    tree: *wlr.SceneTree,
) ?usize {
    var current = node;
    var distance: usize = 0;
    while (true) {
        if (current == &tree.node) return distance;
        const parent = current.parent orelse return null;
        current = &parent.node;
        distance += 1;
    }
}

fn blurOwnerEffect(
    owner: BlurOwner,
    blur: EffectMetadata.WindowBlurData,
    state: *const State,
) ?BlurPipeline.Effect {
    var global_x: i32 = 0;
    var global_y: i32 = 0;
    if (!blurOwnerTree(owner).node.coords(&global_x, &global_y)) return null;

    const logical_x = global_x + blur.box.x - state.x;
    const logical_y = global_y + blur.box.y - state.y;
    const left = scaleBoundary(logical_x, state.scale);
    const top = scaleBoundary(logical_y, state.scale);
    const right = scaleBoundary(
        logical_x + blur.box.width,
        state.scale,
    );
    const bottom = scaleBoundary(
        logical_y + blur.box.height,
        state.scale,
    );
    var box: wlr.Box = .{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    };
    if (box.width <= 0 or box.height <= 0) return null;

    var radii = EffectMetadata.clampedPhysicalRadii(
        .uniform(blur.radius),
        box.width,
        box.height,
        state.scale,
    );
    const transform = invertTransform(state.transform);
    radii = transformRadii(radii, transform);
    var transformed_width, var transformed_height =
        physicalDimensions(state);
    if (@mod(@intFromEnum(state.transform), 2) != 0) {
        mem.swap(i32, &transformed_width, &transformed_height);
    }
    box.transform(
        &box,
        transform,
        transformed_width,
        transformed_height,
    );
    if (!renderBoxesIntersect(
        .{ .x = 0, .y = 0, .width = transformed_width, .height = transformed_height },
        .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height },
    )) return null;
    return .{
        .box = .{
            .x = box.x,
            .y = box.y,
            .width = box.width,
            .height = box.height,
        },
        .radii = radii,
    };
}

fn physicalDimensions(state: *const State) struct { i32, i32 } {
    return switch (state.mode) {
        .standard => |mode| .{ mode.width, mode.height },
        .custom => |mode| .{ mode.width, mode.height },
        .none => .{ 0, 0 },
    };
}

fn expandedRenderBox(
    box: c.struct_wlr_box,
    reach: u32,
) c.struct_wlr_box {
    const amount: i32 = @intCast(@min(reach, math.maxInt(i32)));
    return .{
        .x = box.x -| amount,
        .y = box.y -| amount,
        .width = box.width +| amount *| 2,
        .height = box.height +| amount *| 2,
    };
}

fn expandedRenderRegionIntersects(
    region: ?*const c.pixman_region32_t,
    box: c.struct_wlr_box,
    reach: u32,
) bool {
    const damage = region orelse return false;
    var count: c_int = 0;
    const rectangles = c.pixman_region32_rectangles(damage, &count);
    var index: usize = 0;
    while (index < @as(usize, @intCast(@max(0, count)))) : (index += 1) {
        const rectangle = rectangles[index];
        if (renderBoxesIntersect(
            expandedRenderBox(.{
                .x = rectangle.x1,
                .y = rectangle.y1,
                .width = rectangle.x2 - rectangle.x1,
                .height = rectangle.y2 - rectangle.y1,
            }, reach),
            box,
        )) return true;
    }
    return false;
}

fn renderBoxesIntersect(
    a: c.struct_wlr_box,
    b: c.struct_wlr_box,
) bool {
    return @max(a.x, b.x) < @min(a.x + a.width, b.x + b.width) and
        @max(a.y, b.y) < @min(a.y + a.height, b.y + b.height);
}

fn hasVisibleBlur(output: *const Output) bool {
    if (comptime !build_options.vulkan_effects) return false;
    var it = server.wm.windows.iterator();
    while (it.next()) |window| {
        const blur = windowBlurData(window) orelse continue;
        if (blurOwnerEffect(
            .{ .window = window },
            blur,
            output.effectRenderState(),
        ) != null) {
            return true;
        }
    }
    var layers = server.layer_shell.surfaces.iterator();
    while (layers.next()) |surface| {
        const owner: BlurOwner = .{ .layer_surface = surface };
        const blur = blurOwnerData(owner) orelse continue;
        if (blurOwnerEffect(owner, blur, output.effectRenderState()) != null) {
            return true;
        }
    }
    var popups = server.layer_shell.popups.iterator();
    while (popups.next()) |popup| {
        const owner: BlurOwner = .{ .popup = popup };
        const blur = blurOwnerData(owner) orelse continue;
        if (blurOwnerEffect(owner, blur, output.effectRenderState()) != null) {
            return true;
        }
    }
    return false;
}

/// Animation moves both the blur source and decorations drawn above it. Repaint
/// the complete output so the offscreen blur pass cannot sample decoration
/// pixels retained at a window's previous position. Static cached blur keeps
/// using normal partial damage.
pub fn prepareFullBlurDamage(
    output: *Output,
    animation_changed_scene: bool,
) bool {
    if ((!uncachedBlurRequested() and !animation_changed_scene) or
        !output.hasVisibleBlur())
    {
        return false;
    }
    if (animation_changed_scene) {
        log.debug("forcing full output damage for blurred animation", .{});
    }
    output.scene_output.?.damage_ring.addWhole();
    return true;
}

pub fn setFullBlurDamage(
    output: *const Output,
    state: *wlr.Output.State,
) void {
    var width, var height = physicalDimensions(output.effectRenderState());
    if (@mod(
        @intFromEnum(output.effectRenderState().transform),
        2,
    ) != 0) {
        mem.swap(i32, &width, &height);
    }
    if (width <= 0 or height <= 0) return;

    var region: pixman.Region32 = undefined;
    region.initRect(0, 0, @intCast(width), @intCast(height));
    defer region.deinit();
    state.setDamage(&region);
}

pub fn recordVulkanEffectsMetric(output: *const Output) void {
    if (comptime !build_options.vulkan_effects) return;
    if (!render_metrics.enabled() or uncachedBlurRequested()) return;
    const stats = output.blur_cache.stats;
    if (stats.hits == 0 and stats.partial_rebuilds == 0 and
        stats.full_rebuilds == 0)
    {
        return;
    }
    const wlr_output = output.wlr_output orelse return;
    (render_metrics.VulkanEffectsSample{
        .gpu_duration_ns = -1,
        .cache_hits = stats.hits,
        .cache_partial_rebuilds = stats.partial_rebuilds,
        .cache_full_rebuilds = stats.full_rebuilds,
        .pixels_processed = stats.pixels_processed,
    }).record(std.mem.span(wlr_output.name));
}

fn rectEffect(
    output: *const Output,
    rect: *wlr.SceneRect,
    options: *const c.struct_wlr_render_rect_options,
    effect: EffectMetadata.RectData,
) ?EffectMetadata.RectRenderData {
    const state = output.effectRenderState();
    const scale = state.scale;
    const box = options.box;
    var outer_radii = EffectMetadata.clampedPhysicalRadii(
        effect.radii,
        box.width,
        box.height,
        scale,
    );
    const transform = invertTransform(state.transform);
    outer_radii = transformRadii(outer_radii, transform);

    var geometry: EffectMetadata.RectRenderData = .{
        .outer_radii = outer_radii,
    };
    if (effect.clipped_region) |clipped| {
        const inner_box = transformedInnerBox(rect, clipped.area, state) orelse
            return null;
        if (inner_box.width <= 0 or inner_box.height <= 0) return null;
        var inner_radii = EffectMetadata.clampedPhysicalRadii(
            clipped.radii,
            inner_box.width,
            inner_box.height,
            scale,
        );
        inner_radii = transformRadii(inner_radii, transform);
        geometry.inner_rect = .{
            @floatFromInt(inner_box.x),
            @floatFromInt(inner_box.y),
            @floatFromInt(inner_box.width),
            @floatFromInt(inner_box.height),
        };
        geometry.inner_radii = inner_radii;
        geometry.has_inner = true;
    }
    if (!geometry.has_inner and !hasPhysicalRadius(geometry.outer_radii)) {
        return null;
    }
    return geometry;
}

fn transformedInnerBox(
    rect: *wlr.SceneRect,
    area: wlr.Box,
    state: *const State,
) ?wlr.Box {
    var global_x: i32 = 0;
    var global_y: i32 = 0;
    if (!rect.node.coords(&global_x, &global_y)) return null;

    const logical_x = global_x - state.x;
    const logical_y = global_y - state.y;
    const outer_left = scaleBoundary(logical_x, state.scale);
    const outer_top = scaleBoundary(logical_y, state.scale);
    const outer_right = scaleBoundary(logical_x + rect.width, state.scale);
    const outer_bottom = scaleBoundary(logical_y + rect.height, state.scale);
    const outer_width = outer_right - outer_left;
    const outer_height = outer_bottom - outer_top;
    if (outer_width <= 0 or outer_height <= 0) return null;

    var inner: wlr.Box = .{
        .x = scaleBoundary(logical_x + area.x, state.scale) - outer_left,
        .y = scaleBoundary(logical_y + area.y, state.scale) - outer_top,
        .width = scaleBoundary(logical_x + area.x + area.width, state.scale) -
            scaleBoundary(logical_x + area.x, state.scale),
        .height = scaleBoundary(logical_y + area.y + area.height, state.scale) -
            scaleBoundary(logical_y + area.y, state.scale),
    };
    inner.transform(
        &inner,
        invertTransform(state.transform),
        outer_width,
        outer_height,
    );
    return inner;
}

fn scaleBoundary(value: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * scale));
}

fn invertTransform(transform: wl.Output.Transform) wl.Output.Transform {
    return switch (transform) {
        .@"90" => .@"270",
        .@"270" => .@"90",
        else => transform,
    };
}

fn transformRadii(
    radii: [4]f32,
    transform: wl.Output.Transform,
) [4]f32 {
    return switch (transform) {
        .normal => radii,
        .@"90" => .{ radii[3], radii[0], radii[1], radii[2] },
        .@"180" => .{ radii[2], radii[3], radii[0], radii[1] },
        .@"270" => .{ radii[1], radii[2], radii[3], radii[0] },
        .flipped => .{ radii[1], radii[0], radii[3], radii[2] },
        .flipped_90 => .{ radii[0], radii[3], radii[2], radii[1] },
        .flipped_180 => .{ radii[3], radii[2], radii[1], radii[0] },
        .flipped_270 => .{ radii[2], radii[1], radii[0], radii[3] },
        else => radii,
    };
}

fn hasRadius(radii: EffectMetadata.CornerRadii) bool {
    return radii.top_left != 0 or
        radii.top_right != 0 or
        radii.bottom_right != 0 or
        radii.bottom_left != 0;
}

fn hasPhysicalRadius(radii: [4]f32) bool {
    for (radii) |radius| {
        if (radius > 0) return true;
    }
    return false;
}

/// Ensure the output has at least one workspace and an active workspace.
pub fn ensureWorkspaces(output: *Output) void {
    if (output.workspaces.first() == null) {
        var i: u32 = 1;
        while (i <= 9) : (i += 1) {
            var buf: [16]u8 = undefined;
            const name = fmt.bufPrint(&buf, "{d}", .{i}) catch "workspace";
            const ws = Workspace.create(output, name) catch {
                log.err("out of memory creating static workspace", .{});
                break;
            };
            ws.pinned = true;
        }
    }
    if (output.active_workspace == null) {
        output.active_workspace = output.workspaces.first();
    }
}

/// Make the given workspace the single active workspace on this output.
pub fn activateWorkspace(output: *Output, workspace: *Workspace) void {
    assert(workspace.output == output);
    const prev = output.active_workspace;
    if (prev == workspace) return;
    server.aqueous.forgetOutput(output.policyId());

    if (comptime fx.anim_enabled) {
        if (server.wm.workspace_transition.enabled) {
            if (prev) |p| {
                // Begin a workspace-swap slide. `renderFinish` keeps both the
                // outgoing (`prev_workspace`) and incoming (`active_workspace`)
                // workspaces rendered and offset; the transition is finalized in
                // `stepAnimations` once every participating window has settled.
                // If a transition is already in flight, retarget it: the workspace
                // sliding out is whichever one we are leaving now.
                output.prev_workspace = p;
                output.transition_dir = output.slideDirection(p, workspace);
                output.transition_armed = false;
                // The incoming windows must seed their clones off-screen on the
                // first transition frame; clear any stale seed flags so they do.
                var it = p.windows.iterator(.forward);
                while (it.next()) |w| w.slide_seeded = false;
                var it2 = workspace.windows.iterator(.forward);
                while (it2.next()) |w| w.slide_seeded = false;
            }
        }
    }

    output.active_workspace = workspace;
    // Reaping is intentionally not performed here: it is deferred to the end of
    // the workspace transaction so an in-flight batch cannot free a workspace
    // it still references. Other call sites (window unmap/move) reap directly.
    server.wm.dirtyWindowing();
    server.workspace_manager.dirty();
    if (output.wlr_output) |o| o.scheduleFrame();
}

/// Return the slide direction sign for a transition from `prev` to `next`:
/// +1 when `next` is ordered after `prev` in `output.workspaces` (new content
/// enters from the right), -1 otherwise.
fn slideDirection(output: *Output, prev: *Workspace, next: *Workspace) i32 {
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |w| {
        if (w == prev) return 1;
        if (w == next) return -1;
    }
    return 1;
}

/// Abort any in-flight workspace-swap slide, tearing down the participating
/// windows' clones so they cannot outlive their workspace (e.g. when an output
/// is disconnected, migrated, or cleared mid-transition).
pub fn cancelTransition(output: *Output) void {
    if (comptime !fx.anim_enabled) return;
    if (output.prev_workspace) |prev| {
        var it = prev.windows.iterator(.forward);
        while (it.next()) |w| w.cancelSlide();
    }
    if (output.active_workspace) |active| {
        var it = active.windows.iterator(.forward);
        while (it.next()) |w| w.cancelSlide();
    }
    output.prev_workspace = null;
    output.transition_dir = 0;
    output.transition_armed = false;
}

/// Settle cosmetic window/workspace animation overlays before the overview
/// clones live content. Authoritative geometry, layout, and focus are untouched.
pub fn prepareOverview(output: *Output) void {
    output.cancelTransition();
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        const workspace = window.workspace orelse continue;
        if (workspace.output != output) continue;
        window.cancelSlide();
    }
}

/// If a workspace-swap slide is in flight and every participating window has
/// settled, commit the end state: clear the transition so the outgoing
/// workspace's windows hit the non-visible gate (disabling their live trees) on
/// the next `renderFinish`, then reap the now-hidden empty workspace.
fn finalizeTransition(output: *Output) void {
    if (comptime !fx.anim_enabled) return;
    const prev = output.prev_workspace orelse return;
    // Do not finalize before `renderFinish` has armed the slide: an early frame
    // (scheduled by `activateWorkspace`) can beat the async windowing
    // transaction, at which point no window is animating yet and finalizing
    // here would cancel the transition before it visibly begins.
    if (!output.transition_armed) return;
    if (output.hasActiveAnimations()) return;
    output.prev_workspace = null;
    output.transition_dir = 0;
    output.transition_armed = false;
    server.wm.dirtyWindowing();
    if (!prev.pinned and prev.empty()) output.reapEmpty();
}

/// Made a noop as static exists but this is safer than removing the functionality entirely
pub fn ensureTrailingEmpty(output: *Output) void {
    if (output.workspaces.first() != null) return;
    _ = output.createWorkspace();
}

/// Destroy empty workspaces that are neither active nor the trailing one.
pub fn reapEmpty(output: *Output) void {
    const last = output.workspaces.last();
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| {
        if (workspace.pinned) continue;
        if (workspace == output.active_workspace) continue;
        // Never reap a workspace that is still sliding out: its windows' clones
        // are mid-transition and `Workspace.destroy` asserts the workspace is
        // inactive and empty. The finalize block clears `prev_workspace` and
        // calls `reapEmpty` again once the slide completes.
        if (workspace == output.prev_workspace) continue;
        if (workspace == last) continue;
        if (workspace.empty()) workspace.destroy();
    }
}

/// Return another enabled output to which this output's workspaces may be
/// migrated, or null if this is the last remaining output.
fn fallbackOutput(output: *Output) ?*Output {
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |other| {
        if (other == output) continue;
        if (other.scheduled.state == .destroying) continue;
        if (other.wlr_output == null) continue;
        return other;
    }
    return null;
}

fn migrateWorkspacesTo(output: *Output, dest: *Output) void {
    output.cancelTransition();
    output.active_workspace = null;
    var it = output.workspaces.safeIterator(.forward);
    while (it.next()) |workspace| {
        if (workspace.pinned) {
            if (dest.pinnedByName(workspace.name)) |target| {
                var win_it = workspace.windows.safeIterator(.forward);
                while (win_it.next()) |window| window.setWorkspace(target);
            } else {
                workspace.link.remove();
                workspace.output = dest;
                dest.workspaces.append(workspace);
                continue;
            }
            workspace.destroy();
            continue;
        }

        workspace.link.remove();
        workspace.output = dest;
        dest.workspaces.append(workspace);
    }
    dest.ensureTrailingEmpty();
    dest.reapEmpty();
    server.wm.dirtyWindowing();
    server.workspace_manager.dirty();
}

/// Destroy all workspaces, detaching any remaining windows first. Detaching is
/// done without triggering reaping so it is safe to call while iterating the
/// workspace list.
fn clearWorkspaces(output: *Output) void {
    output.cancelTransition();
    output.active_workspace = null;
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| {
        var window_it = workspace.windows.iterator(.forward);
        while (window_it.next()) |window| window.detachWorkspace();
        workspace.destroy();
    }
}

fn createWorkspace(output: *Output) ?*Workspace {
    var buf: [16]u8 = undefined;
    const index = output.workspaces.length() + 1;
    const name = fmt.bufPrint(&buf, "{d}", .{index}) catch "workspace";
    return Workspace.create(output, name) catch {
        log.err("out of memory creating workspace", .{});
        return null;
    };
}

fn handleCommit(
    listener: *wl.Listener(*wlr.Output.event.Commit),
    event: *wlr.Output.event.Commit,
) void {
    const output: *Output = @fieldParentPtr("commit", listener);
    const committed = event.state.committed;
    if (!(committed.scale or committed.mode or committed.transform or committed.enabled)) return;
    server.aqueous.forgetOutput(output.policyId());
    const wlr_output = output.wlr_output orelse return;
    log.debug("output {s}: commit affects layout (scale={} mode={} transform={} enabled={})", .{
        wlr_output.name,
        committed.scale,
        committed.mode,
        committed.transform,
        committed.enabled,
    });
    server.wm.dirtyWindowing();

    if (committed.scale or committed.enabled) {
        var seat_it = server.input_manager.seats.iterator(.forward);
        while (seat_it.next()) |seat| {
            seat.cursor.reloadScales();
        }
    }
}

/// Attempts to send the river_output_v1.wl_output event if it has not yet been
/// sent and the underlying wl_output global now exists. Wlroots creates the
/// wl_output global lazily (notably on the DRM backend the global is only
/// created once the output is added to the layout and a mode is committed), so
/// this must be retried from every site that learns the global may now exist
/// (manageStart, post-modeset, and client bind) until it succeeds.
pub fn trySendWlOutput(output: *Output) void {
    const wlr_output = output.wlr_output orelse return;
    const global = wlr_output.global orelse return;
    const output_v1 = output.object orelse return;
    // Re-send if we have not sent yet or the global was recreated.
    if (output.sent_wl_output and output.sent_wl_output_global == global) return;
    output_v1.sendWlOutput(global.getName(output_v1.getClient()));
    output.sent_wl_output = true;
    output.sent_wl_output_global = global;
}

/// Handles a client binding to an output
fn handleBind(listener: *wl.Listener(*wlr.Output.event.Bind), _: *wlr.Output.event.Bind) void {
    const output: *Output = @fieldParentPtr("bind", listener);
    // The wl_output.bind event only fires after the wl_output global exists, so
    // this is a reliable point to (re)send river_output_v1.wl_output when the
    // global was still null at manageStart/modeset time (e.g. DRM backend).
    output.trySendWlOutput();
    server.workspace_manager.dirty();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);

    log.debug("wlr_output '{s}' destroyed", .{wlr_output.name});
    server.aqueous.forgetOutput(output.policyId());

    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| seat.policyForgetOutput(output);

    {
        var it = server.layer_shell.surfaces.iterator();
        while (it.next()) |surface| {
            if (surface.wlr_layer_surface.output == wlr_output) {
                surface.wlr_layer_surface.destroy();
            }
        }
    }
    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            if (device.config.map_to_output == wlr_output) {
                device.config.map_to_output = null;
                device.seat.cursor.wlr_cursor.mapInputToOutput(device.wlr_device, null);
            }
        }
    }

    output.destroy.link.remove();
    output.request_state.link.remove();
    output.frame.link.remove();
    output.present.link.remove();
    output.commit.link.remove();
    output.bind.link.remove();

    output.finishRenderMetric();
    output.destroyBlur();

    wlr_output.data = null;

    output.wlr_output = null;
    output.scene_output = null;
    output.scheduled.mode = .none;
    output.sent.mode = .none;
    output.current.mode = .none;
    output.scheduled.state = .destroying;

    server.aqueous.output_service.outputsChanged(true);

    server.wm.dirtyWindowing();
}

pub fn manageStart(output: *Output) void {
    switch (output.scheduled.state) {
        .enabled, .disabled_soft => {
            // We cannot send 0 width/height to the window manager client.
            assert(output.scheduled.mode != .none);

            output.layer_shell.manageStart();

            if (server.wm.object) |wm_v1| {
                const new = output.object == null;
                const output_v1 = output.object orelse blk: {
                    const output_v1 = river.OutputV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                        log.err("out of memory", .{});
                        return; // try again next update
                    };
                    output.object = output_v1;

                    output_v1.setHandler(*Output, handleRequest, handleObjectDestroy, output);
                    wm_v1.sendOutput(output_v1);

                    break :blk output_v1;
                };
                errdefer comptime unreachable;

                // wl_output globals are created/destroyed by the wlroots output layout.
                // Retry until it succeeds; handleBind and the post-modeset pass also retry.
                output.trySendWlOutput();

                const scheduled = &output.scheduled;
                const sent = &output.sent;

                const scheduled_width, const scheduled_height = scheduled.dimensions();
                const sent_width, const sent_height = sent.dimensions();

                if (new or scheduled_width != sent_width or scheduled_height != sent_height) {
                    output_v1.sendDimensions(scheduled_width, scheduled_height);
                }
                if (new or scheduled.x != sent.x or scheduled.y != sent.y) {
                    output_v1.sendPosition(scheduled.x, scheduled.y);
                }
            }

            output.sent = output.scheduled;

            output.link_sent.remove();
            server.wm.sent.outputs.append(output);
        },
        .disabled_hard, .destroying => {
            output.makeInert();

            output.sent = output.scheduled;

            if (output.scheduled.state == .destroying) {
                assert(output.wlr_output == null);
                {
                    var it = server.wm.windows.iterator();
                    while (it.next()) |window| {
                        switch (window.wm_scheduled.fullscreen_requested) {
                            .fullscreen => |output_hint| {
                                if (output_hint == output) {
                                    window.wm_scheduled.fullscreen_requested = .{ .fullscreen = null };
                                }
                            },
                            .no_request, .exit => {},
                        }
                        if (window.wm_requested.fullscreen == output) {
                            window.wm_requested.fullscreen = null;
                        }
                    }
                }
                const dest = output.fallbackOutput();
                if (dest) |to| {
                    output.migrateWorkspacesTo(to);
                } else {
                    output.clearWorkspaces();
                }
                server.workspace_manager.handleOutputRemoved(output, dest);

                output.link.remove();
                output.link_sent.remove();

                util.gpa.destroy(output);
            }
        },
    }
}

pub fn makeInert(output: *Output) void {
    if (output.object) |output_v1| {
        output_v1.sendRemoved();
        output_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        output.layer_shell.makeInert();
        handleObjectDestroy(output_v1, output);
    }
}

fn handleRequestInert(
    output_v1: *river.OutputV1,
    request: river.OutputV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) output_v1.destroy();
}

fn handleObjectDestroy(_: *river.OutputV1, output: *Output) void {
    output.object = null;
    output.sent_wl_output = false;
    output.sent_wl_output_global = null;
}

fn handleRequest(
    output_v1: *river.OutputV1,
    request: river.OutputV1.Request,
    output: *Output,
) void {
    assert(output.object == output_v1);
    switch (request) {
        .destroy => output_v1.destroy(),
        .set_presentation_mode => |args| {
            if (!server.wm.ensureRendering()) return;
            output.rendering_requested.tearing = switch (args.mode) {
                .vsync => false,
                .async => true,
                _ => {
                    output_v1.postError(.invalid_presentation_mode, "invalid presentation mode enum value");
                    return;
                },
            };
        },
    }
}

fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    // The only state currently requested by a wlroots backend is a
    // custom mode as the Wayland/X11 backend window is resized.
    const committed: u32 = @bitCast(event.state.committed);
    const supported: u32 = @bitCast(wlr.Output.State.Fields{ .mode = true });

    if (committed != supported) {
        log.err("backend requested unsupported state {}", .{committed});
        return;
    }

    log.debug("backend requested new mode", .{});

    if (event.state.mode) |mode| {
        output.scheduled.mode = .{ .standard = mode };
    } else {
        output.scheduled.mode = .{ .custom = .{
            .width = event.state.custom_mode.width,
            .height = event.state.custom_mode.height,
            .refresh = event.state.custom_mode.refresh,
        } };
    }

    server.wm.dirtyWindowing();
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);

    const animation_changed_scene = output.stepAnimations();

    // Commit the end of a workspace-swap slide once all windows have settled.
    output.finalizeTransition();

    // TODO this should probably be retried on failure
    output.renderAndCommit(animation_changed_scene) catch |err| switch (err) {
        error.CommitFailed => log.err("output commit failed for {s}", .{wlr_output.name}),
    };

    var now = util.timestamp();
    output.scene_output.?.sendFrameDone(&now);

    // renderAndCommit early-returns when the scene reports no pending changes, so
    // re-arm the frame loop ourselves while any window on this output is still
    // moving; otherwise the animation would stall after the first eased frame.
    if (output.hasActiveAnimations()) {
        wlr_output.scheduleFrame();
    } else {
        // The animation loop is going idle. Clear the delta accumulator so the
        // next slide's first frame starts fresh (dt == 0) instead of inheriting
        // the multi-second gap since this slide ended — which would otherwise
        // produce a single huge first step (clamped to 0.1s) and make every
        // switch after the first appear to snap most of the way instantly.
        output.anim_last_ns = 0;
    }
}

/// Advance the position animation of every window currently displayed on this
/// output by the time elapsed since the previous frame. Returns true when any
/// animation changed scene state. Compiles out (always returns false) when animations
/// are disabled.
fn stepAnimations(output: *Output) bool {
    if (comptime !fx.anim_enabled) return false;

    const now = util.timestamp();
    const now_ns: i64 = @as(i64, @intCast(now.sec)) * std.time.ns_per_s + @as(i64, @intCast(now.nsec));

    var dt_s: f64 = 0;
    if (output.anim_last_ns != 0) {
        const delta_ns = now_ns - output.anim_last_ns;
        dt_s = @as(f64, @floatFromInt(delta_ns)) / @as(f64, std.time.ns_per_s);
        // Clamp so a stall (e.g. after the output was idle) does not teleport the
        // window in a single huge step.
        if (dt_s < 0) dt_s = 0;
        if (dt_s > 0.1) dt_s = 0.1;
    }
    output.anim_last_ns = now_ns;

    if (dt_s <= 0) return false;

    var changed = false;
    var it = server.wm.windows.iterator();
    while (it.next()) |window| {
        const ws = window.workspace orelse continue;
        if (ws.output != output) continue;
        if (window.stepAnimation(dt_s)) changed = true;
    }
    if (server.overview.step(output, dt_s)) changed = true;
    return changed;
}

fn hasActiveAnimations(output: *Output) bool {
    if (comptime !fx.anim_enabled) return false;

    var it = server.wm.windows.iterator();
    while (it.next()) |window| {
        const ws = window.workspace orelse continue;
        if (ws.output != output) continue;
        if (window.anim_active) return true;
    }
    return server.overview.animatingOn(output.policyId());
}

fn renderAndCommit(output: *Output, force: bool) !void {
    output.syncWindowVisualState();
    if (!force and !output.scene_output.?.needsFrame()) return;

    const wlr_output = output.wlr_output.?;

    var state = wlr.Output.State.init();
    defer state.finish();

    output.current.applyNoModeset(&state);

    if (!output.buildSceneState(
        &state,
        null,
        render_metrics.enabled() and output.render_metric_sample == null,
        force,
    )) {
        return error.CommitFailed;
    }

    if (output.rendering_current.tearing) {
        state.tearing_page_flip = true;
        // TODO don't try this every frame if it consistently fails. Stop trying if it fails
        // for 10 frames in a row or something.
        if (!wlr_output.testState(&state)) {
            log.info("tearing page flip test failed for {s}, retrying without tearing", .{wlr_output.name});
            state.tearing_page_flip = false;
        }
    }

    if (!wlr_output.commitState(&state)) {
        output.discardRenderMetric();
        return error.CommitFailed;
    }

    switch (server.lock_manager.state) {
        .unlocked => {
            if (output.lock_render_state != .unlocked) {
                output.lock_render_state = .pending_unlock;
            }
        },
        .locked => {
            assert(!server.scene.normal_tree.node.enabled);
            switch (output.lock_render_state) {
                .pending_unlock, .unlocked, .pending_blank, .pending_lock_surface => unreachable,
                .blanked, .lock_surface => {},
            }
        },
        .waiting_for_blank => {
            assert(!server.scene.normal_tree.node.enabled);
            if (output.lock_render_state != .blanked) {
                output.lock_render_state = .pending_blank;
            }
        },
        .waiting_for_lock_surfaces => {
            const lock_surface_mapped = blk: {
                if (server.lock_manager.lockSurfaceFromOutput(output)) |lock_surface| {
                    break :blk lock_surface.wlr_lock_surface.surface.mapped;
                } else {
                    break :blk false;
                }
            };
            if (lock_surface_mapped) {
                if (output.lock_render_state != .lock_surface) {
                    output.lock_render_state = .pending_lock_surface;
                }
            } else {
                if (output.lock_render_state != .unlocked) {
                    output.lock_render_state = .pending_unlock;
                }
            }
        },
    }
}

pub fn buildSceneState(
    output: *Output,
    state: *wlr.Output.State,
    swapchain: ?*wlr.Swapchain,
    collect_metrics: bool,
    animation_changed_scene: bool,
) bool {
    output.syncWindowVisualState();
    output.effects_swapchain_path = swapchain != null;
    defer output.effects_swapchain_path = false;

    const full_blur_damage =
        output.prepareFullBlurDamage(animation_changed_scene);
    var scene_options: wlr.SceneOutput.StateOptions = .{
        .swapchain = swapchain,
    };
    if (collect_metrics) {
        output.render_metric_sample = .{};
        scene_options.timer = &output.render_metric_sample.?.timer;
    }

    if (!output.scene_output.?.buildState(
        state,
        if (swapchain != null or collect_metrics) &scene_options else null,
    )) {
        if (collect_metrics) output.discardRenderMetric();
        return false;
    }
    output.recordVulkanEffectsMetric();
    if (full_blur_damage) output.setFullBlurDamage(state);
    return true;
}

fn syncWindowVisualState(output: *Output) void {
    _ = output;
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| window.applyOpacity();
}

fn handlePresent(
    listener: *wl.Listener(*wlr.Output.event.Present),
    event: *wlr.Output.event.Present,
) void {
    const output: *Output = @fieldParentPtr("present", listener);
    output.finishRenderMetric();
    if (!event.presented) {
        return;
    }
    switch (output.lock_render_state) {
        .pending_unlock => {
            assert(server.lock_manager.state != .locked);
            output.lock_render_state = .unlocked;
        },
        .unlocked => assert(server.lock_manager.state != .locked),
        .pending_blank => {
            output.lock_render_state = .blanked;
            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .pending_lock_surface => {
            output.lock_render_state = .lock_surface;
            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .blanked, .lock_surface => {},
    }
}

fn pinnedByName(output: *Output, name: [:0]const u8) ?*Workspace {
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| {
        if (workspace.pinned and std.mem.eql(u8, workspace.name, name)) {
            return workspace;
        }
    }
    return null;
}
