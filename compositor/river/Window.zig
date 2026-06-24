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
    /// Whether backdrop blur applies to this window. Driven by
    /// river_window_v1.set_window_blur; defaults to true so windows inherit the
    /// global blur state until the wm says otherwise (false excludes e.g. games).
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

/// Opaque black rectangle used as the background while this window is rendered fullscreen.
/// TODO consider using one of these per output rather than one per window to save memory
/// if the complexity tradeoff is worth it.
fullscreen_background: *wlr.SceneRect,

decorations_below: wl.list.Head(Decoration, .link),
decorations_below_tree: *wlr.SceneTree,

surfaces: Scene.SaveableSurfaces,

border: struct {
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,
},

decorations_above: wl.list.Head(Decoration, .link),
decorations_above_tree: *wlr.SceneTree,

popup_tree: *wlr.SceneTree,

capture_scene: *wlr.Scene,
capture_source: ?*wlr.ExtImageCaptureSourceV1 = null,

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
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
    parent: ?Window.Ref = null,
} = .{},

/// Windowing state requested by the wm.
wm_requested: WmRequested = .init,

/// State to be sent to the window in the next configure.
configure_scheduled: Configure = .init,
/// State sent to the window in the latest configure.
configure_sent: Configure = .init,

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

    window.* = .{
        .ref = .{ .key = key },
        .node = undefined,
        .impl = impl,
        .tree = tree,
        .fullscreen_background = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1 }),
        .decorations_below = undefined,
        .decorations_below_tree = try tree.createSceneTree(),
        .surfaces = try Scene.SaveableSurfaces.init(tree),
        .border = .{
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

    window.node.init(.window);
    window.workspace_link.init();

    window.decorations_below.init();
    window.decorations_above.init();

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);
    window.fullscreen_background.node.setEnabled(false);

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

/// Send dirty state as part of a manage sequence.
pub fn manageStart(window: *Window) void {
    switch (window.state) {
        .init => {},
        .closing => {
            window.state = .init;
            window.wm_sent = .{};
            window.wm_requested = .init;
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

                // A handle may have already been created if the window manager is restarted.
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
                        // Phase 4: forward dock/taskbar requests into the wm.
                        handle.events.request_maximize.add(&window.ftm_request_maximize);
                        handle.events.request_minimize.add(&window.ftm_request_minimize);
                        handle.events.request_activate.add(&window.ftm_request_activate);
                        handle.events.request_fullscreen.add(&window.ftm_request_fullscreen);
                        handle.events.request_close.add(&window.ftm_request_close);
                        // Reset cached sent-state so the next manageFinish pushes fresh state.
                        window.wlr_toplevel_sent = .{};
                    } else |_| {
                        log.err("failed to create wlr foreign toplevel handle", .{});
                    }
                }

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

    const activated = blk: {
        var it = server.wm.sent.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (window.wlr_toplevel_handle) |handle| {
        const sent = &window.wlr_toplevel_sent;
        if (sent.activated != activated) {
            handle.setActivated(activated);
            sent.activated = activated;
        }
        const maximized = wm_requested.maximized;
        if (sent.maximized != maximized) {
            handle.setMaximized(maximized);
            sent.maximized = maximized;
        }
        const fullscreen = wm_requested.fullscreen != null or wm_requested.inform_fullscreen;
        if (sent.fullscreen != fullscreen) {
            handle.setFullscreen(fullscreen);
            sent.fullscreen = fullscreen;
        }
        // The wm communicates "minimized" by hiding the window in the scene.
        const minimized = window.rendering_requested.hidden;
        if (sent.minimized != minimized) {
            handle.setMinimized(minimized);
            sent.minimized = minimized;
        }
        // Parent relationship — only mirror if both parent and self have a handle.
        const parent_handle: ?*wlr.ForeignToplevelHandleV1 = blk: {
            const parent = window.getParent() orelse break :blk null;
            break :blk parent.wlr_toplevel_handle;
        };
        if (sent.parent != parent_handle) {
            handle.setParent(parent_handle);
            sent.parent = parent_handle;
        }
        // Push per-output enter/leave so foreign-toplevel clients can scope
        // windows to monitors (Noctalia onlySameOutput, waybar wlr-taskbar, …).
        window.syncForeignToplevelOutputs();
    }

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
            window.rendering_scheduled.width = xwindow.xsurface.width;
            window.rendering_scheduled.height = xwindow.xsurface.height;
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
    const workspace_visible = if (window.workspace) |workspace| workspace.isActive() else true;
    const enabled = workspace_visible and !requested.hidden and (window.state == .mapped or window.state == .closing);
    window.tree.node.setEnabled(enabled);
    window.popup_tree.node.setEnabled(enabled);

    window.box.width = window.rendering_sent.width;
    window.box.height = window.rendering_sent.height;

    var clip: wlr.Box = requested.clip;
    var content_clip: wlr.Box = requested.content_clip;
    if (window.wm_requested.fullscreen) |output| {
        // Fullscreen positions are snapped: we never animate into/out of fullscreen.
        window.setAnimationTarget(output.sent.x, output.sent.y, false);
        window.fullscreen_background.node.setEnabled(true);
        const width, const height = output.sent.dimensions();
        window.fullscreen_background.setSize(width, height);
        clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        inline for (.{ "left", "right", "top", "bottom" }) |edge| {
            @field(window.border, edge).node.setEnabled(false);
        }
        // Fullscreen content should not be rounded.
        fx.setTreeRadius(window.surfaces.tree, 0);
        fx.setTreeRadius(window.surfaces.saved_tree, 0);
    } else {
        const animate = enabled and !window.shouldSnapPosition();
        // Only animate when the window is actually on-screen; snap otherwise so a
        // hidden/closing window does not visibly "catch up" when it reappears.
        window.setAnimationTarget(requested.x, requested.y, animate);
        window.fullscreen_background.node.setEnabled(false);
        window.drawBorders();
        fx.setTreeRadius(window.surfaces.tree, requested.border.corner_radius);
        fx.setTreeRadius(window.surfaces.saved_tree, requested.border.corner_radius);
    }

    // Per-window blur exclusion: when blur is disabled for this window, mark its
    // buffers opaque so the global optimized-blur pass clips them out (games etc.).
    const blur_excluded = !requested.blur_enabled;
    fx.setTreeBlurExcluded(window.surfaces.tree, blur_excluded);
    fx.setTreeBlurExcluded(window.surfaces.saved_tree, blur_excluded);

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

/// Feed a new target position into the animator and write the value that should
/// be rendered this frame into `window.box.{x,y}`.
///
/// `animate` is false (forcing a snap) when animations are compiled out, on the
/// first ever placement, for fullscreen, and whenever the window is not currently
/// on-screen — this prevents a hidden/closing window from sliding when it becomes
/// visible again. Otherwise a changed target arms the animation; the actual
/// interpolation happens in `stepAnimation`, driven by `Output.handleFrame`.
fn setAnimationTarget(window: *Window, target_x: i32, target_y: i32, animate: bool) void {
    const tx: f64 = @floatFromInt(target_x);
    const ty: f64 = @floatFromInt(target_y);

    if (!fx.anim_enabled or !animate or !window.anim_initialized) {
        window.anim_x = tx;
        window.anim_y = ty;
        window.anim_active = false;
        window.anim_initialized = true;
    } else if (window.anim_target_x != tx or window.anim_target_y != ty) {
        window.anim_active = true;
        // Arming an animation may not move the node this frame (the first frame
        // renders at the old position), so explicitly schedule a frame to ensure
        // the per-frame driver in Output.handleFrame actually starts running.
        if (window.workspace) |ws| {
            if (ws.output.wlr_output) |wlr_output| wlr_output.scheduleFrame();
        }
    }

    window.anim_target_x = tx;
    window.anim_target_y = ty;
    window.box.x = @intFromFloat(@round(window.anim_x));
    window.box.y = @intFromFloat(@round(window.anim_y));
}

/// Advance this window's position animation by `dt_s` seconds and re-position its
/// scene nodes. Returns true while the window is still moving so the owning output
/// keeps scheduling frames. Uses frame-rate-independent exponential smoothing.
pub fn stepAnimation(window: *Window, dt_s: f64) bool {
    if (comptime !fx.anim_enabled) return false;
    if (!window.anim_active) return false;
    if (window.shouldSnapPosition()){
        window.anim_x = window.anim_target_x;
        window.anim_y = window.anim_target_y;
        window.anim_active = false;
        window.box.x = @intFromFloat(@round(window.anim_x));
        window.box.y = @intFromFloat(@round(window.anim_y));
        window.tree.node.setPosition(window.box.x, window.box.y);
        window.popup_tree.node.setPosition(window.box.x, window.box.y);
        return false;
    }
    const t = 1.0 - @exp(-fx.anim_rate * dt_s);
    window.anim_x += (window.anim_target_x - window.anim_x) * t;
    window.anim_y += (window.anim_target_y - window.anim_y) * t;

    if (@abs(window.anim_target_x - window.anim_x) < fx.anim_epsilon and
        @abs(window.anim_target_y - window.anim_y) < fx.anim_epsilon)
    {
        window.anim_x = window.anim_target_x;
        window.anim_y = window.anim_target_y;
        window.anim_active = false;
    }

    window.box.x = @intFromFloat(@round(window.anim_x));
    window.box.y = @intFromFloat(@round(window.anim_y));
    window.tree.node.setPosition(window.box.x, window.box.y);
    window.popup_tree.node.setPosition(window.box.x, window.box.y);

    return window.anim_active;
}

fn drawBorders(window: *Window) void {
    const requested = &window.rendering_requested;
    var content: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = window.box.width,
        .height = window.box.height,
    };
    if (requested.content_clip.empty() or
        content.intersection(&content, &requested.content_clip))
    {
        // f32 cannot represent all u32 values exactly, therefore we must initially use f64
        // (which can) and then cast to f32, potentially losing precision.
        const border = &requested.border;
        const color: [4]f32 = .{
            @floatCast(@as(f64, @floatFromInt(border.r)) / math.maxInt(u32)),
            @floatCast(@as(f64, @floatFromInt(border.g)) / math.maxInt(u32)),
            @floatCast(@as(f64, @floatFromInt(border.b)) / math.maxInt(u32)),
            @floatCast(@as(f64, @floatFromInt(border.a)) / math.maxInt(u32)),
        };
        var left: wlr.Box = .{
            .x = -@as(i32, border.width),
            .y = 0,
            .width = border.width,
            .height = content.height,
        };
        var right: wlr.Box = .{
            .x = content.width,
            .y = 0,
            .width = border.width,
            .height = content.height,
        };
        var top: wlr.Box = .{
            .x = 0,
            .y = -@as(i32, border.width),
            .width = content.width,
            .height = border.width,
        };
        var bottom: wlr.Box = .{
            .x = 0,
            .y = content.height,
            .width = content.width,
            .height = border.width,
        };
        // Use left and right scene rects to draw the corners if needed
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
            fx.setRectRadius(rect, border.corner_radius);
        }
    }
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

pub fn getParent(window: *Window) ?*Window {
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

/// Per-window content opacity: the per-window value (set_window_opacity) wins over
/// the global default (set_opacity); both are 32-bit unsigned fractions. Newly
/// created scene buffers default to opacity 1.0, so this must be reapplied whenever
/// buffers may have been (re)created, not only at render-finish.
pub fn applyOpacity(window: *Window) void {
    const opacity_frac = window.rendering_requested.opacity orelse server.wm.default_opacity;
    const opacity: f32 = @floatCast(@as(f64, @floatFromInt(opacity_frac)) /
        @as(f64, @floatFromInt(std.math.maxInt(u32))));
    fx.setTreeOpacity(window.surfaces.tree, opacity);
    fx.setTreeOpacity(window.surfaces.saved_tree, opacity);
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
        if (server.om.outputs.first()) |output| {
            if (output.active_workspace) |workspace| window.setWorkspace(workspace);
        }
    }
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

// ---------------------------------------------------------------------------
// Phase 4: foreign-toplevel-management client request handlers.
//
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
    // (tag switching, output following, etc.); the compositor never makes
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

fn hasActivePointerLock(window: *Window) bool{
    if(window.wm_requested.fullscreen != null) return true;
    const surface = window.rootSurface() orelse return false;
    const seat = server.input_manager.defaultSeat();
    const constraint = seat.cursor.constraint orelse return false;
    return constraint.state == .active and constraint.wlr_constraint.surface == surface;
}

fn shouldSnapPosition(window: *Window) bool {

    if (window.wm_requested.fullscreen != null) return true;

    const surface = window.rootSurface() orelse return false;
    const seat = server.input_manager.defaultSeat();

    if (seat.wlr_seat.pointer_state.focused_surface == surface) return true;


    if (seat.cursor.constraint) |c| {
        if (c.state == .active and c.wlr_constraint.surface == surface) return true;
    }
    return false;
}
