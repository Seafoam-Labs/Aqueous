// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const CompositorApi = @This();

const server = &@import("../main.zig").server;

const Window = @import("../Window.zig");
const Trace = @import("Trace.zig");

pub const WindowHandle = struct {
    ref: Window.Ref,
};

pub fn windowHandle(_: CompositorApi, window: *Window) WindowHandle {
    return .{ .ref = window.ref };
}

pub fn resolveWindow(_: CompositorApi, handle: WindowHandle) ?*Window {
    return handle.ref.get();
}

pub fn snapshot(_: CompositorApi) Trace.Snapshot {
    return .{
        .windows = server.wm.windows.count,
        .rendering_order_hash = server.wm.rendering_requested.order_hash,
    };
}

pub fn requestManageCycle(_: CompositorApi) void {
    server.wm.dirtyWindowing();
}
