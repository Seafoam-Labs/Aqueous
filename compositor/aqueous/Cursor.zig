// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Cursor = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const scene_surface_projection = @import("scene_surface_projection.zig");
const cursor_lock_restore = @import("cursor_lock_restore.zig");
const cursor_config = @import("cursor_config.zig");

const DragIcon = @import("DragIcon.zig");
const InputDevice = @import("InputDevice.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const PointerBinding = @import("PointerBinding.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const Scene = @import("Scene.zig");
const Seat = @import("Seat.zig");
const Tablet = @import("Tablet.zig");
const TabletTool = @import("TabletTool.zig");
const Window = @import("Window.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.input);

const Mode = union(enum) {
    passthrough,
    /// This mode is entered when a binding is triggered and exited when there
    /// are no longer any buttons pressed.
    ignore,
    /// A drag and drop is in progress.
    drag,
    down: struct {

        // Initial cursor position in layout coordinates
        lx: f64,
        ly: f64,
        // Initial cursor position in surface-local coordinates
        sx: f64,
        sy: f64,
        surface_scale: f64,
    },
    op: struct {
        /// Window coordinates are stored as i32s as they are in logical pixels.
        /// However, it is possible to move the cursor by a fraction of a
        /// logical pixel and this happens in practice with low dpi, high
        /// polling rate mice. Therefore we must accumulate the current
        /// fractional offset of the mouse to avoid rounding down tiny
        /// motions to 0.
        delta_x: f64 = 0,
        delta_y: f64 = 0,
    },
};

const Image = union(enum) {
    /// No cursor image
    none,
    /// Name of the current Xcursor shape
    xcursor: [*:0]const u8,
    /// Cursor surface configured by the client
    client: struct {
        surface: *wlr.Surface,
        hotspot_x: i32,
        hotspot_y: i32,
    },
};

const LayoutPoint = struct {
    lx: f64,
    ly: f64,
};

pub const PointerLockRestore = struct {
    node: *wlr.SceneNode,
    sx: f64,
    sy: f64,
};

pub const SurfacePoint = cursor_lock_restore.SurfacePoint;

/// Current cursor mode as well as any state needed to implement that mode
mode: Mode = .passthrough,

seat: *Seat,
wlr_cursor: *wlr.Cursor,

/// Xcursor manager for the currently configured Xcursor theme.
xcursor_manager: *wlr.XcursorManager,
/// The currently rendered cursor image
image: Image = .none,
image_surface_destroy: wl.Listener(*wlr.Surface) = .init(handleImageSurfaceDestroy),
/// The most recent cursor image set by the window manager client
wm_image: Image = .{ .xcursor = "default" },
wm_image_surface_destroy: wl.Listener(*wlr.Surface) = .init(handleWmImageSurfaceDestroy),

/// The set of currently pressed pointer buttons and the corresponding pointer mapping if any.
pressed: std.AutoHashMapUnmanaged(u32, ?*PointerBinding) = .{},

/// The first client press waits for the interaction's normal focus decision.
/// Later input stays in Seat.event_queue until that manage cycle completes.
pending_button: ?struct {
    event: Seat.Event.PointerButton,
    surface: *wlr.Surface,
} = null,
pending_button_unmap: wl.Listener(void) = .init(handlePendingButtonUnmap),
pending_button_destroy: wl.Listener(*wlr.Surface) = .init(handlePendingButtonDestroy),

/// The pointer constraint for the surface that currently has pointer focus, if
/// any. This constraint is not necessarily active; activation only occurs once
/// the cursor is inside the constraint region.
constraint: ?*PointerConstraint = null,
constraints_suppressed: bool = false,
pointer_lock_restore: ?PointerLockRestore = null,
pointer_mode_generation: u64 = 0,
stale_motion_suppression_until: u32 = 0,

/// Layout coordinates of the last pointer motion we actually forwarded to a
/// client. Used to suppress spurious motion events that would otherwise be
/// re-emitted on every transaction (e.g. when a window's surface origin shifts
/// under a perfectly stationary cursor), which games misread as mouse-look.
/// These are plain floats, so they are always safe to compare; focus changes are
/// detected via the seat's own (lifecycle-managed) `focused_surface` instead of a
/// cached surface pointer to avoid use-after-free on surface destroy.
last_sent_lx: f64 = -1,
last_sent_ly: f64 = -1,
last_sent_sx: f64 = 0,
last_sent_sy: f64 = 0,

/// Keeps track of the last known location of all touch points in layout coordinates.
/// This information is necessary for proper touch dnd support if there are multiple touch points.
touch_points: std.AutoHashMapUnmanaged(i32, LayoutPoint) = .{},

request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(handleRequestSetCursor),

motion_relative: wl.Listener(*wlr.Pointer.event.Motion) = .init(queueMotionRelative),
motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(queueMotionAbsolute),
button: wl.Listener(*wlr.Pointer.event.Button) = .init(queueButton),
axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(queueAxis),
frame: wl.Listener(*wlr.Cursor) = .init(queueFrame),

swipe_begin: wl.Listener(*wlr.Pointer.event.SwipeBegin) = .init(queueSwipeBegin),
swipe_update: wl.Listener(*wlr.Pointer.event.SwipeUpdate) = .init(queueSwipeUpdate),
swipe_end: wl.Listener(*wlr.Pointer.event.SwipeEnd) = .init(queueSwipeEnd),

pinch_begin: wl.Listener(*wlr.Pointer.event.PinchBegin) = .init(queuePinchBegin),
pinch_update: wl.Listener(*wlr.Pointer.event.PinchUpdate) = .init(queuePinchUpdate),
pinch_end: wl.Listener(*wlr.Pointer.event.PinchEnd) = .init(queuePinchEnd),

hold_begin: wl.Listener(*wlr.Pointer.event.HoldBegin) = .init(queueHoldBegin),
hold_end: wl.Listener(*wlr.Pointer.event.HoldEnd) = .init(queueHoldEnd),

touch_down: wl.Listener(*wlr.Touch.event.Down) = .init(handleTouchDown),
touch_motion: wl.Listener(*wlr.Touch.event.Motion) = .init(handleTouchMotion),
touch_up: wl.Listener(*wlr.Touch.event.Up) = .init(handleTouchUp),
touch_cancel: wl.Listener(*wlr.Touch.event.Cancel) = .init(handleTouchCancel),
touch_frame: wl.Listener(void) = .init(handleTouchFrame),

tablet_tool_axis: wl.Listener(*wlr.Tablet.event.Axis) = .init(handleTabletToolAxis),
tablet_tool_proximity: wl.Listener(*wlr.Tablet.event.Proximity) = .init(handleTabletToolProximity),
tablet_tool_tip: wl.Listener(*wlr.Tablet.event.Tip) = .init(handleTabletToolTip),
tablet_tool_button: wl.Listener(*wlr.Tablet.event.Button) = .init(handleTabletToolButton),

pub fn init(cursor: *Cursor, seat: *Seat) !void {
    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();
    wlr_cursor.attachOutputLayout(server.om.output_layout);

    // This is here so that cursor.xcursor_manager doesn't need to be an
    // optional pointer. This isn't optimal as it does a needless allocation,
    // but this is not a hot path.
    const xcursor_manager = try wlr.XcursorManager.create(null, cursor_config.default_size);
    errdefer xcursor_manager.destroy();

    cursor.* = .{
        .seat = seat,
        .wlr_cursor = wlr_cursor,
        .xcursor_manager = xcursor_manager,
    };
    const configured = &server.input_manager.cursor_config;
    cursor.setTheme(configured.themeZ().ptr, configured.size) catch |err| {
        const fallback = cursor_config.Config.defaults();
        if (std.mem.eql(u8, configured.theme(), fallback.theme()) and configured.size == fallback.size) {
            return err;
        }
        log.warn("failed to load configured cursor theme '{s}' at size {d}; falling back to {s} at {d}", .{
            configured.theme(),
            configured.size,
            fallback.theme(),
            fallback.size,
        });
        try cursor.setTheme(fallback.themeZ().ptr, fallback.size);
        server.input_manager.cursor_config = fallback;
    };

    seat.wlr_seat.events.request_set_cursor.add(&cursor.request_set_cursor);

    wlr_cursor.events.motion.add(&cursor.motion_relative);
    wlr_cursor.events.motion_absolute.add(&cursor.motion_absolute);
    wlr_cursor.events.button.add(&cursor.button);
    wlr_cursor.events.axis.add(&cursor.axis);
    wlr_cursor.events.frame.add(&cursor.frame);

    wlr_cursor.events.swipe_begin.add(&cursor.swipe_begin);
    wlr_cursor.events.swipe_update.add(&cursor.swipe_update);
    wlr_cursor.events.swipe_end.add(&cursor.swipe_end);

    wlr_cursor.events.pinch_begin.add(&cursor.pinch_begin);
    wlr_cursor.events.pinch_update.add(&cursor.pinch_update);
    wlr_cursor.events.pinch_end.add(&cursor.pinch_end);

    wlr_cursor.events.hold_begin.add(&cursor.hold_begin);
    wlr_cursor.events.hold_end.add(&cursor.hold_end);

    wlr_cursor.events.touch_down.add(&cursor.touch_down);
    wlr_cursor.events.touch_motion.add(&cursor.touch_motion);
    wlr_cursor.events.touch_up.add(&cursor.touch_up);
    wlr_cursor.events.touch_cancel.add(&cursor.touch_cancel);
    wlr_cursor.events.touch_frame.add(&cursor.touch_frame);

    wlr_cursor.events.tablet_tool_axis.add(&cursor.tablet_tool_axis);
    wlr_cursor.events.tablet_tool_proximity.add(&cursor.tablet_tool_proximity);
    wlr_cursor.events.tablet_tool_tip.add(&cursor.tablet_tool_tip);
    wlr_cursor.events.tablet_tool_button.add(&cursor.tablet_tool_button);
}

pub fn deinit(cursor: *Cursor) void {
    cursor.cancelPendingButton();
    cursor.axis.link.remove();
    cursor.button.link.remove();
    cursor.frame.link.remove();
    cursor.motion_absolute.link.remove();
    cursor.motion_relative.link.remove();
    cursor.swipe_begin.link.remove();
    cursor.swipe_update.link.remove();
    cursor.swipe_end.link.remove();
    cursor.pinch_begin.link.remove();
    cursor.pinch_update.link.remove();
    cursor.pinch_end.link.remove();
    cursor.hold_begin.link.remove();
    cursor.hold_end.link.remove();
    cursor.request_set_cursor.link.remove();

    cursor.touch_down.link.remove();
    cursor.touch_motion.link.remove();
    cursor.touch_up.link.remove();
    cursor.touch_cancel.link.remove();
    cursor.touch_frame.link.remove();

    cursor.tablet_tool_axis.link.remove();
    cursor.tablet_tool_proximity.link.remove();
    cursor.tablet_tool_tip.link.remove();
    cursor.tablet_tool_button.link.remove();

    cursor.xcursor_manager.destroy();
    cursor.wlr_cursor.destroy();
    cursor.pressed.deinit(util.gpa);
    cursor.touch_points.deinit(util.gpa);
}

/// Set the cursor theme for the given seat, as well as the xwayland theme if
/// this is the default seat. Either argument may be null, in which case a
/// default will be used.
pub fn setTheme(cursor: *Cursor, theme: ?[*:0]const u8, _size: ?u32) !void {
    const size = _size orelse cursor_config.default_size;

    const xcursor_manager = try wlr.XcursorManager.create(theme, size);
    errdefer xcursor_manager.destroy();

    // Validate the base-scale default cursor before replacing the working
    // manager. This keeps a missing or malformed live-selected theme from
    // making the cursor disappear.
    try xcursor_manager.load(1);
    const default_xcursor = xcursor_manager.getXcursor("default", 1) orelse
        return error.InvalidTheme;

    // If this cursor belongs to the default seat, update the Xwayland cursor to match the theme.
    // This cursor is communicated to Xwayland clients through the XCB_CW_CURSOR window attribute.
    if (cursor.seat == server.input_manager.defaultSeat()) {
        if (build_options.xwayland) {
            if (server.xwayland) |xwayland| {
                const image = default_xcursor.images[0];
                xwayland.setCursor(
                    image.getBuffer(),
                    @intCast(image.hotspot_x),
                    @intCast(image.hotspot_y),
                );
            }
        }
    }

    // Everything fallible is now done so the the old xcursor_manager can be destroyed.
    cursor.xcursor_manager.destroy();
    cursor.xcursor_manager = xcursor_manager;

    cursor.loadActiveScales();

    switch (cursor.image) {
        .none, .client => {},
        .xcursor => |name| cursor.wlr_cursor.setXcursor(xcursor_manager, name),
    }
}

pub fn setConstraintsSuppressed(cursor: *Cursor, value: bool) void {
    if (cursor.constraints_suppressed == value) return;
    cursor.constraints_suppressed = value;
    if (value) {
        if (cursor.constraint) |c| {
            if (c.state == .active) c.deactivate();
        }
    } else {
        if (cursor.constraint) |c| c.maybeActivate();
    }
}

fn loadActiveScales(cursor: *Cursor) void {
    cursor.xcursor_manager.load(1) catch {};

    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| {
        const wlr_output = output.wlr_output orelse continue;
        if (!wlr_output.enabled) continue;
        cursor.xcursor_manager.load(wlr_output.scale) catch {
            log.err("failed to load xcursor theme at scale {d}", .{wlr_output.scale});
        };
    }
}

pub fn reloadScales(cursor: *Cursor) void {
    cursor.loadActiveScales();
    switch (cursor.image) {
        .xcursor => |name| cursor.wlr_cursor.setXcursor(cursor.xcursor_manager, name),
        .none, .client => {},
    }
}

pub fn setImage(cursor: *Cursor, image: Image) void {
    if (cursor.image == .client) {
        cursor.image_surface_destroy.link.remove();
    }
    cursor.image = image;
    switch (cursor.image) {
        .none => cursor.wlr_cursor.unsetImage(),
        .xcursor => |name| cursor.wlr_cursor.setXcursor(cursor.xcursor_manager, name),
        .client => |client| {
            client.surface.events.destroy.add(&cursor.image_surface_destroy);
            cursor.wlr_cursor.setSurface(client.surface, client.hotspot_x, client.hotspot_y);
        },
    }
}

fn handleImageSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const cursor: *Cursor = @fieldParentPtr("image_surface_destroy", listener);
    // wlroots calls wlr_cursor_unset_image() automatically
    // when the cursor surface is destroyed.
    cursor.image = .none;
    cursor.image_surface_destroy.link.remove();
}

pub fn setWmImage(cursor: *Cursor, wm_image: Image) void {
    if (cursor.wm_image == .client) {
        cursor.wm_image_surface_destroy.link.remove();
    }
    cursor.wm_image = wm_image;
    if (cursor.wm_image == .client) {
        cursor.wm_image.client.surface.events.destroy.add(&cursor.wm_image_surface_destroy);
    }
    if (cursor.seat.wlr_seat.pointer_state.focused_client == null) {
        cursor.setImage(wm_image);
    }
}

fn handleWmImageSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const cursor: *Cursor = @fieldParentPtr("wm_image_surface_destroy", listener);
    cursor.wm_image = .none;
    cursor.wm_image_surface_destroy.link.remove();
}

fn handleRequestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const cursor: *Cursor = @fieldParentPtr("request_set_cursor", listener);
    const focused_client = cursor.seat.wlr_seat.pointer_state.focused_client;

    // Only the client with pointer focus is allowed to set the cursor
    if (event.seat_client == focused_client) {
        log.debug("focused client set cursor", .{});
        if (event.surface) |surface| {
            cursor.setImage(.{ .client = .{
                .surface = surface,
                .hotspot_x = event.hotspot_x,
                .hotspot_y = event.hotspot_y,
            } });
        } else {
            cursor.setImage(.none);
        }
    }
    // Except for the window manager client
    if (server.wm.object) |object| {
        if (event.seat_client.client == object.getClient() and
            object.getVersion() >= 4)
        {
            if (event.surface) |surface| {
                cursor.setWmImage(.{ .client = .{
                    .surface = surface,
                    .hotspot_x = event.hotspot_x,
                    .hotspot_y = event.hotspot_y,
                } });
            } else {
                cursor.setWmImage(.none);
            }
        }
    }
}

fn clearFocus(cursor: *Cursor) void {
    cursor.cancelPendingButton();
    cursor.setImage(cursor.wm_image);
    cursor.seat.wlr_seat.pointerNotifyClearFocus();
    cursor.seat.updatePointerConstraint(null);
    cursor.invalidateLastSent();
}

pub fn invalidateLastSent(cursor: *Cursor) void {
    cursor.last_sent_lx = -1;
    cursor.last_sent_ly = -1;
    cursor.last_sent_sx = 0;
    cursor.last_sent_sy = 0;
}

/// An explicit WM warp leaves any old constraint before moving. Deactivation
/// may restore a locked cursor or its hint, so it must precede the final warp.
pub fn warpForPolicy(cursor: *Cursor, x: i32, y: i32) void {
    cursor.seat.updatePointerConstraint(null);
    cursor.wlr_cursor.warpClosest(null, @floatFromInt(x), @floatFromInt(y));
    cursor.invalidateLastSent();
    // Refresh pointer enter/leave and constraints at the destination without
    // treating the warp as physical motion that can replace keyboard focus.
    cursor.updateState();
}

/// Apply an application request only after validating its complete destination.
/// This path must not unlock constraints or synthesize physical input.
pub fn warpForClient(cursor: *Cursor, surface: *wlr.Surface, sx: f64, sy: f64) void {
    if (server.lock_manager.state != .unlocked or server.aqueous.overview != null or server.window_switcher.output != null or
        cursor.seat.op != null or cursor.seat.drag != .none or
        server.aqueous.interactiveDragActive() or
        cursor.seat.wlr_seat.drag != null or cursor.seat.wlr_seat.pointerHasGrab() or
        (cursor.mode != .passthrough and cursor.mode != .down)) return;
    if (server.session) |session| if (!session.active) return;
    if (!surface.mapped or cursor.seat.wlr_seat.pointer_state.focused_surface != surface or
        !math.isFinite(sx) or !math.isFinite(sy) or sx < 0 or sy < 0 or
        sx >= @as(f64, @floatFromInt(surface.current.width)) or
        sy >= @as(f64, @floatFromInt(surface.current.height))) return;

    const node = scene_surface_projection.nodeForSurface(surface) orelse return;
    var nx: i32 = undefined;
    var ny: i32 = undefined;
    if (!node.coords(&nx, &ny)) return;
    // Picking deliberately uses integer scene origins even when rendering has
    // a fractional animation origin. Use the same origin as physical motion.
    const destination = scene_surface_projection.surfaceToDestination(node, sx, sy);
    const buffer = wlr.SceneBuffer.fromNode(node);
    if (destination.x < 0 or destination.y < 0 or
        destination.x >= @as(f64, @floatFromInt(buffer.dst_width)) or
        destination.y >= @as(f64, @floatFromInt(buffer.dst_height))) return;
    const lx = @as(f64, @floatFromInt(nx)) + destination.x;
    const ly = @as(f64, @floatFromInt(ny)) + destination.y;
    const output = server.om.output_layout.outputAt(lx, ly) orelse return;
    if (!output.enabled) return;
    if (cursor.mode == .passthrough) {
        const hit = server.scene.at(lx, ly) orelse return;
        if (hit.surface != surface or @abs(hit.sx - sx) > 1.0 / 256.0 or
            @abs(hit.sy - sy) > 1.0 / 256.0) return;
    }

    var confined_point: ?struct { x: f64, y: f64 } = null;
    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) {
            if (constraint.wlr_constraint.type == .locked) return;
            const state = constraint.state.active;
            var cx: i32 = undefined;
            var cy: i32 = undefined;
            if (!state.node.coords(&cx, &cy)) return;
            const origin = scene_surface_projection.surfaceToDestination(state.node, 0, 0);
            const scale = scene_surface_projection.scale(state.node);
            const target_sx = (lx - @as(f64, @floatFromInt(cx)) - origin.x) * scale;
            const target_sy = (ly - @as(f64, @floatFromInt(cy)) - origin.y) * scale;
            var allowed_sx: f64 = undefined;
            var allowed_sy: f64 = undefined;
            if (!wlr.region.confine(&constraint.wlr_constraint.region, state.sx, state.sy, target_sx, target_sy, &allowed_sx, &allowed_sy)) return;
            // Confinement is path-sensitive, including disconnected regions.
            // Do not mutate the constraint or silently clamp a rejected request.
            if (@abs(allowed_sx - target_sx) > 0.000001 or
                @abs(allowed_sy - target_sy) > 0.000001) return;
            confined_point = .{ .x = target_sx, .y = target_sy };
        }
    }

    if (!cursor.wlr_cursor.warp(null, lx, ly)) return;
    if (confined_point) |point| {
        cursor.constraint.?.state.active.sx = point.x;
        cursor.constraint.?.state.active.sy = point.y;
    }
    cursor.seat.wm_requested.follow_focus = false;
    cursor.seat.focus_warp = null;
    // Keep any explicit policy output warp intact.
    cursor.invalidateLastSent();
    if (cursor.mode == .down) {
        cursor.mode.down = .{ .lx = lx, .ly = ly, .sx = sx, .sy = sy, .surface_scale = scene_surface_projection.scale(node) };
    } else {
        cursor.updateHovered(false);
    }
    cursor.seat.wlr_seat.pointerNotifyMotion(util.msecTimestamp(), sx, sy);
    cursor.last_sent_lx = lx;
    cursor.last_sent_ly = ly;
    cursor.last_sent_sx = sx;
    cursor.last_sent_sy = sy;
    if (cursor.constraint) |constraint| constraint.maybeActivate();
    cursor.seat.wlr_seat.pointerNotifyFrame();
}

/// Prefer the visible center, retaining the user's position when already over
/// the target. Hit testing excludes occluding windows, panels and popup grabs.
pub fn warpToFocusedWindow(cursor: *Cursor, window: *Window) void {
    const box = window.focusWarpBox() orelse return;
    if (box.containsPoint(cursor.wlr_cursor.x, cursor.wlr_cursor.y) and
        focusWarpHits(window, cursor.wlr_cursor.x, cursor.wlr_cursor.y)) return;

    // Center first, then inset points for partially occluded/input-shaped clients.
    const fractions = [_]f64{ 0.5, 0.25, 0.75, 0.05, 0.95 };
    for (fractions) |fy| {
        for (fractions) |fx_fraction| {
            const x = box.x + @as(i32, @intFromFloat(@as(f64, @floatFromInt(box.width)) * fx_fraction));
            const y = box.y + @as(i32, @intFromFloat(@as(f64, @floatFromInt(box.height)) * fy));
            if (focusWarpHits(window, @floatFromInt(x), @floatFromInt(y))) {
                cursor.warpForPolicy(x, y);
                return;
            }
        }
    }
}

fn focusWarpHits(window: *Window, x: f64, y: f64) bool {
    const at = server.scene.at(x, y) orelse return false;
    return at.data == .window and at.data.window == window and
        at.surface != null and at.surface.?.getRootSurface() == window.rootSurface();
}

fn hasActivePointerConstraint(cursor: *const Cursor) bool {
    if (cursor.constraint) |constraint| {
        return constraint.state == .active;
    }
    return false;
}

fn hasActiveLockedPointerConstraint(cursor: *const Cursor) bool {
    if (cursor.constraint) |constraint| {
        return constraint.state == .active and constraint.wlr_constraint.type == .locked;
    }
    return false;
}

pub fn opStartPointer(cursor: *Cursor) void {
    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) constraint.deactivate();
    }

    log.debug("entering cursor mode op", .{});
    cursor.mode = .{ .op = .{} };

    cursor.clearFocus();
}

pub fn opEndPointer(cursor: *Cursor) void {
    if (cursor.pressed.count() == 0) {
        log.debug("entering cursor mode passthrough", .{});
        cursor.mode = .passthrough;
        cursor.updateState();
    } else {
        log.debug("entering cursor mode ignore", .{});
        cursor.mode = .ignore;
    }
}

/// XWayland move/resize requests do not carry the wl_seat and validated serial
/// supplied by xdg-shell. Accept them only while the default pointer has an
/// active button press directed at the requesting top-level surface.
pub fn canStartXwaylandPointerOperation(cursor: *const Cursor, surface: *wlr.Surface) bool {
    switch (cursor.mode) {
        .down => {},
        else => return false,
    }
    if (cursor.pressed.count() == 0) return false;
    const focused = cursor.seat.wlr_seat.pointer_state.focused_surface orelse return false;
    return focused.getRootSurface() == surface;
}

pub fn processMotionRelative(cursor: *Cursor, event: *const Seat.Event.PointerMotionRelative) void {
    // Physical input supersedes any cursor move deferred by keyboard focus.
    cursor.seat.cancelFocusWarp();
    cursor.processMotionRelativeInternal(event, true);
}

pub fn pointerModeGeneration(cursor: Cursor) u64 {
    return cursor.pointer_mode_generation;
}

pub fn beginPointerLock(cursor: *Cursor, node: *wlr.SceneNode, sx: f64, sy: f64, time_msec: u32) void {
    const point = cursor.clampSurfacePoint(node, sx, sy);
    cursor.pointer_lock_restore = .{ .node = node, .sx = point.sx, .sy = point.sy };
    cursor.transitionPointerMode(time_msec);
    cursor.seat.wm_scheduled.hovered = null;
}

pub fn restorePointerLock(cursor: *Cursor, node: *wlr.SceneNode, sx: f64, sy: f64, time_msec: u32) void {
    const point = cursor.clampSurfacePoint(node, sx, sy);
    const destination = scene_surface_projection.surfaceToDestination(node, point.sx, point.sy);
    var lx: c_int = undefined;
    var ly: c_int = undefined;
    if (node.coords(&lx, &ly)) {
        const layout_x = @as(f64, @floatFromInt(lx)) + destination.x;
        const layout_y = @as(f64, @floatFromInt(ly)) + destination.y;
        cursor.wlr_cursor.warpClosest(null, layout_x, layout_y);
        cursor.last_sent_lx = layout_x;
        cursor.last_sent_ly = layout_y;
        cursor.last_sent_sx = point.sx;
        cursor.last_sent_sy = point.sy;
    }
    cursor.pointer_lock_restore = null;
    cursor.transitionPointerMode(time_msec);
}

pub fn cancelPointerLock(cursor: *Cursor, time_msec: u32) void {
    cursor.pointer_lock_restore = null;
    cursor.transitionPointerMode(time_msec);
}

pub fn transitionPointerMode(cursor: *Cursor, time_msec: u32) void {
    cursor.pointer_mode_generation +%= 1;
    cursor.stale_motion_suppression_until = time_msec +% cursor_lock_restore.transition_suppression_msec;
}

pub fn clampSurfacePoint(cursor: Cursor, node: *wlr.SceneNode, sx: f64, sy: f64) SurfacePoint {
    _ = cursor;
    const buffer = wlr.SceneBuffer.fromNode(node);
    const scene_surface = wlr.SceneSurface.tryFromBuffer(buffer);
    var width: f64 = 0;
    var height: f64 = 0;
    if (scene_surface) |surface| {
        width = @floatFromInt(surface.surface.current.width);
        height = @floatFromInt(surface.surface.current.height);
    } else {
        width = @floatFromInt(buffer.dst_width);
        height = @floatFromInt(buffer.dst_height);
    }
    return cursor_lock_restore.clampPoint(sx, sy, width, height);
}

fn suppressTransitionMotion(cursor: Cursor, event: *const Seat.Event.PointerMotionRelative) bool {
    return cursor_lock_restore.suppressMotion(
        event.generation,
        cursor.pointer_mode_generation,
        event.time_msec,
        cursor.stale_motion_suppression_until,
        event.delta_x,
        event.delta_y,
    );
}

fn processMotionRelativeInternal(
    cursor: *Cursor,
    event: *const Seat.Event.PointerMotionRelative,
    send_relative_motion: bool,
) void {
    if (cursor.suppressTransitionMotion(event)) return;

    if (send_relative_motion) {
        const scale = cursor.focusedSurfaceScale();
        server.input_manager.relative_pointer_manager.sendRelativeMotion(
            cursor.seat.wlr_seat,
            @as(u64, event.time_msec) * 1000,
            event.delta_x * scale,
            event.delta_y * scale,
            event.unaccel_dx * scale,
            event.unaccel_dy * scale,
        );
    }

    var dx: f64 = event.delta_x;
    var dy: f64 = event.delta_y;

    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) {
            switch (constraint.wlr_constraint.type) {
                .locked => return,
                .confined => constraint.confine(&dx, &dy),
            }
        }
    }

    switch (cursor.mode) {
        .passthrough, .drag, .ignore, .down => {
            cursor.move(&event.mapping, dx, dy);
            server.aqueous.handlePointerMotion(cursor.wlr_cursor.x, cursor.wlr_cursor.y);

            switch (cursor.mode) {
                .passthrough, .drag => {
                    cursor.updateHovered(true);
                    cursor.passthrough(event.time_msec);
                },
                .ignore => {},
                .down => |data| {
                    cursor.seat.wlr_seat.pointerNotifyMotion(
                        event.time_msec,
                        data.sx + (cursor.wlr_cursor.x - data.lx) * data.surface_scale,
                        data.sy + (cursor.wlr_cursor.y - data.ly) * data.surface_scale,
                    );
                },
                else => unreachable,
            }

            cursor.updateDragIcons();

            if (cursor.constraint) |constraint| {
                constraint.maybeActivate();
            }
        },
        .op => |*data| {
            dx += data.delta_x;
            dy += data.delta_y;
            data.delta_x = dx - @trunc(dx);
            data.delta_y = dy - @trunc(dy);

            cursor.move(&event.mapping, dx, dy);
            server.aqueous.handlePointerMotion(cursor.wlr_cursor.x, cursor.wlr_cursor.y);
            cursor.seat.opUpdate(@intFromFloat(cursor.wlr_cursor.x), @intFromFloat(cursor.wlr_cursor.y));
        },
    }
}

fn move(cursor: *const Cursor, mapping: *const wlr.Box, dx: f64, dy: f64) void {
    var lx: f64 = cursor.wlr_cursor.x + dx;
    var ly: f64 = cursor.wlr_cursor.y + dy;
    if (!mapping.empty()) {
        mapping.closestPoint(lx, ly, &lx, &ly);
    }
    cursor.wlr_cursor.warpClosest(null, lx, ly);
}

fn focusedSurfaceScale(cursor: *const Cursor) f64 {
    const focused = cursor.seat.wlr_seat.pointer_state.focused_surface orelse return 1;
    const result = server.scene.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y) orelse return 1;
    if (result.surface != focused) return 1;
    return scene_surface_projection.scale(result.node);
}

/// Refresh the compositor's pointer target. `allow_focus_follow` is true only
/// for real pointer-motion events. Layout/render transactions also need to
/// update Wayland pointer focus after moving live input nodes, but must not
/// reinterpret a stationary pointer as user intent and focus/recenter another
/// scrolling column while its cosmetic animation is still in flight.
fn updateHovered(cursor: *Cursor, allow_focus_follow: bool) void {
    const old = cursor.seat.wm_scheduled.hovered;
    // Start from no hovered window. Scene nodes without a client surface are
    // compositor decorations (most notably SSD borders), and must not become
    // focus-follows-mouse targets. Adjacent outward-drawn borders can overlap
    // inside a gap; treating them as windows makes tiny pointer movements flip
    // focus, border state, and stacking repeatedly.
    cursor.seat.wm_scheduled.hovered = null;
    if (!cursor.hasActiveLockedPointerConstraint()) {
        if (server.scene.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| switch (result.data) {
            .window => |window| window_hit: {
                const surface = result.surface orelse break :window_hit;
                switch (window.impl) {
                    .toplevel => |toplevel| {
                        // Exclude input regions of the toplevel that extend beyond the window
                        if (surface.getRootSurface() == toplevel.wlr_toplevel.base.surface) {
                            if (window.box.containsPoint(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) {
                                cursor.seat.wm_scheduled.hovered = window.ref;
                            }
                        } else {
                            cursor.seat.wm_scheduled.hovered = window.ref;
                        }
                    },
                    .xwayland => cursor.seat.wm_scheduled.hovered = window.ref,
                    .destroying => {},
                }
            },
            .shell_surface, .lock_surface, .layer_surface => {},
            .override_redirect => {
                assert(build_options.xwayland);
                assert(server.xwayland != null);
            },
        };
    }

    if (allow_focus_follow) {
        server.aqueous.handleHover(if (cursor.seat.wm_scheduled.hovered) |ref| @bitCast(ref) else null);
    }
    if (cursor.seat.wm_scheduled.hovered != old) {
        server.wm.dirtyWindowing();
    }
}

pub fn processMotionAbsolute(cursor: *Cursor, event: *const Seat.Event.PointerMotionAbsolute) void {
    // Physical input supersedes any cursor move deferred by keyboard focus.
    cursor.seat.cancelFocusWarp();
    if (event.generation != cursor.pointer_mode_generation) return;

    var mapping = event.mapping;
    if (mapping.empty()) {
        server.om.output_layout.getBox(null, &mapping);
    }
    const lx = @as(f64, @floatFromInt(mapping.x)) + @as(f64, @floatFromInt(mapping.width)) * event.x;
    const ly = @as(f64, @floatFromInt(mapping.y)) + @as(f64, @floatFromInt(mapping.height)) * event.y;
    const dx = lx - cursor.wlr_cursor.x;
    const dy = ly - cursor.wlr_cursor.y;
    cursor.processMotionRelativeInternal(&.{
        .mapping = event.mapping,
        .generation = event.generation,
        .time_msec = event.time_msec,
        .delta_x = dx,
        .delta_y = dy,
        .unaccel_dx = dx,
        .unaccel_dy = dy,
    }, !cursor.hasActivePointerConstraint());
}

pub fn processButton(cursor: *Cursor, event: *const Seat.Event.PointerButton) void {
    if (event.state == .pressed and server.window_switcher.output != null) {
        const hit = server.scene.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y);
        const on_layer = if (hit) |h| h.data == .layer_surface else false;
        if (!on_layer) {
            server.window_switcher.dismiss();
            cursor.updateState();
        }
    }
    // Physical input supersedes any cursor move deferred by keyboard focus.
    cursor.seat.cancelFocusWarp();
    if (event.state == .pressed) {
        const result = cursor.pressed.getOrPut(util.gpa, event.button) catch {
            log.err("out of memory", .{});
            return;
        };
        if (result.found_existing) {
            log.err("ignoring duplicate pointer button {d} press", .{event.button});
            return;
        }

        if (cursor.seat.drag == .pointer) {
            result.value_ptr.* = null;
            _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            return;
        }
        const modifiers: u32 = if (cursor.seat.wlr_seat.getKeyboard()) |keyboard| @bitCast(keyboard.getModifiers()) else 0;
        if (cursor.seat.drag == .none and server.aqueous.handlePointerButton(event.button, modifiers, true, cursor.wlr_cursor.x, cursor.wlr_cursor.y, event.time_msec)) {
            result.value_ptr.* = null;
            cursor.mode = .ignore;
            cursor.clearFocus();
            return;
        }

        if (cursor.seat.matchPointerBinding(event.button)) |binding| {
            result.value_ptr.* = binding;
            binding.pressed();
            switch (cursor.mode) {
                .passthrough, .drag, .down => {
                    log.debug("entering cursor mode ignore", .{});
                    cursor.mode = .ignore;
                    cursor.clearFocus();
                },
                // It is important that we do not enter ignore mode if an op is in progress,
                // doing so would result in op_release never being sent for example.
                .op, .ignore => {},
            }
            return;
        }

        result.value_ptr.* = null;

        switch (cursor.mode) {
            .passthrough => {
                if (server.scene.atDrag(cursor.wlr_cursor.x, cursor.wlr_cursor.y, cursor.seat.toplevel_drag.window())) |at| {
                    cursor.interact(at);

                    if (at.surface != null) {
                        log.debug("entering cursor mode down", .{});
                        cursor.mode = .{
                            .down = .{
                                .lx = cursor.wlr_cursor.x,
                                .ly = cursor.wlr_cursor.y,
                                .sx = at.sx,
                                .sy = at.sy,
                                .surface_scale = scene_surface_projection.scale(at.node),
                            },
                        };
                        cursor.sendButtonAfterFocus(event);
                        return;
                    }
                }

                log.debug("entering cursor mode ignore", .{});
                cursor.mode = .ignore;
                cursor.clearFocus();
                return;
            },
            .drag => {
                if (server.scene.atDrag(cursor.wlr_cursor.x, cursor.wlr_cursor.y, cursor.seat.toplevel_drag.window())) |at| {
                    cursor.interact(at);
                    if (at.surface != null) {
                        _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                        return;
                    }
                }
                cursor.clearFocus();
            },
            // Pointer focus does not change while in down mode.
            .down => {
                _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            },
            // No client has pointer focus while in ignore/op mode.
            .ignore, .op => {},
        }
    } else {
        assert(event.state == .released);
        const modifiers: u32 = if (cursor.seat.wlr_seat.getKeyboard()) |keyboard| @bitCast(keyboard.getModifiers()) else 0;
        if (cursor.seat.drag == .none) _ = server.aqueous.handlePointerButton(event.button, modifiers, false, cursor.wlr_cursor.x, cursor.wlr_cursor.y, event.time_msec);
        const result = cursor.pressed.fetchRemove(event.button);
        if (result) |kv| {
            if (kv.value) |binding| {
                binding.released();
            }

            switch (cursor.mode) {
                .passthrough => unreachable,
                .drag, .down, .ignore => {
                    if (cursor.mode != .ignore) {
                        _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                    }
                    if (cursor.pressed.count() == 0) {
                        log.debug("exiting cursor mode {s}", .{@tagName(cursor.mode)});
                        cursor.mode = .passthrough;
                        cursor.passthrough(event.time_msec);
                    }
                },
                .op => {
                    if (cursor.pressed.count() == 0) {
                        cursor.seat.wm_scheduled.op_release = true;
                        server.wm.dirtyWindowing();
                    }
                },
            }
        } else {
            log.err("ignoring duplicate pointer button {d} release", .{event.button});
            return;
        }
    }
}

fn sendButtonAfterFocus(cursor: *Cursor, event: *const Seat.Event.PointerButton) void {
    assert(cursor.pending_button == null);
    assert(cursor.mode == .down and event.state == .pressed);
    if (server.wm.scheduled.dirty and server.lock_manager.state == .unlocked) {
        if (cursor.seat.wlr_seat.pointer_state.focused_surface) |surface| {
            log.debug("deferring pointer button {d} until focus is applied", .{event.button});
            cursor.pending_button = .{ .event = event.*, .surface = surface };
            surface.events.unmap.add(&cursor.pending_button_unmap);
            surface.events.destroy.add(&cursor.pending_button_destroy);
            return;
        }
    }
    _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
}

/// Run after policy has applied focus, including modal/layer/grab restrictions.
/// wlroots sends the new primary-selection offer during keyboard focus change,
/// so a client can request it immediately from its button-press callback.
pub fn finishPendingButton(cursor: *Cursor) void {
    const pending = cursor.pending_button orelse return;
    if (cursor.mode != .down or server.lock_manager.state != .unlocked or
        !pending.surface.mapped or cursor.seat.wlr_seat.pointer_state.focused_surface != pending.surface)
    {
        cursor.cancelPendingButton();
        return;
    }
    cursor.pending_button = null;
    cursor.pending_button_unmap.link.remove();
    cursor.pending_button_destroy.link.remove();
    const event = pending.event;
    _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
}

fn cancelPendingButton(cursor: *Cursor) void {
    const pending = cursor.pending_button orelse return;
    log.debug("cancelling pending pointer button {d}", .{pending.event.button});
    cursor.pending_button = null;
    cursor.pending_button_unmap.link.remove();
    cursor.pending_button_destroy.link.remove();
    // Keep the physical press tracked, but do not send an unmatched release.
    if (cursor.mode == .down) cursor.mode = .ignore;
}

fn handlePendingButtonUnmap(listener: *wl.Listener(void)) void {
    const cursor: *Cursor = @fieldParentPtr("pending_button_unmap", listener);
    cursor.clearFocus();
}

fn handlePendingButtonDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const cursor: *Cursor = @fieldParentPtr("pending_button_destroy", listener);
    cursor.clearFocus();
}

pub fn processAxis(cursor: *Cursor, event: *const Seat.Event.PointerAxis) void {
    cursor.seat.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}

fn interact(cursor: Cursor, result: Scene.AtResult) void {
    switch (result.data) {
        .window => |window| {
            cursor.seat.wm_scheduled.interaction = .{ .window = window.ref };
            server.aqueous.handleWindowInteraction(@bitCast(window.ref));
            server.wm.dirtyWindowing();
        },
        .shell_surface => |shell_surface| {
            cursor.seat.wm_scheduled.interaction = .{ .shell_surface = shell_surface };
            server.wm.dirtyWindowing();
        },
        .lock_surface => |lock_surface| {
            assert(server.lock_manager.state != .unlocked);
            cursor.seat.focus(.{ .lock_surface = lock_surface });
        },
        .layer_surface => |layer_surface| {
            switch (cursor.seat.layer_shell.scheduled.focus) {
                .none, .non_exclusive => {
                    if (layer_surface.wlr_layer_surface.current.keyboard_interactive == .on_demand) {
                        cursor.seat.layer_shell.scheduled.focus = .{
                            .non_exclusive = layer_surface.ref,
                        };
                        server.wm.dirtyWindowing();
                    }
                },
                .exclusive => {},
            }
        },
        .override_redirect => |override_redirect| {
            assert(server.lock_manager.state != .locked);
            override_redirect.focusForInteraction();
        },
    }
}

fn handleTouchDown(
    listener: *wl.Listener(*wlr.Touch.event.Down),
    event: *wlr.Touch.event.Down,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_down", listener);

    cursor.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    cursor.touch_points.putNoClobber(util.gpa, event.touch_id, .{ .lx = lx, .ly = ly }) catch {
        log.err("out of memory", .{});
        return;
    };

    if (server.scene.at(lx, ly)) |result| {
        cursor.interact(result);

        if (result.surface) |surface| {
            _ = cursor.seat.wlr_seat.touchNotifyDown(
                surface,
                event.time_msec,
                event.touch_id,
                result.sx,
                result.sy,
            );
        }
    }
}

fn handleTouchMotion(
    listener: *wl.Listener(*wlr.Touch.event.Motion),
    event: *wlr.Touch.event.Motion,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_motion", listener);

    cursor.seat.handleActivity();

    if (cursor.touch_points.getPtr(event.touch_id)) |point| {
        cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &point.lx, &point.ly);

        cursor.updateDragIcons();

        if (cursor.seat.drag == .touch) {
            const drag = cursor.seat.wlr_seat.drag orelse return;
            if (event.touch_id != drag.grab_touch_id) return;
            cursor.seat.toplevel_drag.motion();
            cursor.refreshDragTarget();
        } else if (server.scene.at(point.lx, point.ly)) |result| {
            cursor.seat.wlr_seat.touchNotifyMotion(event.time_msec, event.touch_id, result.sx, result.sy);
        }
    }
}

fn handleTouchUp(
    listener: *wl.Listener(*wlr.Touch.event.Up),
    event: *wlr.Touch.event.Up,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_up", listener);

    cursor.seat.handleActivity();

    if (cursor.touch_points.remove(event.touch_id)) {
        _ = cursor.seat.wlr_seat.touchNotifyUp(event.time_msec, event.touch_id);
    }
}

fn handleTouchCancel(
    listener: *wl.Listener(*wlr.Touch.event.Cancel),
    _: *wlr.Touch.event.Cancel,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_cancel", listener);

    cursor.seat.handleActivity();

    cursor.touch_points.clearRetainingCapacity();

    const wlr_seat = cursor.seat.wlr_seat;
    while (wlr_seat.touch_state.touch_points.first()) |touch_point| {
        wlr_seat.touchNotifyCancel(touch_point.client);
    }
}

fn handleTouchFrame(listener: *wl.Listener(void)) void {
    const cursor: *Cursor = @fieldParentPtr("touch_frame", listener);

    cursor.seat.handleActivity();

    cursor.seat.wlr_seat.touchNotifyFrame();
}

fn handleTabletToolAxis(
    _: *wl.Listener(*wlr.Tablet.event.Axis),
    event: *wlr.Tablet.event.Axis,
) void {
    const device: *InputDevice = @ptrCast(@alignCast(event.device.data));
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.axis(tablet, event);
}

fn handleTabletToolProximity(
    _: *wl.Listener(*wlr.Tablet.event.Proximity),
    event: *wlr.Tablet.event.Proximity,
) void {
    const device: *InputDevice = @ptrCast(@alignCast(event.device.data));
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.proximity(tablet, event);
}

fn handleTabletToolTip(
    _: *wl.Listener(*wlr.Tablet.event.Tip),
    event: *wlr.Tablet.event.Tip,
) void {
    const device: *InputDevice = @ptrCast(@alignCast(event.device.data));
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.tip(tablet, event);
}

fn handleTabletToolButton(
    _: *wl.Listener(*wlr.Tablet.event.Button),
    event: *wlr.Tablet.event.Button,
) void {
    const device: *InputDevice = @ptrCast(@alignCast(event.device.data));
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.button(tablet, event);
}

pub fn updateState(cursor: *Cursor) void {
    if (cursor.constraint) |constraint| {
        constraint.updateState();
    }

    if (cursor.hasActiveLockedPointerConstraint()) return;

    switch (cursor.mode) {
        .passthrough, .drag => {
            cursor.updateHovered(false);
            cursor.passthrough(util.msecTimestamp());
        },
        .ignore, .down, .op => {},
    }
}

/// Pass an event on to the surface under the cursor, if any.
fn passthrough(cursor: *Cursor, time: u32) void {
    assert(cursor.mode == .passthrough or cursor.mode == .drag);
    if (cursor.mode == .drag) cursor.seat.toplevel_drag.motion();

    if (server.scene.atDrag(cursor.wlr_cursor.x, cursor.wlr_cursor.y, if (cursor.mode == .drag) cursor.seat.toplevel_drag.window() else null)) |result| {
        if (result.data == .lock_surface) {
            assert(server.lock_manager.state != .unlocked);
        } else {
            assert(server.lock_manager.state != .locked);
        }

        if (result.surface) |surface| {
            const lx = cursor.wlr_cursor.x;
            const ly = cursor.wlr_cursor.y;
            // Compare against the seat's own focused surface (cleared by wlroots
            // when a surface is destroyed) so this never dereferences/compares a
            // dangling pointer. A genuine enter/focus change always re-emits a
            // motion so pointer-constraint / relative-pointer setup keyed off the
            // first motion still works.
            const focus_changed = (cursor.seat.wlr_seat.pointer_state.focused_surface != surface);
            const cursor_moved = (lx != cursor.last_sent_lx or ly != cursor.last_sent_ly);

            cursor.seat.wlr_seat.pointerNotifyEnter(surface, result.sx, result.sy);
            cursor.seat.updatePointerConstraint(surface);

            var sx = result.sx;
            var sy = result.sy;
            if (cursor.mode != .drag and !cursor.hasActivePointerConstraint() and !focus_changed and cursor_moved) {
                const scale = scene_surface_projection.scale(result.node);
                sx = cursor.last_sent_sx + (lx - cursor.last_sent_lx) * scale;
                sy = cursor.last_sent_sy + (ly - cursor.last_sent_ly) * scale;
            }

            if (cursor_moved or focus_changed) {
                cursor.seat.wlr_seat.pointerNotifyMotion(time, sx, sy);
                cursor.last_sent_sx = sx;
                cursor.last_sent_sy = sy;
            } else {
                cursor.last_sent_sx = result.sx;
                cursor.last_sent_sy = result.sy;
            }
            cursor.last_sent_lx = lx;
            cursor.last_sent_ly = ly;
            return;
        }
    }

    cursor.clearFocus();
}

pub fn refreshDragTarget(cursor: *Cursor) void {
    const drag = cursor.seat.wlr_seat.drag orelse return;
    const time = util.msecTimestamp();
    switch (drag.grab_type) {
        .keyboard_pointer => if (cursor.mode == .drag) cursor.passthrough(time),
        .keyboard_touch => {
            const point = cursor.touch_points.get(drag.grab_touch_id) orelse return;
            if (server.scene.atDrag(point.lx, point.ly, cursor.seat.toplevel_drag.window())) |hit| {
                if (hit.surface) |surface| {
                    cursor.seat.wlr_seat.touchPointFocus(surface, time, drag.grab_touch_id, hit.sx, hit.sy);
                    cursor.seat.wlr_seat.touchNotifyMotion(time, drag.grab_touch_id, hit.sx, hit.sy);
                    return;
                }
            }
            // zig-wlroots 0.20.1 has an outdated declaration for this function.
            @import("c").wlr_seat_touch_notify_clear_focus(@ptrCast(cursor.seat.wlr_seat), time, drag.grab_touch_id);
            cursor.seat.wlr_seat.touchPointClearFocus(time, drag.grab_touch_id);
        },
        .keyboard => {},
    }
}

fn updateDragIcons(cursor: *Cursor) void {
    var it = server.scene.drag_icons.children.iterator(.forward);
    while (it.next()) |node| {
        const icon = @as(*DragIcon, @ptrCast(@alignCast(node.data)));

        if (icon.wlr_drag_icon.drag.seat == cursor.seat.wlr_seat) {
            icon.updatePosition(cursor);
        }
    }
}

fn queueMotionRelative(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
    const cursor: *Cursor = @fieldParentPtr("motion_relative", listener);
    const device: *InputDevice = @ptrCast(@alignCast(event.device.data));
    cursor.seat.queueEvent(.{ .pointer_motion_relative = .{
        .mapping = device.activeMapping(),
        .generation = cursor.pointerModeGeneration(),
        .time_msec = event.time_msec,
        .delta_x = event.delta_x,
        .delta_y = event.delta_y,
        .unaccel_dx = event.unaccel_dx,
        .unaccel_dy = event.unaccel_dy,
    } }) catch {};
}

fn queueMotionAbsolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
    const cursor: *Cursor = @fieldParentPtr("motion_absolute", listener);
    const device: *InputDevice = @ptrCast(@alignCast(event.device.data));
    cursor.seat.queueEvent(.{ .pointer_motion_absolute = .{
        .mapping = device.activeMapping(),
        .generation = cursor.pointerModeGeneration(),
        .time_msec = event.time_msec,
        .x = event.x,
        .y = event.y,
    } }) catch {};
}

fn queueButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    const cursor: *Cursor = @fieldParentPtr("button", listener);
    if (@import("InputActivityManager.zig").observeInput()) if (event.device.data) |data| {
        const device: *InputDevice = @ptrCast(@alignCast(data));
        const fresh = device.activity_presses.update(event.button, event.state == .pressed);
        if (fresh and !device.virtual and device.seat == server.input_manager.defaultSeat()) server.input_activity.noteActivity(.mouse);
    };
    cursor.seat.queueEvent(.{ .pointer_button = .{
        .time_msec = event.time_msec,
        .button = event.button,
        .state = event.state,
    } }) catch {};
}

fn queueAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const cursor: *Cursor = @fieldParentPtr("axis", listener);
    const device: *InputDevice = @ptrCast(@alignCast(event.device.data));
    cursor.seat.queueEvent(.{ .pointer_axis = .{
        .time_msec = event.time_msec,
        .source = event.source,
        .orientation = event.orientation,
        .relative_direction = event.relative_direction,
        .delta = event.delta * device.config.scroll_factor,
        .delta_discrete = math.lossyCast(i32, @as(f64, @floatFromInt(event.delta_discrete)) * device.config.scroll_factor),
        .delta_discrete_raw = event.delta_discrete,
    } }) catch {};
}

fn queueFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const cursor: *Cursor = @fieldParentPtr("frame", listener);
    cursor.seat.queueEvent(.pointer_frame) catch {};
}

fn queuePinchBegin(listener: *wl.Listener(*wlr.Pointer.event.PinchBegin), event: *wlr.Pointer.event.PinchBegin) void {
    const cursor: *Cursor = @fieldParentPtr("pinch_begin", listener);
    cursor.seat.queueEvent(.{ .pointer_pinch_begin = .{
        .time_msec = event.time_msec,
        .fingers = event.fingers,
    } }) catch {};
}

fn queuePinchUpdate(listener: *wl.Listener(*wlr.Pointer.event.PinchUpdate), event: *wlr.Pointer.event.PinchUpdate) void {
    const cursor: *Cursor = @fieldParentPtr("pinch_update", listener);
    cursor.seat.queueEvent(.{ .pointer_pinch_update = .{
        .time_msec = event.time_msec,
        .fingers = event.fingers,
        .dx = event.dx,
        .dy = event.dy,
        .scale = event.scale,
        .rotation = event.rotation,
    } }) catch {};
}

fn queuePinchEnd(listener: *wl.Listener(*wlr.Pointer.event.PinchEnd), event: *wlr.Pointer.event.PinchEnd) void {
    const cursor: *Cursor = @fieldParentPtr("pinch_end", listener);
    cursor.seat.queueEvent(.{ .pointer_pinch_end = .{
        .time_msec = event.time_msec,
        .cancelled = event.cancelled,
    } }) catch {};
}

fn queueSwipeBegin(listener: *wl.Listener(*wlr.Pointer.event.SwipeBegin), event: *wlr.Pointer.event.SwipeBegin) void {
    const cursor: *Cursor = @fieldParentPtr("swipe_begin", listener);
    cursor.seat.queueEvent(.{ .pointer_swipe_begin = .{
        .time_msec = event.time_msec,
        .fingers = event.fingers,
    } }) catch {};
}

fn queueSwipeUpdate(listener: *wl.Listener(*wlr.Pointer.event.SwipeUpdate), event: *wlr.Pointer.event.SwipeUpdate) void {
    const cursor: *Cursor = @fieldParentPtr("swipe_update", listener);
    cursor.seat.queueEvent(.{ .pointer_swipe_update = .{
        .time_msec = event.time_msec,
        .fingers = event.fingers,
        .dx = event.dx,
        .dy = event.dy,
    } }) catch {};
}

fn queueSwipeEnd(listener: *wl.Listener(*wlr.Pointer.event.SwipeEnd), event: *wlr.Pointer.event.SwipeEnd) void {
    const cursor: *Cursor = @fieldParentPtr("swipe_end", listener);
    cursor.seat.queueEvent(.{ .pointer_swipe_end = .{
        .time_msec = event.time_msec,
        .cancelled = event.cancelled,
    } }) catch {};
}

fn queueHoldBegin(listener: *wl.Listener(*wlr.Pointer.event.HoldBegin), event: *wlr.Pointer.event.HoldBegin) void {
    const cursor: *Cursor = @fieldParentPtr("hold_begin", listener);
    cursor.seat.queueEvent(.{ .pointer_hold_begin = .{
        .time_msec = event.time_msec,
        .fingers = event.fingers,
    } }) catch {};
}

fn queueHoldEnd(listener: *wl.Listener(*wlr.Pointer.event.HoldEnd), event: *wlr.Pointer.event.HoldEnd) void {
    const cursor: *Cursor = @fieldParentPtr("hold_end", listener);
    cursor.seat.queueEvent(.{ .pointer_hold_end = .{
        .time_msec = event.time_msec,
        .cancelled = event.cancelled,
    } }) catch {};
}
