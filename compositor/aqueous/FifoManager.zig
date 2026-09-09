// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! The pinned wlroots owns FIFO resources and cached surface state. Aqueous
//! supplies submission results and presentation events from its render path.
const FifoManager = @This();
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const c = @import("c");

manager: *c.struct_wlr_fifo_manager_v1,

pub fn init(display: *wl.Server) !FifoManager {
    return .{ .manager = c.wlr_fifo_manager_v1_create(@ptrCast(display)) orelse return error.OutOfMemory };
}

pub fn global(fifo: FifoManager) *wl.Global {
    return @ptrCast(c.wlr_fifo_manager_v1_get_global(fifo.manager));
}

pub fn pending(fifo: FifoManager, output: *wlr.Output) bool {
    return c.wlr_fifo_manager_v1_output_pending(fifo.manager, @ptrCast(output));
}

pub fn prepare(fifo: FifoManager, output: *wlr.Output) void {
    c.wlr_fifo_manager_v1_prepare(fifo.manager, @ptrCast(output));
}

pub fn finish(fifo: FifoManager, output: *wlr.Output, committed: bool) void {
    c.wlr_fifo_manager_v1_finish(fifo.manager, @ptrCast(output), committed);
}

pub fn present(fifo: FifoManager, output: *wlr.Output, event: *const wlr.Output.event.Present) bool {
    return c.wlr_fifo_manager_v1_present(fifo.manager, @ptrCast(output), @ptrCast(event));
}
