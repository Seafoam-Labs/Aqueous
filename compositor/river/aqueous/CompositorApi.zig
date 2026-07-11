// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const CompositorApi = @This();

const std = @import("std");

const server = &@import("../main.zig").server;

const Window = @import("../Window.zig");
const Trace = @import("Trace.zig");
const layout = @import("layout/types.zig");

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
    var geometry = std.hash.Wyhash.init(0);
    var window_it = server.wm.windows.iterator();
    while (window_it.next()) |window| window.policyTrace(&geometry);

    var workspaces = std.hash.Wyhash.init(0);
    var output_it = server.om.outputs.iterator(.forward);
    while (output_it.next()) |output| output.policyTrace(&workspaces);

    var focus = std.hash.Wyhash.init(0);
    var seat_it = server.input_manager.seats.iterator(.forward);
    while (seat_it.next()) |seat| {
        const handle = seat.policyFocusedHandle() orelse 0;
        focus.update(std.mem.asBytes(&handle));
    }

    return .{
        .windows = server.wm.windows.count,
        .rendering_order_hash = server.wm.rendering_requested.order_hash,
        .geometry_hash = geometry.final(),
        .workspace_hash = workspaces.final(),
        .focus_hash = focus.final(),
    };
}

pub fn requestManageCycle(_: CompositorApi) void {
    server.wm.dirtyWindowing();
}

pub fn focusedWindow(_: CompositorApi) ?layout.Handle {
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| {
        if (seat.policyFocusedHandle()) |handle| return handle;
    }
    return null;
}

pub fn requestFocus(_: CompositorApi, handle: layout.Handle) void {
    var seats = server.input_manager.seats.iterator(.forward);
    if (seats.next()) |seat| seat.policyRequestFocus(handle);
}

pub const PolicyOutput = struct {
    id: u64,
    area: layout.Rect,
    windows: []const layout.Window,
    window_start: usize,
};

pub const PolicySnapshot = struct {
    outputs: []PolicyOutput,
    windows: []layout.Window,

    pub fn deinit(policy_snapshot: *PolicySnapshot, allocator: std.mem.Allocator) void {
        freeWindowStrings(allocator, policy_snapshot.windows);
        allocator.free(policy_snapshot.outputs);
        allocator.free(policy_snapshot.windows);
        policy_snapshot.* = undefined;
    }
};

pub fn policySnapshot(_: CompositorApi, allocator: std.mem.Allocator) !PolicySnapshot {
    var output_count: usize = 0;
    var output_it = server.om.outputs.iterator(.forward);
    while (output_it.next()) |output| {
        const box = output.policyBox();
        if (box.width > 0 and box.height > 0) output_count += 1;
    }

    const outputs = try allocator.alloc(PolicyOutput, output_count);
    errdefer allocator.free(outputs);
    var windows: std.ArrayListUnmanaged(layout.Window) = .empty;
    errdefer {
        freeWindowStrings(allocator, windows.items);
        windows.deinit(allocator);
    }
    try windows.ensureTotalCapacity(allocator, server.wm.windows.count);

    output_it = server.om.outputs.iterator(.forward);
    var output_index: usize = 0;
    while (output_it.next()) |output| {
        const box = output.policyBox();
        if (box.width <= 0 or box.height <= 0) continue;
        const start = windows.items.len;
        var window_it = server.wm.windows.iterator();
        while (window_it.next()) |window| {
            const window_snapshot = window.policySnapshot();
            if (!window_snapshot.active or window_snapshot.output_id != output.policyId()) continue;
            const app_id = if (window_snapshot.app_id) |value| try allocator.dupe(u8, std.mem.span(value)) else null;
            const title = if (window_snapshot.title) |value|
                allocator.dupe(u8, std.mem.span(value)) catch |err| {
                    if (app_id) |owned| allocator.free(owned);
                    return err;
                }
            else
                null;
            windows.appendAssumeCapacity(.{
                .handle = window_snapshot.handle,
                .app_id = app_id,
                .title = title,
                .fullscreen = window_snapshot.fullscreen,
                .min_width = window_snapshot.min_width,
                .min_height = window_snapshot.min_height,
            });
        }
        outputs[output_index] = .{
            .id = output.policyId(),
            .area = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height },
            .windows = undefined,
            .window_start = start,
        };
        output_index += 1;
    }

    const owned_windows = try windows.toOwnedSlice(allocator);
    for (outputs, 0..) |*output, index| {
        const end = if (index + 1 < outputs.len)
            outputs[index + 1].window_start
        else
            owned_windows.len;
        output.windows = owned_windows[output.window_start..end];
    }
    return .{ .outputs = outputs, .windows = owned_windows };
}

fn freeWindowStrings(allocator: std.mem.Allocator, windows: []const layout.Window) void {
    for (windows) |window| {
        if (window.app_id) |value| allocator.free(value);
        if (window.title) |value| allocator.free(value);
    }
}

pub fn applyPlacement(_: CompositorApi, placement: layout.Placement) void {
    const ref: Window.Ref = @bitCast(placement.handle);
    const window = ref.get() orelse return;
    const border_color = if ((CompositorApi{}).focusedWindow() == placement.handle)
        placement.border.focused
    else
        placement.border.normal;
    window.policyApplyPlacement(
        placement.geometry.x,
        placement.geometry.y,
        placement.geometry.width,
        placement.geometry.height,
        placement.visible,
        @intCast(@max(0, placement.border.width)),
        border_color,
    );
}
