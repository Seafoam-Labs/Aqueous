// SPDX-License-Identifier: GPL-3.0-only
//! Private inherited control FD; compiled out of production. Emits through real
//! device ingress, never a public Wayland/JSON synthetic input endpoint.
const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const server = &@import("main.zig").server;
var control: c_int = -1;
var source: ?*wl.EventSource = null;
var buffer: [4096]u8 = undefined;
var used: usize = 0;
pub var observation_enabled = true;
var sample_start: ?i64 = null;
var sample_end: i64 = 0;
var keyboards: [3]?*wlr.Keyboard = .{ null, null, null };
var pointers: [3]?*wlr.Pointer = .{ null, null, null };
const util = @import("util.zig");
extern fn wlr_pointer_init(*wlr.Pointer, *const extern struct { name: [*:0]const u8 }, [*:0]const u8) void;
extern fn wlr_pointer_finish(*wlr.Pointer) void;

pub fn start(fd: c_int) !void {
    if (fd < 3) return error.InvalidTestFd;
    control = fd;
    _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true })));
    _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, 1);
    source = try server.wl_server.getEventLoop().addFd(?*anyopaque, fd, .{ .readable = true }, read, null);
}
pub fn finish() void {
    if (source) |s| s.remove();
    source = null;
    if (control >= 0) _ = std.c.close(control);
    control = -1;
    for (&keyboards) |*slot| if (slot.*) |device| {
        device.finish();
        util.gpa.destroy(device);
        slot.* = null;
    };
    for (&pointers) |*slot| if (slot.*) |device| {
        wlr_pointer_finish(device);
        util.gpa.destroy(device);
        slot.* = null;
    };
}
fn read(fd: c_int, mask: wl.EventMask, _: ?*anyopaque) c_int {
    if (mask.hangup or mask.@"error") {
        finish();
        return 0;
    }
    const n = std.c.read(fd, buffer[used..].ptr, buffer.len - used);
    if (n <= 0) return 0;
    used += @intCast(n);
    while (std.mem.indexOfScalar(u8, buffer[0..used], '\n')) |end| {
        command(buffer[0..end]) catch {
            const msg = "error\n";
            _ = std.os.linux.sendto(fd, msg.ptr, msg.len, std.os.linux.MSG.NOSIGNAL, null, 0);
            std.mem.copyForwards(u8, &buffer, buffer[end + 1 .. used]);
            used -= end + 1;
            continue;
        };
        var reply: [96]u8 = undefined;
        const msg = if (sample_start) |start_ns|
            std.fmt.bufPrint(&reply, "sample {d} {d}\n", .{ start_ns, sample_end }) catch unreachable
        else
            "ok\n";
        sample_start = null;
        _ = std.os.linux.sendto(fd, msg.ptr, msg.len, std.os.linux.MSG.NOSIGNAL, null, 0);
        std.mem.copyForwards(u8, &buffer, buffer[end + 1 .. used]);
        used -= end + 1;
    }
    if (used == buffer.len) finish();
    return 0;
}
fn number(it: *std.mem.TokenIterator(u8, .scalar)) !u32 {
    return std.fmt.parseInt(u32, it.next() orelse return error.Missing, 10);
}
fn nanoseconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000000000 + ts.nsec;
}
fn command(line: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const op = it.next() orelse return error.Missing;
    if (std.mem.eql(u8, op, "observe")) {
        // Benchmark boundaries must have all synthetic keys/buttons released.
        // Disable the periodic observer too, while keeping the same compositor,
        // connections and native application dispatch path for both cases.
        const value = try number(&it);
        if (value > 1) return error.Invalid;
        observation_enabled = value == 1;
        try server.input_activity.timer.?.timerUpdate(if (observation_enabled) 1 else 0);
        return;
    }
    if (std.mem.eql(u8, op, "warp")) {
        const x = try number(&it);
        const y = try number(&it);
        server.input_manager.defaultSeat().cursor.warpForPolicy(@intCast(x), @intCast(y));
        return;
    }
    if (std.mem.eql(u8, op, "sample")) {
        // All timestamps stay on the inherited diagnostic FD. No timing or
        // synthetic input values are added to the activity protocol.
        const event = it.rest();
        if (!std.mem.eql(u8, event, "key") and !std.mem.eql(u8, event, "button")) return error.Invalid;
        const key = std.mem.eql(u8, event, "key");
        if ((key and keyboards[0] == null) or (!key and pointers[0] == null)) return error.MissingDevice;
        const start_ns = nanoseconds();
        try command(if (key) "key 0 30 1" else "button 0 272 1");
        sample_end = nanoseconds();
        sample_start = start_ns;
        return;
    }
    if (std.mem.eql(u8, op, "owner")) {
        server.input_activity.testOwner(@intCast(try number(&it)));
        return;
    }
    if (std.mem.eql(u8, op, "active")) {
        server.input_activity.test_active = try number(&it) != 0;
        server.input_activity.refresh();
        return;
    }
    if (std.mem.eql(u8, op, "revoke")) {
        server.input_activity.testRevoke();
        return;
    }
    if (std.mem.eql(u8, op, "remove")) {
        const index = try number(&it);
        if (index >= 3) return error.Invalid;
        if (keyboards[index]) |device| {
            device.finish();
            util.gpa.destroy(device);
            keyboards[index] = null;
        }
        if (pointers[index]) |device| {
            wlr_pointer_finish(device);
            util.gpa.destroy(device);
            pointers[index] = null;
        }
        return;
    }
    if (std.mem.eql(u8, op, "burst")) {
        for (0..100) |_| {
            try command("key 0 30 1");
            try command("key 0 30 0");
            try command("button 0 272 1");
            try command("button 0 272 0");
        }
        return;
    }
    const index = try number(&it);
    if (index >= 3) return error.Invalid;
    const code = try number(&it);
    const pressed = try number(&it);
    if (pressed > 1) return error.Invalid;
    if (std.mem.eql(u8, op, "key")) {
        if (keyboards[index] == null) {
            const device = try util.gpa.create(wlr.Keyboard);
            device.init(&.{ .name = "aqueous-activity-test", .led_update = null }, "activity test keyboard");
            _ = device.setKeymap(server.xkb_config.default_keymap);
            server.input_manager.defaultSeat().attachNewDevice(&device.base, index == 1);
            keyboards[index] = device;
        }
        var event: wlr.Keyboard.event.Key = .{ .time_msec = util.msecTimestamp(), .keycode = code, .state = if (pressed == 1) .pressed else .released, .update_state = true };
        keyboards[index].?.notifyKey(&event);
    } else if (std.mem.eql(u8, op, "button")) {
        if (pointers[index] == null) {
            const device = try util.gpa.create(wlr.Pointer);
            wlr_pointer_init(device, &.{ .name = "aqueous-activity-test" }, "activity test pointer");
            server.input_manager.defaultSeat().attachNewDevice(&device.base, index == 1);
            pointers[index] = device;
        }
        var event: wlr.Pointer.event.Button = .{ .device = &pointers[index].?.base, .time_msec = util.msecTimestamp(), .button = code, .state = if (pressed == 1) .pressed else .released };
        pointers[index].?.events.button.emit(&event);
    } else return error.Invalid;
}
