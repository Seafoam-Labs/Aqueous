// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const c = @import("c");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const Aqueous = @import("wm/Aqueous.zig");
const server = &@import("main.zig").server;
const drag_geometry = @import("wm/input/drag.zig");
const Native = c.struct_wlr_xdg_toplevel_drag_v1;

pub fn init(display: *wl.Server) !*wl.Global {
    return @ptrCast(c.wlr_xdg_toplevel_drag_manager_v1_create(@ptrCast(display)) orelse return error.OutOfMemory);
}

/// Embedded in Seat. wlroots owns the DnD grab and the protocol object; the
/// policy movement has no pointer operation to release on completion.
pub const Operation = struct {
    object: ?*Native = null,
    seat: ?*Seat = null,
    movement: ?Aqueous.Drag = null,
    attachment: ?u64 = null,
    stopped: bool = false,
    change: wl.Listener(void) = .init(handleChange),
    destroy: wl.Listener(void) = .init(handleDestroy),

    pub fn start(op: *Operation, seat: *Seat, drag: *wlr.Drag) void {
        const source = drag.source orelse return;
        const object: *Native = c.wlr_xdg_toplevel_drag_v1_try_from_data_source(@ptrCast(source)) orelse return;
        op.object = object;
        op.seat = seat;
        const change: *wl.Signal(void) = @ptrCast(&object.events.change);
        const destroy: *wl.Signal(void) = @ptrCast(&object.events.destroy);
        change.add(&op.change);
        destroy.add(&op.destroy);
        op.sync();
        seat.cursor.refreshDragTarget();
    }

    pub fn window(op: *const Operation) ?*Window {
        const object = op.object orelse return null;
        if (!object.active or object.ended) return null;
        const native = object.toplevel orelse return null;
        const top: *wlr.XdgToplevel = @ptrCast(@alignCast(native));
        const data = top.base.data orelse return null;
        const toplevel: *XdgToplevel = @ptrCast(@alignCast(data));
        return toplevel.window;
    }

    fn position(op: *const Operation) ?struct { x: f64, y: f64 } {
        const seat = op.seat orelse return null;
        const drag = seat.wlr_seat.drag orelse return null;
        return switch (drag.grab_type) {
            .keyboard_pointer => .{ .x = seat.cursor.wlr_cursor.x, .y = seat.cursor.wlr_cursor.y },
            .keyboard_touch => if (seat.cursor.touch_points.get(drag.grab_touch_id)) |p| .{ .x = p.lx, .y = p.ly } else null,
            .keyboard => null,
        };
    }

    fn finish(op: *Operation) void {
        const movement = op.movement orelse return;
        op.movement = null;
        server.aqueous.finishDrag(movement);
    }

    pub fn syncWindow(op: *Operation, handle: u64) void {
        const attached = op.window() orelse return;
        if (@as(u64, @bitCast(attached.ref)) == handle) op.sync();
    }

    pub fn stopWindow(op: *Operation, handle: u64) void {
        if (op.movement) |movement| if (movement.handle == handle) {
            op.stopped = true;
            op.finish();
        };
    }

    pub fn validate(op: *Operation) void {
        const movement = op.movement orelse return;
        const attached = op.window() orelse {
            op.finish();
            return;
        };
        const workspace = attached.workspace;
        if (attached.state != .mapped or workspace == null or
            workspace.?.output.policyId() != movement.layout_key.output or
            workspace.?.policyNumber() != movement.layout_key.workspace or
            workspace.?.output.policyActiveWorkspaceNumber() != movement.layout_key.workspace or
            !server.aqueous.clientDragEligible(movement) or server.lock_manager.state != .unlocked)
        {
            op.stopped = true;
            op.finish();
        }
    }

    fn sync(op: *Operation) void {
        const attached = op.window();
        const attachment: ?u64 = if (attached) |w| @bitCast(w.ref) else null;
        if (op.attachment != attachment) {
            op.finish();
            op.attachment = attachment;
            op.stopped = false;
        }
        op.validate();
        if (op.movement != null or op.stopped) return;
        const current = attached orelse return;
        if (current.state != .mapped or server.lock_manager.state != .unlocked) return;
        const workspace = current.workspace orelse return;
        if (workspace.output.policyActiveWorkspaceNumber() != workspace.policyNumber()) return;
        const seat = op.seat orelse return;
        const pos = op.position() orelse return;
        const object = op.object orelse return;
        const handle: u64 = @bitCast(current.ref);
        var movement = server.aqueous.createClientDrag(handle, .{
            .seat = @intFromPtr(seat),
            .x = pos.x,
            .y = pos.y,
        }, .move_floating, .{}, false) orelse return;
        // Native xdg window geometry and pointer layout positions are both
        // logical coordinates. Buffer/output scale must not be applied again.
        movement.start.x = drag_geometry.toplevelDragOrigin(pos.x, object.x_offset);
        movement.start.y = drag_geometry.toplevelDragOrigin(pos.y, object.y_offset);
        op.movement = movement;
        server.aqueous.updateInteractiveDrag(&op.movement.?, pos.x, pos.y);
    }

    pub fn motion(op: *Operation) void {
        op.sync();
        const pos = op.position() orelse return;
        if (op.movement) |*movement| {
            if (movement.last_pointer_x != pos.x or movement.last_pointer_y != pos.y)
                server.aqueous.updateInteractiveDrag(movement, pos.x, pos.y);
        }
    }

    pub fn cancel(op: *Operation) void {
        const object = op.object orelse return;
        // A completed drop may still be transferring data while another
        // pointer button keeps the grab alive. Do not cancel that transfer.
        if (!object.active) return;
        if (object.source) |source| c.wlr_data_source_destroy(source);
    }

    pub fn deinit(op: *Operation) void {
        if (op.object == null) return;
        op.finish();
        op.change.link.remove();
        op.destroy.link.remove();
        op.object = null;
        op.seat = null;
        op.attachment = null;
        op.stopped = false;
    }

    fn handleChange(listener: *wl.Listener(void)) void {
        const op: *Operation = @fieldParentPtr("change", listener);
        op.sync();
        server.wm.dirtyWindowing();
        // End notifications can run inside source destruction. Creating a
        // fresh offer there would append a source listener during its teardown.
        if (op.object) |object| if (object.active) {
            if (op.seat) |seat| seat.cursor.refreshDragTarget();
        };
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const op: *Operation = @fieldParentPtr("destroy", listener);
        op.deinit();
        server.wm.dirtyWindowing();
    }
};
