// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const policy = @import("tablet");
const wlr = @import("wlroots");
const c = @import("c");
const server = &@import("main.zig").server;
const InputDevice = @import("InputDevice.zig");
const OutputManager = @import("OutputManager.zig");

pub const Status = enum { unconfigured, disabled, desktop, resolved, waiting_output, ambiguous_output };
pub const Mapping = struct {
    status: Status = .unconfigured,
    output_id: u64 = 0,
    box: policy.Box = .{},
    transform: u3 = 0,
    pub fn blocked(m: Mapping) bool {
        return switch (m.status) {
            .disabled, .waiting_output, .ambiguous_output => true,
            else => false,
        };
    }
};

pub fn identity(device: *const InputDevice) policy.Identity {
    const handle = device.wlr_device.getLibinputDevice();
    return .{
        .name = if (device.wlr_device.name) |name| std.mem.span(name) else "",
        .tablet = device.wlr_device.type == .tablet,
        .virtual = device.virtual,
        .vendor = if (handle) |h| std.math.cast(u16, c.libinput_device_get_id_vendor(@ptrCast(h))) else null,
        .product = if (handle) |h| std.math.cast(u16, c.libinput_device_get_id_product(@ptrCast(h))) else null,
        .path = device.identity_path.slice(),
    };
}

pub fn initializeIdentity(device: *InputDevice) void {
    const h = device.wlr_device.getLibinputDevice() orelse return;
    const udev = c.libinput_device_get_udev_device(@ptrCast(h)) orelse return;
    defer _ = c.udev_device_unref(udev);
    if (c.udev_device_get_property_value(udev, "ID_PATH")) |path| {
        device.identity_path = policy.Text.init(std.mem.span(path)) catch .{};
    }
}

pub fn resolve(device: *const InputDevice) Mapping {
    if (!server.aqueous.mode.runsInternal()) return .{};
    const config = &server.aqueous.config.wm.input.tablets;
    if (!config.valid) return .{};
    const rule = config.select(identity(device)) orelse return .{};
    if (!rule.enabled) return .{ .status = .disabled };
    if (rule.mapping == .desktop) return .{ .status = .desktop };
    var result: Mapping = .{ .status = .waiting_output };
    var matches: usize = 0;
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        const native = output.wlr_output orelse continue;
        var hash: [71]u8 = undefined;
        const selected = if (!rule.output_edid.empty()) std.ascii.eqlIgnoreCase(rule.output_edid.slice(), OutputManager.outputIdentityHash(native, &hash) orelse "") else std.mem.eql(u8, rule.output.slice(), std.mem.span(native.name));
        if (!selected) continue;
        matches += 1;
        if (!native.enabled or output.current.state != .enabled or output.scheduled.state == .destroying or !output.current.mirror_of.empty()) continue;
        var box: wlr.Box = undefined;
        server.om.output_layout.getBox(native, &box);
        if (box.empty()) continue;
        result = .{ .status = .resolved, .output_id = output.policyId(), .transform = @intCast(@intFromEnum(native.transform)), .box = .{ .x = @floatFromInt(box.x), .y = @floatFromInt(box.y), .width = @floatFromInt(box.width), .height = @floatFromInt(box.height) } };
    }
    return if (matches > 1) .{ .status = .ambiguous_output } else result;
}

pub fn usable(m: Mapping) bool {
    if (m.status != .resolved) return !m.blocked();
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (output.policyId() != m.output_id) continue;
        const native = output.wlr_output orelse return false;
        if (!native.enabled or output.current.state != .enabled or output.scheduled.state == .destroying or !output.current.mirror_of.empty()) return false;
        var box: wlr.Box = undefined;
        server.om.output_layout.getBox(native, &box);
        return @as(f64, @floatFromInt(box.x)) == m.box.x and @as(f64, @floatFromInt(box.y)) == m.box.y and
            @as(f64, @floatFromInt(box.width)) == m.box.width and @as(f64, @floatFromInt(box.height)) == m.box.height and @intFromEnum(native.transform) == m.transform;
    }
    return false;
}

pub fn refresh() void {
    var devices = server.input_manager.devices.iterator(.forward);
    while (devices.next()) |device| if (device.wlr_device.type == .tablet) {
        device.tablet_mapping = resolve(device);
    };
    var tools = server.input_manager.tablet_tools.iterator(.forward);
    while (tools.next()) |tool| if (tool.tablet) |tablet| tool.syncMapping(tablet);
}

pub fn forgetDevice(device: *InputDevice) void {
    var tools = server.input_manager.tablet_tools.iterator(.forward);
    while (tools.next()) |tool| if (tool.tablet) |tablet| {
        if (&tablet.device == device) {
            tool.cancel();
            tool.tablet = null;
            tool.in_proximity = false;
        }
    };
}

pub fn forgetOutput(id: u64) void {
    var devices = server.input_manager.devices.iterator(.forward);
    while (devices.next()) |device| if (device.tablet_mapping.output_id == id) {
        device.tablet_mapping = .{ .status = .waiting_output };
    };
    var tools = server.input_manager.tablet_tools.iterator(.forward);
    while (tools.next()) |tool| if (tool.mapping.output_id == id) {
        tool.cancel();
        tool.mapping = .{ .status = .waiting_output };
    };
}
