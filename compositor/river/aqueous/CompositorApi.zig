// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const CompositorApi = @This();

const std = @import("std");

const server = &@import("../main.zig").server;

const Window = @import("../Window.zig");
const Output = @import("../Output.zig");
const Trace = @import("Trace.zig");
const layout = @import("layout/types.zig");
const wm_config = @import("config/wm.zig");
const xkb = @import("xkbcommon");

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

pub fn applyGlobals(_: CompositorApi, blur_enabled: bool, blur_radius: i32, blur_passes: i32, opacity: f64, transition_enabled: bool, transition_rate: f64) void {
    server.wm.policyApplyGlobals(blur_enabled, blur_radius, blur_passes, opacity, transition_enabled, transition_rate);
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
    server.wm.dirtyWindowing();
}

pub fn closeWindow(_: CompositorApi, handle: layout.Handle) void {
    const ref: Window.Ref = @bitCast(handle);
    if (ref.get()) |window| window.close();
}

pub fn focusedContext(_: CompositorApi) ?struct { window: *Window, output: *Output, workspace_number: u32 } {
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| switch (seat.focused) {
        .window => |window| {
            const workspace = window.workspace orelse return null;
            return .{ .window = window, .output = workspace.output, .workspace_number = workspace.policyNumber() };
        },
        else => {},
    };
    return null;
}

pub fn directionalNeighbor(_: CompositorApi, handle: layout.Handle, dx: i32, dy: i32) ?layout.Handle {
    const ref: Window.Ref = @bitCast(handle);
    const origin = ref.get() orelse return null;
    const workspace = origin.workspace orelse return null;
    const ox = origin.box.x + @divTrunc(origin.box.width, 2);
    const oy = origin.box.y + @divTrunc(origin.box.height, 2);
    var best: ?layout.Handle = null;
    var best_score: i64 = std.math.maxInt(i64);
    var windows = server.wm.windows.iterator();
    while (windows.next()) |candidate| {
        if (candidate == origin or candidate.workspace != workspace or candidate.state == .closing or candidate.state == .init) continue;
        const cx = candidate.box.x + @divTrunc(candidate.box.width, 2);
        const cy = candidate.box.y + @divTrunc(candidate.box.height, 2);
        const delta_x = cx - ox;
        const delta_y = cy - oy;
        if ((dx < 0 and delta_x >= 0) or (dx > 0 and delta_x <= 0) or (dy < 0 and delta_y >= 0) or (dy > 0 and delta_y <= 0)) continue;
        const primary: i64 = @intCast(if (dx != 0) @abs(delta_x) else @abs(delta_y));
        const secondary: i64 = @intCast(if (dx != 0) @abs(delta_y) else @abs(delta_x));
        const score = primary * 1_000_000 + secondary;
        if (score < best_score) {
            best_score = score;
            best = @bitCast(candidate.ref);
        }
    }
    return best;
}

pub fn activateWorkspace(_: CompositorApi, output_id: u64, number: u32) bool {
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| if (output.policyId() == output_id) {
        const workspace = output.policyWorkspaceAt(number) orelse return false;
        output.activateWorkspace(workspace);
        return true;
    };
    return false;
}

pub fn moveWindowToWorkspace(_: CompositorApi, handle: layout.Handle, output_id: u64, number: u32) bool {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return false;
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| if (output.policyId() == output_id) {
        const workspace = output.policyWorkspaceAt(number) orelse return false;
        window.setWorkspace(workspace);
        return true;
    };
    return false;
}

pub fn suppressPointerConstraints(_: CompositorApi, suppressed: bool) void {
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| seat.cursor.setConstraintsSuppressed(suppressed);
}

pub fn windowAt(_: CompositorApi, x: f64, y: f64) ?struct { handle: layout.Handle, geometry: layout.Rect } {
    const result = server.scene.at(x, y) orelse return null;
    return switch (result.data) {
        .window => |window| .{
            .handle = @bitCast(window.ref),
            .geometry = .{ .x = window.box.x, .y = window.box.y, .width = window.box.width, .height = window.box.height },
        },
        else => null,
    };
}

pub fn applyInputConfig(_: CompositorApi, input: wm_config.Input) void {
    var devices = server.libinput_config.devices.iterator(.forward);
    while (devices.next()) |device| device.policyApply(input);

    if (input.xkb_layout.empty() and input.xkb_variant.empty() and input.xkb_options.empty()) return;
    var layout_buf: [257]u8 = undefined;
    var variant_buf: [257]u8 = undefined;
    var options_buf: [257]u8 = undefined;
    const layout_z: ?[:0]const u8 = if (!input.xkb_layout.empty()) blk: {
        @memcpy(layout_buf[0..input.xkb_layout.len], input.xkb_layout.slice());
        layout_buf[input.xkb_layout.len] = 0;
        break :blk layout_buf[0..input.xkb_layout.len :0];
    } else null;
    const variant_z: ?[:0]const u8 = if (!input.xkb_variant.empty()) blk: {
        @memcpy(variant_buf[0..input.xkb_variant.len], input.xkb_variant.slice());
        variant_buf[input.xkb_variant.len] = 0;
        break :blk variant_buf[0..input.xkb_variant.len :0];
    } else null;
    const options_z: ?[:0]const u8 = if (!input.xkb_options.empty()) blk: {
        @memcpy(options_buf[0..input.xkb_options.len], input.xkb_options.slice());
        options_buf[input.xkb_options.len] = 0;
        break :blk options_buf[0..input.xkb_options.len :0];
    } else null;
    const names: xkb.RuleNames = .{ .rules = null, .model = null, .layout = if (layout_z) |v| v.ptr else null, .variant = if (variant_z) |v| v.ptr else null, .options = if (options_z) |v| v.ptr else null };
    const keymap = xkb.Keymap.newFromNames(server.xkb_config.context, &names, .no_flags) orelse {
        std.log.scoped(.aqueous).err("failed to compile configured XKB keymap", .{});
        return;
    };
    defer keymap.unref();
    server.xkb_config.default_keymap.unref();
    server.xkb_config.default_keymap = keymap.ref();
    var all_devices = server.input_manager.devices.iterator(.forward);
    while (all_devices.next()) |device| {
        if (!device.virtual and device.wlr_device.type == .keyboard) {
            const keyboard: *@import("../Keyboard.zig") = @ptrCast(@alignCast(device.wlr_device.toKeyboard().data orelse continue));
            keyboard.setKeymap(keymap);
        }
    }
}

pub const PolicyOutput = struct {
    id: u64,
    name: []const u8,
    make: ?[]const u8,
    model: ?[]const u8,
    serial: ?[]const u8,
    workspace_number: u32,
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
            if (!window_snapshot.active) continue;
            // A newly created xdg_toplevel has to receive its initial configure
            // before it can map. Workspace assignment historically happened in
            // Window.map(), so requiring an output here creates a deadlock for
            // the integrated policy: the window cannot be arranged/configured
            // until it maps, and cannot map until it is configured. Admit an
            // unassigned window on the first usable output; applyRule() below
            // assigns it to that output's active workspace during this cycle.
            if (window_snapshot.output_id) |id| {
                if (id != output.policyId()) continue;
            } else if (output_index != 0) continue;
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
                .max_width = window_snapshot.max_width,
                .max_height = window_snapshot.max_height,
            });
        }
        const identity = output.policyIdentity();
        outputs[output_index] = .{
            .id = output.policyId(),
            .name = identity.name,
            .make = identity.make,
            .model = identity.model,
            .serial = identity.serial,
            .workspace_number = output.policyActiveWorkspaceNumber(),
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

pub fn applyRule(_: CompositorApi, handle: layout.Handle, output_id: u64, workspace_number: u32, fullscreen: bool, blur: ?bool, opacity: ?f64, force_ssd: bool) void {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return;
    var target_output: ?*@import("../Output.zig") = null;
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| if (output.policyId() == output_id) {
        target_output = output;
        break;
    };
    if (target_output) |output| {
        const workspace = if (workspace_number > 0)
            output.policyWorkspaceAt(workspace_number)
        else
            output.active_workspace;
        if (workspace) |target| {
            if (window.workspace != target) window.setWorkspace(target);
        }
    }
    window.policyApplyRule(target_output, fullscreen, blur, opacity, force_ssd);
}

pub fn clearFullscreen(_: CompositorApi, handle: layout.Handle) void {
    const ref: Window.Ref = @bitCast(handle);
    if (ref.get()) |window| window.policyClearFullscreen();
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
