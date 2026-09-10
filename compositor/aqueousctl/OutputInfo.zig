// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
//! Optional Aqueous metadata supplement to the standard output-management list.
//! A missing service must not prevent output discovery on other compositors.
const std = @import("std");
const linux = std.os.linux;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn read(allocator: std.mem.Allocator) ?std.json.Parsed(std.json.Value) {
    return readRequest(allocator, "{\"op\":\"list\"}\n");
}

pub fn readRequest(allocator: std.mem.Allocator, request: []const u8) ?std.json.Parsed(std.json.Value) {
    const runtime = getenv("XDG_RUNTIME_DIR") orelse return null;
    var address: linux.sockaddr.un = .{ .path = [_]u8{0} ** 108 };
    const path = std.fmt.bufPrint(address.path[0 .. address.path.len - 1], "{s}/aqueous/outputd.sock", .{std.mem.span(runtime)}) catch return null;
    address.path[path.len] = 0;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return null;
    if (linux.sendto(fd, request.ptr, request.len, linux.MSG.NOSIGNAL, null, 0) != request.len) return null;
    const buffer = allocator.alloc(u8, 256 * 1024) catch return null;
    defer allocator.free(buffer);
    var used: usize = 0;
    for (0..16) |_| {
        var pollfds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&pollfds, 1, 50) <= 0) return null;
        const received = linux.recvfrom(fd, buffer[used..].ptr, buffer.len - used, 0, null, null);
        if (linux.errno(received) != .SUCCESS or received == 0) return null;
        used += received;
        if (std.mem.indexOfScalar(u8, buffer[0..used], '\n')) |end| {
            return std.json.parseFromSlice(std.json.Value, allocator, buffer[0..end], .{ .allocate = .alloc_always }) catch null;
        }
        if (used == buffer.len) return null;
    }
    return null;
}

pub fn find(parsed: ?std.json.Parsed(std.json.Value), name: ?[]const u8) ?std.json.ObjectMap {
    const data = parsed orelse return null;
    const wanted = name orelse return null;
    if (data.value != .object) return null;
    const outputs = data.value.object.get("outputs") orelse return null;
    if (outputs != .array) return null;
    for (outputs.array.items) |output| {
        if (output != .object) continue;
        const output_name = output.object.get("name") orelse continue;
        if (output_name == .string and std.mem.eql(u8, wanted, output_name.string)) return output.object;
    }
    return null;
}
