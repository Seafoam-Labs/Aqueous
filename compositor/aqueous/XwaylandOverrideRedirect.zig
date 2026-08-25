// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const XwaylandOverrideRedirect = @This();

const std = @import("std");
const assert = std.debug.assert;

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const fx = @import("fx.zig");
const util = @import("util.zig");
const visual_state = @import("visual_state.zig");

const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.xwayland);
const xwayland_projection = @import("xwayland_projection.zig");

extern fn wlr_scene_surface_set_destination_scale(
    scene_surface: *wlr.SceneSurface,
    scale: f64,
) void;

xsurface: *wlr.XwaylandSurface,
surface_tree: ?*wlr.SceneTree = null,
owner: ?Window.Ref = null,

// Active over entire lifetime
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(handleRequestConfigure),
destroy: wl.Listener(void) = .init(handleDestroy),
set_override_redirect: wl.Listener(void) = .init(handleSetOverrideRedirect),
associate: wl.Listener(void) = .init(handleAssociate),
dissociate: wl.Listener(void) = .init(handleDissociate),
set_hints: wl.Listener(void) = .init(handleSetHints),
set_window_type: wl.Listener(void) = .init(handleSetWindowType),
set_role: wl.Listener(void) = .init(handleSetRole),
focus_in: wl.Listener(void) = .init(handleFocusIn),
grab_focus: wl.Listener(void) = .init(handleGrabFocus),
grab_focused_before_map: bool = false,

// Active while the xsurface is associated with a wlr_surface
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),

// Active while mapped
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
set_geometry: wl.Listener(void) = .init(handleSetGeometry),

pub fn create(xsurface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
    log.debug("new xwayland override redirect: title='{?s}', class='{?s}'", .{
        xsurface.title,
        xsurface.class,
    });

    const override_redirect = try util.gpa.create(XwaylandOverrideRedirect);
    errdefer util.gpa.destroy(override_redirect);

    override_redirect.* = .{ .xsurface = xsurface };

    xsurface.events.request_configure.add(&override_redirect.request_configure);
    xsurface.events.destroy.add(&override_redirect.destroy);
    xsurface.events.set_override_redirect.add(&override_redirect.set_override_redirect);

    xsurface.events.associate.add(&override_redirect.associate);
    xsurface.events.dissociate.add(&override_redirect.dissociate);
    xsurface.events.set_role.add(&override_redirect.set_role);
    xsurface.events.set_window_type.add(&override_redirect.set_window_type);
    xsurface.events.set_hints.add(&override_redirect.set_hints);
    xsurface.events.focus_in.add(&override_redirect.focus_in);
    xsurface.events.grab_focus.add(&override_redirect.grab_focus);

    if (xsurface.surface) |surface| {
        handleAssociate(&override_redirect.associate);
        if (surface.mapped) {
            handleMap(&override_redirect.map);
        }
    }
}

fn handleRequestConfigure(
    _: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    event.surface.configure(event.x, event.y, event.width, event.height);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("destroy", listener);

    override_redirect.request_configure.link.remove();
    override_redirect.destroy.link.remove();
    override_redirect.associate.link.remove();
    override_redirect.dissociate.link.remove();
    override_redirect.set_override_redirect.link.remove();
    override_redirect.set_window_type.link.remove();
    override_redirect.set_hints.link.remove();
    override_redirect.set_role.link.remove();
    override_redirect.focus_in.link.remove();
    override_redirect.grab_focus.link.remove();

    util.gpa.destroy(override_redirect);
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("associate", listener);

    override_redirect.xsurface.surface.?.events.map.add(&override_redirect.map);
    override_redirect.xsurface.surface.?.events.unmap.add(&override_redirect.unmap);
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("dissociate", listener);

    override_redirect.map.link.remove();
    override_redirect.unmap.link.remove();
}

pub fn handleMap(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("map", listener);

    override_redirect.mapImpl() catch {
        log.err("out of memory", .{});
        override_redirect.xsurface.surface.?.resource.getClient().postNoMemory();
    };
}

fn mapImpl(override_redirect: *XwaylandOverrideRedirect) error{OutOfMemory}!void {
    const surface = override_redirect.xsurface.surface.?;
    override_redirect.surface_tree =
        try server.scene.layers.override_redirect.createSceneSubsurfaceTree(surface);
    try SceneNodeData.attach(&override_redirect.surface_tree.?.node, .{
        .override_redirect = override_redirect,
    });

    surface.data = &override_redirect.surface_tree.?.node;

    override_redirect.applyProjection();

    override_redirect.xsurface.events.set_geometry.add(&override_redirect.set_geometry);
    // As with managed XWayland windows, run after the scene helper's commit
    // listener so newly replaced buffers receive the final effective opacity.
    surface.events.commit.add(&override_redirect.commit);

    if (override_redirect.resolveOwner()) |owner| override_redirect.owner = owner.ref;
    override_redirect.applyOpacity();

    override_redirect.focusIfDesired();
    if (override_redirect.grab_focused_before_map) {
        override_redirect.grab_focused_before_map = false;
        if (!override_redirect.shouldPreserveOwnerFocus()) {
            server.input_manager.defaultSeat().focusXwaylandGrabSurface(surface);
        }
    }
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("commit", listener);
    override_redirect.applyProjection();
    override_redirect.applyOpacity();
}

fn applyOpacity(override_redirect: *XwaylandOverrideRedirect) void {
    const tree = override_redirect.surface_tree orelse return;
    const opacity = if (override_redirect.owner) |owner|
        if (owner.get()) |window| window.effectiveOpacity() else override_redirect.defaultOpacity()
    else if (override_redirect.resolveOwner()) |window| blk: {
        override_redirect.owner = window.ref;
        break :blk window.effectiveOpacity();
    } else override_redirect.defaultOpacity();
    fx.setTreeOpacity(tree, opacity);
}

fn defaultOpacity(_: *const XwaylandOverrideRedirect) f32 {
    return visual_state.fractionToOpacity(server.wm.default_opacity);
}

/// Prefer the explicit X11 transient-parent chain. Some legacy toolkits omit it,
/// so fall back to the currently focused top-level from the same process, then to
/// an unambiguous same-PID top-level.
fn resolveOwner(override_redirect: *XwaylandOverrideRedirect) ?*Window {
    var parent = override_redirect.xsurface.parent;
    while (parent) |xsurface| : (parent = xsurface.parent) {
        if (xsurface.override_redirect) continue;
        const data = xsurface.data orelse continue;
        const xwindow: *XwaylandWindow = @ptrCast(@alignCast(data));
        return xwindow.window;
    }

    const seat = server.input_manager.defaultSeat();
    if (seat.focused == .window and seat.focused.window.impl == .xwayland and
        seat.focused.window.impl.xwayland.xsurface.pid == override_redirect.xsurface.pid)
    {
        return seat.focused.window;
    }

    var candidate: ?*Window = null;
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        if (window.impl != .xwayland or
            window.impl.xwayland.xsurface.pid != override_redirect.xsurface.pid)
        {
            continue;
        }
        if (candidate != null) return null;
        candidate = window;
    }
    return candidate;
}

fn refocusIfMapped(override_redirect: *XwaylandOverrideRedirect) void {
    const surface = override_redirect.xsurface.surface orelse return;
    if (!surface.mapped) return;
    if (override_redirect.surface_tree == null) return;
    override_redirect.focusIfDesired();
}

/// Keep Wayland keyboard focus on an already-focused same-process Xwayland
/// owner for ordinary override-redirect popups. A pointer constraint identifies
/// the exceptional game/overlay surface which genuinely needs direct focus.
fn shouldPreserveOwnerFocus(override_redirect: *XwaylandOverrideRedirect) bool {
    const surface = override_redirect.xsurface.surface orelse return false;
    const seat = server.input_manager.defaultSeat();
    if (seat.focused != .window or
        seat.focused.window.impl != .xwayland or
        seat.focused.window.impl.xwayland.xsurface.pid != override_redirect.xsurface.pid)
    {
        return false;
    }

    return server.input_manager.pointer_constraints.constraintForSurface(
        surface,
        seat.wlr_seat,
    ) == null;
}

pub fn focusIfDesired(override_redirect: *XwaylandOverrideRedirect) void {
    if (server.lock_manager.state != .unlocked) return;

    // Most override-redirect surfaces are transient menus or tooltips. Moving
    // X11 keyboard focus to those surfaces sends FocusOut to their owner and
    // causes clients such as Steam to immediately dismiss the menu. Only move
    // keyboard focus when the X11 role/hints explicitly request it.
    if (override_redirect.xsurface.overrideRedirectWantsFocus() and
        override_redirect.xsurface.icccmInputModel() != .none)
    {
        // Override-redirect menus use an X11 grab to receive their keyboard and
        // pointer input. If their top-level owner is already focused, keep the
        // Wayland keyboard focus there: entering the popup sends FocusOut to the
        // owner and clients such as Steam immediately close the menu. This must
        // also cover popups whose type/role hints are incomplete at map time and
        // therefore temporarily pass overrideRedirectWantsFocus().
        if (override_redirect.shouldPreserveOwnerFocus()) return;
        server.input_manager.defaultSeat().focusFromClient(.{
            .override_redirect = override_redirect,
        });
    }
}

/// Preserve the owner focus used by ordinary X11 menus. A pointer constraint
/// is the unambiguous signal that an override-redirect game surface needs
/// direct focus for cursor trapping.
pub fn focusForInteraction(override_redirect: *XwaylandOverrideRedirect) void {
    if (server.lock_manager.state != .unlocked) return;
    if (!override_redirect.xsurface.overrideRedirectWantsFocus() or
        override_redirect.xsurface.icccmInputModel() == .none or
        override_redirect.xsurface.surface == null)
    {
        return;
    }

    if (override_redirect.shouldPreserveOwnerFocus()) return;
    server.input_manager.defaultSeat().focusFromClient(.{
        .override_redirect = override_redirect,
    });
}

fn handleFocusIn(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("focus_in", listener);
    const surface = override_redirect.xsurface.surface orelse return;
    if (!surface.mapped or override_redirect.surface_tree == null) return;
    if (override_redirect.shouldPreserveOwnerFocus()) return;

    const seat = server.input_manager.defaultSeat();
    if (seat.focused.surface() != surface) {
        seat.focusFromClient(.{ .override_redirect = override_redirect });
        server.wm.dirtyWindowing();
    }
}

fn handleGrabFocus(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("grab_focus", listener);
    const surface = override_redirect.xsurface.surface orelse {
        override_redirect.grab_focused_before_map = true;
        return;
    };
    if (!surface.mapped or override_redirect.surface_tree == null) {
        override_redirect.grab_focused_before_map = true;
        return;
    }
    if (override_redirect.shouldPreserveOwnerFocus()) return;

    log.debug(
        "Xwayland grab-focus override-redirect=0x{x} pid={d} title='{?s}' surface=0x{x}",
        .{
            override_redirect.xsurface.window_id,
            override_redirect.xsurface.pid,
            override_redirect.xsurface.title,
            @intFromPtr(surface),
        },
    );
    server.input_manager.defaultSeat().focusXwaylandGrabSurface(surface);
}

fn handleSetHints(listener: *wl.Listener(void)) void {
    const override: *XwaylandOverrideRedirect = @fieldParentPtr("set_hints", listener);
    override.refocusIfMapped();
}

fn handleSetWindowType(listener: *wl.Listener(void)) void {
    const override: *XwaylandOverrideRedirect = @fieldParentPtr("set_window_type", listener);
    override.refocusIfMapped();
}

fn handleSetRole(listener: *wl.Listener(void)) void {
    const override: *XwaylandOverrideRedirect = @fieldParentPtr("set_role", listener);
    override.refocusIfMapped();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("unmap", listener);

    server.input_manager.xwayland_keyboard_grabs.releaseSurface(override_redirect.xsurface.surface.?);
    override_redirect.commit.link.remove();
    override_redirect.set_geometry.link.remove();

    override_redirect.xsurface.surface.?.data = null;
    override_redirect.surface_tree.?.node.destroy();
    override_redirect.surface_tree = null;

    // If the unmapped surface owns X11 keyboard focus, restore its owner when
    // possible. A focused override-redirect without an owner must explicitly
    // clear focus so the seat never retains a destroyed surface.
    var seat_it = server.input_manager.seats.iterator(.forward);
    while (seat_it.next()) |seat| {
        if (seat.wlr_seat.keyboard_state.focused_surface != override_redirect.xsurface.surface) continue;

        switch (seat.focused) {
            .window => |window| {
                if (window.impl == .xwayland and
                    window.impl.xwayland.xsurface.pid == override_redirect.xsurface.pid)
                {
                    seat.keyboardEnterOrLeave(window.rootSurface());
                } else {
                    seat.keyboardEnterOrLeave(null);
                }
            },
            .override_redirect => |focused_override| {
                if (focused_override == override_redirect) {
                    if (override_redirect.owner) |owner| {
                        if (owner.get()) |window| {
                            seat.focus(.{ .window = window });
                            continue;
                        }
                    }
                    seat.focus(.none);
                }
            },
            else => seat.keyboardEnterOrLeave(null),
        }
    }
    override_redirect.owner = null;

    server.wm.dirtyWindowing();
}

fn handleSetGeometry(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_geometry", listener);
    override_redirect.applyProjection();
}

fn projection(override_redirect: *XwaylandOverrideRedirect) ?xwayland_projection.Projection {
    if (server.xwayland_scaling != .native) return null;
    if (override_redirect.owner) |owner_ref| {
        if (owner_ref.get()) |owner| {
            if (owner.impl == .xwayland) return owner.impl.xwayland.projection();
        }
    }
    if (override_redirect.resolveOwner()) |owner| {
        override_redirect.owner = owner.ref;
        if (owner.impl == .xwayland) return owner.impl.xwayland.projection();
    }
    return server.om.xwaylandProjectionForX11Point(
        override_redirect.xsurface.x,
        override_redirect.xsurface.y,
    );
}

fn applyProjection(override_redirect: *XwaylandOverrideRedirect) void {
    const tree = override_redirect.surface_tree orelse return;
    if (override_redirect.projection()) |projected| {
        const logical_x, const logical_y = projected.x11ToLogicalPoint(
            override_redirect.xsurface.x,
            override_redirect.xsurface.y,
        );
        tree.node.setPosition(
            @intFromFloat(@round(logical_x)),
            @intFromFloat(@round(logical_y)),
        );
        var scale = projected.scale;
        tree.node.forEachBuffer(*f64, setSurfaceScaleIterator, &scale);
    } else {
        tree.node.setPosition(override_redirect.xsurface.x, override_redirect.xsurface.y);
    }
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

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_override_redirect", listener);
    const xsurface = override_redirect.xsurface;

    log.debug("xwayland surface unset override redirect", .{});

    assert(!xsurface.override_redirect);

    if (xsurface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&override_redirect.unmap);
        }
        handleDissociate(&override_redirect.dissociate);
    }
    handleDestroy(&override_redirect.destroy);

    XwaylandWindow.create(xsurface) catch {
        log.err("out of memory", .{});
        return;
    };
}
