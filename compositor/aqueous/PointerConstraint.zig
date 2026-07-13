// SPDX-FileCopyrightText: © 2023 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const PointerConstraint = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const Seat = @import("Seat.zig");

const ActivationBlock = enum {
    suppressed,
    compositor_operation,
    no_pointer_focus,
    different_surface_tree,
    no_scene_surface,
    outside_surface,
    outside_region,
};

const log = std.log.scoped(.input);

wlr_constraint: *wlr.PointerConstraintV1,
last_activation_block: ?ActivationBlock = null,

state: union(enum) {
    inactive,
    active: struct {
        /// Node of the active constraint surface in the scene graph.
        node: *wlr.SceneNode,
        /// Coordinates of the pointer on activation in the surface coordinate system.
        sx: f64,
        sy: f64,
    },
} = .inactive,

destroy: wl.Listener(*wlr.PointerConstraintV1) = .init(handleDestroy),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),

node_destroy: wl.Listener(void) = .init(handleNodeDestroy),

pub fn create(wlr_constraint: *wlr.PointerConstraintV1) error{OutOfMemory}!void {
    const seat: *Seat = @ptrCast(@alignCast(wlr_constraint.seat.data));

    const constraint = try util.gpa.create(PointerConstraint);
    errdefer util.gpa.destroy(constraint);

    constraint.* = .{
        .wlr_constraint = wlr_constraint,
    };
    wlr_constraint.data = constraint;

    wlr_constraint.events.destroy.add(&constraint.destroy);
    wlr_constraint.surface.events.commit.add(&constraint.commit);

    log.debug(
        "new pointer constraint type={s} surface=0x{x} root=0x{x} keyboard=0x{x} pointer=0x{x}",
        .{
            @tagName(wlr_constraint.type),
            @intFromPtr(wlr_constraint.surface),
            @intFromPtr(wlr_constraint.surface.getRootSurface()),
            surfaceAddress(seat.wlr_seat.keyboard_state.focused_surface),
            surfaceAddress(seat.wlr_seat.pointer_state.focused_surface),
        },
    );

    // new_constraint is emitted after wlroots inserts the object in its
    // manager, so the normal pointer-focus lookup can select it immediately.
    seat.updatePointerConstraint(seat.wlr_seat.pointer_state.focused_surface);
}

pub fn maybeActivate(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrCast(@alignCast(constraint.wlr_constraint.seat.data));

    assert(seat.cursor.constraint == constraint);

    if (seat.cursor.constraints_suppressed) {
        constraint.activationBlocked(.suppressed, seat);
        return;
    }
    if (constraint.state == .active) return;

    if (seat.cursor.mode == .op) {
        constraint.activationBlocked(.compositor_operation, seat);
        return;
    }

    const pointer_surface = seat.wlr_seat.pointer_state.focused_surface orelse {
        constraint.activationBlocked(.no_pointer_focus, seat);
        return;
    };
    if (pointer_surface.getRootSurface() != constraint.wlr_constraint.surface.getRootSurface()) {
        constraint.activationBlocked(.different_surface_tree, seat);
        return;
    }

    // Find the constrained surface's own scene node instead of accepting only
    // the top-most result of a whole-scene hit test. This keeps child surfaces
    // and same-client overlays from masking a valid root-surface constraint.
    const node = sceneNodeForSurface(constraint.wlr_constraint.surface) orelse {
        constraint.activationBlocked(.no_scene_surface, seat);
        return;
    };
    var surface_sx: f64 = undefined;
    var surface_sy: f64 = undefined;
    const hit = node.at(
        seat.cursor.wlr_cursor.x,
        seat.cursor.wlr_cursor.y,
        &surface_sx,
        &surface_sy,
    ) orelse {
        constraint.activationBlocked(.outside_surface, seat);
        return;
    };
    if (hit != node) {
        constraint.activationBlocked(.outside_surface, seat);
        return;
    }

    const sx: i32 = @intFromFloat(surface_sx);
    const sy: i32 = @intFromFloat(surface_sy);
    if (!constraint.wlr_constraint.region.containsPoint(sx, sy, null)) {
        constraint.activationBlockedRegion(seat, sx, sy);
        return;
    }

    assert(constraint.state == .inactive);
    constraint.last_activation_block = null;
    const point = seat.cursor.clampSurfacePoint(node, surface_sx, surface_sy);
    constraint.state = .{
        .active = .{
            .node = node,
            .sx = point.sx,
            .sy = point.sy,
        },
    };
    node.events.destroy.add(&constraint.node_destroy);
    if (constraint.wlr_constraint.type == .locked) {
        seat.cursor.beginPointerLock(node, point.sx, point.sy, util.msecTimestamp());
    }
    seat.cursor.invalidateLastSent();

    log.info(
        "activating pointer constraint type={s} surface=0x{x} pointer=0x{x}",
        .{
            @tagName(constraint.wlr_constraint.type),
            @intFromPtr(constraint.wlr_constraint.surface),
            @intFromPtr(pointer_surface),
        },
    );

    constraint.wlr_constraint.sendActivated();
}

fn activationBlockedRegion(constraint: *PointerConstraint, seat: *Seat, sx: i32, sy: i32) void {
    if (constraint.last_activation_block == .outside_region) return;
    constraint.last_activation_block = .outside_region;
    const extents = constraint.wlr_constraint.region.extents;
    log.debug(
        "pointer constraint waiting reason=outside_region type={s} surface=0x{x} point={d},{d} region={d},{d}-{d},{d} keyboard=0x{x} pointer=0x{x}",
        .{
            @tagName(constraint.wlr_constraint.type),
            @intFromPtr(constraint.wlr_constraint.surface),
            sx,
            sy,
            extents.x1,
            extents.y1,
            extents.x2,
            extents.y2,
            surfaceAddress(seat.wlr_seat.keyboard_state.focused_surface),
            surfaceAddress(seat.wlr_seat.pointer_state.focused_surface),
        },
    );
}

fn activationBlocked(constraint: *PointerConstraint, reason: ActivationBlock, seat: *Seat) void {
    if (constraint.last_activation_block == reason) return;
    constraint.last_activation_block = reason;
    log.debug(
        "pointer constraint waiting reason={s} type={s} surface=0x{x} root=0x{x} keyboard=0x{x} pointer=0x{x}",
        .{
            @tagName(reason),
            @tagName(constraint.wlr_constraint.type),
            @intFromPtr(constraint.wlr_constraint.surface),
            @intFromPtr(constraint.wlr_constraint.surface.getRootSurface()),
            surfaceAddress(seat.wlr_seat.keyboard_state.focused_surface),
            surfaceAddress(seat.wlr_seat.pointer_state.focused_surface),
        },
    );
}

fn surfaceAddress(surface: ?*wlr.Surface) usize {
    return if (surface) |s| @intFromPtr(s) else 0;
}

const SurfaceNodeSearch = struct {
    target: *wlr.Surface,
    node: ?*wlr.SceneNode = null,
};

fn findSurfaceNode(
    buffer: *wlr.SceneBuffer,
    _: c_int,
    _: c_int,
    search: *SurfaceNodeSearch,
) void {
    if (search.node != null) return;
    const scene_surface = wlr.SceneSurface.tryFromBuffer(buffer) orelse return;
    if (scene_surface.surface == search.target) search.node = &buffer.node;
}

fn sceneNodeForSurface(surface: *wlr.Surface) ?*wlr.SceneNode {
    const root_data = surface.getRootSurface().data orelse return null;
    const root_node: *wlr.SceneNode = @ptrCast(@alignCast(root_data));
    var search: SurfaceNodeSearch = .{ .target = surface };
    root_node.forEachBuffer(*SurfaceNodeSearch, findSurfaceNode, &search);
    return search.node;
}

/// Called when the cursor position or content in the scene graph changes
pub fn updateState(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrCast(@alignCast(constraint.wlr_constraint.seat.data));

    constraint.maybeActivate();

    if (constraint.state != .active) return;

    var lx: i32 = undefined;
    var ly: i32 = undefined;
    if (!constraint.state.active.node.coords(&lx, &ly)) {
        log.info("deactivating pointer constraint, scene node disabled", .{});
        constraint.deactivate();
        return;
    }

    const sx = constraint.state.active.sx;
    const sy = constraint.state.active.sy;
    const warp_lx = @as(f64, @floatFromInt(lx)) + sx;
    const warp_ly = @as(f64, @floatFromInt(ly)) + sy;
    if (!seat.cursor.wlr_cursor.warp(null, warp_lx, warp_ly)) {
        log.info("deactivating pointer constraint, could not warp cursor", .{});
        constraint.deactivate();
        return;
    }

    // It is possible for the cursor to end up outside of the constraint region despite the warp
    // if, for example, the a keybinding is used to resize the window.
    if (!constraint.wlr_constraint.region.containsPoint(@intFromFloat(sx), @intFromFloat(sy), null)) {
        log.info("deactivating pointer constraint, cursor outside region despite warp", .{});
        constraint.deactivate();
        return;
    }
}

pub fn confine(constraint: *PointerConstraint, dx: *f64, dy: *f64) void {
    assert(constraint.state == .active);
    assert(constraint.wlr_constraint.type == .confined);

    const region = &constraint.wlr_constraint.region;
    const sx = constraint.state.active.sx;
    const sy = constraint.state.active.sy;
    var new_sx: f64 = undefined;
    var new_sy: f64 = undefined;
    assert(wlr.region.confine(region, sx, sy, sx + dx.*, sy + dy.*, &new_sx, &new_sy));

    dx.* = new_sx - sx;
    dy.* = new_sy - sy;

    constraint.state.active.sx = new_sx;
    constraint.state.active.sy = new_sy;
}

pub fn deactivate(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrCast(@alignCast(constraint.wlr_constraint.seat.data));

    assert(seat.cursor.constraint == constraint);
    assert(constraint.state == .active);

    constraint.restoreLockedCursorOrHint(true);

    constraint.state = .inactive;
    constraint.node_destroy.link.remove();
    constraint.wlr_constraint.sendDeactivated();
}

fn restoreLockedCursorOrHint(constraint: *PointerConstraint, send_warp: bool) void {
    const seat: *Seat = @ptrCast(@alignCast(constraint.wlr_constraint.seat.data));

    if (constraint.wlr_constraint.type == .locked) {
        const state = constraint.state.active;
        var sx = state.sx;
        var sy = state.sy;
        if (constraint.wlr_constraint.current.cursor_hint.enabled) {
            sx = constraint.wlr_constraint.current.cursor_hint.x;
            sy = constraint.wlr_constraint.current.cursor_hint.y;
        } else if (seat.cursor.pointer_lock_restore) |restore| {
            if (restore.node == state.node) {
                sx = restore.sx;
                sy = restore.sy;
            }
        }

        const point = seat.cursor.clampSurfacePoint(state.node, sx, sy);
        seat.cursor.restorePointerLock(state.node, point.sx, point.sy, util.msecTimestamp());
        if (send_warp) _ = seat.wlr_seat.pointerWarp(point.sx, point.sy);
        return;
    }

    constraint.warpToHintIfSet();
    seat.cursor.invalidateLastSent();
}

fn warpToHintIfSet(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrCast(@alignCast(constraint.wlr_constraint.seat.data));

    if (constraint.wlr_constraint.current.cursor_hint.enabled) {
        var lx: i32 = undefined;
        var ly: i32 = undefined;
        _ = constraint.state.active.node.coords(&lx, &ly);

        const point = seat.cursor.clampSurfacePoint(constraint.state.active.node, constraint.wlr_constraint.current.cursor_hint.x, constraint.wlr_constraint.current.cursor_hint.y);
        const sx = point.sx;
        const sy = point.sy;
        seat.cursor.invalidateLastSent();
        _ = seat.cursor.wlr_cursor.warp(null, @as(f64, @floatFromInt(lx)) + sx, @as(f64, @floatFromInt(ly)) + sy);
        _ = seat.wlr_seat.pointerWarp(sx, sy);
        seat.cursor.invalidateLastSent();
    }
}

fn handleNodeDestroy(listener: *wl.Listener(void)) void {
    const constraint: *PointerConstraint = @fieldParentPtr("node_destroy", listener);

    log.info("deactivating pointer constraint, scene node destroyed", .{});
    constraint.deactivate();
}

fn handleDestroy(listener: *wl.Listener(*wlr.PointerConstraintV1), _: *wlr.PointerConstraintV1) void {
    const constraint: *PointerConstraint = @fieldParentPtr("destroy", listener);
    const seat: *Seat = @ptrCast(@alignCast(constraint.wlr_constraint.seat.data));

    if (constraint.state == .active) {
        // We can't simply call deactivate() here as it calls sendDeactivated(),
        // which could in the case of a oneshot constraint lifetime recursively
        // destroy the constraint.
        constraint.restoreLockedCursorOrHint(true);
        constraint.node_destroy.link.remove();
    }

    constraint.destroy.link.remove();
    constraint.commit.link.remove();

    if (seat.cursor.constraint == constraint) {
        seat.cursor.constraint = null;
    }

    util.gpa.destroy(constraint);
}

// It is necessary to listen for the commit event rather than the set_region
// event as the latter is not triggered by wlroots when the input region of
// the surface changes.
fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const constraint: *PointerConstraint = @fieldParentPtr("commit", listener);
    const seat: *Seat = @ptrCast(@alignCast(constraint.wlr_constraint.seat.data));

    switch (constraint.state) {
        .active => |state| {
            const sx: i32 = @intFromFloat(state.sx);
            const sy: i32 = @intFromFloat(state.sy);
            if (!constraint.wlr_constraint.region.containsPoint(sx, sy, null)) {
                log.info("deactivating pointer constraint, (input) region change left pointer outside constraint", .{});
                constraint.deactivate();
            }
        },
        .inactive => {
            if (seat.cursor.constraint == constraint) {
                constraint.maybeActivate();
            }
        },
    }
}
