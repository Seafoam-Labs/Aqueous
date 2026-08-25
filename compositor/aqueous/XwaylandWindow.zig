// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const XwaylandWindow = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.xwayland);
const xwayland_projection = @import("xwayland_projection.zig");

extern fn wlr_scene_surface_set_destination_scale(
    scene_surface: *wlr.SceneSurface,
    scale: f64,
) void;

/// TODO(zig): get rid of this and use @fieldParentPtr(), https://github.com/ziglang/zig/issues/6611
window: *Window,

xsurface: *wlr.XwaylandSurface,
/// Created on map and destroyed on unmap
surface_tree: ?*wlr.SceneTree = null,

// Active over entire lifetime
destroy: wl.Listener(void) = .init(handleDestroy),
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(handleRequestConfigure),
request_move: wl.Listener(void) = .init(handleRequestMove),
request_resize: wl.Listener(*wlr.XwaylandSurface.event.Resize) = .init(handleRequestResize),
set_override_redirect: wl.Listener(void) = .init(handleSetOverrideRedirect),
associate: wl.Listener(void) = .init(handleAssociate),
dissociate: wl.Listener(void) = .init(handleDissociate),
set_size_hints: wl.Listener(void) = .init(handleSetSizeHints),
set_title: wl.Listener(void) = .init(handleSetTitle),
set_class: wl.Listener(void) = .init(handleSetClass),
set_parent: wl.Listener(void) = .init(handleSetParent),
set_decorations: wl.Listener(void) = .init(handleSetDecorations),
set_hints: wl.Listener(void) = .init(handleSetHints),
request_maximize: wl.Listener(void) = .init(handleRequestMaximize),
request_fullscreen: wl.Listener(void) = .init(handleRequestFullscreen),
request_minimize: wl.Listener(*wlr.XwaylandSurface.event.Minimize) = .init(handleRequestMinimize),
focus_in: wl.Listener(void) = .init(handleFocusIn),
grab_focus: wl.Listener(void) = .init(handleGrabFocus),
focused_before_map: bool = false,
grab_focused_before_map: bool = false,
projection_scale: f64 = 1,

// Active while the xsurface is associated with a wlr_surface
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),

pub fn create(xsurface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
    log.debug("new xwayland window: title='{?s}', class='{?s}'", .{
        xsurface.title,
        xsurface.class,
    });

    const window = try Window.create(.{ .xwayland = .{
        .window = undefined,
        .xsurface = xsurface,
    } });
    errdefer window.destroy();

    const xwindow = &window.impl.xwayland;
    xwindow.window = window;

    xsurface.data = xwindow;

    // Add listeners that are active over the window's entire lifetime
    xsurface.events.destroy.add(&xwindow.destroy);
    xsurface.events.associate.add(&xwindow.associate);
    xsurface.events.dissociate.add(&xwindow.dissociate);
    xsurface.events.request_configure.add(&xwindow.request_configure);
    xsurface.events.request_move.add(&xwindow.request_move);
    xsurface.events.request_resize.add(&xwindow.request_resize);
    xsurface.events.set_override_redirect.add(&xwindow.set_override_redirect);
    xsurface.events.set_size_hints.add(&xwindow.set_size_hints);
    xsurface.events.set_title.add(&xwindow.set_title);
    xsurface.events.set_class.add(&xwindow.set_class);
    xsurface.events.set_parent.add(&xwindow.set_parent);
    xsurface.events.set_decorations.add(&xwindow.set_decorations);
    xsurface.events.set_hints.add(&xwindow.set_hints);
    xsurface.events.request_maximize.add(&xwindow.request_maximize);
    xsurface.events.request_fullscreen.add(&xwindow.request_fullscreen);
    xsurface.events.request_minimize.add(&xwindow.request_minimize);
    xsurface.events.focus_in.add(&xwindow.focus_in);
    xsurface.events.grab_focus.add(&xwindow.grab_focus);

    if (xsurface.surface) |surface| {
        handleAssociate(&xwindow.associate);
        if (surface.mapped) {
            handleMap(&xwindow.map);
        }
    }
}

/// Always returns false as we do not care about frame perfection for Xwayland windows.
pub fn configure(xwindow: *XwaylandWindow) bool {
    const window = xwindow.window;
    const scheduled = &window.configure_scheduled;
    const sent = &window.configure_sent;

    const projected_output = xwindow.projection();
    const current_logical_size = xwindow.logicalSize(
        xwindow.xsurface.width,
        xwindow.xsurface.height,
    );
    // Sending a 0 width/height to X11 clients is invalid, so fake it with the
    // current size expressed in compositor-logical coordinates.
    if (scheduled.width == 0) scheduled.width = current_logical_size[0];
    if (scheduled.height == 0) scheduled.height = current_logical_size[1];
    const width = scheduled.width orelse current_logical_size[0];
    const height = scheduled.height orelse current_logical_size[1];

    const x: i16, const y: i16, const configured_width: u16, const configured_height: u16 =
        if (projected_output) |value| blk: {
            const projected_x, const projected_y = value.logicalToX11Point(window.box.x, window.box.y);
            const projected_width, const projected_height = value.logicalToX11Size(width, height);
            xwindow.projection_scale = value.scale;
            if (xwindow.surface_tree) |tree| setSurfaceTreeScale(tree, value.scale);
            setSurfaceTreeScale(&window.capture_scene.tree, value.scale);
            break :blk .{
                math.lossyCast(i16, projected_x),
                math.lossyCast(i16, projected_y),
                projected_width,
                projected_height,
            };
        } else .{
            math.lossyCast(i16, window.box.x),
            math.lossyCast(i16, window.box.y),
            math.lossyCast(u16, width),
            math.lossyCast(u16, height),
        };

    // Unlike native Wayland windows, we need to tell X11 windows about their
    // position. However, river does not necessarily know the new position
    // until after a rendering sequence is completed. Therefore, configure()
    // is called both on manageFinish() and renderFinish() for Xwayland windows.
    // Frame perfection is not achievable for Xwayland windows in any case.
    if (x != xwindow.xsurface.x or
        y != xwindow.xsurface.y or
        configured_width != xwindow.xsurface.width or
        configured_height != xwindow.xsurface.height)
    {
        xwindow.xsurface.configure(x, y, configured_width, configured_height);
    }

    if (scheduled.activated != sent.activated) {
        xwindow.setActivated(scheduled.activated);
    }
    if (scheduled.maximized != sent.maximized) {
        xwindow.xsurface.setMaximized(scheduled.maximized, scheduled.maximized);
    }
    if (scheduled.inform_fullscreen != sent.inform_fullscreen) {
        xwindow.xsurface.setFullscreen(scheduled.inform_fullscreen);
    }
    window.configure_sent = window.configure_scheduled;
    window.configure_sent.width = width;
    window.configure_sent.height = height;
    window.configure_scheduled.width = null;
    window.configure_scheduled.height = null;

    return false;
}

pub fn projection(xwindow: *const XwaylandWindow) ?xwayland_projection.Projection {
    if (server.xwayland_scaling != .native) return null;
    const width: i32 = @intCast(xwindow.window.configure_scheduled.width orelse
        xwindow.window.configure_sent.width orelse 1);
    const height: i32 = @intCast(xwindow.window.configure_scheduled.height orelse
        xwindow.window.configure_sent.height orelse 1);
    return server.om.xwaylandProjectionForLogicalBox(.{
        .x = xwindow.window.box.x,
        .y = xwindow.window.box.y,
        .width = width,
        .height = height,
    });
}

pub fn logicalSize(xwindow: *const XwaylandWindow, width: u16, height: u16) struct { u31, u31 } {
    return if (xwindow.projection()) |projected|
        projected.x11ToLogicalSize(width, height)
    else
        .{ @as(u31, width), @as(u31, height) };
}

fn setSurfaceTreeScale(tree: *wlr.SceneTree, scale: f64) void {
    var mutable_scale = scale;
    tree.node.forEachBuffer(*f64, setSurfaceScaleIterator, &mutable_scale);
}

fn setSurfaceScaleIterator(
    buffer: *wlr.SceneBuffer,
    _: c_int,
    _: c_int,
    scale: *f64,
) void {
    const scene_surface = wlr.SceneSurface.tryFromBuffer(buffer) orelse return;
    wlr_scene_surface_set_destination_scale(scene_surface, scale.*);
}

fn setActivated(xwindow: XwaylandWindow, activated: bool) void {
    // See comment on handleRequestMinimize() for details
    if (activated and xwindow.xsurface.minimized) {
        xwindow.xsurface.setMinimized(false);
    }
    xwindow.xsurface.activate(activated);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("destroy", listener);

    // Remove listeners that are active for the entire lifetime of the window
    xwindow.destroy.link.remove();
    xwindow.associate.link.remove();
    xwindow.dissociate.link.remove();
    xwindow.request_configure.link.remove();
    xwindow.request_move.link.remove();
    xwindow.request_resize.link.remove();
    xwindow.set_override_redirect.link.remove();
    xwindow.set_size_hints.link.remove();
    xwindow.set_title.link.remove();
    xwindow.set_class.link.remove();
    xwindow.set_parent.link.remove();
    xwindow.set_decorations.link.remove();
    xwindow.set_hints.link.remove();
    xwindow.request_maximize.link.remove();
    xwindow.request_fullscreen.link.remove();
    xwindow.request_minimize.link.remove();
    xwindow.focus_in.link.remove();
    xwindow.grab_focus.link.remove();

    xwindow.xsurface.data = null;

    const window = xwindow.window;
    switch (window.state) {
        .init, .closing => {},
        // As with XDG, an X11 window may be destroyed after policy assigned a
        // workspace but before it mapped, in which case no unmap event exists
        // to release the intrusive workspace link.
        .ready, .initialized => {
            window.clearWorkspace();
            window.state = .closing;
            server.wm.dirtyWindowing();
        },
        // A mapped Xwayland surface must emit unmap before destroy.
        .mapped => unreachable,
    }
    window.impl = .destroying;
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("associate", listener);

    xwindow.xsurface.surface.?.events.map.add(&xwindow.map);
    xwindow.xsurface.surface.?.events.unmap.add(&xwindow.unmap);
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("dissociate", listener);
    xwindow.map.link.remove();
    xwindow.unmap.link.remove();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("commit", listener);
    const window = xwindow.window;
    if (window.state == .mapped) {
        const surface = xwindow.xsurface.surface.?;
        if (surface.current.width > 0 and surface.current.height > 0) {
            const width, const height = xwindow.logicalSize(
                math.lossyCast(u16, surface.current.width),
                math.lossyCast(u16, surface.current.height),
            );
            window.setDimensions(width, height);
        }
        window.applySurfaceVisualState();
    }
}

pub fn handleMap(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("map", listener);
    const window = xwindow.window;
    const surface = xwindow.xsurface.surface.?;

    xwindow.surface_tree = window.surfaces.tree.createSceneSubsurfaceTree(surface) catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
        return;
    };
    if (xwindow.projection()) |projected| {
        xwindow.projection_scale = projected.scale;
        setSurfaceTreeScale(xwindow.surface_tree.?, projected.scale);
    }
    surface.data = &window.tree.node;

    const capture_surface = window.capture_scene.tree.createSceneSurface(surface) catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
        return;
    };
    if (xwindow.projection()) |projected| {
        wlr_scene_surface_set_destination_scale(capture_surface, projected.scale);
    }

    // Register after the scene tree so our commit listener runs after wlroots
    // has created/replaced scene buffers. Otherwise the scene helper can reset
    // opacity immediately after Aqueous applies it.
    surface.events.commit.add(&xwindow.commit);

    if (xwindow.xsurface.fullscreen) {
        window.wm_scheduled.fullscreen_requested = .{ .fullscreen = null };
    }

    xwindow.updateFocusHint();

    window.state = .initialized;
    server.aqueous.noteWindowAdmission(@bitCast(window.ref));
    window.map() catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
    };
    if (xwindow.focused_before_map) {
        xwindow.focused_before_map = false;
        server.input_manager.defaultSeat().focusFromClient(.{ .window = window });
    }
    if (xwindow.grab_focused_before_map) {
        xwindow.grab_focused_before_map = false;
        server.input_manager.defaultSeat().focusXwaylandGrabSurface(surface);
    }
    server.wm.dirtyWindowing();
}

/// Xwayland permits an X11 client to move focus between windows owned by the
/// same process, then emits focus_in so the compositor can synchronize its
/// wl_seat. Ignoring it leaves X11 and Wayland focus disagreeing, which breaks
/// focus/grab behavior in games and globally-active clients.
fn handleFocusIn(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("focus_in", listener);
    const surface = xwindow.xsurface.surface orelse {
        xwindow.focused_before_map = true;
        return;
    };
    if (!surface.mapped or xwindow.window.state == .init) {
        xwindow.focused_before_map = true;
        return;
    }

    const seat = server.input_manager.defaultSeat();
    if (seat.focused.surface() != surface) {
        seat.focusFromClient(.{ .window = xwindow.window });
        server.wm.dirtyWindowing();
    }
}

/// wlroots reports FocusIn(mode=Grab) separately from ordinary focus changes.
/// It is temporary input routing, not a durable WM selection change.
fn handleGrabFocus(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("grab_focus", listener);
    const surface = xwindow.xsurface.surface orelse {
        xwindow.grab_focused_before_map = true;
        return;
    };
    if (!surface.mapped or xwindow.window.state == .init) {
        xwindow.grab_focused_before_map = true;
        return;
    }

    log.debug(
        "Xwayland grab-focus window=0x{x} pid={d} title='{?s}' surface=0x{x}",
        .{
            xwindow.xsurface.window_id,
            xwindow.xsurface.pid,
            xwindow.xsurface.title,
            @intFromPtr(surface),
        },
    );
    server.input_manager.defaultSeat().focusXwaylandGrabSurface(surface);
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("unmap", listener);

    server.input_manager.xwayland_keyboard_grabs.releaseSurface(xwindow.xsurface.surface.?);
    xwindow.commit.link.remove();

    xwindow.xsurface.surface.?.data = null;

    xwindow.window.unmap();

    // Don't destroy the surface tree until after Window.unmap() has a chance
    // to save buffers for frame perfection.
    xwindow.surface_tree.?.node.destroy();
    xwindow.surface_tree = null;
}

fn handleRequestConfigure(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_configure", listener);

    // If unmapped, let the client do whatever it wants
    if (xwindow.xsurface.surface == null or !xwindow.xsurface.surface.?.mapped) {
        xwindow.xsurface.configure(event.x, event.y, event.width, event.height);
        return;
    }

    if (xwindow.projection()) |projected| {
        const projected_x, const projected_y = projected.logicalToX11Point(
            xwindow.window.box.x,
            xwindow.window.box.y,
        );
        xwindow.xsurface.configure(
            math.lossyCast(i16, projected_x),
            math.lossyCast(i16, projected_y),
            event.width,
            event.height,
        );
        const logical_width, const logical_height = projected.x11ToLogicalSize(event.width, event.height);
        xwindow.window.setDimensions(logical_width, logical_height);
        return;
    }

    xwindow.xsurface.configure(
        math.lossyCast(i16, xwindow.window.box.x),
        math.lossyCast(i16, xwindow.window.box.y),
        event.width,
        event.height,
    );
    xwindow.window.setDimensions(event.width, event.height);
}

/// _NET_WM_MOVERESIZE has no Wayland seat or serial. XWayland has one core
/// pointer, so use the default seat after verifying that its active press is
/// focused on this managed top-level.
fn clientPointerSeat(xwindow: *XwaylandWindow) ?*Seat {
    const surface = xwindow.xsurface.surface orelse return null;
    if (!surface.mapped or xwindow.window.state != .mapped) return null;
    const seat = server.input_manager.defaultSeat();
    if (!seat.cursor.canStartXwaylandPointerOperation(surface)) return null;
    return seat;
}

fn handleRequestMove(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_move", listener);
    const seat = xwindow.clientPointerSeat() orelse return;
    xwindow.window.wm_scheduled.pointer_move_requested = seat;
    server.wm.dirtyWindowing();
}

fn handleRequestResize(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Resize),
    event: *wlr.XwaylandSurface.event.Resize,
) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_resize", listener);
    const edges: wlr.Edges = @bitCast(event.edges);
    if (!edges.top and !edges.bottom and !edges.left and !edges.right) return;
    const seat = xwindow.clientPointerSeat() orelse return;
    xwindow.window.wm_scheduled.pointer_resize_requested = .{
        .seat = seat,
        .edges = @bitCast(event.edges),
    };
    server.wm.dirtyWindowing();
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_override_redirect", listener);
    const xsurface = xwindow.xsurface;

    log.debug("xwayland surface set override redirect", .{});

    assert(xsurface.override_redirect);

    if (xsurface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&xwindow.unmap);
        }
        handleDissociate(&xwindow.dissociate);
    }
    handleDestroy(&xwindow.destroy);

    XwaylandOverrideRedirect.create(xsurface) catch {
        log.err("out of memory", .{});
        return;
    };
}

fn handleSetSizeHints(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_size_hints", listener);
    if (xwindow.xsurface.size_hints) |size_hints| {
        const scale = if (server.xwayland_scaling == .native) xwindow.projection_scale else 1;
        const min_width: u31 = @intFromFloat(@max(0, @round(@as(f64, @floatFromInt(size_hints.min_width)) / scale)));
        const min_height: u31 = @intFromFloat(@max(0, @round(@as(f64, @floatFromInt(size_hints.min_height)) / scale)));
        // Don't trust X11 clients not to set a min_width greater than their max_width.
        const max_width: u31 =
            if (size_hints.max_width <= 0) 0 else @max(min_width, @as(u31, @intFromFloat(@round(@as(f64, @floatFromInt(size_hints.max_width)) / scale))));
        const max_height: u31 =
            if (size_hints.max_height <= 0) 0 else @max(min_height, @as(u31, @intFromFloat(@round(@as(f64, @floatFromInt(size_hints.max_height)) / scale))));
        xwindow.window.setDimensionsHint(.{
            .min_width = min_width,
            .max_width = max_width,
            .min_height = min_height,
            .max_height = max_height,
        });
    }
}

fn handleSetTitle(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_title", listener);
    xwindow.window.notifyTitle();
}

fn handleSetClass(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_class", listener);
    xwindow.window.notifyAppId();
}

fn handleSetParent(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_parent", listener);
    if (xwindow.xsurface.parent == null) xwindow.window.policy_state.auto_float_parent = 0;
    server.wm.dirtyWindowing();
}

/// Recompute whether this X11 window accepts keyboard focus from its ICCCM input model
/// (WM_HINTS `input` flag + WM_TAKE_FOCUS). An input model of `none` (notification toasts,
/// docks, some splash windows) means the window does not want focus; forward that to the wm
/// via river_window_v1.focus_hint so it can avoid focus-stealing popups.
fn updateFocusHint(xwindow: *XwaylandWindow) void {
    xwindow.window.setAcceptsFocus(xwindow.xsurface.icccmInputModel() != .none);
}

fn handleSetHints(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_hints", listener);
    xwindow.updateFocusHint();
}

fn handleSetDecorations(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_decorations", listener);

    if (xwindow.xsurface.decorations.no_border or xwindow.xsurface.decorations.no_title) {
        xwindow.window.setDecorationHint(.prefers_csd);
    } else {
        xwindow.window.setDecorationHint(.prefers_ssd);
    }
}

fn handleRequestMaximize(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_maximize", listener);
    if (xwindow.xsurface.maximized_vert or xwindow.xsurface.maximized_horz) {
        xwindow.window.wm_scheduled.maximize_requested = .maximize;
    } else {
        xwindow.window.wm_scheduled.maximize_requested = .unmaximize;
    }
    server.wm.dirtyWindowing();
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_fullscreen", listener);
    if (xwindow.xsurface.fullscreen) {
        xwindow.window.wm_scheduled.fullscreen_requested = .{ .fullscreen = null };
    } else {
        xwindow.window.wm_scheduled.fullscreen_requested = .exit;
    }
    server.wm.dirtyWindowing();
}

/// Some X11 clients enter their iconic state before compositor policy
/// responds. Validate synchronously so rejected requests can be reverted before
/// the client gets stuck minimized outside the integrated state machine.
fn handleRequestMinimize(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Minimize),
    event: *wlr.XwaylandSurface.event.Minimize,
) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_minimize", listener);
    const handle: @import("wm/layout/types.zig").Handle = @bitCast(xwindow.window.ref);
    if (!server.aqueous.clientMinimizeAllowed(handle, event.minimize)) {
        // X11 clients may update their iconic state before policy responds.
        // Explicitly reject it so a tiled window cannot disappear outside the
        // integrated layout's state machine.
        xwindow.xsurface.setMinimized(false);
        return;
    }
    xwindow.xsurface.setMinimized(event.minimize);
    xwindow.window.wm_scheduled.minimize_requested = if (event.minimize) .minimize else .unminimize;
    server.wm.dirtyWindowing();
}
