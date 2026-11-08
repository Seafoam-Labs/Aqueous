// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Window = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const meta = std.meta;
const posix = std.posix;
const wlr = @import("wlroots");
const pixman = @import("pixman");
const wl = @import("wayland").server.wl;
const aqueous = @import("wayland").server.aqueous;
const wp = @import("wayland").server.wp;
const SlotMap = @import("slotmap").SlotMap;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const scaling = @import("scaling");
const OverlayPreference = @import("wm/rules/engine.zig").OverlayPreference;

extern fn wlr_scene_node_set_position_f64(node: *wlr.SceneNode, x: f64, y: f64) void;
extern fn wlr_surface_set_preferred_scale_override(surface: *wlr.Surface, scale: f64) void;
extern fn wlr_scene_node_coords_f64(node: *wlr.SceneNode, x: *f64, y: *f64) bool;
extern fn wlr_scene_node_set_presentation(node: *wlr.SceneNode, dx: f64, dy: f64, clip: ?*const wlr.Box, input_enabled: bool, input_clip: ?*const wlr.Box) bool;

const Decoration = @import("Decoration.zig");
const Output = @import("Output.zig");
const fx = @import("fx.zig");
const visual_state = @import("visual_state.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const WindowInfoManager = @import("WindowInfoManager.zig");
const WmNode = @import("WmNode.zig");
const Workspace = @import("Workspace.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.wm);

pub const Dimensions = struct {
    width: u31,
    height: u31,
};

pub const DimensionsHint = struct {
    min_width: u31 = 0,
    max_width: u31 = 0,
    min_height: u31 = 0,
    max_height: u31 = 0,
    base_width: u31 = 0,
    base_height: u31 = 0,
    width_inc: u31 = 0,
    height_inc: u31 = 0,
    min_aspect_num: u31 = 0,
    min_aspect_den: u31 = 0,
    max_aspect_num: u31 = 0,
    max_aspect_den: u31 = 0,
};

/// Window-manager metadata that has the exact same lifetime as this Window.
/// Compositor-owned state such as fullscreen, workspace, output, and current
/// geometry deliberately does not live here.
pub const PolicyState = @import("wm/state/PolicyState.zig");

const Impl = union(enum) {
    toplevel: XdgToplevel,
    xwayland: if (build_options.xwayland) XwaylandWindow else noreturn,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the window.
    destroying,
};

pub const FullscreenRequest = union(enum) {
    no_request,
    fullscreen: ?*Output,
    exit,
};

pub const Border = struct {
    edges: aqueous.WindowV1.Edges = .{},
    width: u31 = 0,
    r: u32 = 0,
    b: u32 = 0,
    g: u32 = 0,
    a: u32 = 0,
    /// Corner radius applied to the border rects and window content. Defaults
    /// to `fx.default_corner_radius`, which is 0 in the no-effects diagnostic build.
    corner_radius: u31 = fx.default_corner_radius,
};

const BorderNodes = struct {
    rounded_outline: *wlr.SceneRect,
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,
};

/// Windowing state requested by the wm.
const WmRequested = struct {
    dimensions: ?Dimensions,
    bounds: Dimensions,
    ssd: bool,
    tiled: aqueous.WindowV1.Edges,
    capabilities: aqueous.WindowV1.Capabilities,
    resizing: bool,
    maximized: bool,
    fullscreen: ?*Output,
    inform_fullscreen: bool,
    close: bool,

    pub const init: WmRequested = .{
        .dimensions = null,
        .bounds = .{ .width = 0, .height = 0 },
        .ssd = false,
        .tiled = .{},
        .capabilities = .{
            .window_menu = true,
            .maximize = true,
            .fullscreen = true,
            .minimize = true,
        },
        .resizing = false,
        .maximized = false,
        .fullscreen = null,
        .inform_fullscreen = false,
        .close = false,
    };
};

pub const Configure = struct {
    suspended: bool = false,
    constrained: wlr.Edges = .{},
    width: ?u31,
    height: ?u31,
    bounds: Dimensions,
    /// True if the window has keyboard focus from at least one seat.
    activated: bool,
    ssd: bool,
    tiled: aqueous.WindowV1.Edges,
    capabilities: aqueous.WindowV1.Capabilities,
    maximized: bool,
    inform_fullscreen: bool,
    resizing: bool,

    pub const init: Configure = .{
        .width = null,
        .height = null,
        .bounds = .{ .width = 0, .height = 0 },
        .activated = false,
        .ssd = false,
        .tiled = .{},
        .capabilities = .{},
        .maximized = false,
        .inform_fullscreen = false,
        .resizing = false,
    };
};

/// Rendering state requested by the wm.
const RenderingRequested = struct {
    x: i32,
    y: i32,
    precise_x: f64,
    precise_y: f64,
    output_scale: f32,
    output_origin_x: i32,
    output_origin_y: i32,
    hidden: bool,
    border: Border,
    clip: wlr.Box,
    content_clip: wlr.Box,
    /// Per-window blur preference retained for policy/protocol compatibility.
    /// It must never be implemented by falsifying scene-buffer opaque regions;
    /// selective translucent blur requires the compositor's effect mask.
    blur_enabled: bool = true,
    /// Window-content opacity as a 32-bit unsigned fraction (0 = transparent,
    /// 0xffffffff = opaque); null inherits the global default driven by
    /// aqueous_window_manager_v1.set_opacity. Driven by
    /// aqueous_window_v1.set_window_opacity.
    opacity: ?u32 = null,
    buffer_scale_policy: scaling.BufferScalePolicy = .native,
    overlay_plane: OverlayPreference = .off,

    pub const init: RenderingRequested = .{
        .x = 0,
        .y = 0,
        .precise_x = 0,
        .precise_y = 0,
        .output_scale = 1,
        .output_origin_x = 0,
        .output_origin_y = 0,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .blur_enabled = true,
        .opacity = null,
        .buffer_scale_policy = .native,
        .overlay_plane = .off,
    };
};

pub const Ref = packed struct {
    key: SlotMap(*Window).Key,

    pub fn get(ref: Ref) ?*Window {
        return server.wm.windows.get(ref.key);
    }
};

pub const PolicySnapshot = struct {
    handle: u64,
    parent_handle: ?u64,
    output_id: ?u64,
    active: bool,
    app_id: ?[*:0]const u8,
    title: ?[*:0]const u8,
    tag: ?[*:0]const u8,
    content_type: wp.ContentTypeV1.Type,
    accepts_focus: bool,
    fullscreen: bool,
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
    base_width: i32,
    base_height: i32,
    width_inc: i32,
    height_inc: i32,
    min_aspect_num: i32,
    min_aspect_den: i32,
    max_aspect_num: i32,
    max_aspect_den: i32,
    preferred_width: i32,
    preferred_height: i32,
};

pub const InfoBackend = enum { xdg, xwayland };

/// Read-only compositor-owned state exposed through aqueous_window_info_v1.
/// Strings borrow their backing protocol/output objects and are consumed
/// synchronously while servicing the request.
pub const InfoSnapshot = struct {
    description: ?[*:0]const u8,
    backend: InfoBackend,
    app_id: ?[*:0]const u8,
    class: ?[*:0]const u8,
    title: ?[*:0]const u8,
    tag: ?[*:0]const u8,
    content_type: wp.ContentTypeV1.Type,
    output: ?[*:0]const u8,
    workspace: u32,
    geometry: wlr.Box,
    focused: bool,
    floating: bool,
    fullscreen: bool,
    maximized: bool,
    minimized: bool,
    visible: bool,
    always_above: bool,
    always_below: bool,
    snapped: bool,
    fixed_position: bool,
    skip_switcher: bool,
    skip_taskbar: bool,
    layout: [:0]const u8,
};

ref: Ref,

/// The workspace this window currently belongs to, or null if unassigned.
/// An unassigned window is always visible; an assigned window is visible only
/// while its workspace is the active one on its output.
workspace: ?*Workspace = null,
/// Pointer-free placement retained while no usable output is available.
output_recovery: ?struct { workspace_number: u32, fullscreen: bool } = null,
/// Original connector and workspace, retained across temporary fallback outputs.
/// Explicit placement cancels the return; automatic recovery preserves it.
output_home: ?struct { name: []const u8, workspace_number: u32 } = null,
/// Node in the owning workspace's member list (`Workspace.windows`).
workspace_link: wl.list.Link,

/// The window management protocol object for this window
/// Created in manageStart() when state is .ready
/// Set to null in manageStart() when state is .closing
object: ?*aqueous.WindowV1 = null,
node: WmNode,

state: enum {
    /// Initial state, also returned to after closed event is sent.
    init,
    /// The window is ready to be configured.
    /// The aqueous_window_v1 will be created in the next manage sequence.
    ready,
    /// The first configure has been sent but the window is not yet mapped.
    initialized,
    /// The window is mapped.
    mapped,
    /// The old policy object will be closed in the next manage sequence, or
    /// synchronously if an XDG client immediately starts a new mapping.
    closing,
} = .init,

/// The implementation of this window
impl: Impl,

/// This is the root scene tree for the window.
/// The trees in the following fields are in rendering order.
tree: *wlr.SceneTree,

/// Backend-specific blur mask behind this window's content. The output-local
/// cache owns the background image; this handle defines where it is displayed.
backdrop_blur: ?fx.WindowBlur,

/// Auto HDR expansion override from the matched window rule, reapplied every
/// manage cycle. Null follows the output default (fullscreen windows expand).
hdr_expand_rule: ?bool = null,

/// Opaque black rectangle used as the background while this window is rendered fullscreen.
/// TODO consider using one of these per output rather than one per window to save memory
/// if the complexity tradeoff is worth it.
fullscreen_background: *wlr.SceneRect,
/// Transparent scene entry which fixes the blur composite below every visible
/// surface and decoration belonging to this window.
blur_marker: *wlr.SceneRect,

decorations_below: wl.list.Head(Decoration, .link),
decorations_below_tree: *wlr.SceneTree,

surfaces: Scene.SaveableSurfaces,

border: BorderNodes,

decorations_above: wl.list.Head(Decoration, .link),
decorations_above_tree: *wlr.SceneTree,

popup_tree: *wlr.SceneTree,

capture_scene: *wlr.Scene,
capture_source: ?*wlr.ExtImageCaptureSourceV1 = null,
capture_impl: wlr.ExtImageCaptureSourceV1.Interface = undefined,
capture_original_impl: *const wlr.ExtImageCaptureSourceV1.Interface = undefined,
capture_sessions: usize = 0,
content_type: wp.ContentTypeV1.Type = .none,

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: aqueous.WindowV1.DecorationHint = .only_supports_csd,
    /// Whether the window accepts keyboard focus. Wayland-native windows always do;
    /// XWayland windows reflect their ICCCM input model (`none` ⇒ false). Forwarded to
    /// the wm via aqueous_window_v1.focus_hint so it can avoid focus-stealing popups.
    accepts_focus: bool = true,
    show_window_menu_requested: ?struct { x: i32, y: i32 } = null,
    /// Set back to no_request at the end of each update sequence
    fullscreen_requested: FullscreenRequest = .no_request,
    maximize_requested: enum {
        no_request,
        maximize,
        unmaximize,
    } = .no_request,
    minimize_requested: enum {
        no_request,
        minimize,
        unminimize,
    } = .no_request,
    /// XDG clients and foreign-toplevel controllers request activation.
    /// The integrated policy consumes this as a one-shot focus request.
    activate_requested: bool = false,
    dirty_app_id: bool = false,
    dirty_title: bool = false,
    pointer_move_requested: ?*Seat = null,
    pointer_resize_requested: ?struct {
        seat: *Seat,
        edges: aqueous.WindowV1.Edges,
    } = null,
} = .{},

/// State sent to the wm in the latest manage sequence.
/// This state is only kept around in order to avoid sending redundant events
/// to the wm.
wm_sent: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: aqueous.WindowV1.DecorationHint = .only_supports_csd,
    accepts_focus: bool = true,
    parent: ?Window.Ref = null,
} = .{},

/// Windowing state requested by the wm.
wm_requested: WmRequested = .init,

/// Integrated-policy metadata owned by the window rather than mirrored in a
/// handle-keyed side table.
policy_state: PolicyState = .{},

/// State to be sent to the window in the next configure.
configure_scheduled: Configure = .init,
/// State sent to the window in the latest configure.
configure_sent: Configure = .init,
/// Force the next xdg_toplevel configure even when the effective state and
/// dimensions are unchanged. xdg-shell requires a configure response to
/// fullscreen requests even when compositor policy rejects the request or the
/// surface is already in the requested state.
force_configure: bool = false,

/// State to be sent to the wm in the next render sequence.
rendering_scheduled: struct {
    /// Dimensions committed by the window.
    width: u31 = 0,
    height: u31 = 0,
    /// Send dimensions even if they are unchanged.
    resend_dimensions: bool = false,
} = .{},

/// State sent to the wm in the latest render sequence.
rendering_sent: struct {
    width: u31 = 0,
    height: u31 = 0,
    presentation_hint: aqueous.OutputV1.PresentationMode = .vsync,
} = .{},

/// Rendering state requested by the wm.
rendering_requested: RenderingRequested = .init,

/// The currently rendered position/dimensions of the window in the scene graph
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

/// Pointer-driven operation owned by the integrated policy. Interactive motion
/// must remain attached to the cursor, so ordinary position easing is bypassed
/// while this is set. The resize variant is also forwarded to xdg_toplevel so
/// clients can use their interactive-resize rendering path.
interactive: enum { none, move, resize } = .none,

/// The compositor-owned overview has already captured this window and is
/// presenting its frozen clone. Keep every live scene path suppressed across
/// intervening render transactions until overview teardown restores it.
overview_hidden: bool = false,

/// Position animation state. `anim_target_{x,y}` is the destination requested by
/// the window manager; `anim_{x,y}` is the eased value actually written to the
/// scene node each frame. `renderFinish` feeds the target in and snaps on the
/// first placement / fullscreen state changes / hidden transitions; `Output.handleFrame` drives
/// the interpolation while `anim_active` is set. All of this compiles out when
/// `-Danimations=false` (see `fx.anim_enabled`).
anim_target_x: f64 = 0,
anim_target_y: f64 = 0,
anim_x: f64 = 0,
anim_y: f64 = 0,
anim_active: bool = false,
anim_initialized: bool = false,
/// Fullscreen style committed by the previous render transaction.
rendered_fullscreen: bool = false,
/// Fixed global viewport for an output-local workspace transition. Ordinary
/// window moves leave this null so floating windows can still span outputs.
anim_viewport: ?wlr.Box = null,
/// Set once a window's presentation has been seeded off-screen for the current
/// workspace-swap slide, so the seeding only happens on the first transition
/// frame. Reset at the start of each transition in `Output.activateWorkspace`.
slide_seeded: bool = false,
/// Smoothing rate to use for the current in-flight animation. Defaults to the
/// ordinary `fx.anim_rate`; set to `fx.workspace_slide_rate` while a
/// workspace-swap slide is running so the transition can be paced separately.
cur_anim_rate: f64 = fx.anim_rate,

foreign_toplevel_handle: ?*wlr.ExtForeignToplevelHandleV1 = null,
wlr_toplevel_handle: ?*wlr.ForeignToplevelHandleV1 = null,

/// State last pushed to wlr_toplevel_handle, so we don't re-send identical updates.
wlr_toplevel_sent: struct {
    activated: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    fullscreen: bool = false,
    parent: ?*wlr.ForeignToplevelHandleV1 = null,
} = .{},

/// Set of wlr_outputs currently "entered" on the wlr_toplevel_handle.
/// Used so we only emit outputEnter / outputLeave on diffs.
wlr_toplevel_outputs: std.AutoArrayHashMapUnmanaged(*wlr.Output, void) = .{},

/// Listeners for foreign-toplevel-management client requests
/// (e.g. clicking a window in the Noctalia dock). They are wired up when
/// `wlr_toplevel_handle` is created and removed when it is destroyed.
ftm_request_maximize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized) =
    .init(handleFtmRequestMaximize),
ftm_request_minimize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized) =
    .init(handleFtmRequestMinimize),
ftm_request_activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated) =
    .init(handleFtmRequestActivate),
ftm_request_fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen) =
    .init(handleFtmRequestFullscreen),
ftm_request_close: wl.Listener(*wlr.ForeignToplevelHandleV1) =
    .init(handleFtmRequestClose),

pub fn policySnapshot(window: *const Window) PolicySnapshot {
    const parent = window.getParent();
    const parent_handle: ?u64 = if (parent) |parent_window| @bitCast(parent_window.ref) else null;
    // A transient belongs with its parent even before its own first map. This
    // also lets the integrated policy choose the correct output for the
    // initial configure instead of defaulting every new dialog to output 0.
    // After the parent edge has been consumed, explicit workspace rules and
    // user moves remain authoritative.
    const effective_workspace = if (parent) |parent_window|
        if (window.policy_state.auto_float_parent != parent_handle.?)
            parent_window.workspace orelse window.workspace
        else
            window.workspace
    else
        window.workspace;
    const output = if (effective_workspace) |workspace| workspace.output else null;
    const admitted = window.state != .init and window.state != .closing;
    const workspace_visible = output == null or output.?.policyWorkspaceActive(effective_workspace);
    // A ready/initialized toplevel must remain visible to integrated policy
    // until it maps, even when an initial-placement rule assigned it directly
    // to an inactive workspace. Otherwise it is omitted before policy can give
    // it dimensions, so xdg-shell can never complete the initial configure.
    // renderFinish() independently gates the scene tree on workspace activity,
    // so admitting the pre-map window here cannot expose it on the active
    // workspace.
    const active = admitted and (window.state != .mapped or workspace_visible);
    return .{
        .handle = @bitCast(window.ref),
        .parent_handle = parent_handle,
        .output_id = if (output) |value| value.policyId() else null,
        .active = active,
        // The protocol implementation has already been destroyed by the time a
        // closing window reaches the integrated policy snapshot. Its metadata
        // accessors deliberately reject that state, and inactive windows are
        // filtered by the caller anyway.
        .app_id = if (active) window.getAppId() else null,
        .title = if (active) window.getTitle() else null,
        .tag = if (active) window.getTag() else null,
        .content_type = window.content_type,
        .accepts_focus = window.wm_scheduled.accepts_focus,
        .fullscreen = window.wm_requested.fullscreen != null,
        .min_width = @intCast(window.wm_scheduled.dimensions_hint.min_width),
        .min_height = @intCast(window.wm_scheduled.dimensions_hint.min_height),
        .max_width = @intCast(window.wm_scheduled.dimensions_hint.max_width),
        .max_height = @intCast(window.wm_scheduled.dimensions_hint.max_height),
        .base_width = @intCast(window.wm_scheduled.dimensions_hint.base_width),
        .base_height = @intCast(window.wm_scheduled.dimensions_hint.base_height),
        .width_inc = @intCast(window.wm_scheduled.dimensions_hint.width_inc),
        .height_inc = @intCast(window.wm_scheduled.dimensions_hint.height_inc),
        .min_aspect_num = @intCast(window.wm_scheduled.dimensions_hint.min_aspect_num),
        .min_aspect_den = @intCast(window.wm_scheduled.dimensions_hint.min_aspect_den),
        .max_aspect_num = @intCast(window.wm_scheduled.dimensions_hint.max_aspect_num),
        .max_aspect_den = @intCast(window.wm_scheduled.dimensions_hint.max_aspect_den),
        // rendering_scheduled tracks the newest client-committed dimensions,
        // including the first natural-size buffer before renderFinish has
        // copied it into box.
        .preferred_width = @intCast(window.rendering_scheduled.width),
        .preferred_height = @intCast(window.rendering_scheduled.height),
    };
}

/// Send an unspecified-size initial configure so a native XDG client can
/// choose its natural dimensions. XWayland windows already have a mapped
/// client-selected size before integrated policy admits them.
pub fn policyRequestNaturalSize(window: *Window) bool {
    if (window.state != .ready or window.impl != .toplevel) return false;
    window.wm_requested.dimensions = .{ .width = 0, .height = 0 };
    return true;
}

pub fn policyApplyPlacement(
    window: *Window,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    output_scale: f32,
    output_origin_x: i32,
    output_origin_y: i32,
    clip: ?wlr.Box,
    visible: bool,
    border_width: u31,
    border_color: u32,
    corner_radius: u31,
    tiled: bool,
    maximized: bool,
) void {
    if (width > 0 and height > 0) {
        const target_width: u31 = @intCast(width);
        const target_height: u31 = @intCast(height);
        // The integrated policy recomputes the complete layout on every manage
        // cycle. Do not turn an unchanged placement back into a fresh configure:
        // doing so makes a harmless redundant dirty notification feed another
        // full configure/render pass (and used to produce alternating trace
        // fingerprints because manageFinish clears wm_requested.dimensions).
        if (window.configure_sent.width != target_width or
            window.configure_sent.height != target_height)
        {
            window.wm_requested.dimensions = .{ .width = target_width, .height = target_height };
        }
    } else if (visible) {
        return;
    }
    window.rendering_requested.x = x;
    window.rendering_requested.y = y;
    const grid = scaling.PhysicalGrid.init(output_scale);
    window.rendering_requested.precise_x = grid.snapFromOrigin(
        @floatFromInt(x),
        @floatFromInt(output_origin_x),
    );
    window.rendering_requested.precise_y = grid.snapFromOrigin(
        @floatFromInt(y),
        @floatFromInt(output_origin_y),
    );
    window.rendering_requested.output_scale = output_scale;
    window.rendering_requested.output_origin_x = output_origin_x;
    window.rendering_requested.output_origin_y = output_origin_y;
    // Placement is a complete rendering contract. Clear clips requested by a
    // previous scrolling layout when the new layout does not provide one.
    window.rendering_requested.clip = clip orelse .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    window.rendering_requested.hidden = !visible;
    window.wm_requested.tiled = if (tiled) .{ .top = true, .bottom = true, .left = true, .right = true } else .{};
    window.wm_requested.maximized = maximized;
    const expand: u32 = 0x01010101;
    window.rendering_requested.border = .{
        .edges = if (border_width > 0) .{ .top = true, .bottom = true, .left = true, .right = true } else .{},
        .width = border_width,
        .corner_radius = if (build_options.vulkan_effects) corner_radius else 0,
        .r = ((border_color >> 16) & 0xff) * expand,
        .g = ((border_color >> 8) & 0xff) * expand,
        .b = (border_color & 0xff) * expand,
        .a = ((border_color >> 24) & 0xff) * expand,
    };
    window.node.link.remove();
    server.wm.rendering_requested.list.append(&window.node);
}

pub fn policyBeginInteractive(window: *Window, resize: bool) void {
    const next: @TypeOf(window.interactive) = if (resize) .resize else .move;
    if (window.interactive == next) return;

    // Pointer-driven operations use the settled logical geometry directly.
    window.cancelSlide();
    window.interactive = next;

    const resizing = next == .resize;
    if (window.wm_requested.resizing != resizing) {
        window.wm_requested.resizing = resizing;
        server.wm.dirtyWindowing();
    }
}

pub fn policyEndInteractive(window: *Window) void {
    if (window.interactive == .none) return;
    const was_resizing = window.interactive == .resize;
    window.interactive = .none;
    if (was_resizing and window.wm_requested.resizing) {
        window.wm_requested.resizing = false;
        server.wm.dirtyWindowing();
    }
}

pub fn policyApplyVisualRule(
    window: *Window,
    blur: ?bool,
    opacity: ?f64,
    hdr_expand: ?bool,
    buffer_scale_policy: scaling.BufferScalePolicy,
    overlay_plane: OverlayPreference,
    force_ssd: bool,
) void {
    window.rendering_requested.blur_enabled = blur orelse true;
    if (opacity) |fraction| {
        const clamped = std.math.clamp(fraction, 0, 1);
        window.rendering_requested.opacity = @intFromFloat(clamped * @as(f64, @floatFromInt(std.math.maxInt(u32))));
    } else window.rendering_requested.opacity = null;
    window.hdr_expand_rule = hdr_expand;
    window.rendering_requested.buffer_scale_policy = buffer_scale_policy;
    window.rendering_requested.overlay_plane = overlay_plane;
    // Integrated policy owns this value outright. Recompute it on every cycle
    // so disabling force_ssd or losing the xdg-decoration object cannot leave
    // server-side mode stuck on from an earlier transaction.
    window.wm_requested.ssd = integratedSsdMode(force_ssd, window.hasXdgDecoration());
}

fn integratedSsdMode(force_ssd: bool, has_xdg_decoration: bool) bool {
    return force_ssd and has_xdg_decoration;
}

fn hasXdgDecoration(window: *const Window) bool {
    return switch (window.impl) {
        .toplevel => |*toplevel| toplevel.decoration != null,
        .xwayland, .destroying => false,
    };
}

test "integrated SSD policy follows force setting and protocol capability" {
    try std.testing.expect(!integratedSsdMode(false, false));
    try std.testing.expect(!integratedSsdMode(false, true));
    try std.testing.expect(!integratedSsdMode(true, false));
    try std.testing.expect(integratedSsdMode(true, true));
}

pub fn overlayPreference(window: *const Window) OverlayPreference {
    return window.rendering_requested.overlay_plane;
}

/// Return the live scene buffer for the window's root surface. Subsurfaces and
/// popups intentionally cannot become the one output-layer candidate.
pub fn overlaySceneBuffer(window: *Window) ?*wlr.SceneBuffer {
    const Context = struct {
        root: *wlr.Surface,
        result: *?*wlr.SceneBuffer,
    };
    const root = window.rootSurface() orelse return null;
    var result: ?*wlr.SceneBuffer = null;
    var context: Context = .{ .root = root, .result = &result };
    window.surfaces.tree.node.forEachBuffer(
        *Context,
        struct {
            fn iterator(
                buffer: *wlr.SceneBuffer,
                _: c_int,
                _: c_int,
                ctx: *Context,
            ) void {
                const scene_surface = wlr.SceneSurface.tryFromBuffer(buffer) orelse return;
                if (scene_surface.surface == ctx.root) ctx.result.* = buffer;
            }
        }.iterator,
        &context,
    );
    return result;
}

pub fn policySetFullscreen(window: *Window, output: ?*Output) void {
    window.wm_requested.fullscreen = output;
    window.wm_requested.inform_fullscreen = true;
}

pub fn policyClearFullscreen(window: *Window) void {
    window.wm_requested.fullscreen = null;
    window.wm_requested.inform_fullscreen = false;
}

pub fn policyTrace(window: *const Window, hasher: *std.hash.Wyhash) void {
    const handle: u64 = @bitCast(window.ref);
    hasher.update(std.mem.asBytes(&handle));
    const has_dimensions = window.wm_requested.dimensions != null;
    hasher.update(std.mem.asBytes(&has_dimensions));
    const dimensions = window.wm_requested.dimensions orelse Dimensions{ .width = 0, .height = 0 };
    hasher.update(std.mem.asBytes(&dimensions.width));
    hasher.update(std.mem.asBytes(&dimensions.height));
    hasher.update(std.mem.asBytes(&window.rendering_requested.x));
    hasher.update(std.mem.asBytes(&window.rendering_requested.y));
    hasher.update(std.mem.asBytes(&window.rendering_requested.precise_x));
    hasher.update(std.mem.asBytes(&window.rendering_requested.precise_y));
    hasher.update(std.mem.asBytes(&window.rendering_requested.output_scale));
    hasher.update(std.mem.asBytes(&window.rendering_requested.buffer_scale_policy));
    hasher.update(std.mem.asBytes(&window.rendering_requested.hidden));
    const fullscreen = window.wm_requested.fullscreen != null;
    hasher.update(std.mem.asBytes(&fullscreen));
    const workspace_id: u32 = if (window.workspace) |workspace| workspace.policyId() else 0;
    hasher.update(std.mem.asBytes(&workspace_id));
}

pub fn create(impl: Impl) error{OutOfMemory}!*Window {
    assert(impl != .destroying);

    const window = try util.gpa.create(Window);
    errdefer util.gpa.destroy(window);

    const key = try server.wm.windows.put(util.gpa, window);
    errdefer server.wm.windows.remove(key);

    const tree = try server.scene.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.scene.layers.popups.createSceneTree();
    errdefer popup_tree.node.destroy();

    const backdrop_blur = fx.createWindowBlur(tree);

    window.* = .{
        .ref = .{ .key = key },
        .node = undefined,
        .impl = impl,
        .tree = tree,
        .backdrop_blur = backdrop_blur,
        .fullscreen_background = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1 }),
        .blur_marker = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1.0 / 255.0 }),
        .decorations_below = undefined,
        .decorations_below_tree = try tree.createSceneTree(),
        .surfaces = try Scene.SaveableSurfaces.init(tree),
        .border = .{
            .rounded_outline = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .left = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .right = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .top = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .bottom = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
        },
        .decorations_above = undefined,
        .decorations_above_tree = try tree.createSceneTree(),
        .popup_tree = popup_tree,
        .capture_scene = try wlr.Scene.create(),
        .workspace_link = undefined,
    };
    errdefer window.capture_scene.tree.node.destroy();

    window.node.init(.window);
    window.workspace_link.init();

    window.decorations_below.init();
    window.decorations_above.init();

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);
    window.fullscreen_background.node.setEnabled(false);
    window.blur_marker.node.setEnabled(false);
    if (window.backdrop_blur) |blur| {
        fx.configureWindowBlur(blur, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, 0, false);
    }

    // The outline is a window-sized visual rectangle whose center is removed
    // by the effects shader. Exclude it from hit-testing so the shader-only
    // transparent area cannot block pointer focus on the client surface.
    fx.setRectInputEnabled(window.border.rounded_outline, false);
    fx.setRectInputEnabled(window.blur_marker, false);
    fx.setRectInputEnabled(window.fullscreen_background, false);
    // Allocate once at construction. Animation frames only update this state.
    for ([_]*wlr.SceneTree{ tree, popup_tree, window.surfaces.tree, window.surfaces.saved_tree, window.decorations_above_tree, window.decorations_below_tree }) |presentation_tree| {
        if (!wlr_scene_node_set_presentation(&presentation_tree.node, 0, 0, null, true, null))
            return error.OutOfMemory;
    }

    window.capture_scene.restack_xwayland_surfaces = false;

    try SceneNodeData.attach(&window.tree.node, .{ .window = window });
    try SceneNodeData.attach(&window.popup_tree.node, .{ .window = window });

    return window;
}

/// It's safe to destroy the window after we no longer need the saved buffers
/// for frame perfection. We no longer need the saved buffers after the manage
/// sequence in which the closed event was sent is completed and the following
/// render sequence is completed as well.
pub fn destroy(window: *Window) void {
    assert(window.impl == .destroying);

    switch (window.state) {
        .init => {},
        .closing => {
            server.wm.dirtyWindowing();
            return;
        },
        .ready, .initialized, .mapped => unreachable,
    }
    assert(window.object == null);
    window.forgetOutputHome();

    // A backend destroy event can arrive after policy assigned the window to a
    // workspace but before the surface ever mapped. Those windows never receive
    // an unmap event, so keep destruction as the final ownership boundary: no
    // intrusive workspace link may outlive the Window allocation.
    if (window.workspace != null) {
        log.err("destroying window still attached to a workspace; detaching defensively", .{});
        window.clearWorkspace();
    }
    assert(window.workspace_link.prev == &window.workspace_link);
    assert(window.workspace_link.next == &window.workspace_link);

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            assert(seat.focused != .window or seat.focused.window != window);
        }
    }

    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.safeIterator(.forward);
        while (it.next()) |decoration| decoration.destroy();
    }

    window.tree.node.destroy();
    window.popup_tree.node.destroy();
    window.capture_scene.tree.node.destroy();

    window.node.deinit();

    server.aqueous.forgetWindow(@bitCast(window.ref));
    server.wm.windows.remove(window.ref.key);

    util.gpa.destroy(window);
}

/// Assign this window to the given workspace, removing it from any previous one.
pub fn setWorkspace(window: *Window, workspace: *Workspace) void {
    window.forgetOutputHome();
    window.assignWorkspace(workspace);
}

fn assignWorkspace(window: *Window, workspace: *Workspace) void {
    window.output_recovery = null;
    if (window.workspace == workspace) return;
    // Presentation clipping belongs to the original workspace/output viewport.
    window.cancelSlide();
    window.workspace_link.remove();
    workspace.windows.append(window);
    window.workspace = workspace;
    // Fullscreen geometry and output policy must follow the window's workspace.
    if (window.wm_requested.fullscreen != null) {
        window.wm_requested.fullscreen = workspace.output;
    }
    // Reaping the emptied source workspace and ensuring a trailing empty are
    // deferred to the coalesced workspace cycle so a workspace is never freed
    // synchronously while another in-flight request still references it.
    server.wm.dirtyWindowing();
    server.workspace_manager.dirty();
}

/// Remove this window from its workspace, if any.
pub fn clearWorkspace(window: *Window) void {
    window.forgetOutputHome();
    window.output_recovery = null;
    if (window.workspace == null) return;
    window.detachWorkspace();
    // Reaping is deferred to the coalesced workspace cycle (see setWorkspace).
    server.wm.dirtyWindowing();
    server.workspace_manager.dirty();
}

/// Detach this window from its workspace without any further side effects.
/// Safe to call while the owning output iterates its workspace list.
pub fn detachWorkspace(window: *Window) void {
    if (window.workspace == null) return;
    window.workspace_link.remove();
    window.workspace_link.init();
    window.workspace = null;
    // Clear presentation state when the window leaves its workspace.
    window.cancelSlide();
}

/// Restore removal placement before snapshots admit unassigned windows onto
/// the active workspace. Failed allocations leave the saved placement intact.
pub fn recoverOutput(window: *Window, output: *Output) void {
    const recovery = window.output_recovery orelse return;
    const workspace = output.ensureWorkspaceNumber(recovery.workspace_number) orelse return;
    window.recoverWorkspace(workspace);
}

/// Record only the first departure: losing a temporary fallback must not
/// replace the original connector with the intermediate output's identity.
pub fn rememberOutputHome(window: *Window, name: []const u8, number: u32) void {
    if (window.output_home != null or name.len == 0) return;
    const owned_name = util.gpa.dupe(u8, name) catch {
        log.err("out of memory saving window's original output", .{});
        return;
    };
    window.output_home = .{ .name = owned_name, .workspace_number = number };
}

fn forgetOutputHome(window: *Window) void {
    if (window.output_home) |home| util.gpa.free(home.name);
    window.output_home = null;
}

/// Run after output management and before snapshots, including for windows on
/// inactive workspaces. An unrelated hotplug must not consume the return target.
pub fn restoreOutputHome(window: *Window) void {
    const home = window.output_home orelse return;
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (!output.policyTransferTarget() or !std.mem.eql(u8, output.policyName(), home.name)) continue;
        const box = output.policyFullBox();
        if (box.width <= 0 or box.height <= 0) continue;
        const workspace = output.ensureWorkspaceNumber(home.workspace_number) orelse return;
        server.aqueous.cancelRemovedOutputDrag(@bitCast(window.ref));
        window.recoverWorkspace(workspace);
        window.forgetOutputHome();
        return;
    }
}

fn recoverWorkspace(window: *Window, workspace: *Workspace) void {
    const fullscreen = if (window.output_recovery) |recovery| recovery.fullscreen else window.wm_requested.fullscreen != null;
    window.assignWorkspace(workspace);
    const output = workspace.output;
    if (fullscreen) window.policySetFullscreen(output);
    switch (window.wm_scheduled.fullscreen_requested) {
        .fullscreen => window.wm_scheduled.fullscreen_requested = .{ .fullscreen = output },
        .no_request, .exit => {},
    }
    window.policy_state.needs_output_recovery = true;
}

pub fn setDimensionsHint(window: *Window, hint: DimensionsHint) void {
    window.wm_scheduled.dimensions_hint = hint;
    if (!meta.eql(window.wm_sent.dimensions_hint, hint)) {
        server.wm.dirtyWindowing();
    }
}

pub fn setDimensions(window: *Window, width: u31, height: u31) void {
    window.rendering_scheduled.width = width;
    window.rendering_scheduled.height = height;

    const rendering_changed = window.rendering_scheduled.resend_dimensions or
        window.rendering_scheduled.width != window.rendering_sent.width or
        window.rendering_scheduled.height != window.rendering_sent.height;

    // A transient waiting for its toolkit-selected natural size was omitted
    // from the previous layout. Once a real size arrives it needs policy to
    // place it; invalidating rendering alone leaves the placeholder geometry
    // in place until unrelated input (commonly pointer motion) starts a cycle.
    if (window.policy_state.pending_natural_parent != 0 and width > 0 and height > 0) {
        server.wm.dirtyWindowing();
    } else if (rendering_changed) {
        server.wm.dirtyRendering();
    }
}

pub fn setDecorationHint(window: *Window, hint: aqueous.WindowV1.DecorationHint) void {
    window.wm_scheduled.decoration_hint = hint;
    if (hint != window.wm_sent.decoration_hint) {
        server.wm.dirtyWindowing();
    }
}

pub fn setAcceptsFocus(window: *Window, accepts_focus: bool) void {
    window.wm_scheduled.accepts_focus = accepts_focus;
    if (accepts_focus != window.wm_sent.accepts_focus) {
        server.wm.dirtyWindowing();
    }
}

/// Send dirty state as part of a manage sequence.
pub fn manageStart(window: *Window) void {
    switch (window.state) {
        .init => {},
        .closing => window.finishUnmap(),
        .ready, .initialized, .mapped => {
            const wm_v1 = server.wm.object orelse return;
            const new = window.object == null;
            const window_v1 = window.object orelse blk: {
                const window_v1 = aqueous.WindowV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                    log.err("out of memory", .{});
                    return; // try again next update
                };
                window.object = window_v1;
                window_v1.setHandler(*Window, handleRequest, handleDestroy, window);
                wm_v1.sendWindow(window_v1);

                window.node.link.remove();
                server.wm.rendering_requested.list.append(&window.node);

                // External policy needs the ext identifier before the first map
                // so it can satisfy aqueous_window_v1.identifier's send-once
                // contract. Integrated policy publishes from map() instead.
                window.publishForeignToplevels();

                break :blk window_v1;
            };

            errdefer comptime unreachable;

            if (new) {
                if (window_v1.getVersion() >= 2) {
                    window_v1.sendUnreliablePid(window.unreliablePid());
                }
                if (window_v1.getVersion() >= 4) {
                    if (window.foreign_toplevel_handle) |handle| {
                        window_v1.sendIdentifier(handle.identifier);
                    }
                }
            }

            const scheduled = &window.wm_scheduled;
            const sent = &window.wm_sent;

            if (new or !meta.eql(scheduled.dimensions_hint, sent.dimensions_hint)) {
                window_v1.sendDimensionsHint(
                    scheduled.dimensions_hint.min_width,
                    scheduled.dimensions_hint.min_height,
                    scheduled.dimensions_hint.max_width,
                    scheduled.dimensions_hint.max_height,
                );
                sent.dimensions_hint = scheduled.dimensions_hint;
            }
            if (new or scheduled.decoration_hint != sent.decoration_hint) {
                window_v1.sendDecorationHint(window.wm_scheduled.decoration_hint);
                sent.decoration_hint = scheduled.decoration_hint;
            }
            if (new or scheduled.accepts_focus != sent.accepts_focus) {
                // focus_hint (aqueous-window-management-v1 >= 9). Older wm clients won't see it.
                if (window_v1.getVersion() >= 9) {
                    window_v1.sendFocusHint(@as(u32, @intFromBool(scheduled.accepts_focus)));
                }
                sent.accepts_focus = scheduled.accepts_focus;
            }

            if (scheduled.show_window_menu_requested) |offset| {
                window_v1.sendShowWindowMenuRequested(offset.x, offset.y);
                scheduled.show_window_menu_requested = null;
            }
            switch (scheduled.fullscreen_requested) {
                .no_request => {},
                .fullscreen => |output_hint| {
                    if (output_hint) |output| {
                        window_v1.sendFullscreenRequested(output.object);
                    } else {
                        window_v1.sendFullscreenRequested(null);
                    }
                },
                .exit => window_v1.sendExitFullscreenRequested(),
            }
            scheduled.fullscreen_requested = .no_request;
            switch (scheduled.maximize_requested) {
                .no_request => {},
                .maximize => window_v1.sendMaximizeRequested(),
                .unmaximize => window_v1.sendUnmaximizeRequested(),
            }
            scheduled.maximize_requested = .no_request;
            switch (scheduled.minimize_requested) {
                .no_request => {},
                .minimize => window_v1.sendMinimizeRequested(),
                .unminimize => if (window_v1.getVersion() >= 5) {
                    window_v1.sendUnminimizeRequested();
                },
            }
            scheduled.minimize_requested = .no_request;

            if (window.getParent()) |parent| {
                if (sent.parent == null or sent.parent.?.get() != parent) {
                    window_v1.sendParent(parent.object);
                    sent.parent = parent.ref;
                }
            } else if (sent.parent != null) {
                window_v1.sendParent(null);
                sent.parent = null;
            }

            if (new or scheduled.dirty_app_id) {
                window_v1.sendAppId(window.getAppId());
                scheduled.dirty_app_id = false;
            }
            if (new or scheduled.dirty_title) {
                window_v1.sendTitle(window.getTitle());
                scheduled.dirty_title = false;
            }

            if (scheduled.pointer_move_requested) |seat| {
                if (seat.object) |seat_v1| {
                    log.debug("send pointer move requested", .{});
                    window_v1.sendPointerMoveRequested(seat_v1);
                }
            }
            scheduled.pointer_move_requested = null;
            if (scheduled.pointer_resize_requested) |data| {
                if (data.seat.object) |seat_v1| {
                    log.debug("send pointer resize requested", .{});
                    window_v1.sendPointerResizeRequested(seat_v1, data.edges);
                }
            }
            scheduled.pointer_resize_requested = null;
        },
    }
}

pub fn makeInert(window: *Window) void {
    if (window.object) |window_v1| {
        window_v1.sendClosed();
        window_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        handleDestroy(window_v1, window);
    } else {
        assert(window.node.object == null);
    }
}

/// Complete the policy-side teardown of an unmapped window.
///
/// This normally runs from manageStart(), but an xdg_surface may unmap and
/// immediately make its next bufferless initial commit in the same Wayland
/// event-loop dispatch. In that case the idle manage cycle has not run yet,
/// and XdgToplevel must complete this transition before admitting the remap.
pub fn finishUnmap(window: *Window) void {
    assert(window.state == .closing);

    window.policy_state.cancelPendingNaturalSize();
    window.state = .init;
    window.wm_sent = .{};
    window.wm_requested = .init;
    window.configure_scheduled = .init;
    window.configure_sent = .init;
    window.force_configure = false;
    window.rendering_sent = .{};
    window.rendering_requested = .init;

    window.node.link.remove();
    window.node.link.init();

    window.makeInert();
}

fn pinnedByName(output: *Output, name: [:0]const u8) ?*Workspace {
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |ws| {
        if (ws.pinned and std.mem.eql(u8, ws.name, name)) return ws;
    }
    return null;
}

fn handleRequestInert(
    window_v1: *aqueous.WindowV1,
    request: aqueous.WindowV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) window_v1.destroy();
}

fn handleDestroy(_: *aqueous.WindowV1, window: *Window) void {
    window.object = null;
    window.wm_requested = .init;
    window.rendering_requested = .{
        .x = window.rendering_requested.x,
        .y = window.rendering_requested.y,
        .precise_x = window.rendering_requested.precise_x,
        .precise_y = window.rendering_requested.precise_y,
        .output_scale = window.rendering_requested.output_scale,
        .output_origin_x = window.rendering_requested.output_origin_x,
        .output_origin_y = window.rendering_requested.output_origin_y,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    server.wm.dirtyWindowing();
    window.node.makeInert();
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| decoration.makeInert();
    }
    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                seat.focus(.none);
            }
        }
    }
}

fn handleRequest(
    window_v1: *aqueous.WindowV1,
    request: aqueous.WindowV1.Request,
    window: *Window,
) void {
    assert(window.object == window_v1);
    const wm_requested = &window.wm_requested;
    const rendering_requested = &window.rendering_requested;
    switch (request) {
        .destroy => window_v1.destroy(),
        .close => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.close = true;
        },
        .get_node => |args| {
            if (window.node.object != null) {
                window_v1.postError(.node_exists, "window already has a node object");
                return;
            }
            window.node.createObject(window_v1.getClient(), window_v1.getVersion(), args.id);
        },
        .propose_dimensions => |args| {
            if (!server.wm.ensureWindowing()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_dimensions, "dimensions must be greater than or equal to 0 ");
                return;
            }
            wm_requested.dimensions = .{
                .width = @intCast(args.width),
                .height = @intCast(args.height),
            };
        },
        .hide => {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.hidden = true;
        },
        .show => {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.hidden = false;
        },
        .set_workspace => |args| {
            const workspace = WorkspaceManager.workspaceForResource(args.workspace) orelse return;
            window.setWorkspace(workspace);
        },
        .use_ssd => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.ssd = true;
        },
        .use_csd => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.ssd = false;
        },
        .set_borders => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0) {
                window_v1.postError(.invalid_border, "border width must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.border = .{
                .edges = args.edges,
                .width = @intCast(args.width),
                .r = args.r,
                .g = args.g,
                .b = args.b,
                .a = args.a,
            };
        },
        .set_tiled => |args| {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.tiled = args.edges;
        },
        .set_window_blur => |args| {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.blur_enabled = args.enabled != 0;
        },
        .set_window_opacity => |args| {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.opacity = args.value;
            window.applyOpacity();
        },
        inline .get_decoration_above, .get_decoration_below => |args, req| {
            const above = req == .get_decoration_above;
            const surface = wlr.Surface.fromWlSurface(args.surface);
            const decoration = Decoration.create(
                window_v1.getClient(),
                window_v1.getVersion(),
                args.id,
                surface,
                if (above) window.decorations_above_tree else window.decorations_below_tree,
            ) catch |err| switch (err) {
                error.OutOfMemory, error.ResourceCreateFailed => {
                    window_v1.getClient().postNoMemory();
                    log.err("out of memory", .{});
                    return;
                },
                error.AlreadyHasRole => return,
            };
            if (above) {
                window.decorations_above.append(decoration);
            } else {
                window.decorations_below.append(decoration);
            }
        },
        .inform_resize_start => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.resizing = true;
        },
        .inform_resize_end => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.resizing = false;
        },
        .set_capabilities => |args| {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.capabilities = args.caps;
        },
        .inform_maximized => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.maximized = true;
        },
        .inform_unmaximized => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.maximized = false;
        },
        .inform_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.inform_fullscreen = true;
        },
        .inform_not_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.inform_fullscreen = false;
        },
        .fullscreen => |args| {
            if (!server.wm.ensureWindowing()) return;
            const data = args.output.getUserData() orelse return;
            const output: *Output = @ptrCast(@alignCast(data));
            wm_requested.fullscreen = output;
        },
        .exit_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.fullscreen = null;
        },
        .set_clip_box => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_clip_box, "width/height must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.clip = .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            };
        },
        .set_content_clip_box => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_clip_box, "width/height must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.content_clip = .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            };
        },
        .set_dimension_bounds => |args| {
            if (!server.wm.ensureWindowing()) return;
            if (args.max_width < 0 or args.max_height < 0) {
                window_v1.postError(.invalid_dimensions, "dimensions must be greater than or equal to 0 ");
                return;
            }
            wm_requested.bounds = .{
                .width = @intCast(args.max_width),
                .height = @intCast(args.max_height),
            };
        },
    }
}

/// Conservative repaint demand, including prospective visibility on resume.
pub fn shouldSuspend(window: *Window, prospective: bool) bool {
    if (window.impl != .toplevel or window.state != .mapped) return false;
    const toplevel = &window.impl.toplevel;
    switch (toplevel.configure_state) {
        .idle, .committed => {},
        else => {
            // A timed-out resize still needs its buffer. Suspending it would
            // tell a cooperative client to stop producing the awaited content.
            const sent = window.configure_sent;
            if ((sent.width != null and sent.width.? != toplevel.geometry.width) or
                (sent.height != null and sent.height.? != toplevel.geometry.height)) return false;
        },
    }
    const workspace_visible = if (window.workspace) |ws|
        ws.isActive() or ws.output.prev_workspace == ws
    else
        true;
    var preview = window.anim_active and window.tree.node.enabled;
    if (server.overview.tree.node.enabled) {
        for (server.overview.entries.items) |entry| {
            if (entry.handle == @as(u64, @bitCast(window.ref))) {
                preview = true;
                break;
            }
        }
    }
    if (window.workspace) |ws| {
        if (workspace_visible and ws.output.prev_workspace != null) preview = true;
    }
    const requested = &window.rendering_requested;
    var box: wlr.Box = .{
        .x = requested.x,
        .y = requested.y,
        .width = if (window.wm_requested.dimensions) |d| d.width else window.box.width,
        .height = if (window.wm_requested.dimensions) |d| d.height else window.box.height,
    };
    var clipped = false;
    inline for (.{ requested.clip, requested.content_clip }) |clip| {
        if (!clip.empty()) {
            var global_clip = clip;
            global_clip.x += requested.x;
            global_clip.y += requested.y;
            if (!box.intersection(&box, &global_clip)) clipped = true;
        }
    }
    var output_visible = false;
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        const physical = output.wlr_output orelse continue;
        // Mirrors require a powered source (OutputMirror.source).
        if (!output.current.mirror_of.empty()) continue;
        const powered = (output.current.state == .enabled and physical.enabled) or
            (prospective and output.sent.state == .enabled);
        if (!powered) continue;
        if (preview and window.workspace != null and window.workspace.?.output == output) {
            output_visible = true;
            break;
        }
        const dims = output.sent.dimensions();
        const output_box: wlr.Box = .{ .x = output.sent.x, .y = output.sent.y, .width = @intCast(dims[0]), .height = @intCast(dims[1]) };
        var intersection: wlr.Box = undefined;
        if (!clipped and intersection.intersection(&box, &output_box)) {
            output_visible = true;
            break;
        }
    }
    return @import("xdg_state.zig").suspended(.{
        .mapped = true,
        .capture = window.capture_sessions != 0,
        .desktop = server.scene.normal_tree.node.enabled,
        .output = output_visible,
        .preview = preview,
        .workspace = workspace_visible,
        .hidden = requested.hidden or window.overview_hidden,
        .clipped = clipped,
    });
}

/// Reconcile after settled render state, never configure from a scene callback.
pub fn refreshSuspension(window: *Window) void {
    if (window.impl == .toplevel and window.state == .mapped and
        window.shouldSuspend(false) != window.configure_sent.suspended)
        server.wm.dirtyWindowing();
}

/// Resources alone are not consumers: start/stop run once per capture session.
pub fn trackCaptureSource(window: *Window, source: *wlr.ExtImageCaptureSourceV1) void {
    if (window.capture_source != null) return;
    window.capture_source = source;
    window.capture_original_impl = source.impl;
    window.capture_impl = source.impl.*;
    window.capture_impl.start = captureStart;
    window.capture_impl.stop = captureStop;
    window.capture_impl.request_frame = captureRequestFrame;
    window.capture_impl.copy_frame = captureCopyFrame;
    source.impl = &window.capture_impl;
}

pub fn captureAllowed(window: *const Window) bool {
    return window.state == .mapped and server.lock_manager.state == .unlocked;
}

fn captureRequestFrame(source: *wlr.ExtImageCaptureSourceV1, schedule: bool) callconv(.c) void {
    const window: *Window = @fieldParentPtr("capture_impl", @constCast(source.impl));
    if (!window.captureAllowed()) {
        // Wake an already queued frame even if an unmapped/locked source no
        // longer produces damage. captureCopyFrame fails it before any copy.
        var damage: pixman.Region32 = undefined;
        damage.initRect(0, 0, @max(1, source.width), @max(1, source.height));
        defer damage.deinit();
        var event: wlr.ExtImageCaptureSourceV1.event.Frame = .{ .damage = &damage };
        source.events.frame.emit(&event);
        return;
    }
    if (window.capture_original_impl.request_frame) |request| request(source, schedule);
}

fn captureCopyFrame(source: *wlr.ExtImageCaptureSourceV1, frame: *wlr.ExtImageCopyCaptureFrameV1, event: *wlr.ExtImageCaptureSourceV1.event.Frame) callconv(.c) void {
    const window: *Window = @fieldParentPtr("capture_impl", @constCast(source.impl));
    if (!window.captureAllowed()) {
        frame.fail(.stopped);
        return;
    }
    window.capture_original_impl.copy_frame(source, frame, event);
}

fn captureStart(source: *wlr.ExtImageCaptureSourceV1, cursors: bool) callconv(.c) void {
    const window: *Window = @fieldParentPtr("capture_impl", @constCast(source.impl));
    window.capture_sessions += 1;
    if (window.capture_original_impl.start) |start| start(source, cursors);
    server.wm.dirtyWindowing();
}

fn captureStop(source: *wlr.ExtImageCaptureSourceV1) callconv(.c) void {
    const window: *Window = @fieldParentPtr("capture_impl", @constCast(source.impl));
    assert(window.capture_sessions > 0);
    window.capture_sessions -= 1;
    if (window.capture_original_impl.stop) |stop| stop(source);
    server.wm.dirtyWindowing();
}

/// Apply policy and return whether the transaction must wait for a buffer.
pub fn manageFinish(window: *Window) bool {
    const wm_requested = &window.wm_requested;

    // This can happen if the window is destroyed after being sent to the wm but
    // before being mapped.
    if (window.impl == .destroying) {
        assert(window.state == .closing);
        return false;
    }

    switch (window.state) {
        .init => unreachable,
        .ready => {
            if (wm_requested.dimensions == null and wm_requested.fullscreen == null) {
                return false;
            }
            window.state = .initialized;
        },
        .initialized, .mapped => {},
        .closing => return false,
    }

    if (wm_requested.close) {
        window.close();
        wm_requested.close = false;
    }

    const activated = window.isFocused();
    window.syncForeignToplevelState();

    const width, const height = blk: {
        if (wm_requested.fullscreen) |output| {
            const width, const height = output.sent.dimensions();
            if (window.configure_sent.width != width or
                window.configure_sent.height != height)
            {
                window.configure_scheduled.width = width;
                window.configure_scheduled.height = height;
                window.rendering_scheduled.resend_dimensions = true;
                break :blk .{ width, height };
            }
        } else if (wm_requested.dimensions) |dimensions| {
            window.rendering_scheduled.resend_dimensions = true;
            break :blk .{ dimensions.width, dimensions.height };
        }
        break :blk .{ null, null };
    };
    // A size transaction needs a client buffer even when the window is hidden.
    // Resume in that configure, then reconcile suspension after it settles.
    const suspended = window.shouldSuspend(true) and width == null and height == null;
    wm_requested.dimensions = null;

    window.configure_scheduled = .{
        .suspended = suspended,
        .constrained = if (server.aqueous.mode.runsInternal() and
            !server.aqueous.clientResizeAllowed(@bitCast(window.ref)))
            .{ .top = true, .bottom = true, .left = true, .right = true }
        else
            .{},
        .width = width,
        .height = height,
        .bounds = wm_requested.bounds,
        .activated = activated,
        .ssd = wm_requested.ssd,
        .tiled = wm_requested.tiled,
        .capabilities = wm_requested.capabilities,
        .resizing = wm_requested.resizing,
        .maximized = wm_requested.maximized,
        .inform_fullscreen = wm_requested.inform_fullscreen,
    };

    // Publish the policy-selected scale before the initial/size-changing xdg
    // configure. Clients can allocate their first real buffer at the intended
    // scale, and the wlroots override keeps later scene-output notifications
    // from replacing an integer-ceil preference with the fractional output
    // scale.
    if (window.impl == .toplevel) {
        window.applyPreferredScaleToSurface(window.impl.toplevel.wlr_toplevel.base.surface);
        var popups = server.layer_shell.popups.iterator();
        while (popups.next()) |popup| {
            if (popup.owner != null and popup.owner.? == window.ref) {
                window.applyPreferredScaleToSurface(popup.wlr_popup.base.surface);
            }
        }
    }

    const track_configure = switch (window.impl) {
        .toplevel => |*toplevel| toplevel.configure(),
        .xwayland => |*xwindow| xwindow.configure(),
        .destroying => unreachable,
    };

    if (track_configure and window.state == .mapped) {
        // Only snapshot the surfaces when the configure actually changes the
        // window's dimensions. State-only configures (e.g. the activated flag
        // flipping on every focus change) don't need the old content kept on
        // screen, and the snapshot churn would dirty the optimized-blur backdrop
        // and momentarily drop per-buffer fx state on each focus toggle.
        if (width != null or height != null) {
            window.surfaces.save();
            // The freshly cloned snapshot buffers copy their fx state, but make
            // sure both trees reflect the current opacity regardless.
            window.applyOpacity();
        }
        window.sendFrameDone();
    }

    return track_configure;
}

pub fn applyPreferredScaleToSurface(window: *const Window, surface: *wlr.Surface) void {
    const policy = window.rendering_requested.buffer_scale_policy;
    const advertised_scale = policy.advertisedScale(window.rendering_requested.output_scale);
    const override_scale = switch (policy) {
        .native => 0,
        .integer_ceil => advertised_scale,
    };
    wlr_surface_set_preferred_scale_override(surface, override_scale);
    wlr.FractionalScaleManagerV1.notifyScale(surface, advertised_scale);
    surface.setPreferredBufferScale(@intFromFloat(@ceil(advertised_scale)));
}

pub fn renderStart(window: *Window) void {
    switch (window.impl) {
        .toplevel => |*toplevel| {
            switch (toplevel.configure_state) {
                .inflight, .acked => {
                    // The transaction has timed out for the xdg toplevel, which means a commit
                    // in response to the configure with the inflight width/height has not yet
                    // been made. It may seem that we should therefore leave the current.box
                    // width/height unchanged. However, this would in fact cause visual glitches.
                    //
                    // We must update the dimensions to the current geometry of the
                    // xdg toplevel here in order to handle the following series of events:
                    //
                    // 0. initial state: client has dimensions X
                    // 1. transaction A sends a configure of size Y
                    // 2. transaction A times out - saved surfaces are dropped
                    // 3. transaction B sends a configure of size Z
                    // 4. client commits buffer of size Y
                    // 5. transaction B times out - saved surfaces are dropped
                    //
                    // If we did not use the current geometry of the toplevel at this point
                    // we would be rendering the SSD border at initial size X but the surface
                    // would be rendered at size Y.
                    switch (toplevel.configure_state) {
                        .inflight => |serial| toplevel.configure_state = .{ .timed_out = serial },
                        .acked => toplevel.configure_state = .timed_out_acked,
                        else => unreachable,
                    }
                },
                .committed => {
                    toplevel.configure_state = .idle;
                },
                // A timed_out or timed_out_acked value is possible in the case of a
                // manage sequence followed by two render sequences for example.
                .idle, .timed_out, .timed_out_acked => {},
            }
            window.rendering_scheduled.width = @intCast(toplevel.geometry.width);
            window.rendering_scheduled.height = @intCast(toplevel.geometry.height);
        },
        .xwayland => |xwindow| {
            // Drive the rendered size from the surface's actually-committed
            // buffer rather than the configured `xsurface.width/height`. For
            // async X11 clients (Electron/Discord) the configured size leads
            // the committed buffer, so trusting `xsurface.width/height` every
            // frame makes `drawBorders`/`applySurfaceClip` render the SSD
            // border and clip at a size the surface has not yet committed —
            // the resting artifact. Hold the previously-committed size until
            // the surface actually commits a buffer at the requested size.
            if (xwindow.xsurface.surface) |surface| {
                if (surface.mapped and surface.current.width > 0 and surface.current.height > 0) {
                    const width, const height = xwindow.logicalSize(
                        math.lossyCast(u16, surface.current.width),
                        math.lossyCast(u16, surface.current.height),
                    );
                    window.rendering_scheduled.width = width;
                    window.rendering_scheduled.height = height;
                } else {
                    const width, const height = xwindow.logicalSize(
                        xwindow.xsurface.width,
                        xwindow.xsurface.height,
                    );
                    window.rendering_scheduled.width = width;
                    window.rendering_scheduled.height = height;
                }
            } else {
                const width, const height = xwindow.logicalSize(
                    xwindow.xsurface.width,
                    xwindow.xsurface.height,
                );
                window.rendering_scheduled.width = width;
                window.rendering_scheduled.height = height;
            }
        },
        .destroying => {},
    }

    const sent = &window.rendering_sent;
    const scheduled = &window.rendering_scheduled;

    // Check if mapped to handle timeout of the first configure sent.
    if (window.state == .mapped and
        (scheduled.resend_dimensions or
            scheduled.width != sent.width or scheduled.height != sent.height))
    {
        if (window.object) |window_v1| {
            window_v1.sendDimensions(scheduled.width, scheduled.height);
            window.rendering_scheduled.resend_dimensions = false;
        }
    }
    sent.width = scheduled.width;
    sent.height = scheduled.height;

    const presentation_hint = window.presentationHint();
    if (sent.presentation_hint != presentation_hint) {
        if (window.object) |window_v1| {
            if (window_v1.getVersion() >= 4) {
                window_v1.sendPresentationHint(presentation_hint);
            }
        }
        sent.presentation_hint = presentation_hint;
    }
}

fn presentationHint(window: *Window) aqueous.OutputV1.PresentationMode {
    const root_surface = window.rootSurface() orelse return .vsync;
    return switch (server.tearing_control_manager.hintFromSurface(root_surface)) {
        .async => .async,
        .vsync => .vsync,
        _ => unreachable,
    };
}

pub fn renderFinish(window: *Window) void {
    defer server.overview.refreshDeck(window);
    const requested = &window.rendering_requested;

    // Keep the scene nodes disabled until the render sequence in which the first
    // dimensions event was sent is completed. If we enable the nodes before the
    // window is mapped, there may be an imperfect frame rendered after the window
    // commits its initial buffer and before the render sequence with the first
    // dimensions event is completed.
    // Keeping the nodes enabled while closing is necessary for frame perfection.
    // A window is visible when its workspace is the active one, OR — during a
    // workspace-swap slide — when its workspace is the one currently sliding
    // out. Keeping both the incoming and outgoing workspaces rendered for the
    // duration of the transition lets the swap be a positional slide (driven by
    // the same presentation offset as a normal move) instead of a toggle.
    var is_incoming = false;
    var is_outgoing = false;
    var transition_dir: i32 = 0;
    var output_width: i32 = 0;
    if (window.workspace) |workspace| {
        const ws_output = workspace.output;
        is_incoming = workspace.isActive();
        is_outgoing = ws_output.prev_workspace == workspace;
        transition_dir = ws_output.transition_dir;
        const dims = ws_output.sent.dimensions();
        output_width = @intCast(dims[0]);
    }
    const workspace_visible = (window.workspace == null) or is_incoming or is_outgoing;
    const fullscreen = window.wm_requested.fullscreen;
    const output_enabled = if (window.workspace) |ws| ws.output.sent.state == .enabled else true;
    // Fullscreen geometry changes settle atomically with the transaction.
    const fullscreen_changed = window.rendered_fullscreen != (fullscreen != null) or
        (window.anim_active and fullscreen != null and
            (window.box.width != window.rendering_sent.width or
                window.box.height != window.rendering_sent.height));
    window.rendered_fullscreen = fullscreen != null;
    if (fullscreen_changed) {
        window.cancelSlide();
        // A follow-up configure/focus transaction must not seed this snapped
        // incoming window off-screen again while another window finishes.
        window.slide_seeded = true;
    }
    const transitioning = (is_incoming or is_outgoing) and transition_dir != 0 and
        !fullscreen_changed;
    // Capture the prior settled visibility before applying this transaction.
    // Scrolling layouts keep a fixed clip even for off-screen placements, so a
    // previously visible member can animate out through that aperture instead
    // of disappearing on the first frame of the viewport change.
    const was_enabled = window.tree.node.enabled;
    const enabled = workspace_visible and !requested.hidden and !window.overview_hidden and
        (window.state == .mapped or window.state == .closing);
    window.tree.node.setEnabled(enabled);
    window.popup_tree.node.setEnabled(enabled);

    if (!workspace_visible) window.cancelSlide();

    window.box.width = window.rendering_sent.width;
    window.box.height = window.rendering_sent.height;

    // Workspace motion applies independently of fullscreen styling. Live input
    // geometry settles at the destination; only presentation is eased.
    const base_x = if (fullscreen) |output| output.sent.x else requested.x;
    const base_y = if (fullscreen) |output| output.sent.y else requested.y;
    window.anim_viewport = if (transitioning)
        window.workspace.?.output.current.box()
    else
        null;
    if (window.interactive != .none and fullscreen == null) {
        window.setAnimationTarget(base_x, base_y, false);
    } else if (transitioning and is_outgoing) {
        window.setAnimationTarget(base_x - transition_dir * output_width, base_y, true);
        window.cur_anim_rate = server.wm.workspace_transition.rate;
    } else if (transitioning and is_incoming and !window.slide_seeded) {
        // A reversal reuses the current visual position instead of reseeding an
        // already-visible window at the opposite edge of the output.
        if (window.anim_active) {
            window.setAnimationTarget(base_x, base_y, true);
            window.cur_anim_rate = server.wm.workspace_transition.rate;
        } else {
            window.beginSlideFrom(base_x + transition_dir * output_width, base_y, base_x, base_y);
        }
        window.slide_seeded = true;
    } else if (transitioning and is_incoming) {
        window.setAnimationTarget(base_x, base_y, true);
        window.cur_anim_rate = server.wm.workspace_transition.rate;
    } else if (fullscreen != null or fullscreen_changed or window.interactive != .none or !output_enabled) {
        // Fullscreen changes and pointer-driven geometry snap. Disabled
        // outputs cannot advance a new animation after their slide is cancelled.
        window.setAnimationTarget(base_x, base_y, false);
    } else {
        // Retain scrolling motion across a follow-up focus transaction even
        // when the leaving live tree has already been disabled by its viewport.
        const leaving_scrolling_viewport = (was_enabled or window.anim_active) and
            workspace_visible and !window.overview_hidden and
            window.state == .mapped and !requested.clip.empty();
        window.setAnimationTarget(base_x, base_y, enabled or leaving_scrolling_viewport);
    }

    const presenting = enabled or (window.anim_active and workspace_visible and
        !window.overview_hidden and window.state == .mapped);
    window.tree.node.setEnabled(presenting);
    window.popup_tree.node.setEnabled(presenting);

    var clip: wlr.Box = requested.clip;
    var content_clip: wlr.Box = requested.content_clip;
    if (fullscreen) |output| {
        const width, const height = output.sent.dimensions();
        clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    window.syncFullscreenBackground();
    window.drawBorders();
    window.refreshBackdropBlur();

    // Snap the settled animation target, not the requested layout position:
    // outgoing workspace windows keep their requested position but use an
    // off-screen box target until the transition is finalized.
    const grid = scaling.PhysicalGrid.init(requested.output_scale);
    const output_origin_x: f64 = @floatFromInt(requested.output_origin_x);
    const output_origin_y: f64 = @floatFromInt(requested.output_origin_y);
    const live_x = grid.snapFromOrigin(@floatFromInt(window.box.x), output_origin_x);
    const live_y = grid.snapFromOrigin(@floatFromInt(window.box.y), output_origin_y);
    wlr_scene_node_set_position_f64(
        &window.tree.node,
        live_x,
        live_y,
    );
    wlr_scene_node_set_position_f64(
        &window.popup_tree.node,
        live_x,
        live_y,
    );

    switch (window.impl) {
        .xwayland => |*xwindow| _ = xwindow.configure(),
        .toplevel, .destroying => {},
    }

    window.applySurfaceClip(&clip, &content_clip);
    window.applySurfaceVisualState();
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| {
            const no_clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            decoration.renderFinish(&no_clip);
        }
    }
    window.updatePresentation();
}

/// Visible content in committed logical layout coordinates, excluding borders.
pub fn focusWarpBox(window: *Window) ?wlr.Box {
    if (window.state != .mapped or !window.tree.node.enabled or window.overview_hidden) return null;
    const workspace = window.workspace orelse return null;
    if (!workspace.isActive()) return null;
    var visible: wlr.Box = .{ .x = 0, .y = 0, .width = window.box.width, .height = window.box.height };
    if (visible.empty()) return null;
    if (window.wm_requested.fullscreen == null) {
        for ([_]wlr.Box{ window.rendering_requested.clip, window.rendering_requested.content_clip }) |clip| {
            if (!clip.empty() and !visible.intersection(&visible, &clip)) return null;
        }
    }
    visible.x += window.box.x;
    visible.y += window.box.y;
    const output_box = workspace.output.current.box();
    if (!visible.intersection(&visible, &output_box)) return null;
    return visible;
}

pub fn refreshBackdropBlur(window: *Window) void {
    const requested = &window.rendering_requested;
    const fullscreen = window.wm_requested.fullscreen != null;
    window.syncBackdropBlur(
        &requested.clip,
        &requested.content_clip,
        if (fullscreen) 0 else requested.border.corner_radius,
        !fullscreen,
    );
}

/// Size the blur mask to the same visible window-local rectangle as the
/// surface content. A clip through a window edge intentionally drops rounding
/// at the newly-created edge, matching drawBorders().
fn syncBackdropBlur(
    window: *Window,
    clip: *const wlr.Box,
    content_clip: *const wlr.Box,
    radius: u31,
    allow: bool,
) void {
    const blur = window.backdrop_blur orelse return;
    const requested = &window.rendering_requested;
    const native = if (window.rootSurface()) |surface|
        server.background_effect_manager.controls(surface)
    else
        false;
    const active = !native and allow and
        server.wm.blur.enabled and
        server.wm.blur.radius > 0 and
        server.wm.blur.passes > 0 and
        requested.blur_enabled and
        window.box.width > 0 and
        window.box.height > 0;
    if (!active) {
        window.disableBackdropBlur(blur);
        return;
    }

    const full: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = window.box.width,
        .height = window.box.height,
    };
    var visible = full;
    var effective_clip = clip.*;
    if (window.anim_active and !effective_clip.empty()) {
        // Layout clips describe a fixed viewport at the settled target. Convert
        // that viewport back into the moving window's local coordinates.
        const origin_x: i32 = @intFromFloat(@round(window.anim_x));
        const origin_y: i32 = @intFromFloat(@round(window.anim_y));
        effective_clip.x += requested.x - origin_x;
        effective_clip.y += requested.y - origin_y;
    }
    if (!effective_clip.empty() and !visible.intersection(&visible, &effective_clip)) {
        window.disableBackdropBlur(blur);
        return;
    }
    if (window.anim_active) {
        if (window.anim_viewport) |viewport| {
            const origin_x: i32 = @intFromFloat(@round(window.anim_x));
            const origin_y: i32 = @intFromFloat(@round(window.anim_y));
            const local_viewport: wlr.Box = .{
                .x = viewport.x - origin_x,
                .y = viewport.y - origin_y,
                .width = viewport.width,
                .height = viewport.height,
            };
            if (!visible.intersection(&visible, &local_viewport)) {
                window.disableBackdropBlur(blur);
                return;
            }
        }
    }
    if (!content_clip.empty() and !visible.intersection(&visible, content_clip)) {
        window.disableBackdropBlur(blur);
        return;
    }

    const clipped = visible.x != full.x or visible.y != full.y or
        visible.width != full.width or visible.height != full.height;
    const marker = window.blur_marker;
    marker.node.setEnabled(true);
    marker.node.setPosition(visible.x, visible.y);
    marker.setSize(visible.width, visible.height);
    fx.configureWindowBlur(blur, visible, if (clipped) 0 else radius, true);
}

fn disableBackdropBlur(window: *Window, blur: fx.WindowBlur) void {
    window.blur_marker.node.setEnabled(false);
    fx.configureWindowBlur(
        blur,
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        0,
        false,
    );
}

/// Logical geometry settles immediately; presentation eases independently.
fn setAnimationTarget(window: *Window, target_x: i32, target_y: i32, animate: bool) void {
    const tx: f64 = @floatFromInt(target_x);
    const ty: f64 = @floatFromInt(target_y);
    if (!fx.anim_enabled or !animate or !window.anim_initialized) {
        window.anim_x = tx;
        window.anim_y = ty;
        window.anim_active = false;
        window.anim_initialized = true;
    } else if (window.anim_target_x != tx or window.anim_target_y != ty) {
        if (!window.anim_active) {
            window.anim_x = @floatFromInt(window.box.x);
            window.anim_y = @floatFromInt(window.box.y);
        }
        window.anim_active = true;
        window.cur_anim_rate = fx.anim_rate;
        if (window.workspace) |ws| {
            if (ws.output.wlr_output) |output| output.scheduleFrame();
        }
    }
    window.anim_target_x = tx;
    window.anim_target_y = ty;
    window.box.x = target_x;
    window.box.y = target_y;
}

fn syncFullscreenBackground(window: *Window) void {
    window.fullscreen_background.node.setEnabled(false);
    const output = window.wm_requested.fullscreen orelse return;
    const width, const height = output.sent.dimensions();
    window.fullscreen_background.node.setPosition(0, 0);
    window.fullscreen_background.setSize(width, height);
    window.fullscreen_background.node.setEnabled(true);
}

/// Seed an incoming workspace off screen without moving its input geometry.
pub fn beginSlideFrom(window: *Window, start_x: i32, start_y: i32, target_x: i32, target_y: i32) void {
    if (comptime !fx.anim_enabled) return;
    window.anim_x = @floatFromInt(start_x);
    window.anim_y = @floatFromInt(start_y);
    window.anim_initialized = true;
    window.anim_active = true;
    window.setAnimationTarget(target_x, target_y, true);
    window.cur_anim_rate = server.wm.workspace_transition.rate;
    if (window.workspace) |ws| {
        if (ws.output.wlr_output) |output| output.scheduleFrame();
    }
}

pub fn cancelSlide(window: *Window) void {
    window.anim_active = false;
    window.anim_x = window.anim_target_x;
    window.anim_y = window.anim_target_y;
    window.anim_viewport = null;
    window.slide_seeded = false;
    window.cur_anim_rate = fx.anim_rate;
    window.updatePresentation();
}

/// Called once per owning output frame; mirrors never advance the animation.
pub fn stepAnimation(window: *Window, dt_s: f64) bool {
    if (comptime !fx.anim_enabled) return false;
    if (!window.anim_active) return false;
    const t = 1.0 - @exp(-window.cur_anim_rate * dt_s);
    window.anim_x += (window.anim_target_x - window.anim_x) * t;
    window.anim_y += (window.anim_target_y - window.anim_y) * t;
    if (@abs(window.anim_target_x - window.anim_x) < fx.anim_epsilon and
        @abs(window.anim_target_y - window.anim_y) < fx.anim_epsilon)
    {
        window.anim_x = window.anim_target_x;
        window.anim_y = window.anim_target_y;
        window.anim_active = false;
        // Retain the workspace clip until Output hides the outgoing tree.
        if (window.rendering_requested.hidden) {
            window.tree.node.setEnabled(false);
            window.popup_tree.node.setEnabled(false);
        }
        window.refreshSuspension();
    }
    window.updatePresentation();
    return true;
}

fn updatePresentation(window: *Window) void {
    const requested = &window.rendering_requested;
    const grid = scaling.PhysicalGrid.init(requested.output_scale);
    const origin_x: f64 = @floatFromInt(requested.output_origin_x);
    const origin_y: f64 = @floatFromInt(requested.output_origin_y);
    const x = if (window.anim_viewport != null) @round(window.anim_x) else grid.snapFromOrigin(window.anim_x, origin_x);
    const y = if (window.anim_viewport != null) @round(window.anim_y) else grid.snapFromOrigin(window.anim_y, origin_y);
    const input_enabled = !requested.hidden and !window.overview_hidden and
        (if (window.workspace) |ws| ws.isActive() else true);
    var layout_clip = requested.clip;
    layout_clip.x += requested.x;
    layout_clip.y += requested.y;
    const clip = if (window.wm_requested.fullscreen == null and !requested.clip.empty()) &layout_clip else null;
    var window_clip = window.anim_viewport;
    if (clip) |layout| {
        if (window_clip) |*viewport| {
            _ = viewport.intersection(viewport, layout);
        } else {
            window_clip = layout.*;
        }
    }
    for ([_]*wlr.SceneTree{ window.tree, window.popup_tree }) |tree| {
        var logical_x: f64 = 0;
        var logical_y: f64 = 0;
        _ = wlr_scene_node_coords_f64(&tree.node, &logical_x, &logical_y);
        const ok = wlr_scene_node_set_presentation(
            &tree.node,
            if (window.anim_active) x - logical_x else 0,
            if (window.anim_active) y - logical_y else 0,
            if (tree == window.tree)
                (if (window_clip) |*aperture| aperture else null)
            else
                (if (window.anim_viewport) |*aperture| aperture else null),
            input_enabled,
            null,
        );
        assert(ok); // State was allocated in create().
    }
    for ([_]*wlr.SceneTree{ window.surfaces.tree, window.surfaces.saved_tree, window.decorations_above_tree, window.decorations_below_tree }) |tree| {
        const ok = wlr_scene_node_set_presentation(&tree.node, 0, 0, clip, true, clip);
        assert(ok);
    }
    window.drawBorders();
    window.syncFullscreenBackground();
    window.refreshBackdropBlur();
}

pub const OverviewBuffer = struct {
    buffer: *wlr.SceneBuffer,
    x: i32,
    y: i32,
    source: wlr.FBox,
    dest_width: i32,
    dest_height: i32,
    transform: wl.Output.Transform,
    clip: ?fx.BufferClip,
};

const OverviewBufferCapture = struct {
    allocator: std.mem.Allocator,
    records: *std.ArrayListUnmanaged(OverviewBuffer),
    failed: bool = false,
};

/// Clone the complete, current toplevel surface tree for a compositor-owned
/// overview card. Layout/content clips are removed only for the duration of
/// the synchronous clone walk and restored before this function returns.
pub fn cloneOverviewInto(
    window: *Window,
    allocator: std.mem.Allocator,
    target: *wlr.SceneTree,
    records: *std.ArrayListUnmanaged(OverviewBuffer),
) !void {
    const no_clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    window.applySurfaceClip(&no_clip, &no_clip);
    defer window.applySurfaceClip(
        &window.rendering_requested.clip,
        &window.rendering_requested.content_clip,
    );

    records.clearRetainingCapacity();
    var capture: OverviewBufferCapture = .{
        .allocator = allocator,
        .records = records,
    };
    const cloned = window.surfaces.cloneInto(target, captureOverviewBuffer, &capture);
    if (!cloned or capture.failed) return error.OutOfMemory;
    if (records.items.len == 0) return error.NoBuffers;
}

fn captureOverviewBuffer(
    source_buffer: *wlr.SceneBuffer,
    buffer: *wlr.SceneBuffer,
    sx: c_int,
    sy: c_int,
    data: *anyopaque,
) void {
    server.background_effect_manager.dropSnapshot(buffer);
    const capture: *OverviewBufferCapture = @ptrCast(@alignCast(data));
    if (capture.failed) return;
    const source = effectiveSourceBox(source_buffer) orelse {
        capture.failed = true;
        return;
    };
    const quarter_turn = transformSwapsAxes(source_buffer.transform);
    const natural_width = if (quarter_turn) source.height else source.width;
    const natural_height = if (quarter_turn) source.width else source.height;
    const dest_width = if (source_buffer.dst_width > 0)
        source_buffer.dst_width
    else
        @max(1, @as(i32, @intFromFloat(@round(natural_width))));
    const dest_height = if (source_buffer.dst_height > 0)
        source_buffer.dst_height
    else
        @max(1, @as(i32, @intFromFloat(@round(natural_height))));
    capture.records.append(capture.allocator, .{
        .buffer = buffer,
        .x = sx,
        .y = sy,
        .source = source,
        .dest_width = dest_width,
        .dest_height = dest_height,
        .transform = source_buffer.transform,
        .clip = fx.bufferClip(buffer),
    }) catch {
        capture.failed = true;
    };
}

fn effectiveSourceBox(buffer: *const wlr.SceneBuffer) ?wlr.FBox {
    if (!buffer.src_box.empty()) return buffer.src_box;
    const backing = buffer.buffer orelse return null;
    if (backing.width <= 0 or backing.height <= 0) return null;
    return .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(backing.width),
        .height = @floatFromInt(backing.height),
    };
}

fn transformSwapsAxes(transform: wl.Output.Transform) bool {
    return switch (transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
}

const BorderClip = struct {
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    visible: bool = true,
};

fn drawBorders(window: *Window) void {
    if (window.wm_requested.fullscreen != null) {
        disableBorderNodes(&window.border);
        return;
    }
    const clip = window.animationBorderClip();
    if (!clip.visible) {
        disableBorderNodes(&window.border);
        return;
    }
    window.drawBorderNodes(&window.border, &clip.box);
}

fn animationBorderClip(window: *const Window) BorderClip {
    const requested = &window.rendering_requested;
    var viewport = window.anim_viewport;
    if (!requested.clip.empty()) {
        const layout_viewport: wlr.Box = .{
            .x = requested.x + requested.clip.x,
            .y = requested.y + requested.clip.y,
            .width = requested.clip.width,
            .height = requested.clip.height,
        };
        if (viewport) |output_viewport| {
            var clipped: wlr.Box = undefined;
            if (!clipped.intersection(&layout_viewport, &output_viewport)) {
                return .{ .visible = false };
            }
            viewport = clipped;
        } else {
            viewport = layout_viewport;
        }
    }
    const fixed_viewport = viewport orelse return .{};
    const origin_x: i32 = @intFromFloat(@round(window.anim_x));
    const origin_y: i32 = @intFromFloat(@round(window.anim_y));
    return .{ .box = .{
        .x = fixed_viewport.x - origin_x,
        .y = fixed_viewport.y - origin_y,
        .width = fixed_viewport.width,
        .height = fixed_viewport.height,
    } };
}

fn disableBorderNodes(nodes: *const BorderNodes) void {
    inline for (.{
        "rounded_outline",
        "left",
        "right",
        "top",
        "bottom",
    }) |part| {
        @field(nodes, part).node.setEnabled(false);
    }
}

fn drawBorderNodes(
    window: *Window,
    nodes: *const BorderNodes,
    clip: *const wlr.Box,
) void {
    const requested = &window.rendering_requested;
    disableBorderNodes(nodes);
    var content: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = window.box.width,
        .height = window.box.height,
    };
    if (!requested.content_clip.empty() and
        !content.intersection(&content, &requested.content_clip)) return;

    // f32 cannot represent all u32 values exactly, therefore we must initially use f64
    // (which can) and then cast to f32, potentially losing precision.
    const border = &requested.border;
    if (border.width == 0) return;
    const color: [4]f32 = .{
        @floatCast(@as(f64, @floatFromInt(border.r)) / math.maxInt(u32)),
        @floatCast(@as(f64, @floatFromInt(border.g)) / math.maxInt(u32)),
        @floatCast(@as(f64, @floatFromInt(border.b)) / math.maxInt(u32)),
        @floatCast(@as(f64, @floatFromInt(border.a)) / math.maxInt(u32)),
    };

    // Complete four-sided borders remain rounded even when a viewport cuts the
    // window. The rounded path below crops the ring itself to the aperture, so
    // newly exposed clip corners are rounded without leaking outside it.
    // Selective borders still use the edge-node fallback below.
    const rounded = border.corner_radius > 0 and
        border.edges.top and
        border.edges.right and
        border.edges.bottom and
        border.edges.left;
    if (!rounded) {
        var left: wlr.Box = .{
            .x = content.x - @as(i32, border.width),
            .y = content.y,
            .width = border.width,
            .height = content.height,
        };
        var right: wlr.Box = .{
            .x = content.x + content.width,
            .y = content.y,
            .width = border.width,
            .height = content.height,
        };
        var top: wlr.Box = .{
            .x = content.x,
            .y = content.y - @as(i32, border.width),
            .width = content.width,
            .height = border.width,
        };
        var bottom: wlr.Box = .{
            .x = content.x,
            .y = content.y + content.height,
            .width = content.width,
            .height = border.width,
        };
        // Use left and right scene rects to draw square corners if needed.
        if (border.edges.top) {
            left.y -= border.width;
            left.height += border.width;
            right.y -= border.width;
            right.height += border.width;
        }
        if (border.edges.bottom) {
            left.height += border.width;
            right.height += border.width;
        }
        inline for (.{
            .{ .name = "left", .box = &left },
            .{ .name = "right", .box = &right },
            .{ .name = "top", .box = &top },
            .{ .name = "bottom", .box = &bottom },
        }) |edge| {
            if (!clip.empty()) {
                _ = edge.box.intersection(edge.box, clip);
            }
            const rect = @field(nodes, edge.name);
            rect.node.setEnabled(@field(border.edges, edge.name));
            rect.node.setPosition(edge.box.x, edge.box.y);
            rect.setSize(edge.box.width, edge.box.height);
            rect.setColor(&color);
            fx.setRectRadius(rect, 0);
        }
        return;
    }

    const half_short_side: u31 = @intCast(@divTrunc(@min(content.width, content.height), 2));
    const radius: u31 = @min(border.corner_radius, half_short_side);
    const requested_outer_radius: u31 = @intCast(@min(
        @as(u32, radius) + @as(u32, border.width),
        math.maxInt(u31),
    ));
    const bw: i32 = border.width;

    const cropped_outline = visual_state.clippedOutline(
        .{ .x = content.x, .y = content.y, .width = content.width, .height = content.height },
        .{ .x = clip.x, .y = clip.y, .width = clip.width, .height = clip.height },
        bw,
    ) orelse return;
    const visible_outline: wlr.Box = .{
        .x = cropped_outline.x,
        .y = cropped_outline.y,
        .width = cropped_outline.width,
        .height = cropped_outline.height,
    };
    const visible_half_short_side: u31 = @intCast(@divTrunc(@min(visible_outline.width, visible_outline.height), 2));
    const outer_radius = @min(requested_outer_radius, visible_half_short_side);
    const rect = nodes.rounded_outline;
    rect.node.setEnabled(true);
    rect.node.setPosition(visible_outline.x, visible_outline.y);
    rect.setSize(visible_outline.width, visible_outline.height);
    rect.setColor(&color);
    fx.setRectRadius(rect, outer_radius);
    fx.setRectClippedRegion(rect, .{
        .x = content.x - visible_outline.x,
        .y = content.y - visible_outline.y,
        .width = content.width,
        .height = content.height,
    }, .{
        .top_left = radius,
        .top_right = radius,
        .bottom_right = radius,
        .bottom_left = radius,
    });
}

fn applySurfaceClip(window: *Window, a: *const wlr.Box, b: *const wlr.Box) void {
    // Layout clipping is global; fullscreen bounds remain local to the content.
    var surface_clip = if (window.wm_requested.fullscreen != null) a.* else b.*;
    window.surfaces.setEnabled(true);
    switch (window.impl) {
        .toplevel => |toplevel| {
            surface_clip.x += toplevel.geometry.x;
            surface_clip.y += toplevel.geometry.y;
        },
        .xwayland, .destroying => {},
    }
    // wlroots asserts that a subsurface tree is present.
    if (!window.surfaces.tree.children.empty()) {
        window.surfaces.tree.node.subsurfaceTreeSetClip(&surface_clip);
    }
    // Subsurface clipping changes both node origins and destination extents.
    // Refresh masks after those changes, including temporary unclips for clones.
    fx.setTreeClip(window.surfaces.tree, window.surfaceMask(b));
}

/// Returns null if the window is currently being destroyed and no longer has
/// an associated surface.
/// May also return null for Xwayland windows that are not currently mapped.
pub fn rootSurface(window: Window) ?*wlr.Surface {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
        .xwayland => |xwindow| xwindow.xsurface.surface,
        .destroying => null,
    };
}

pub fn sendFrameDone(window: Window) void {
    assert(window.state == .mapped);
    assert(window.impl != .destroying);

    var now = util.timestamp();
    window.rootSurface().?.sendFrameDone(&now);
}

pub fn close(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
        .xwayland => |xwindow| xwindow.xsurface.close(),
        .destroying => {},
    }
}

pub fn destroyPopups(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.destroyPopups(),
        .xwayland, .destroying => {},
    }
}

pub fn getParent(window: *const Window) ?*Window {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const wlr_parent = toplevel.wlr_toplevel.parent orelse return null;
            const data = wlr_parent.base.data orelse return null;
            const parent: *XdgToplevel = @ptrCast(@alignCast(data));
            return parent.window;
        },
        .xwayland => |xwindow| {
            const parent_xsurface = xwindow.xsurface.parent orelse return null;
            // It seems that the parent may be an Override Redirect window, which
            // have null data.
            const parent_data = parent_xsurface.data orelse return null;
            const parent_xwindow: *XwaylandWindow = @ptrCast(@alignCast(parent_data));
            return parent_xwindow.window;
        },
        .destroying => return null,
    }
}

pub fn isDialog(window: *const Window) bool {
    return window.impl == .toplevel and window.impl.toplevel.dialog.object != null and window.getParent() != null;
}

fn modalChildEligible(window: *Window, parent: *Window) bool {
    const workspace = window.workspace orelse return false;
    const output = workspace.output;
    return window.isDialog() and window.impl.toplevel.dialog.modal() and
        window.getParent() == parent and window.state == .mapped and
        window.workspace == parent.workspace and output.policyWorkspaceActive(workspace) and
        output.sent.state == .enabled and output.wlr_output != null and
        window.wm_scheduled.accepts_focus and window.policy_state.focus_allowed and
        window.policy_state.isVisible() and !window.rendering_requested.hidden and !window.overview_hidden;
}

const ModalContext = struct {
    pub fn child(_: ModalContext, handle: u64) ?u64 {
        const ref: Ref = @bitCast(handle);
        const parent = ref.get() orelse return null;
        // The rendering list is ordered bottom to top and includes the latest
        // committed policy order. Prefer it to slot allocation order.
        var ordered = server.wm.rendering_requested.list.iterator(.reverse);
        while (ordered.next()) |node| switch (node.get()) {
            .window => |window| if (window.modalChildEligible(parent)) return @bitCast(window.ref),
            .shell_surface => {},
        };
        // Newly mapped children may not have entered that list yet.
        var result: ?u64 = null;
        var windows = server.wm.windows.iterator();
        while (windows.next()) |window| {
            if (window.modalChildEligible(parent)) {
                const candidate: u64 = @bitCast(window.ref);
                if (result == null or candidate > result.?) result = candidate;
            }
        }
        return result;
    }
};

pub fn resolveModalHandle(handle: u64) u64 {
    if (!server.aqueous.mode.runsInternal()) return handle;
    return @import("wm/focus/dialog.zig").resolve(ModalContext{}, handle, server.wm.windows.count);
}

/// Dialogs share a fullscreen ancestor's scene layer only along live dialog
/// edges on the same workspace. This must also enter the scene-order hash.
pub fn inFullscreenLayer(window: *Window) bool {
    if (window.wm_requested.fullscreen != null) return true;
    if (!server.aqueous.mode.runsInternal()) return false;
    var current = window;
    for (0..server.wm.windows.count) |_| {
        if (!current.isDialog()) return false;
        const parent = current.getParent() orelse return false;
        if (parent.workspace != window.workspace or parent.state != .mapped or
            !parent.policy_state.isVisible() or parent.rendering_requested.hidden) return false;
        if (parent.wm_requested.fullscreen != null) return true;
        current = parent;
    }
    return false;
}

pub fn unreliablePid(window: *Window) i32 {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const client = toplevel.wlr_toplevel.base.surface.resource.getClient();
            return client.getCredentials().pid;
        },
        .xwayland => |xwindow| return xwindow.xsurface.pid,
        .destroying => unreachable,
    }
}

/// Return the current title of the window if any.
pub fn getTitle(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.title,
        .xwayland => |xwindow| xwindow.xsurface.title,
        .destroying => unreachable,
    };
}

pub fn getTag(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| if (toplevel.tag_metadata.tag) |value| value.ptr else null,
        .xwayland, .destroying => null,
    };
}

pub fn getDescription(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| if (toplevel.tag_metadata.description) |value| value.ptr else null,
        .xwayland, .destroying => null,
    };
}

/// Return the current app_id of the window if any.
pub fn getAppId(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
        // X11 clients don't have an app_id but the class serves a similar role.
        .xwayland => |xwindow| xwindow.xsurface.class,
        .destroying => unreachable,
    };
}

pub fn infoSnapshot(window: *const Window) InfoSnapshot {
    const backend: InfoBackend, const app_id: ?[*:0]const u8, const class: ?[*:0]const u8 = switch (window.impl) {
        .toplevel => |toplevel| .{ .xdg, toplevel.wlr_toplevel.app_id, null },
        .xwayland => |xwindow| .{ .xwayland, null, xwindow.xsurface.class },
        .destroying => unreachable,
    };
    const workspace = window.workspace;
    const focused = blk: {
        var seats = server.input_manager.seats.iterator(.forward);
        while (seats.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) break :blk true;
        }
        break :blk false;
    };
    const visible_workspace = if (workspace) |ws| ws.isActive() else true;
    const kind = window.policy_state.kind();
    return .{
        .backend = backend,
        .app_id = app_id,
        .class = class,
        .title = window.getTitle(),
        .tag = window.getTag(),
        .description = window.getDescription(),
        .content_type = window.content_type,
        .output = if (workspace) |ws|
            if (ws.output.wlr_output) |output| output.name else null
        else
            null,
        .workspace = if (workspace) |ws| ws.policyNumber() else 0,
        .geometry = window.box,
        .focused = focused,
        .floating = kind == .floating,
        .fullscreen = window.wm_requested.fullscreen != null or window.wm_requested.inform_fullscreen,
        .maximized = kind == .maximized or window.wm_requested.maximized,
        .minimized = kind == .minimized or window.rendering_requested.hidden,
        .visible = window.state == .mapped and visible_workspace and !window.rendering_requested.hidden,
        .always_above = window.policy_state.stack_layer == .above,
        .always_below = window.policy_state.stack_layer == .below,
        .snapped = window.policy_state.snap_state != .none,
        .fixed_position = window.policy_state.fixed_position,
        .skip_switcher = window.policy_state.skip_switcher,
        .skip_taskbar = window.policy_state.skip_taskbar,
        .layout = @tagName(kind),
    };
}

pub fn matchedRuleFingerprint(window: *const Window) u64 {
    return if (window.policy_state.rule_initialized) window.policy_state.rule_match else 0;
}

/// Per-window content opacity: the per-window value (set_window_opacity) wins over
/// the global default (set_opacity); both are 32-bit unsigned fractions. Newly
/// created scene buffers default to opacity 1.0, so this must be reapplied whenever
/// buffers may have been (re)created, not only at render-finish.
pub fn applyOpacity(window: *Window) void {
    const opacity = window.effectiveOpacity();
    // Outgoing content remains live and is confined by its presentation clip.
    const outgoing = if (window.workspace) |ws| ws.output.prev_workspace == ws else false;
    if (WindowInfoManager.windowStateDiagnostics()) {
        // A window on an inactive workspace must never be left enabled outside
        // its own output: that state renders the window on a neighboring output.
        // Output must disable outgoing trees before clearing prev_workspace.
        if (window.workspace) |ws| {
            const output_box = ws.output.current.box();
            const window_box: wlr.Box = .{
                .x = window.box.x,
                .y = window.box.y,
                .width = window.box.width,
                .height = window.box.height,
            };
            var visible: wlr.Box = undefined;
            if (!outgoing and !ws.isActive() and opacity > 0 and
                window.tree.node.enabled and window.state == .mapped and
                !window.rendering_requested.hidden and !window.overview_hidden and
                !visible.intersection(&window_box, &output_box))
            {
                log.warn("transition invariant: opaque live window outside its output on inactive workspace {s}", .{ws.output.policyName()});
            }
        }
    }
    fx.setTreeOpacity(window.surfaces.saved_tree, opacity);
    fx.setTreeOpacity(window.popup_tree, opacity);
    fx.setTreeOpacity(window.surfaces.tree, opacity);
}

pub fn applySurfaceVisualState(window: *Window) void {
    fx.setTreeClip(window.surfaces.tree, window.surfaceMask(&window.rendering_requested.content_clip));
    // Saved transaction buffers own frozen masks. In
    // particular, a later live resize must not change a snapshot's silhouette.
    window.applyOpacity();
}

fn surfaceMask(window: *const Window, content_clip: *const wlr.Box) ?fx.BufferClip {
    const radius = window.rendering_requested.border.corner_radius;
    if (window.wm_requested.fullscreen != null or radius == 0) return null;
    var content: wlr.Box = .{ .x = 0, .y = 0, .width = window.box.width, .height = window.box.height };
    if (!content_clip.empty()) _ = content.intersection(&content, content_clip);
    return fx.BufferClip.init(.{ .x = content.x, .y = content.y, .width = content.width, .height = content.height }, radius);
}

/// Effective compositor opacity shared by a top-level and its popup surfaces.
pub fn effectiveOpacity(window: *const Window) f32 {
    const opacity_frac = window.rendering_requested.opacity orelse server.wm.default_opacity;
    return visual_state.fractionToOpacity(opacity_frac);
}

/// Publish this window through both the standard ext list and the legacy wlr
/// manager used by wlrctl/taskbars. This must not depend on an external
/// aqueous_window_manager_v1 client: integrated policy deliberately has none.
fn publishForeignToplevels(window: *Window) void {
    if (window.foreign_toplevel_handle == null) {
        if (wlr.ExtForeignToplevelHandleV1.create(server.foreign_toplevel_list, &.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        })) |handle| {
            window.foreign_toplevel_handle = handle;
            handle.data = window;
        } else |_| {
            log.err("failed to create ext foreign toplevel handle", .{});
        }
    }

    if (window.wlr_toplevel_handle == null) {
        if (wlr.ForeignToplevelHandleV1.create(server.wlr_foreign_toplevel_manager)) |handle| {
            window.wlr_toplevel_handle = handle;
            handle.data = window;
            if (window.getTitle()) |title| handle.setTitle(title);
            if (window.getAppId()) |app_id| handle.setAppId(app_id);
            handle.events.request_maximize.add(&window.ftm_request_maximize);
            handle.events.request_minimize.add(&window.ftm_request_minimize);
            handle.events.request_activate.add(&window.ftm_request_activate);
            handle.events.request_fullscreen.add(&window.ftm_request_fullscreen);
            handle.events.request_close.add(&window.ftm_request_close);
            window.wlr_toplevel_sent = .{};
        } else |_| {
            log.err("failed to create wlr foreign toplevel handle", .{});
        }
    }
}

/// Push the compositor's authoritative current state to the legacy foreign
/// handle. Seat.manageFinish() has already applied policy focus when this runs
/// from a transaction; map() also calls it to seed a newly published handle.
fn syncForeignToplevelState(window: *Window) void {
    const handle = window.wlr_toplevel_handle orelse return;
    const activated = window.isFocused();

    const sent = &window.wlr_toplevel_sent;
    if (sent.activated != activated) {
        handle.setActivated(activated);
        sent.activated = activated;
    }
    const maximized = window.wm_requested.maximized;
    if (sent.maximized != maximized) {
        handle.setMaximized(maximized);
        sent.maximized = maximized;
    }
    const fullscreen = window.wm_requested.fullscreen != null or window.wm_requested.inform_fullscreen;
    if (sent.fullscreen != fullscreen) {
        handle.setFullscreen(fullscreen);
        sent.fullscreen = fullscreen;
    }
    const minimized = window.rendering_requested.hidden;
    if (sent.minimized != minimized) {
        handle.setMinimized(minimized);
        sent.minimized = minimized;
    }
    const parent_handle: ?*wlr.ForeignToplevelHandleV1 = blk: {
        const parent = window.getParent() orelse break :blk null;
        break :blk parent.wlr_toplevel_handle;
    };
    if (sent.parent != parent_handle) {
        handle.setParent(parent_handle);
        sent.parent = parent_handle;
    }
    window.syncForeignToplevelOutputs();
}

fn isFocused(window: *const Window) bool {
    var it = server.input_manager.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (seat.focused == .window and seat.focused.window == window) return true;
    }
    return false;
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(window: *Window) !void {
    log.debug("window '{?s}' mapped", .{window.getTitle()});
    assert(window.impl != .destroying);
    assert(window.state == .initialized);
    window.state = .mapped;

    // Mapping changes scene visibility even when the committed dimensions are
    // unchanged. A same-size XDG remap needs no tracked resize transaction, so
    // its pre-map render can leave the parent scene node disabled. Do not rely
    // on a later size change or unrelated input to run renderFinish() again.
    server.wm.dirtyRendering();

    // Complete a deferred natural-size transient placement using the buffer
    // which caused this map. The commit listener updates rendering_scheduled
    // before the coalesced manage cycle reads its policy snapshot.
    if (window.policy_state.pending_natural_parent != 0) server.wm.dirtyWindowing();

    // The first buffer was just committed. Apply compositor-owned opacity and
    // corner metadata before its first rendered frame.
    window.applySurfaceVisualState();

    if (window.workspace == null and window.output_recovery == null) {
        if (window.initialOutput()) |output| {
            if (output.active_workspace) |workspace| {
                window.setWorkspace(workspace);
            }
        }
    }

    // Foreign-toplevel protocols describe mapped windows. This is also the
    // integrated-policy publication path: there is no aqueous_window_manager_v1
    // object in that mode, so publication must not depend on manageStart().
    window.publishForeignToplevels();
    window.syncForeignToplevelState();
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(window: *Window) void {
    log.debug("window '{?s}' unmapped", .{window.getTitle()});

    window.surfaces.save();

    assert(window.impl != .destroying);
    assert(window.state == .mapped);
    window.state = .closing;

    window.clearWorkspace();

    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.destroy();
        window.foreign_toplevel_handle = null;
    }

    if (window.wlr_toplevel_handle) |handle| {
        window.ftm_request_maximize.link.remove();
        window.ftm_request_minimize.link.remove();
        window.ftm_request_activate.link.remove();
        window.ftm_request_fullscreen.link.remove();
        window.ftm_request_close.link.remove();
        handle.destroy();
        window.wlr_toplevel_handle = null;
        window.wlr_toplevel_sent = .{};
        window.wlr_toplevel_outputs.deinit(util.gpa);
        window.wlr_toplevel_outputs = .{};
    }
}

pub fn notifyTitle(window: *Window) void {
    window.wm_scheduled.dirty_title = true;
    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
    if (window.wlr_toplevel_handle) |handle| {
        if (window.getTitle()) |title| handle.setTitle(title);
    }
}

pub fn notifyAppId(window: *Window) void {
    window.wm_scheduled.dirty_app_id = true;
    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
    if (window.wlr_toplevel_handle) |handle| {
        if (window.getAppId()) |app_id| handle.setAppId(app_id);
    }
}

pub fn notifyContentType(window: *Window, content_type: wp.ContentTypeV1.Type) void {
    server.wm.dirtyWindowing();
    window.content_type = content_type;
}

/// Diff-emit outputEnter / outputLeave on the wlr_toplevel_handle so that
/// foreign-toplevel clients (Noctalia, waybar wlr-taskbar per-monitor, etc.)
/// can correctly scope windows to outputs.
///
/// A window is considered "on" an output if its scene-graph box intersects
/// that output's layout box AND the window is currently visible (mapped and
/// not rendering-hidden). Hidden / unmapped windows leave all outputs.
pub fn syncForeignToplevelOutputs(window: *Window) void {
    const handle = window.wlr_toplevel_handle orelse return;

    const visible = window.state == .mapped and !window.rendering_requested.hidden;

    // Compute the set of wlr_outputs this window currently overlaps.
    var desired: std.AutoArrayHashMapUnmanaged(*wlr.Output, void) = .{};
    defer desired.deinit(util.gpa);

    if (visible and window.box.width > 0 and window.box.height > 0) {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;
            var output_box: wlr.Box = undefined;
            server.om.output_layout.getBox(wlr_output, &output_box);
            if (output_box.empty()) continue;
            var overlap: wlr.Box = undefined;
            if (!overlap.intersection(&output_box, &window.box)) continue;
            desired.put(util.gpa, wlr_output, {}) catch return;
        }
    }

    // Leave outputs that are no longer in `desired`.
    {
        var sent_it = window.wlr_toplevel_outputs.iterator();
        while (sent_it.next()) |entry| {
            if (!desired.contains(entry.key_ptr.*)) {
                handle.outputLeave(entry.key_ptr.*);
            }
        }
    }

    // Enter outputs newly added.
    {
        var d_it = desired.iterator();
        while (d_it.next()) |entry| {
            if (!window.wlr_toplevel_outputs.contains(entry.key_ptr.*)) {
                handle.outputEnter(entry.key_ptr.*);
            }
        }
    }

    // Swap stored set for next diff.
    window.wlr_toplevel_outputs.clearRetainingCapacity();
    var d_it2 = desired.iterator();
    while (d_it2.next()) |entry| {
        window.wlr_toplevel_outputs.put(util.gpa, entry.key_ptr.*, {}) catch {};
    }
}

pub fn initialOutput(window: *Window) ?*Output {
    if (window.getParent()) |parent| {
        if (parent.workspace) |workspace| {
            if (outputIsUsable(workspace.output)) {
                return workspace.output;
            }
        }
    }

    if (server.input_manager.seats.first()) |seat| {
        const cursor = seat.cursor.wlr_cursor;

        if (server.om.outputAt(cursor.x, cursor.y)) |wlr_output| {
            if (wlr_output.data) |data| {
                const output: *Output = @ptrCast(@alignCast(data));
                if (outputIsUsable(output)) return output;
            }
        }
    }

    if (server.aqueous.output_service.primaryOutput()) |output| return output;

    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (outputIsUsable(output)) return output;
    }
    return null;
}

pub fn getContentType(window: *Window) wp.ContentTypeV1.Type {
    return window.content_type;
}

// ---------------------------------------------------------------------------
// External docks/taskbars (Noctalia, waybar's wlr-taskbar, etc.) can ask the
// compositor to activate / close / maximize / minimize / fullscreen a window
// via zwlr_foreign_toplevel_manager_v1. We forward those into the same
// `wm_scheduled.*_requested` fields that XDG clients use, so the river WM
// client sees them as ordinary requests and can react identically.
// ---------------------------------------------------------------------------

pub fn requestMaximized(window: *Window, maximized: bool) void {
    window.wm_scheduled.maximize_requested = if (maximized) .maximize else .unmaximize;
    server.wm.dirtyWindowing();
}
pub fn requestMinimized(window: *Window, minimized: bool) void {
    window.wm_scheduled.minimize_requested = if (minimized) .minimize else .unminimize;
    server.wm.dirtyWindowing();
}
pub fn requestFullscreen(window: *Window, fullscreen: bool, output: ?*Output) void {
    window.wm_scheduled.fullscreen_requested = if (fullscreen) .{ .fullscreen = output } else .exit;
    server.wm.dirtyWindowing();
}

/// Dispatch activation after the caller has applied its protocol's authorization.
pub fn requestActivate(window: *Window) void {
    if (window.state != .mapped and window.state != .initialized) return;

    if (server.aqueous.mode.runsInternal()) {
        window.wm_scheduled.activate_requested = true;
    }
    if (window.object) |window_v1| {
        if (window_v1.getVersion() >= 5) window_v1.sendActivateRequested();
    }
    server.wm.dirtyWindowing();
}

fn handleFtmRequestMaximize(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized),
    event: *wlr.ForeignToplevelHandleV1.event.Maximized,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_maximize", listener);
    if (window.state != .mapped and window.state != .initialized) return;
    window.requestMaximized(event.maximized);
}

fn handleFtmRequestMinimize(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized),
    event: *wlr.ForeignToplevelHandleV1.event.Minimized,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_minimize", listener);
    if (window.state != .mapped and window.state != .initialized) return;
    window.requestMinimized(event.minimized);
}

fn handleFtmRequestActivate(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated),
    event: *wlr.ForeignToplevelHandleV1.event.Activated,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_activate", listener);
    _ = event; // seat is informational; the wm picks the focus seat itself.
    window.requestActivate();
}

fn handleFtmRequestFullscreen(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen),
    event: *wlr.ForeignToplevelHandleV1.event.Fullscreen,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_fullscreen", listener);
    if (window.state != .mapped and window.state != .initialized) return;
    const output_hint: ?*Output = if (event.output) |output|
        @ptrCast(@alignCast(output.data))
    else
        null;
    window.requestFullscreen(event.fullscreen, output_hint);
}

fn handleFtmRequestClose(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1),
    _: *wlr.ForeignToplevelHandleV1,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_close", listener);
    if (window.state != .mapped and window.state != .initialized) return;
    window.close();
}

fn outputIsUsable(output: *Output) bool {
    const box = output.policyFullBox();
    return output.active_workspace != null and box.width > 0 and box.height > 0;
}
