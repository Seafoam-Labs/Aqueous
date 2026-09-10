// SPDX-License-Identifier: GPL-3.0-only
//! Private synthetic touch source, compiled only with -Dtoplevel-drag-testing.
const std = @import("std");
const wlr = @import("wlroots");
const util = @import("util.zig");
const server = &@import("main.zig").server;
const Impl = extern struct { name: [*:0]const u8 };
const impl: Impl = .{ .name = "aqueous-drag-test" };
extern fn wlr_touch_init(*wlr.Touch, *const Impl, [*:0]const u8) void;
extern fn wlr_touch_finish(*wlr.Touch) void;
var touches: [2]?*wlr.Touch = .{ null, null };

pub fn finish() void {
    for (&touches) |*slot| if (slot.*) |device| {
        wlr_touch_finish(device);
        util.gpa.destroy(device);
        slot.* = null;
    };
}

fn number(obj: std.json.ObjectMap, key: []const u8, default: f64) !f64 {
    const value = obj.get(key) orelse return default;
    const result: f64 = switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => return error.Invalid,
    };
    if (!std.math.isFinite(result)) return error.Invalid;
    return result;
}

pub fn request(obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
    const action = obj.get("action") orelse return error.Invalid;
    if (action != .string) return error.Invalid;
    const index_value = try number(obj, "device", 0);
    if (index_value < 0 or index_value > 1 or @floor(index_value) != index_value) return error.Invalid;
    const index: usize = @intFromFloat(index_value);
    var seat = server.input_manager.defaultSeat();
    if (index == 1) {
        var found = false;
        var seats = server.input_manager.seats.iterator(.forward);
        while (seats.next()) |candidate| {
            if (std.mem.eql(u8, std.mem.span(candidate.wlr_seat.name), "drag-second")) {
                seat = candidate;
                found = true;
                break;
            }
        }
        if (!found) {
            try @import("Seat.zig").create("drag-second");
            return request(obj, writer);
        }
        if (std.mem.eql(u8, action.string, "remove-seat")) {
            seat.destroy();
            try writer.writeAll("{\"ok\":true}\n");
            return;
        }
    }
    const id_value = try number(obj, "id", 0);
    const x = try number(obj, "x", 0.5);
    const y = try number(obj, "y", 0.5);
    if (id_value < 0 or id_value > 31 or @floor(id_value) != id_value or x < 0 or x > 1 or y < 0 or y > 1) return error.Invalid;
    const id: i32 = @intFromFloat(id_value);
    if (touches[index] == null) {
        const device = try util.gpa.create(wlr.Touch);
        wlr_touch_init(device, &impl, "Toplevel drag test touch");
        seat.attachNewDevice(&device.base, false);
        touches[index] = device;
    }
    const device = touches[index].?;
    const time = util.msecTimestamp();
    if (std.mem.eql(u8, action.string, "down")) {
        var event: wlr.Touch.event.Down = .{ .device = &device.base, .time_msec = time, .touch_id = id, .x = x, .y = y };
        device.events.down.emit(&event);
    } else if (std.mem.eql(u8, action.string, "motion")) {
        var event: wlr.Touch.event.Motion = .{ .device = &device.base, .time_msec = time, .touch_id = id, .x = x, .y = y };
        device.events.motion.emit(&event);
    } else if (std.mem.eql(u8, action.string, "up")) {
        var event: wlr.Touch.event.Up = .{ .device = &device.base, .time_msec = time, .touch_id = id };
        device.events.up.emit(&event);
    } else if (std.mem.eql(u8, action.string, "cancel")) {
        var event: wlr.Touch.event.Cancel = .{ .device = &device.base, .time_msec = time, .touch_id = id };
        device.events.cancel.emit(&event);
    } else if (!std.mem.eql(u8, action.string, "add")) return error.Invalid;
    device.events.frame.emit();
    try writer.writeAll("{\"ok\":true}\n");
}
