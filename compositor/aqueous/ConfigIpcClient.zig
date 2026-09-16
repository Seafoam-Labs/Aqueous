// SPDX-License-Identifier: GPL-3.0-only
//! Bounded native JSON client shared by the canonical helper. The owner
//! connection for a preview is held by the UI, never this short-lived client.
const std = @import("std");
const linux = std.os.linux;
const A = std.mem.Allocator;
const max_frame = 4 * 1024 * 1024 + 65536;
extern "c" fn poll(fds: [*]std.posix.pollfd, count: usize, timeout: c_int) c_int;
const io = std.Io.Threaded.global_single_threaded.io();
pub const Client = struct {
    fd: i32,
    session: [32]u8 = undefined,
    number: u32 = 0,
    deadline: i64,
    preview_feature_policy: bool = false,
    pub fn open(a: A) !Client {
        const path = if (std.c.getenv("AQUEOUS_SOCKET")) |p| std.mem.span(p) else return error.CompositorUnavailable;
        var address: linux.sockaddr.un = .{ .path = @splat(0) };
        if (!std.fs.path.isAbsolute(path) or path.len >= address.path.len) return error.CompositorUnavailable;
        @memcpy(address.path[0..path.len], path);
        const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd) != .SUCCESS) return error.CompositorUnavailable;
        var c: Client = .{ .fd = @intCast(fd), .deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000 };
        errdefer c.close();
        const rc = linux.connect(c.fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un));
        if (linux.errno(rc) != .SUCCESS) return error.CompositorUnavailable;
        const hello = try c.call(a, "hello", .{});
        defer a.free(hello);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, hello, .{});
        defer parsed.deinit();
        const session = parsed.value.object.get("session") orelse return error.InvalidReply;
        if (session != .string or session.string.len != 32) return error.InvalidReply;
        c.session = session.string[0..32].*;
        if (parsed.value.object.get("capabilities")) |caps| if (caps == .object) {
            if (caps.object.get("display_preview_feature_policy_v1")) |feature| c.preview_feature_policy = feature == .bool and feature.bool;
        };
        return c;
    }
    pub fn close(c: Client) void {
        _ = linux.close(c.fd);
    }
    fn ready(c: *Client, events: i16) !void {
        const left = c.deadline - std.Io.Clock.awake.now(io).toMilliseconds();
        if (left <= 0) return error.CompositorTimeout;
        var fd: [1]std.posix.pollfd = .{.{ .fd = c.fd, .events = events, .revents = 0 }};
        if (poll(&fd, 1, @intCast(left)) <= 0) return error.CompositorTimeout;
    }
    pub fn call(c: *Client, a: A, op: []const u8, params: anytype) ![]u8 {
        c.number += 1;
        var id_buf: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{c.number});
        const bytes = try std.json.Stringify.valueAlloc(a, .{ .ipc = 1, .id = id, .session = if (c.number == 1) @as([]const u8, "") else &c.session, .op = op, .params = if (comptime @TypeOf(params) == @TypeOf(.{})) struct {}{} else params }, .{});
        defer a.free(bytes);
        if (bytes.len > 65536) return error.CompositorRequestTooLarge;
        const framed = try std.fmt.allocPrint(a, "{s}\n", .{bytes});
        defer a.free(framed);
        var sent: usize = 0;
        while (sent < framed.len) {
            try c.ready(std.posix.POLL.OUT);
            const rc = linux.sendto(c.fd, framed[sent..].ptr, framed.len - sent, linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => sent += rc,
                .INTR, .AGAIN => continue,
                else => return error.CompositorDisconnected,
            }
        }
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(a);
        while (true) {
            try c.ready(std.posix.POLL.IN);
            var buffer: [4096]u8 = undefined;
            const rc = linux.recvfrom(c.fd, &buffer, buffer.len, 0, null, null);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                else => return error.CompositorDisconnected,
            }
            if (rc == 0) return error.CompositorDisconnected;
            if (output.items.len + rc > max_frame) return error.InvalidReply;
            try output.appendSlice(a, buffer[0..rc]);
            if (std.mem.indexOfScalar(u8, output.items, '\n')) |end| {
                const parsed = try std.json.parseFromSlice(std.json.Value, a, output.items[0..end], .{});
                defer parsed.deinit();
                if (parsed.value != .object) return error.InvalidReply;
                const obj = parsed.value.object;
                const reply_id = obj.get("id") orelse return error.InvalidReply;
                if (reply_id != .string or !std.mem.eql(u8, id, reply_id.string)) return error.InvalidReply;
                const ok = obj.get("ok") orelse return error.InvalidReply;
                if (ok != .bool) return error.InvalidReply;
                if (!ok.bool) {
                    // Preserve documented feature rejection codes through the
                    // helper, while bounding the set of remotely named errors.
                    if (obj.get("error")) |remote| if (remote == .object) {
                        const code = remote.object.get("code") orelse return error.CompositorRejected;
                        if (code != .string) return error.CompositorRejected;
                        inline for (std.meta.fields(@import("display_preview_policy.zig").Reason)) |field| {
                            if (std.mem.eql(u8, code.string, field.name)) return @field(anyerror, field.name);
                        }
                    };
                    return error.CompositorRejected;
                }
                return std.json.Stringify.valueAlloc(a, obj.get("result") orelse return error.InvalidReply, .{});
            }
        }
    }
};
