// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const XdgDialogManager = @This();
const c = @import("c");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const XdgToplevel = @import("XdgToplevel.zig");
const server = &@import("main.zig").server;

manager: *c.struct_wlr_xdg_wm_dialog_v1,
new_dialog: wl.Listener(*c.struct_wlr_xdg_dialog_v1) = .init(handleNewDialog),

pub fn init(display: *wl.Server) !XdgDialogManager {
    return .{ .manager = c.wlr_xdg_wm_dialog_v1_create(@ptrCast(display), 1) orelse return error.OutOfMemory };
}

pub fn listen(manager: *XdgDialogManager) void {
    const signal: *wl.Signal(*c.struct_wlr_xdg_dialog_v1) = @ptrCast(&manager.manager.events.new_dialog);
    signal.add(&manager.new_dialog);
}

pub fn deinit(manager: *XdgDialogManager) void {
    manager.new_dialog.link.remove();
}

pub fn global(manager: XdgDialogManager) *wl.Global {
    return @ptrCast(manager.manager.global);
}

fn handleNewDialog(_: *wl.Listener(*c.struct_wlr_xdg_dialog_v1), dialog: *c.struct_wlr_xdg_dialog_v1) void {
    const top: *wlr.XdgToplevel = @ptrCast(@alignCast(dialog.xdg_toplevel));
    // new_dialog can precede the initial surface commit/new_toplevel event.
    const data = top.base.data orelse return;
    const toplevel: *XdgToplevel = @ptrCast(@alignCast(data));
    toplevel.dialog.attach(dialog);
}

/// Embedded in XdgToplevel: its address remains stable until both listeners
/// have been removed. wlroots owns the protocol object and its modal state.
pub const Dialog = struct {
    object: ?*c.struct_wlr_xdg_dialog_v1 = null,
    destroy: wl.Listener(void) = .init(handleDestroy),
    set_modal: wl.Listener(void) = .init(handleSetModal),

    pub fn discover(dialog: *Dialog, top: *wlr.XdgToplevel) void {
        if (c.wlr_xdg_dialog_v1_try_from_wlr_xdg_toplevel(@ptrCast(top))) |object| dialog.attach(object);
    }

    fn attach(dialog: *Dialog, object: *c.struct_wlr_xdg_dialog_v1) void {
        if (dialog.object != null) return;
        dialog.object = object;
        const destroy_signal: *wl.Signal(void) = @ptrCast(&object.events.destroy);
        const modal_signal: *wl.Signal(void) = @ptrCast(&object.events.set_modal);
        destroy_signal.add(&dialog.destroy);
        modal_signal.add(&dialog.set_modal);
        server.wm.dirtyWindowing();
    }

    pub fn deinit(dialog: *Dialog) void {
        if (dialog.object == null) return;
        dialog.destroy.link.remove();
        dialog.set_modal.link.remove();
        dialog.object = null;
        server.wm.dirtyWindowing();
    }

    pub fn modal(dialog: Dialog) bool {
        return if (dialog.object) |object| object.modal else false;
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const dialog: *Dialog = @fieldParentPtr("destroy", listener);
        // The addon still exists during this signal. Never rediscover it here.
        dialog.deinit();
    }

    fn handleSetModal(_: *wl.Listener(void)) void {
        server.wm.dirtyWindowing();
    }
};
