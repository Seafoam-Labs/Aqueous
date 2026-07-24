// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Window = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const meta = std.meta;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;
const SlotMap = @import("slotmap").SlotMap;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Decoration = @import("Decoration.zig");
const Output = @import("Output.zig");
const fx = @import("fx.zig");
const visual_state = @import("visual_state.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
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
    edges: river.WindowV1.Edges = .{},
    width: u31 = 0,
    r: u32 = 0,
    b: u32 = 0,
    g: u32 = 0,
    a: u32 = 0,
    /// Corner radius applied to the border rects and window content. Defaults
    /// to `fx.corner_radius`, which is 0 (square) unless SceneFX is compiled in.
    corner_radius: u31 = fx.corner_radius,
};

/// Windowing state requested by the wm.
const WmRequested = struct {
    dimensions: ?Dimensions,
    bounds: Dimensions,
    ssd: bool,
    tiled: river.WindowV1.Edges,
    capabilities: river.WindowV1.Capabilities,
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
    width: ?u31,
    height: ?u31,
    bounds: Dimensions,
    /// True if the window has keyboard focus from at least one seat.
    activated: bool,
    ssd: bool,
    tiled: river.WindowV1.Edges,
    capabilities: river.WindowV1.Capabilities,
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
    hidden: bool,
    border: Border,
    clip: wlr.Box,
    content_clip: wlr.Box,
    /// Per-window blur preference retained for policy/protocol compatibility.
    /// It must never be implemented by falsifying scene-buffer opaque regions;
    /// selective translucent blur requires a real SceneFX mask.
    blur_enabled: bool = true,
    /// Window-content opacity as a 32-bit unsigned fraction (0 = transparent,
    /// 0xffffffff = opaque); null inherits the global default driven by
    /// river_window_manager_v1.set_opacity. Driven by
    /// river_window_v1.set_window_opacity.
    opacity: ?u32 = null,

    pub const init: RenderingRequested = .{
        .x = 0,
        .y = 0,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .blur_enabled = true,
        .opacity = null,
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
    fullscreen: bool,
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
};

pub const InfoBackend = enum { xdg, xwayland };

/// Read-only compositor-owned state exposed through aqueous_window_info_v1.
/// Strings borrow their backing protocol/output objects and are consumed
/// synchronously while servicing the request.
pub const InfoSnapshot = struct {
    backend: InfoBackend,
    app_id: ?[*:0]const u8,
    class: ?[*:0]const u8,
    title: ?[*:0]const u8,
    output: ?[*:0]const u8,
    workspace: u32,
    geometry: wlr.Box,
    focused: bool,
    floating: bool,
    fullscreen: bool,
    maximized: bool,
    minimized: bool,
    visible: bool,
    layout: [:0]const u8,
};

ref: Ref,

/// The workspace this window currently belongs to, or null if unassigned.
/// An unassigned window is always visible; an assigned window is visible only
/// while its workspace is the active one on its output.
workspace: ?*Workspace = null,
/// Node in the owning workspace's member list (`Workspace.windows`).
workspace_link: wl.list.Link,

/// The window management protocol object for this window
/// Created in manageStart() when state is .ready
/// Set to null in manageStart() when state is .closing
object: ?*river.WindowV1 = null,
node: WmNode,

state: enum {
    /// Initial state, also returned to after closed event is sent.
    init,
    /// The window is ready to be configured.
    /// The river_window_v1 will be created in the next manage sequence.
    ready,
    /// The first configure has been sent but the window is not yet mapped.
    initialized,
    /// The window is mapped.
    mapped,
    /// The closed event will be sent in the next manage sequence.
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

/// Opaque black rectangle used as the background while this window is rendered fullscreen.
/// TODO consider using one of these per output rather than one per window to save memory
/// if the complexity tradeoff is worth it.
fullscreen_background: *wlr.SceneRect,

decorations_below: wl.list.Head(Decoration, .link),
decorations_below_tree: *wlr.SceneTree,

surfaces: Scene.SaveableSurfaces,

border: struct {
    rounded_outline: *wlr.SceneRect,
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,
},

decorations_above: wl.list.Head(Decoration, .link),
decorations_above_tree: *wlr.SceneTree,

popup_tree: *wlr.SceneTree,

/// Cosmetic overlay tree used to render the position animation. It holds a
/// frozen clone of the window's surfaces and is the only node moved while a
/// position animation runs, so the live `tree`/`popup_tree` (and therefore
/// scene hit-testing) stay pinned at the final target. No `SceneNodeData` is
/// attached, so it is input-inert. Empty/disabled when not animating.
anim_tree: *wlr.SceneTree,

capture_scene: *wlr.Scene,
capture_source: ?*wlr.ExtImageCaptureSourceV1 = null,

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
    /// Whether the window accepts keyboard focus. Wayland-native windows always do;
    /// XWayland windows reflect their ICCCM input model (`none` ⇒ false). Forwarded to
    /// the wm via river_window_v1.focus_hint so it can avoid focus-stealing popups.
    accepts_focus: bool = true,
    show_window_menu_requested: ?struct { x: i32, y: i32 } = null,
    /// Set back to no_request at the end of each update sequence
    fullscreen_requested: FullscreenRequest = .no_request,
    maximize_requested: enum {
        no_request,
        maximize,
        unmaximize,
    } = .no_request,
    minimize_requested: bool = false,
    dirty_app_id: bool = false,
    dirty_title: bool = false,
    pointer_move_requested: ?*Seat = null,
    pointer_resize_requested: ?struct {
        seat: *Seat,
        edges: river.WindowV1.Edges,
    } = null,
} = .{},

/// State sent to the wm in the latest manage sequence.
/// This state is only kept around in order to avoid sending redundant events
/// to the wm.
wm_sent: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
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
    presentation_hint: river.OutputV1.PresentationMode = .vsync,
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

/// Position animation state. `anim_target_{x,y}` is the destination requested by
/// the window manager; `anim_{x,y}` is the eased value actually written to the
/// scene node each frame. `renderFinish` feeds the target in and snaps on the
/// first placement / fullscreen / hidden transitions; `Output.handleFrame` drives
/// the interpolation while `anim_active` is set. All of this compiles out when
/// `-Danimations=false` (see `fx.anim_enabled`).
anim_target_x: f64 = 0,
anim_target_y: f64 = 0,
anim_x: f64 = 0,
anim_y: f64 = 0,
anim_active: bool = false,
anim_initialized: bool = false,
/// True while `anim_tree` currently holds a cloned snapshot of the surfaces.
anim_snapshot: bool = false,
/// Original geometry of each buffer cloned into `anim_tree`. Clipped scrolling
/// animations recrop these buffers on every frame so the viewport remains
/// fixed in layout coordinates while the clone moves behind it.
anim_buffers: std.ArrayListUnmanaged(AnimBuffer) = .empty,
/// Set once a window's clone has been seeded off-screen for the current
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
    const active = window.state != .init and window.state != .closing and
        (output == null or output.?.policyWorkspaceActive(effective_workspace));
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
        .fullscreen = window.wm_requested.fullscreen != null,
        .min_width = @intCast(window.wm_scheduled.dimensions_hint.min_width),
        .min_height = @intCast(window.wm_scheduled.dimensions_hint.min_height),
        .max_width = @intCast(window.wm_scheduled.dimensions_hint.max_width),
        .max_height = @intCast(window.wm_scheduled.dimensions_hint.max_height),
    };
}

pub fn policyApplyPlacement(
    window: *Window,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    clip: ?wlr.Box,
    visible: bool,
    border_width: u31,
    border_color: u32,
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

    // Do not leave a cosmetic clone chasing the pointer. The authoritative live
    // tree is already at window.box, so dropping the clone is visually seamless.
    window.anim_active = false;
    window.clearSnapshot();
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

pub fn policyApplyVisualRule(window: *Window, blur: ?bool, opacity: ?f64, force_ssd: bool) void {
    window.rendering_requested.blur_enabled = blur orelse true;
    if (opacity) |fraction| {
        const clamped = std.math.clamp(fraction, 0, 1);
        window.rendering_requested.opacity = @intFromFloat(clamped * @as(f64, @floatFromInt(std.math.maxInt(u32))));
    } else window.rendering_requested.opacity = null;
    if (force_ssd and window.wm_scheduled.decoration_hint != .only_supports_csd) window.wm_requested.ssd = true;
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

    const anim_tree = try server.scene.hidden_tree.createSceneTree();
    errdefer anim_tree.node.destroy();

    const backdrop_blur = fx.createWindowBlur(tree);

    window.* = .{
        .ref = .{ .key = key },
        .node = undefined,
        .impl = impl,
        .tree = tree,
        .backdrop_blur = backdrop_blur,
        .fullscreen_background = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1 }),
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
        .anim_tree = anim_tree,
        .capture_scene = try wlr.Scene.create(),
        .workspace_link = undefined,
    };

    window.node.init(.window);
    window.workspace_link.init();

    window.decorations_below.init();
    window.decorations_above.init();

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);
    window.anim_tree.node.setEnabled(false);
    window.fullscreen_background.node.setEnabled(false);
    if (window.backdrop_blur) |blur| {
        fx.configureWindowBlur(blur, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, 0, false);
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
    window.anim_tree.node.destroy();
    window.anim_buffers.deinit(util.gpa);
    window.capture_scene.tree.node.destroy();

    window.node.deinit();

    server.aqueous.forgetWindow(@bitCast(window.ref));
    server.wm.windows.remove(window.ref.key);

    util.gpa.destroy(window);
}

/// Assign this window to the given workspace, removing it from any previous one.
pub fn setWorkspace(window: *Window, workspace: *Workspace) void {
    if (window.workspace == workspace) return;
    window.workspace_link.remove();
    workspace.windows.append(window);
    window.workspace = workspace;
    // Reaping the emptied source workspace and ensuring a trailing empty are
    // deferred to the coalesced workspace cycle so a workspace is never freed
    // synchronously while another in-flight request still references it.
    server.wm.dirtyWindowing();
    server.workspace_manager.dirty();
}

/// Remove this window from its workspace, if any.
pub fn clearWorkspace(window: *Window) void {
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
    // Drop any in-flight slide clone so it can't linger, enabled, in the shared
    // scene layer once the window no longer belongs to a (visible) workspace.
    window.clearSnapshot();
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

    if (window.rendering_scheduled.resend_dimensions or
        window.rendering_scheduled.width != window.rendering_sent.width or
        window.rendering_scheduled.height != window.rendering_sent.height)
    {
        server.wm.dirtyRendering();
    }
}

pub fn setDecorationHint(window: *Window, hint: river.WindowV1.DecorationHint) void {
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
        .closing => {
            window.state = .init;
            window.wm_sent = .{};
            window.wm_requested = .init;
            window.force_configure = false;
            window.rendering_sent = .{};
            window.rendering_requested = .init;

            window.node.link.remove();
            window.node.link.init();

            window.makeInert();
        },
        .ready, .initialized, .mapped => {
            const wm_v1 = server.wm.object orelse return;
            const new = window.object == null;
            const window_v1 = window.object orelse blk: {
                const window_v1 = river.WindowV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                    log.err("out of memory", .{});
                    return; // try again next update
                };
                window.object = window_v1;
                window_v1.setHandler(*Window, handleRequest, handleDestroy, window);
                wm_v1.sendWindow(window_v1);

                window.node.link.remove();
                server.wm.rendering_requested.list.append(&window.node);

                // External policy needs the ext identifier before the first map
                // so it can satisfy river_window_v1.identifier's send-once
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
                // focus_hint (river-window-management-v1 >= 9). Older wm clients won't see it.
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
            if (scheduled.minimize_requested) {
                window_v1.sendMinimizeRequested();
            }
            scheduled.minimize_requested = false;

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

fn pinnedByName(output: *Output, name: [:0]const u8) ?*Workspace {
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |ws| {
        if (ws.pinned and std.mem.eql(u8, ws.name, name)) return ws;
    }
    return null;
}

fn handleRequestInert(
    window_v1: *river.WindowV1,
    request: river.WindowV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) window_v1.destroy();
}

fn handleDestroy(_: *river.WindowV1, window: *Window) void {
    window.object = null;
    window.wm_requested = .init;
    window.rendering_requested = .{
        .x = window.rendering_requested.x,
        .y = window.rendering_requested.y,
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
    window_v1: *river.WindowV1,
    request: river.WindowV1.Request,
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

/// Applies window management state from the window manager and sends a configure
/// to the window if necessary.
/// Returns true if the configure should be waited for by the transaction system.
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
    wm_requested.dimensions = null;

    window.configure_scheduled = .{
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
                    window.rendering_scheduled.width = @intCast(surface.current.width);
                    window.rendering_scheduled.height = @intCast(surface.current.height);
                } else {
                    window.rendering_scheduled.width = xwindow.xsurface.width;
                    window.rendering_scheduled.height = xwindow.xsurface.height;
                }
            } else {
                window.rendering_scheduled.width = xwindow.xsurface.width;
                window.rendering_scheduled.height = xwindow.xsurface.height;
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

fn presentationHint(window: *Window) river.OutputV1.PresentationMode {
    const root_surface = window.rootSurface() orelse return .vsync;
    return switch (server.tearing_control_manager.hintFromSurface(root_surface)) {
        .async => .async,
        .vsync => .vsync,
        _ => unreachable,
    };
}

pub fn renderFinish(window: *Window) void {
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
    // the same eased `anim_tree` overlay as a normal move) instead of a toggle.
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
    const transitioning = (is_incoming or is_outgoing) and transition_dir != 0;
    const enabled = workspace_visible and !requested.hidden and (window.state == .mapped or window.state == .closing);
    window.tree.node.setEnabled(enabled);
    window.popup_tree.node.setEnabled(enabled);

    // A slide-animation clone lives in the shared scene layer and is enabled
    // independently of the live tree. If the window's workspace is no longer
    // active (e.g. the workspace was switched mid-slide), tear the clone down so
    // it cannot keep compositing — at the window's opacity — over the now-active
    // workspace's windows.
    if (!workspace_visible) window.clearSnapshot();

    window.box.width = window.rendering_sent.width;
    window.box.height = window.rendering_sent.height;

    var clip: wlr.Box = requested.clip;
    var content_clip: wlr.Box = requested.content_clip;
    if (window.wm_requested.fullscreen) |output| {
        // Fullscreen positions are snapped: we never animate into/out of fullscreen.
        window.setAnimationTarget(output.sent.x, output.sent.y, false);
        // Gate the fullscreen background on workspace visibility too, otherwise a
        // fullscreen window on an inactive workspace leaks its background into the
        // active workspace's scene tree.
        window.fullscreen_background.node.setEnabled(workspace_visible);
        const width, const height = output.sent.dimensions();
        window.fullscreen_background.setSize(width, height);
        clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        inline for (.{
            "rounded_outline",
            "left",
            "right",
            "top",
            "bottom",
        }) |part| {
            @field(window.border, part).node.setEnabled(false);
        }
        // Fullscreen content should not be rounded.
        fx.setTreeRadius(window.surfaces.tree, 0);
        fx.setTreeRadius(window.surfaces.saved_tree, 0);
    } else {
        if (window.interactive != .none) {
            // Pointer-driven move/resize must track the latest policy geometry
            // exactly. Retargetable easing here makes the visible clone trail
            // behind the cursor and can keep stale resize contents on screen.
            window.setAnimationTarget(requested.x, requested.y, false);
        } else if (transitioning and is_outgoing) {
            // Outgoing window: ease its clone from the real position to one
            // output-width off-screen in the transition direction; the live
            // tree jumps off-screen immediately (it is leaving) but stays
            // invisible behind the clone.
            window.setAnimationTarget(requested.x - transition_dir * output_width, requested.y, true);
            window.cur_anim_rate = server.wm.workspace_transition.rate;
        } else if (transitioning and is_incoming and !window.slide_seeded) {
            // Incoming window, first transition frame: seed its clone one
            // output-width off-screen, then ease it to its real position.
            window.beginSlideFrom(
                requested.x + transition_dir * output_width,
                requested.y,
                requested.x,
                requested.y,
            );
            window.slide_seeded = true;
        } else if (transitioning and is_incoming) {
            // Incoming window, subsequent frames: keep easing toward the real
            // position so the in-flight slide continues.
            window.setAnimationTarget(requested.x, requested.y, true);
            window.cur_anim_rate = server.wm.workspace_transition.rate;
        } else {
            // Only animate when the window is actually on-screen; snap otherwise
            // so a hidden/closing window does not visibly "catch up" when it
            // reappears.
            window.setAnimationTarget(requested.x, requested.y, enabled);
        }
        window.fullscreen_background.node.setEnabled(false);
        window.drawBorders();
        fx.setTreeRadius(window.surfaces.tree, requested.border.corner_radius);
        fx.setTreeRadius(window.surfaces.saved_tree, requested.border.corner_radius);
        if (window.anim_snapshot) {
            fx.setTreeRadius(window.anim_tree, requested.border.corner_radius);
        }
    }
    window.refreshBackdropBlur();

    // While a position animation is running, applyOpacity() updates the visible
    // animation clone and keeps the live surfaces invisible at the target so
    // scene hit-testing / input stay correct.
    window.applyOpacity();
    window.tree.node.setPosition(window.box.x, window.box.y);
    window.popup_tree.node.setPosition(window.box.x, window.box.y);

    switch (window.impl) {
        .xwayland => |*xwindow| _ = xwindow.configure(),
        .toplevel, .destroying => {},
    }

    window.applySurfaceClip(&clip, &content_clip);
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| {
            decoration.renderFinish(&clip);
        }
    }
}

fn refreshBackdropBlur(window: *Window) void {
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
    const active = allow and
        server.wm.blur.enabled and
        server.wm.blur.radius > 0 and
        server.wm.blur.passes > 0 and
        requested.blur_enabled and
        !window.anim_snapshot and
        window.box.width > 0 and
        window.box.height > 0;
    if (!active) {
        fx.configureWindowBlur(blur, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, 0, false);
        return;
    }

    const full: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = window.box.width,
        .height = window.box.height,
    };
    var visible = full;
    if (!clip.empty() and !visible.intersection(&visible, clip)) {
        fx.configureWindowBlur(blur, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, 0, false);
        return;
    }
    if (!content_clip.empty() and !visible.intersection(&visible, content_clip)) {
        fx.configureWindowBlur(blur, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, 0, false);
        return;
    }

    const clipped = visible.x != full.x or visible.y != full.y or
        visible.width != full.width or visible.height != full.height;
    fx.configureWindowBlur(blur, visible, if (clipped) 0 else radius, true);
}

/// Feed a new target position into the animator.
///
/// The input/geometry nodes (`tree`/`popup_tree`, and `box`) ALWAYS jump to the
/// final target immediately — they are never translated while an animation runs.
/// This keeps scene hit-testing (`Scene.at`) reading the settled origin, so a
/// moving window can no longer fabricate surface-local pointer motion. The visual
/// slide is performed entirely by the input-inert `anim_tree` overlay, which holds
/// a frozen clone of the surfaces and is eased from the old origin to the target in
/// `stepAnimation`.
///
/// `animate` is false (forcing a snap, no overlay) when animations are compiled
/// out, on the first ever placement, for fullscreen, and whenever the window is
/// not currently on-screen.
fn setAnimationTarget(window: *Window, target_x: i32, target_y: i32, animate: bool) void {
    const tx: f64 = @floatFromInt(target_x);
    const ty: f64 = @floatFromInt(target_y);

    if (!fx.anim_enabled or !animate or !window.anim_initialized) {
        window.clearSnapshot();
        window.anim_x = tx;
        window.anim_y = ty;
        window.anim_active = false;
        window.anim_initialized = true;
    } else if (window.anim_target_x != tx or window.anim_target_y != ty) {
        // Begin a fresh slide from the current on-screen origin. If a slide is
        // already in flight, keep its current visual position and just retarget.
        if (!window.anim_active) {
            window.anim_x = @floatFromInt(window.box.x);
            window.anim_y = @floatFromInt(window.box.y);
        }
        window.armSnapshot();
        window.anim_active = true;
        // Default to the ordinary move rate; the workspace-swap call sites
        // re-assert `fx.workspace_slide_rate` after this returns.
        window.cur_anim_rate = fx.anim_rate;
        // Arming an animation does not move the live node, so explicitly schedule
        // a frame to ensure the per-frame driver in Output.handleFrame runs.
        if (window.workspace) |ws| {
            if (ws.output.wlr_output) |wlr_output| wlr_output.scheduleFrame();
        }
    }

    window.anim_target_x = tx;
    window.anim_target_y = ty;
    // Geometry/input always settle at the target; only `anim_tree` animates.
    window.box.x = target_x;
    window.box.y = target_y;
    window.updateAnimationClip();
}

/// Capture a frozen clone of the live surfaces into `anim_tree`, positioned at the
/// window's current on-screen origin, so it can be eased toward the target while
/// the live surfaces are pinned (and kept invisible) at the target. No-op if a
/// snapshot is already armed (a re-target reuses the existing clone).
fn armSnapshot(window: *Window) void {
    if (comptime !fx.anim_enabled) return;
    if (window.anim_snapshot) return;
    // Render the overlay as a sibling of the live tree so it draws in the same
    // layer; raise it above so the (invisible) live surfaces don't occlude it.
    if (window.tree.node.parent) |parent| {
        window.anim_tree.node.reparent(parent);
    }
    // A scrolling window's live surface tree may already be cropped by the
    // prior frame. Temporarily remove that crop so the snapshot retains the
    // complete buffer and can reveal the correct portion as it moves. The live
    // tree receives the current requested clip later in renderFinish().
    const no_clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    window.applySurfaceClip(&no_clip, &no_clip);
    window.surfaces.cloneInto(window.anim_tree);
    window.anim_buffers.clearRetainingCapacity();
    var capture: AnimBufferCapture = .{ .window = window };
    window.anim_tree.node.forEachBuffer(*AnimBufferCapture, captureAnimBuffer, &capture);
    if (capture.failed) {
        log.err("unable to track animation buffers for viewport clipping", .{});
        var it = window.anim_tree.children.safeIterator(.forward);
        while (it.next()) |node| node.destroy();
        window.anim_buffers.clearRetainingCapacity();
        return;
    }
    window.anim_tree.node.setPosition(
        @intFromFloat(@round(window.anim_x)),
        @intFromFloat(@round(window.anim_y)),
    );
    window.anim_tree.node.raiseToTop();
    window.anim_tree.node.setEnabled(true);
    window.anim_snapshot = true;
}

/// If a slide animation clone is currently armed, re-raise it above its live
/// siblings. Called after `WindowManager.renderFinish`'s reorder loop, which
/// re-raises every window's live `tree` (and never the clones), so an in-flight
/// clone would otherwise be buried by an opaque live tree mid-slide. Mirrors the
/// reparent in `armSnapshot` so a window that became fullscreen during the slide
/// still has its clone follow the live tree's (possibly new) parent layer.
pub fn raiseSnapshotIfActive(window: *Window) void {
    if (!window.anim_snapshot) return;
    if (window.tree.node.parent) |parent| {
        window.anim_tree.node.reparent(parent);
    }
    window.anim_tree.node.raiseToTop();
}

/// Tear down the cosmetic overlay and restore the live surfaces' opacity, leaving
/// no positional pop because the live tree has been at the target the whole time.
fn clearSnapshot(window: *Window) void {
    if (!window.anim_snapshot) return;
    var it = window.anim_tree.children.safeIterator(.forward);
    while (it.next()) |node| node.destroy();
    window.anim_buffers.clearRetainingCapacity();
    window.anim_tree.node.setEnabled(false);
    window.anim_snapshot = false;
    window.applyOpacity();
    window.refreshBackdropBlur();
}

/// Begin a slide whose eased clone starts at (start_x, start_y) and animates to
/// (target_x, target_y). Used by the workspace-swap transition to make an
/// incoming window's clone appear off-screen and then slide into place, while
/// the live surfaces (and input geometry) settle directly at the target.
pub fn beginSlideFrom(
    window: *Window,
    start_x: i32,
    start_y: i32,
    target_x: i32,
    target_y: i32,
) void {
    if (comptime !fx.anim_enabled) return;
    // Seed the clone's origin off-screen and arm it there. Clearing anim_active
    // first ensures setAnimationTarget does not overwrite the seeded origin with
    // the live (on-screen) box position.
    window.anim_x = @floatFromInt(start_x);
    window.anim_y = @floatFromInt(start_y);
    window.anim_active = false;
    window.armSnapshot();
    window.anim_active = true;
    window.setAnimationTarget(target_x, target_y, true);
    // setAnimationTarget reset the rate to the ordinary default; re-assert the
    // slower workspace-swap pacing for this incoming slide.
    window.cur_anim_rate = server.wm.workspace_transition.rate;
}

/// Abort any in-flight slide for this window, tearing down its clone. Used when
/// a workspace-swap transition is cancelled (output disconnect/migrate/clear).
pub fn cancelSlide(window: *Window) void {
    if (comptime !fx.anim_enabled) return;
    window.anim_active = false;
    window.slide_seeded = false;
    window.cur_anim_rate = fx.anim_rate;
    window.clearSnapshot();
}

/// Advance this window's position animation by `dt_s` seconds. Only the cosmetic
/// `anim_tree` overlay is moved; the live `tree`/`popup_tree` stay pinned at the
/// target. Returns true when animation changed scene state, including the final
/// snapshot teardown frame. Uses frame-rate-independent exponential smoothing.
pub fn stepAnimation(window: *Window, dt_s: f64) bool {
    if (comptime !fx.anim_enabled) return false;
    if (!window.anim_active) {
        // Defensive invariant: a clone may only stay armed while a slide is in
        // flight (`anim_active`). If any path ever clears `anim_active` without
        // routing through `clearSnapshot()`, tear the orphaned clone down here so
        // it cannot keep compositing in the shared scene layer.
        if (window.anim_snapshot) {
            window.clearSnapshot();
            return true;
        }
        return false;
    }

    const t = 1.0 - @exp(-window.cur_anim_rate * dt_s);
    window.anim_x += (window.anim_target_x - window.anim_x) * t;
    window.anim_y += (window.anim_target_y - window.anim_y) * t;

    if (@abs(window.anim_target_x - window.anim_x) < fx.anim_epsilon and
        @abs(window.anim_target_y - window.anim_y) < fx.anim_epsilon)
    {
        window.anim_x = window.anim_target_x;
        window.anim_y = window.anim_target_y;
        window.anim_active = false;
        window.clearSnapshot();
        return true;
    }

    window.anim_tree.node.setPosition(
        @intFromFloat(@round(window.anim_x)),
        @intFromFloat(@round(window.anim_y)),
    );
    window.updateAnimationClip();

    return true;
}

const AnimBuffer = struct {
    buffer: *wlr.SceneBuffer,
    x: i32,
    y: i32,
    source: wlr.FBox,
    dest_width: i32,
    dest_height: i32,
    transform: wl.Output.Transform,
};

const AnimBufferCapture = struct {
    window: *Window,
    failed: bool = false,
};

fn captureAnimBuffer(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, capture: *AnimBufferCapture) void {
    if (capture.failed) return;
    const source = effectiveSourceBox(buffer) orelse return;
    const quarter_turn = transformSwapsAxes(buffer.transform);
    const natural_width = if (quarter_turn) source.height else source.width;
    const natural_height = if (quarter_turn) source.width else source.height;
    const dest_width = if (buffer.dst_width > 0)
        buffer.dst_width
    else
        @max(1, @as(i32, @intFromFloat(@round(natural_width))));
    const dest_height = if (buffer.dst_height > 0)
        buffer.dst_height
    else
        @max(1, @as(i32, @intFromFloat(@round(natural_height))));
    capture.window.anim_buffers.append(util.gpa, .{
        .buffer = buffer,
        .x = sx,
        .y = sy,
        .source = source,
        .dest_width = dest_width,
        .dest_height = dest_height,
        .transform = buffer.transform,
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

fn inverseTransform(transform: wl.Output.Transform) wl.Output.Transform {
    return switch (transform) {
        .@"90" => .@"270",
        .@"270" => .@"90",
        // Reflections, including reflected rotations, are self-inverse.
        else => transform,
    };
}

/// Crop the input-inert animation clone against the fixed global viewport.
/// Source rectangles are transformed back into buffer coordinates so rotated
/// and flipped client buffers remain correct.
fn updateAnimationClip(window: *Window) void {
    if (!window.anim_snapshot) return;
    const requested = &window.rendering_requested;
    if (requested.clip.empty()) {
        for (window.anim_buffers.items) |record| restoreAnimBuffer(record);
        return;
    }

    const origin_x: i32 = @intFromFloat(@round(window.anim_x));
    const origin_y: i32 = @intFromFloat(@round(window.anim_y));
    const viewport: wlr.Box = .{
        .x = requested.x + requested.clip.x,
        .y = requested.y + requested.clip.y,
        .width = requested.clip.width,
        .height = requested.clip.height,
    };
    for (window.anim_buffers.items) |record| {
        const destination: visual_state.Rect = .{
            .x = origin_x + record.x,
            .y = origin_y + record.y,
            .width = record.dest_width,
            .height = record.dest_height,
        };
        const clipped = visual_state.destinationCrop(destination, .{
            .x = viewport.x,
            .y = viewport.y,
            .width = viewport.width,
            .height = viewport.height,
        }) orelse {
            record.buffer.node.setEnabled(false);
            continue;
        };

        record.buffer.node.setEnabled(true);
        const crop_x = clipped.x;
        const crop_y = clipped.y;
        record.buffer.node.setPosition(record.x + crop_x, record.y + crop_y);
        record.buffer.setDestSize(clipped.width, clipped.height);

        const transformed_width = if (transformSwapsAxes(record.transform)) record.source.height else record.source.width;
        const transformed_height = if (transformSwapsAxes(record.transform)) record.source.width else record.source.height;
        const transformed_crop: wlr.FBox = .{
            .x = @as(f64, @floatFromInt(crop_x)) * transformed_width / @as(f64, @floatFromInt(record.dest_width)),
            .y = @as(f64, @floatFromInt(crop_y)) * transformed_height / @as(f64, @floatFromInt(record.dest_height)),
            .width = @as(f64, @floatFromInt(clipped.width)) * transformed_width / @as(f64, @floatFromInt(record.dest_width)),
            .height = @as(f64, @floatFromInt(clipped.height)) * transformed_height / @as(f64, @floatFromInt(record.dest_height)),
        };
        var source_crop: wlr.FBox = undefined;
        source_crop.transform(
            &transformed_crop,
            inverseTransform(record.transform),
            transformed_width,
            transformed_height,
        );
        source_crop.x += record.source.x;
        source_crop.y += record.source.y;
        record.buffer.setSourceBox(&source_crop);
    }
}

fn restoreAnimBuffer(record: AnimBuffer) void {
    record.buffer.node.setEnabled(true);
    record.buffer.node.setPosition(record.x, record.y);
    record.buffer.setDestSize(record.dest_width, record.dest_height);
    record.buffer.setSourceBox(&record.source);
}

fn drawBorders(window: *Window) void {
    const requested = &window.rendering_requested;
    inline for (.{
        "rounded_outline",
        "left",
        "right",
        "top",
        "bottom",
    }) |part| {
        @field(window.border, part).node.setEnabled(false);
    }

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

    // A set_clip_box can cut through any side of the outline. Keep that path
    // square: rounding the newly clipped edge would create a corner at the clip
    // boundary rather than preserve the window's original corner. A single
    // clipped ring also represents all four edges, so selective borders use the
    // edge-node fallback below.
    const rounded = border.corner_radius > 0 and
        requested.clip.empty() and
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
            if (!requested.clip.empty()) {
                _ = edge.box.intersection(edge.box, &requested.clip);
            }
            const rect = @field(window.border, edge.name);
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
    const outer_radius: u31 = @intCast(@min(
        @as(u32, radius) + @as(u32, border.width),
        math.maxInt(u31),
    ));
    const bw: i32 = border.width;

    const outline: wlr.Box = .{
        .x = content.x - bw,
        .y = content.y - bw,
        .width = content.width + 2 * bw,
        .height = content.height + 2 * bw,
    };
    const rect = window.border.rounded_outline;
    rect.node.setEnabled(true);
    rect.node.setPosition(outline.x, outline.y);
    rect.setSize(outline.width, outline.height);
    rect.setColor(&color);
    fx.setRectRadius(rect, outer_radius);
    fx.setRectClippedRegion(rect, .{
        .x = bw,
        .y = bw,
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
    var surface_clip: wlr.Box = undefined;
    if (!a.empty() and !b.empty()) {
        if (!surface_clip.intersection(a, b)) {
            // Clip boxes are both non-empty but don't intersect, all window
            // content is clipped away.
            window.surfaces.setEnabled(false);
            return;
        }
    } else if (!a.empty()) {
        surface_clip = a.*;
    } else {
        surface_clip = b.*;
    }
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
            const parent: *XdgToplevel = @ptrCast(@alignCast(wlr_parent.base.data));
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
    const kind = window.policy_state.kind;
    return .{
        .backend = backend,
        .app_id = app_id,
        .class = class,
        .title = window.getTitle(),
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

    fx.setTreeOpacity(window.surfaces.saved_tree, opacity);
    fx.setTreeOpacity(window.popup_tree, opacity);
    if (window.anim_snapshot) {
        fx.setTreeOpacity(window.anim_tree, opacity);
        fx.setTreeOpacity(window.surfaces.tree, 0);
    } else {
        fx.setTreeOpacity(window.surfaces.tree, opacity);
    }
}

/// Effective compositor opacity shared by a top-level and its popup surfaces.
pub fn effectiveOpacity(window: *const Window) f32 {
    const opacity_frac = window.rendering_requested.opacity orelse server.wm.default_opacity;
    return visual_state.fractionToOpacity(opacity_frac);
}

/// Publish this window through both the standard ext list and the legacy wlr
/// manager used by wlrctl/taskbars. This must not depend on an external
/// river_window_manager_v1 client: integrated policy deliberately has none.
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

    // The first buffer was just committed; scene buffers start at opacity 1.0, so
    // apply the requested/global opacity now rather than waiting for the next
    // render sequence.
    window.applyOpacity();

    if (window.workspace == null) {
        if (window.initialOutput()) |output| {
            if (output.active_workspace) |workspace| {
                window.setWorkspace(workspace);
            }
        }
    }

    // Foreign-toplevel protocols describe mapped windows. This is also the
    // integrated-policy publication path: there is no river_window_manager_v1
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

// ---------------------------------------------------------------------------
// External docks/taskbars (Noctalia, waybar's wlr-taskbar, etc.) can ask the
// compositor to activate / close / maximize / minimize / fullscreen a window
// via zwlr_foreign_toplevel_manager_v1. We forward those into the same
// `wm_scheduled.*_requested` fields that XDG clients use, so the river WM
// client sees them as ordinary requests and can react identically.
// ---------------------------------------------------------------------------

fn handleFtmRequestMaximize(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized),
    event: *wlr.ForeignToplevelHandleV1.event.Maximized,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_maximize", listener);
    if (window.state != .mapped and window.state != .initialized) return;
    window.wm_scheduled.maximize_requested = if (event.maximized) .maximize else .unmaximize;
    server.wm.dirtyWindowing();
}

fn handleFtmRequestMinimize(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized),
    event: *wlr.ForeignToplevelHandleV1.event.Minimized,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_minimize", listener);
    if (window.state != .mapped and window.state != .initialized) return;
    if (event.minimized) {
        // "Please minimize" — schedule it for the next manage sequence; the wm
        // client receives it via river_window_v1.minimize_requested.
        window.wm_scheduled.minimize_requested = true;
        server.wm.dirtyWindowing();
    } else {
        // "Please un-minimize" — forward to the wm via the dedicated
        // unminimize_requested event (river-window-management-v1 >= 5).
        // Older wm clients won't see this; they should rely on activate.
        const window_v1 = window.object orelse return;
        if (window_v1.getVersion() >= 5) {
            window_v1.sendUnminimizeRequested();
            server.wm.dirtyWindowing();
        }
    }
}

fn handleFtmRequestActivate(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated),
    event: *wlr.ForeignToplevelHandleV1.event.Activated,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_activate", listener);
    _ = event; // seat is informational; the wm picks the focus seat itself.
    if (window.state != .mapped and window.state != .initialized) return;
    // Forward to the wm client via the dedicated activate_requested event
    // (river-window-management-v1 >= 5). The wm client decides focus policy
    // (workspace switching, output following, etc.); the compositor never makes
    // focus decisions on its own.
    const window_v1 = window.object orelse return;
    if (window_v1.getVersion() >= 5) {
        window_v1.sendActivateRequested();
        server.wm.dirtyWindowing();
    }
}

fn handleFtmRequestFullscreen(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen),
    event: *wlr.ForeignToplevelHandleV1.event.Fullscreen,
) void {
    const window: *Window = @fieldParentPtr("ftm_request_fullscreen", listener);
    if (window.state != .mapped and window.state != .initialized) return;
    if (event.fullscreen) {
        const output_hint: ?*Output = if (@intFromPtr(event.output) != 0)
            @ptrCast(@alignCast(event.output.data))
        else
            null;
        window.wm_scheduled.fullscreen_requested = .{ .fullscreen = output_hint };
    } else {
        window.wm_scheduled.fullscreen_requested = .exit;
    }
    server.wm.dirtyWindowing();
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
