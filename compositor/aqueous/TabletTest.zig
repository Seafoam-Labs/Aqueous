// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
//! Private synthetic tablet source, compiled only with -Dtablet-testing=true.
const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const util = @import("util.zig");
const Tool = @import("TabletTool.zig");
const server = &@import("main.zig").server;
const Impl = extern struct { name: [*:0]const u8 };
extern fn wlr_tablet_init(*wlr.Tablet, *const Impl, [*:0]const u8) void;
extern fn wlr_tablet_finish(*wlr.Tablet) void;
extern fn wlr_pointer_init(*wlr.Pointer, *const Impl, [*:0]const u8) void;
extern fn wlr_pointer_finish(*wlr.Pointer) void;
var mouse: ?*wlr.Pointer = null;
const impl: Impl = .{ .name = "aqueous-test-tablet" };
const Slot = struct { native: wlr.Tablet, tool: wlr.TabletTool, name: [:0]u8 };
var slots: [4]?*Slot = @splat(null);

pub fn finish() void {
    if (mouse) |pointer| {
        wlr_pointer_finish(pointer);
        util.gpa.destroy(pointer);
        mouse = null;
    }
    for (&slots) |*slot| if (slot.*) |s| {
        wlr_tablet_finish(&s.native);
        s.tool.events.destroy.emit(&s.tool);
        util.gpa.free(s.name);
        util.gpa.destroy(s);
        slot.* = null;
    };
}
fn number(obj: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => default,
    };
}
pub fn request(obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
    const op = obj.get("action") orelse return error.Invalid;
    if (op != .string) return error.Invalid;
    const index_f = number(obj, "device", 0);
    if (!std.math.isFinite(index_f) or index_f < 0 or index_f >= slots.len or @floor(index_f) != index_f) return error.Invalid;
    const index: usize = @intFromFloat(index_f);
    if (std.mem.eql(u8, op.string, "mouse")) {
        if (mouse == null) {
            const pointer = try util.gpa.create(wlr.Pointer);
            wlr_pointer_init(pointer, &impl, "Independent test mouse");
            server.input_manager.defaultSeat().attachNewDevice(&pointer.base, false);
            mouse = pointer;
        }
        const pointer = mouse.?;
        var event: wlr.Pointer.event.MotionAbsolute = .{ .device = &pointer.base, .time_msec = 5, .x = number(obj, "x", 0.8), .y = number(obj, "y", 0.5) };
        pointer.events.motion_absolute.emit(&event);
        pointer.events.frame.emit(pointer);
    }
    if (std.mem.eql(u8, op.string, "add")) {
        if (slots[index] != null) return error.Exists;
        const name = obj.get("name") orelse return error.Invalid;
        if (name != .string or name.string.len == 0 or name.string.len > 256 or std.mem.indexOfScalar(u8, name.string, 0) != null) return error.Invalid;
        const s = try util.gpa.create(Slot);
        errdefer util.gpa.destroy(s);
        s.name = try util.gpa.dupeZ(u8, name.string);
        wlr_tablet_init(&s.native, &impl, s.name);
        s.tool = std.mem.zeroes(wlr.TabletTool);
        s.tool.type = .pen;
        s.tool.pressure = true;
        s.tool.tilt = true;
        s.tool.events.destroy.init();
        server.input_manager.defaultSeat().attachNewDevice(&s.native.base, false);
        slots[index] = s;
        @import("TabletMapping.zig").refresh();
    }
    const s = slots[index] orelse return error.NotFound;
    if (std.mem.eql(u8, op.string, "remove")) {
        wlr_tablet_finish(&s.native);
        s.tool.events.destroy.emit(&s.tool);
        util.gpa.free(s.name);
        util.gpa.destroy(s);
        slots[index] = null;
        try writer.writeAll("{\"ok\":true}\n");
        return;
    }
    if (std.mem.eql(u8, op.string, "in") or std.mem.eql(u8, op.string, "out")) {
        var event: wlr.Tablet.event.Proximity = .{ .device = &s.native.base, .tool = &s.tool, .time_msec = 1, .x = number(obj, "x", 0.5), .y = number(obj, "y", 0.5), .state = if (std.mem.eql(u8, op.string, "in")) .in else .out };
        s.native.events.proximity.emit(&event);
    } else if (std.mem.eql(u8, op.string, "axis")) {
        var event = std.mem.zeroes(wlr.Tablet.event.Axis);
        event.device = &s.native.base;
        event.tool = &s.tool;
        event.time_msec = 2;
        event.updated_axes = .{ .x = obj.contains("x"), .y = obj.contains("y"), .pressure = true, .tilt_x = true, .tilt_y = true };
        event.x = number(obj, "x", 0.5);
        event.y = number(obj, "y", 0.5);
        event.pressure = number(obj, "pressure", 0.7);
        event.tilt_x = 12;
        event.tilt_y = -8;
        s.native.events.axis.emit(&event);
    } else if (std.mem.eql(u8, op.string, "down") or std.mem.eql(u8, op.string, "up")) {
        var event: wlr.Tablet.event.Tip = .{ .device = &s.native.base, .tool = &s.tool, .time_msec = 3, .x = 0.5, .y = 0.5, .state = if (std.mem.eql(u8, op.string, "down")) .down else .up };
        s.native.events.tip.emit(&event);
    } else if (std.mem.eql(u8, op.string, "button") or std.mem.eql(u8, op.string, "release")) {
        var event: wlr.Tablet.event.Button = .{ .device = &s.native.base, .tool = &s.tool, .time_msec = 4, .button = 0x14b, .state = if (std.mem.eql(u8, op.string, "button")) .pressed else .released };
        s.native.events.button.emit(&event);
    } else if (!std.mem.eql(u8, op.string, "add") and !std.mem.eql(u8, op.string, "state") and !std.mem.eql(u8, op.string, "mouse")) return error.Invalid;
    const tool = try Tool.get(server.input_manager.defaultSeat().wlr_seat, &s.tool);
    const cursor = server.input_manager.defaultSeat().cursor.wlr_cursor;
    try std.json.Stringify.value(.{ .ok = true, .x = tool.wlr_cursor.x, .y = tool.wlr_cursor.y, .mouse_x = cursor.x, .mouse_y = cursor.y, .status = @tagName(tool.mapping.status), .pending = tool.deferred_mapping, .down = tool.wp_tool.is_down, .buttons = tool.wp_tool.num_buttons, .wait_release = tool.wait_release }, .{}, writer);
    try writer.writeByte('\n');
}
