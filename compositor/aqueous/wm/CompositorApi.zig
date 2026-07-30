// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const CompositorApi = @This();

const std = @import("std");

const server = &@import("../main.zig").server;

const Window = @import("../Window.zig");
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");
const Trace = @import("Trace.zig");
const layout = @import("layout/types.zig");
const overview_model = @import("overview/model.zig");
const output_transfer = @import("input/output_transfer.zig");
const wm_config = @import("config/wm.zig");
const xkb = @import("xkbcommon");

pub const WindowHandle = struct {
    ref: Window.Ref,
};

pub const WorkspaceContext = struct {
    output: *Output,
    workspace_number: u32,
};

pub const ClientFullscreenRequest = struct {
    handle: layout.Handle,
    current_output_id: ?u64,
    action: union(enum) {
        enter: ?u64,
        exit,
    },
};

pub const ClientPointer = struct {
    seat: usize,
    x: f64,
    y: f64,
};

pub const ClientResizeEdges = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const ClientWindowRequest = struct {
    handle: layout.Handle,
    action: union(enum) {
        move: ClientPointer,
        resize: struct {
            pointer: ClientPointer,
            edges: ClientResizeEdges,
        },
        maximize,
        unmaximize,
        minimize,
        unminimize,
        activate,
    },
};

pub fn windowHandle(_: CompositorApi, window: *Window) WindowHandle {
    return .{ .ref = window.ref };
}

pub fn resolveWindow(_: CompositorApi, handle: WindowHandle) ?*Window {
    return handle.ref.get();
}

pub fn policyState(handle: layout.Handle) ?*Window.PolicyState {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return null;
    return &window.policy_state;
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

pub fn beginInteractive(_: CompositorApi, handle: layout.Handle, resize: bool) void {
    const ref: Window.Ref = @bitCast(handle);
    if (ref.get()) |window| window.policyBeginInteractive(resize);
}

pub fn endInteractive(_: CompositorApi, handle: layout.Handle) void {
    const ref: Window.Ref = @bitCast(handle);
    if (ref.get()) |window| window.policyEndInteractive();
}

/// Take ownership of the validated pointer grab which produced a client-side
/// move or resize request. Seat.manageFinish() applies the cursor mode change
/// later in the same management transaction.
pub fn beginClientPointerOperation(_: CompositorApi, seat_id: usize) bool {
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| {
        if (@intFromPtr(seat) != seat_id) continue;
        if (seat.op != null or seat.wm_requested.op != .none) return false;
        seat.wm_requested.op = .start_pointer;
        return true;
    }
    return false;
}

pub fn endClientPointerOperation(_: CompositorApi, seat_id: usize) void {
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| {
        if (@intFromPtr(seat) != seat_id) continue;
        if (seat.op != null or seat.wm_requested.op == .start_pointer) {
            seat.wm_requested.op = .end;
            server.wm.dirtyWindowing();
        }
        return;
    }
}

pub fn applyGlobals(
    _: CompositorApi,
    blur_enabled: bool,
    blur_radius: i32,
    blur_passes: i32,
    blur_appearance: @import("../fx.zig").BlurAppearance,
    opacity: f64,
    transition_enabled: bool,
    transition_rate: f64,
) void {
    server.wm.policyApplyGlobals(
        blur_enabled,
        blur_radius,
        blur_passes,
        blur_appearance,
        opacity,
        transition_enabled,
        transition_rate,
    );
}

pub fn focusedWindow(_: CompositorApi) ?layout.Handle {
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| {
        if (seat.policyFocusedHandle()) |handle| return handle;
    }
    return null;
}

/// Whether keyboard focus is intentionally owned by a non-window surface such
/// as a layer-shell launcher, lock surface, or Xwayland override-redirect menu.
/// Automatic window-focus restoration must wait for that surface to release
/// focus instead of recording a request that Seat.manageFinish() cannot apply.
pub fn hasNonWindowKeyboardFocus(_: CompositorApi) bool {
    var seats = server.input_manager.seats.iterator(.forward);
    const seat = seats.next() orelse return false;
    return switch (seat.focused) {
        .none, .window => false,
        .shell_surface, .override_redirect, .lock_surface, .layer_surface => true,
    };
}

pub fn requestFocus(_: CompositorApi, handle: layout.Handle) void {
    var seats = server.input_manager.seats.iterator(.forward);
    if (seats.next()) |seat| seat.policyRequestFocus(handle);
    server.wm.dirtyWindowing();
}

pub fn clearFocus(_: CompositorApi) void {
    var seats = server.input_manager.seats.iterator(.forward);
    if (seats.next()) |seat| seat.policyClearFocus();
    server.wm.dirtyWindowing();
}

pub fn selectOutput(_: CompositorApi, output_id: u64) bool {
    const output = outputById(output_id) orelse return false;
    const box = output.policyFullBox();
    if (output.active_workspace == null or box.width <= 0 or box.height <= 0) return false;
    var seats = server.input_manager.seats.iterator(.forward);
    const seat = seats.next() orelse return false;
    seat.policySelectOutput(output);
    return true;
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

/// Resolve the output selected for output/workspace actions. Explicit seat
/// selection takes precedence over surface focus so selecting an empty output
/// is effective before the requested keyboard-focus clear is committed.
fn selectedOutput(_: CompositorApi) ?*Output {
    var seats = server.input_manager.seats.iterator(.forward);
    if (seats.next()) |seat| {
        if (seat.selected_output) |selected| {
            var outputs = server.om.outputs.iterator(.forward);
            while (outputs.next()) |output| {
                if (output != selected) continue;
                const box = output.policyFullBox();
                if (output.active_workspace != null and box.width > 0 and box.height > 0) return output;
                break;
            }
            // The selected output was disabled or disappeared. Destruction
            // normally clears this eagerly; validation here also covers soft
            // disable and layout removal.
            seat.selected_output = null;
        }

        if (seat.focused == .window) {
            if (seat.focused.window.workspace) |workspace| {
                seat.policySelectOutput(workspace.output);
                return workspace.output;
            }
        }

        // A configured primary is the deterministic initial/fallback output.
        // Explicit output selection and focused windows above still win, so a
        // config reload never steals an established user focus target.
        if (server.aqueous.output_service.primaryOutput()) |output| {
            seat.policySelectOutput(output);
            return output;
        }

        if (server.om.outputAt(seat.cursor.wlr_cursor.x, seat.cursor.wlr_cursor.y)) |wlr_output| {
            if (wlr_output.data) |data| {
                const output: *Output = @ptrCast(@alignCast(data));
                if (output.active_workspace != null) {
                    seat.policySelectOutput(output);
                    return output;
                }
            }
        }
    }

    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| if (output.active_workspace != null) {
        var fallback_seats = server.input_manager.seats.iterator(.forward);
        if (fallback_seats.next()) |seat| seat.policySelectOutput(output);
        return output;
    };
    return null;
}

pub fn selectedOutputId(api: CompositorApi) ?u64 {
    return (api.selectedOutput() orelse return null).policyId();
}

pub fn workspaceContext(api: CompositorApi) ?WorkspaceContext {
    const output = api.selectedOutput() orelse return null;
    return .{
        .output = output,
        .workspace_number = output.policyActiveWorkspaceNumber(),
    };
}

pub fn windowOnWorkspace(_: CompositorApi, handle: layout.Handle, output_id: u64, workspace_number: u32) bool {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return false;
    const workspace = window.workspace orelse return false;
    return workspace.output.policyId() == output_id and workspace.policyNumber() == workspace_number;
}

pub fn overviewWindowDisappearing(_: CompositorApi, handle: layout.Handle) bool {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return true;
    // Window.manageStart() advances closing windows back to .init before the
    // integrated policy receives its snapshot. A card can only have reached
    // .init from .closing, since overview membership is frozen from mapped
    // windows and newly admitted windows cancel the overview separately.
    return window.state == .closing or window.state == .init;
}

pub fn windowWorkspace(_: CompositorApi, handle: layout.Handle) ?struct { output_id: u64, workspace_number: u32 } {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return null;
    const workspace = window.workspace orelse return null;
    return .{
        .output_id = workspace.output.policyId(),
        .workspace_number = workspace.policyNumber(),
    };
}

pub const OutputTarget = struct {
    id: u64,
    workspace_number: u32,
    area: layout.Rect,
    usable_area: layout.Rect,
};

/// Resolve the enabled output containing a global logical pointer coordinate.
/// When `nearest` is true, coordinates left behind by a removed output recover
/// to the nearest remaining rectangle with output id as a stable tie-break.
pub fn outputTargetAt(_: CompositorApi, x: f64, y: f64, nearest: bool) ?OutputTarget {
    var best: ?*Output = null;
    var best_distance: f64 = std.math.inf(f64);
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (!output.policyTransferTarget()) continue;
        const box = output.policyFullBox();
        if (box.width <= 0 or box.height <= 0) continue;
        const area: layout.Rect = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        if (output_transfer.containsPoint(area, x, y)) return outputTarget(output);
        if (!nearest or !std.math.isFinite(x) or !std.math.isFinite(y)) continue;

        const right: f64 = @floatFromInt(@as(i64, box.x) + box.width);
        const bottom: f64 = @floatFromInt(@as(i64, box.y) + box.height);
        const closest_x = std.math.clamp(x, @as(f64, @floatFromInt(box.x)), right);
        const closest_y = std.math.clamp(y, @as(f64, @floatFromInt(box.y)), bottom);
        const dx = x - closest_x;
        const dy = y - closest_y;
        const distance = dx * dx + dy * dy;
        if (best == null or distance < best_distance or
            (distance == best_distance and output.policyId() < best.?.policyId()))
        {
            best = output;
            best_distance = distance;
        }
    }
    return if (best) |output| outputTarget(output) else null;
}

fn outputTarget(output: *Output) OutputTarget {
    const box = output.policyFullBox();
    const usable = output.policyUsableBox();
    return .{
        .id = output.policyId(),
        .workspace_number = output.policyActiveWorkspaceNumber(),
        .area = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height },
        .usable_area = .{ .x = usable.x, .y = usable.y, .width = usable.width, .height = usable.height },
    };
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
        server.aqueous.forgetOutput(output_id);
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

/// Construct the compositor visual and compact cards which could not be
/// cloned. The policy retains only the returned prefix.
pub fn showOverview(
    _: CompositorApi,
    output_id: u64,
    cards: []overview_model.Card,
    selected: *layout.Handle,
) !usize {
    const output = outputById(output_id) orelse return error.OutputUnavailable;
    if (!output.policyTransferTarget()) return error.OutputUnavailable;
    output.prepareOverview();
    const accepted = try server.overview.show(
        output,
        output.policyFullBox(),
        cards,
        selected,
    );
    if (output.wlr_output) |wlr_output| wlr_output.scheduleFrame();
    return accepted;
}

pub fn updateOverviewSelection(_: CompositorApi, handle: layout.Handle) void {
    server.overview.setSelected(handle);
}

pub fn removeOverviewWindow(_: CompositorApi, handle: layout.Handle) void {
    server.overview.remove(handle);
}

pub fn hideOverview(_: CompositorApi) void {
    server.overview.hide();
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (output.wlr_output) |wlr_output| wlr_output.scheduleFrame();
    }
}

pub fn refreshPointerFocus(_: CompositorApi) void {
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| seat.cursor.updateState();
}

pub fn sessionUnlocked(_: CompositorApi) bool {
    return server.lock_manager.state == .unlocked;
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

    // Repeat is a keyboard protocol setting, not a libinput option. Apply it
    // independently of XKB so repeat-only configurations and hot reloads work.
    var keyboard_devices = server.input_manager.devices.iterator(.forward);
    while (keyboard_devices.next()) |device| {
        if (!device.virtual and device.wlr_device.type == .keyboard) {
            const keyboard: *@import("../Keyboard.zig") = @ptrCast(@alignCast(device.wlr_device.toKeyboard().data orelse continue));
            keyboard.setRepeatInfo(input.repeat_rate, input.repeat_delay);
        }
    }

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
    /// Complete output rectangle, used by fullscreen and ignore-struts rules.
    area: layout.Rect,
    /// Rectangle remaining after live layer-shell exclusive zones.
    usable_area: layout.Rect,
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
        if (!output.policyExposed()) continue;
        const box = output.policyFullBox();
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
        if (!output.policyExposed()) continue;
        const box = output.policyFullBox();
        if (box.width <= 0 or box.height <= 0) continue;
        const usable_box = output.policyUsableBox();
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
            // unassigned window on the first usable output; ensureWorkspace()
            // assigns it to that output's active workspace during this cycle.
            if (window_snapshot.output_id) |id| {
                if (id != output.policyId()) continue;
            } else {
                const initial_ouput = window.initialOutput() orelse continue;
                if (initial_ouput != output) continue;
            }
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
                .parent = window_snapshot.parent_handle,
                .app_id = app_id,
                .title = title,
                .accepts_focus = window_snapshot.accepts_focus,
                .fullscreen = window_snapshot.fullscreen,
                .scrolling_full_width = window.policy_state.scrolling_full_width,
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
            .usable_area = .{ .x = usable_box.x, .y = usable_box.y, .width = usable_box.width, .height = usable_box.height },
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

/// Collect and consume fullscreen requests emitted by application toplevels or
/// foreign-toplevel controllers while the integrated policy is active. The
/// request fields are cleared only after the result allocation succeeds, so an
/// allocation failure leaves every one-shot request available for a retry.
pub fn takeClientFullscreenRequests(_: CompositorApi, allocator: std.mem.Allocator) ![]ClientFullscreenRequest {
    var count: usize = 0;
    var window_it = server.wm.windows.iterator();
    while (window_it.next()) |window| {
        if (window.wm_scheduled.fullscreen_requested != .no_request) count += 1;
    }

    const requests = try allocator.alloc(ClientFullscreenRequest, count);
    var index: usize = 0;
    window_it = server.wm.windows.iterator();
    while (window_it.next()) |window| {
        const pending = window.wm_scheduled.fullscreen_requested;
        if (pending == .no_request) continue;

        const current_output = if (window.workspace) |workspace|
            workspace.output
        else
            window.initialOutput();
        requests[index] = .{
            .handle = @bitCast(window.ref),
            .current_output_id = if (current_output) |output| output.policyId() else null,
            .action = switch (pending) {
                .no_request => unreachable,
                .fullscreen => |output_hint| .{ .enter = if (output_hint) |output| output.policyId() else null },
                .exit => .exit,
            },
        };
        index += 1;
    }

    // No Wayland callback can interleave with this synchronous collection, so
    // the second pass clears exactly the requests represented in the slice.
    window_it = server.wm.windows.iterator();
    while (window_it.next()) |window| {
        if (window.wm_scheduled.fullscreen_requested != .no_request) {
            window.wm_scheduled.fullscreen_requested = .no_request;
        }
    }
    return requests;
}

/// Collect the client-originated operations which are meaningful to the
/// integrated window policy. Policy decides whether the target's current state
/// permits each request; collection always consumes the one-shot fields so an
/// ignored request cannot be replayed on a later state transition.
pub fn takeClientWindowRequests(_: CompositorApi, allocator: std.mem.Allocator) ![]ClientWindowRequest {
    var count: usize = 0;
    var window_it = server.wm.windows.iterator();
    while (window_it.next()) |window| {
        if (window.wm_scheduled.pointer_move_requested != null) count += 1;
        if (window.wm_scheduled.pointer_resize_requested != null) count += 1;
        if (window.wm_scheduled.maximize_requested != .no_request) count += 1;
        if (window.wm_scheduled.minimize_requested != .no_request) count += 1;
        if (window.wm_scheduled.activate_requested) count += 1;
    }

    const requests = try allocator.alloc(ClientWindowRequest, count);
    var index: usize = 0;
    window_it = server.wm.windows.iterator();
    while (window_it.next()) |window| {
        const handle: layout.Handle = @bitCast(window.ref);
        if (window.wm_scheduled.pointer_move_requested) |seat| {
            requests[index] = .{
                .handle = handle,
                .action = .{ .move = clientPointer(seat) },
            };
            index += 1;
        }
        if (window.wm_scheduled.pointer_resize_requested) |data| {
            requests[index] = .{
                .handle = handle,
                .action = .{ .resize = .{
                    .pointer = clientPointer(data.seat),
                    .edges = .{
                        .top = data.edges.top,
                        .bottom = data.edges.bottom,
                        .left = data.edges.left,
                        .right = data.edges.right,
                    },
                } },
            };
            index += 1;
        }
        switch (window.wm_scheduled.maximize_requested) {
            .no_request => {},
            .maximize => {
                requests[index] = .{ .handle = handle, .action = .maximize };
                index += 1;
            },
            .unmaximize => {
                requests[index] = .{ .handle = handle, .action = .unmaximize };
                index += 1;
            },
        }
        switch (window.wm_scheduled.minimize_requested) {
            .no_request => {},
            .minimize => {
                requests[index] = .{ .handle = handle, .action = .minimize };
                index += 1;
            },
            .unminimize => {
                requests[index] = .{ .handle = handle, .action = .unminimize };
                index += 1;
            },
        }
        if (window.wm_scheduled.activate_requested) {
            requests[index] = .{ .handle = handle, .action = .activate };
            index += 1;
        }
    }
    std.debug.assert(index == requests.len);

    window_it = server.wm.windows.iterator();
    while (window_it.next()) |window| {
        window.wm_scheduled.pointer_move_requested = null;
        window.wm_scheduled.pointer_resize_requested = null;
        window.wm_scheduled.maximize_requested = .no_request;
        window.wm_scheduled.minimize_requested = .no_request;
        window.wm_scheduled.activate_requested = false;
    }
    return requests;
}

fn clientPointer(seat: *Seat) ClientPointer {
    return .{
        .seat = @intFromPtr(seat),
        .x = seat.cursor.wlr_cursor.x,
        .y = seat.cursor.wlr_cursor.y,
    };
}

fn outputById(output_id: u64) ?*Output {
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| if (output.policyId() == output_id) return output;
    return null;
}

/// Assign a newly admitted window to the active workspace without disturbing
/// an existing user or rule assignment.
pub fn ensureWorkspace(_: CompositorApi, handle: layout.Handle, output_id: u64) void {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return;
    if (window.workspace != null) return;
    const output = outputById(output_id) orelse return;
    if (output.active_workspace) |workspace| window.setWorkspace(workspace);
}

/// Place a newly-parented transient beside its owner. This is edge-triggered
/// by the policy so later explicit workspace rules and user moves still win.
pub fn moveToParentWorkspace(_: CompositorApi, handle: layout.Handle) void {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return;
    const parent = window.getParent() orelse return;
    const workspace = parent.workspace orelse return;
    window.setWorkspace(workspace);
}

pub fn windowGeometry(_: CompositorApi, handle: layout.Handle) ?layout.Rect {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return null;
    if (window.box.width <= 0 or window.box.height <= 0) return null;
    return .{ .x = window.box.x, .y = window.box.y, .width = window.box.width, .height = window.box.height };
}

pub fn applyRuleWorkspace(_: CompositorApi, handle: layout.Handle, output_id: u64, workspace_number: u32) bool {
    if (workspace_number == 0) return false;
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return false;
    const output = outputById(output_id) orelse return false;
    const workspace = output.policyWorkspaceAt(workspace_number) orelse return false;
    if (window.workspace != workspace) window.setWorkspace(workspace);
    return true;
}

pub fn applyRuleVisual(_: CompositorApi, handle: layout.Handle, blur: ?bool, opacity: ?f64, force_ssd: bool) void {
    const ref: Window.Ref = @bitCast(handle);
    if (ref.get()) |window| window.policyApplyVisualRule(blur, opacity, force_ssd);
}

pub fn setFullscreen(_: CompositorApi, handle: layout.Handle, output_id: u64) bool {
    const ref: Window.Ref = @bitCast(handle);
    const window = ref.get() orelse return false;
    const output = outputById(output_id) orelse return false;
    window.policySetFullscreen(output);
    return true;
}

pub fn clearFullscreen(_: CompositorApi, handle: layout.Handle) void {
    const ref: Window.Ref = @bitCast(handle);
    if (ref.get()) |window| window.policyClearFullscreen();
}

pub fn clearOtherFullscreen(_: CompositorApi, output_id: u64, except: layout.Handle) void {
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        const state = window.policySnapshot();
        if (state.handle == except or !state.fullscreen or state.output_id != output_id) continue;
        window.policy_state.overrideFullscreen();
        window.policyClearFullscreen();
    }
}

fn freeWindowStrings(allocator: std.mem.Allocator, windows: []const layout.Window) void {
    for (windows) |window| {
        if (window.app_id) |value| allocator.free(value);
        if (window.title) |value| allocator.free(value);
    }
}

pub fn applyPlacement(
    _: CompositorApi,
    placement: layout.Placement,
    focused: bool,
) void {
    const ref: Window.Ref = @bitCast(placement.handle);
    const window = ref.get() orelse return;
    const border_color = if (focused)
        placement.border.focused
    else
        placement.border.normal;
    window.policyApplyPlacement(
        placement.geometry.x,
        placement.geometry.y,
        placement.geometry.width,
        placement.geometry.height,
        if (placement.clip) |clip| .{
            .x = clip.x,
            .y = clip.y,
            .width = clip.width,
            .height = clip.height,
        } else null,
        placement.visible,
        @intCast(@max(0, placement.border.width)),
        border_color,
        placement.tiled,
        placement.maximized,
    );
}
