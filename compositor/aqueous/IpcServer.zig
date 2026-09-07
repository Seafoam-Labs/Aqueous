// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const IpcServer = @This();
const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland").server.wl;
const util = @import("util.zig");
const Codec = @import("IpcProtocol.zig");
const Shell = @import("ShellManager.zig");
const Types = @import("ShellCommand.zig");
const server = &@import("main.zig").server;
const log = std.log.scoped(.ipc);
extern fn getenv([*:0]const u8) ?[*:0]const u8;

fd: i32 = -1,
source: ?*wl.EventSource = null,
idle: ?*wl.EventSource = null,
exit_timer: ?*wl.EventSource = null,
path: ?[:0]const u8 = null,
directory: ?[:0]const u8 = null,
bound: bool = false,
clients: [16]?*Client = @splat(null),

pub fn start(ipc: *IpcServer) !void {
    errdefer ipc.deinit();
    const runtime = getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
    if (runtime[0] != '/') return error.InvalidRuntimeDirectory;
    try privateDirectory(runtime, false);
    const parent = try std.fmt.allocPrintSentinel(util.gpa, "{s}/aqueous", .{std.mem.span(runtime)}, 0);
    defer util.gpa.free(parent);
    const made = linux.mkdir(parent, 0o700);
    if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) return error.CreateDirectory;
    try privateDirectory(parent, true);
    const directory = try std.fmt.allocPrintSentinel(util.gpa, "{s}/{s}", .{ parent, server.shell_manager.session }, 0);
    if (linux.errno(linux.mkdir(directory, 0o700)) != .SUCCESS) {
        util.gpa.free(directory);
        return error.CreateInstanceDirectory;
    }
    ipc.directory = directory;
    // Ownership of directory is now held by deinit, including failure paths.
    try ipc.listen();
}

fn listen(ipc: *IpcServer) !void {
    ipc.path = try std.fmt.allocPrintSentinel(util.gpa, "{s}/ipc.sock", .{ipc.directory.?}, 0);
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    if (ipc.path.?.len >= address.path.len) return error.SocketPathTooLong;
    @memcpy(address.path[0..ipc.path.?.len], ipc.path.?);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    ipc.fd = @intCast(rc);
    if (linux.errno(linux.bind(ipc.fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.BindFailed;
    ipc.bound = true;
    if (linux.errno(linux.chmod(ipc.path.?, 0o600)) != .SUCCESS) return error.ChmodFailed;
    if (linux.errno(linux.listen(ipc.fd, 16)) != .SUCCESS) return error.ListenFailed;
    const loop = server.wl_server.getEventLoop();
    ipc.source = try loop.addFd(*IpcServer, ipc.fd, .{ .readable = true }, accept, ipc);
    ipc.exit_timer = try loop.addTimer(*IpcServer, exitTimeout, ipc);
    log.info("protocol=1 listening on {s}", .{ipc.path.?});
}

fn privateDirectory(path: [*:0]const u8, repair_owned: bool) !void {
    var st: linux.Statx = undefined;
    const flags: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true };
    if (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, flags, &st)) != .SUCCESS) return error.StatDirectory;
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.UID or st.uid != linux.getuid() or
        st.mode & 0o170000 != 0o040000) return error.InsecureRuntimeDirectory;
    if (st.mode & 0o777 != 0o700) {
        if (!repair_owned or linux.errno(linux.chmod(path, 0o700)) != .SUCCESS) return error.InsecureRuntimeDirectory;
    }
}

pub fn deinit(ipc: *IpcServer) void {
    if (ipc.idle) |idle| idle.remove();
    ipc.idle = null;
    for (&ipc.clients) |*slot| if (slot.*) |client| client.close();
    if (ipc.source) |source| source.remove();
    if (ipc.exit_timer) |timer| timer.remove();
    if (ipc.fd >= 0) _ = linux.close(ipc.fd);
    if (ipc.path) |path| {
        if (ipc.bound) _ = linux.unlink(path);
        util.gpa.free(path);
    }
    if (ipc.directory) |directory| {
        _ = linux.rmdir(directory);
        util.gpa.free(directory);
    }
    ipc.* = .{};
}

fn accept(_: c_int, mask: wl.EventMask, ipc: *IpcServer) c_int {
    if (mask.hangup or mask.@"error") return 0;
    for (0..8) |_| {
        const rc = linux.accept4(ipc.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return 0;
        const fd: i32 = @intCast(rc);
        ipc.attach(fd) catch {
            _ = linux.close(fd);
        };
    }
    return 0;
}

fn attach(ipc: *IpcServer, fd: i32) !void {
    const Cred = extern struct { pid: i32, uid: u32, gid: u32 };
    var cred: Cred = .{ .pid = 0, .uid = 0, .gid = 0 };
    var len: linux.socklen_t = @sizeOf(Cred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
    if (!Codec.peerAllowed(linux.errno(rc) == .SUCCESS and len == @sizeOf(Cred), cred.uid, linux.getuid())) return error.PeerRejected;
    const slot = for (&ipc.clients) |*slot| {
        if (slot.* == null) break slot;
    } else return error.ClientLimit;
    const client = try util.gpa.create(Client);
    errdefer util.gpa.destroy(client);
    client.* = .{ .ipc = ipc, .fd = fd, .slot = slot };
    client.backend = try Shell.attachSocket(client);
    errdefer Shell.detach(client.backend);
    client.source = try server.wl_server.getEventLoop().addFd(*Client, fd, .{ .readable = true }, Client.ready, client);
    slot.* = client;
}

fn schedule(ipc: *IpcServer) void {
    if (ipc.idle == null) ipc.idle = server.wl_server.getEventLoop().addIdle(*IpcServer, service, ipc) catch null;
}

fn service(ipc: *IpcServer) void {
    ipc.idle = null;
    for (ipc.clients) |slot| if (slot) |client| {
        if (!client.failed) client.consume() catch client.fail();
        if (client.failed) client.close();
    };
}

fn exitTimeout(_: *IpcServer) c_int {
    server.wl_server.terminate();
    return 0;
}

pub const Client = struct {
    ipc: *IpcServer,
    fd: i32,
    slot: *?*Client,
    source: ?*wl.EventSource = null,
    backend: *Shell.Client = undefined,
    input: [Codec.max_request + 1]u8 = undefined,
    input_len: usize = 0,
    output: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    failed: bool = false,
    hello: bool = false,
    session: [32]u8 = undefined,
    last_id: ?u128 = null,
    request_id: [20]u8 = undefined,
    request_len: usize = 0,
    pending: bool = false,
    response_queued: bool = false,
    delivery: u64 = 0,
    exiting: bool = false,

    pub fn fail(client: *Client) void {
        client.failed = true;
        if (client.source) |source| source.fdUpdate(.{ .readable = true, .writable = true }) catch {};
        client.ipc.schedule();
    }

    fn close(client: *Client) void {
        if (client.source) |source| source.remove();
        _ = linux.close(client.fd);
        Shell.detach(client.backend);
        client.output.deinit(util.gpa);
        client.slot.* = null;
        if (client.exiting) server.wl_server.terminate();
        util.gpa.destroy(client);
    }

    fn ready(_: c_int, mask: wl.EventMask, client: *Client) c_int {
        if (mask.@"error" or client.failed) {
            client.close();
            return 0;
        }
        if (mask.writable) client.flush() catch client.fail();
        if (!client.failed and (mask.readable or mask.hangup)) client.read() catch client.fail();
        if (client.failed) client.close();
        return 0;
    }

    fn read(client: *Client) !void {
        for (0..8) |_| {
            if (client.input_len == client.input.len) return error.RequestTooLarge;
            const dest = client.input[client.input_len..];
            const rc = linux.recvfrom(client.fd, dest.ptr, @min(dest.len, 8192), 0, null, null);
            switch (linux.errno(rc)) {
                .AGAIN => return,
                .INTR => continue,
                .SUCCESS => {},
                else => return error.ReadFailed,
            }
            if (rc == 0) return error.Disconnected;
            client.input_len += rc;
            try client.consume();
            if (client.failed) return;
            if (std.mem.indexOfScalar(u8, client.input[0..client.input_len], '\n') != null) return;
        }
    }

    fn consume(client: *Client) !void {
        for (0..16) |_| {
            const end = std.mem.indexOfScalar(u8, client.input[0..client.input_len], '\n') orelse return;
            try client.request(client.input[0..end]);
            const used = end + 1;
            std.mem.copyForwards(u8, client.input[0 .. client.input_len - used], client.input[used..client.input_len]);
            client.input_len -= used;
            if (client.failed) return;
        }
        if (std.mem.indexOfScalar(u8, client.input[0..client.input_len], '\n') != null) client.ipc.schedule();
    }

    fn enqueue(client: *Client, bytes: []const u8) !void {
        if (client.failed) return error.Disconnected;
        if (bytes.len > Codec.max_frame or bytes.len + 1 > Codec.max_frame + Codec.max_request - (client.output.items.len - client.offset)) return error.OutputLimit;
        if (client.offset != 0) {
            const remaining = client.output.items.len - client.offset;
            std.mem.copyForwards(u8, client.output.items[0..remaining], client.output.items[client.offset..]);
            client.output.items.len = remaining;
            client.offset = 0;
        }
        try client.output.appendSlice(util.gpa, bytes);
        try client.output.append(util.gpa, '\n');
        try client.source.?.fdUpdate(.{ .readable = true, .writable = true });
    }

    fn flush(client: *Client) !void {
        var budget: usize = 256 * 1024;
        while (client.offset < client.output.items.len and budget != 0) {
            const bytes = client.output.items[client.offset..];
            const rc = linux.sendto(client.fd, bytes.ptr, @min(bytes.len, budget), linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .AGAIN => return,
                .INTR => continue,
                .SUCCESS => {},
                else => return error.WriteFailed,
            }
            if (rc == 0) return error.WriteFailed;
            client.offset += rc;
            budget -= rc;
        }
        if (client.offset == client.output.items.len) {
            client.output.clearAndFree(util.gpa);
            client.offset = 0;
            client.response_queued = false;
            try client.source.?.fdUpdate(.{ .readable = true });
            if (client.exiting) server.wl_server.terminate();
        }
    }

    fn reply(client: *Client, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(util.gpa, .{ .ipc = 1, .id = client.request_id[0..client.request_len], .ok = true, .result = value }, .{});
        defer util.gpa.free(bytes);
        try client.enqueue(bytes);
        client.pending = false;
        client.response_queued = true;
    }

    fn reject(client: *Client, id: []const u8, code: []const u8) !void {
        const bytes = try std.json.Stringify.valueAlloc(util.gpa, .{ .ipc = 1, .id = id, .ok = false, .@"error" = .{ .code = code, .message = code } }, .{});
        defer util.gpa.free(bytes);
        try client.enqueue(bytes);
        client.response_queued = true;
    }

    fn request(client: *Client, bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(util.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const req = try Codec.parse(a, bytes);
        if (client.last_id) |last| if (req.number <= last) return error.ReusedId;
        client.last_id = req.number;
        if (client.pending or client.response_queued or client.exiting) return client.reject(req.id, "busy");
        if (req.version != 1) return client.reject(req.id, "unsupported");
        const op = std.meta.stringToEnum(Codec.Op, req.op) orelse return client.reject(req.id, "unsupported");
        if (!client.hello and op != .hello) return client.reject(req.id, "invalid");
        if (op != .hello and !std.mem.eql(u8, req.session, server.shell_manager.session[0..32])) return client.reject(req.id, "stale_session");
        @memcpy(client.request_id[0..req.id.len], req.id);
        client.request_len = req.id.len;
        switch (op) {
            .hello => {
                if (client.hello or req.params.count() != 0) return client.reject(req.id, "invalid");
                client.hello = true;
                client.session = server.shell_manager.session[0..32].*;
                const commands = server.aqueous.mode == .internal;
                try client.reply(.{
                    .session = server.shell_manager.session[0..32],
                    .schema = 1,
                    .max_request_bytes = Codec.max_request,
                    .max_frame_bytes = Codec.max_frame,
                    .max_batch_bytes = Codec.max_batch,
                    .max_pending_requests = 1,
                    .max_clients = 16,
                    .max_state_bytes = Codec.max_batch / 2,
                    .max_depth = Codec.max_depth,
                    .capabilities = .{ .state = true, .commands = commands, .keyboard = commands, .overview = commands, .shortcut_inhibition = true },
                });
            },
            .snapshot => {
                if (req.params.count() != 0 or client.backend.subscribed) return client.reject(req.id, "invalid");
                client.pending = true;
                client.backend.snapshot = true;
                server.shell_manager.dirty();
            },
            .subscribe => {
                if (req.params.count() != 0 or client.backend.subscribed) return client.reject(req.id, "invalid");
                try client.reply(.{ .subscribed = true });
                client.backend.subscribed = true;
                server.shell_manager.dirty();
            },
            .ack => {
                if (req.params.count() != 1) return error.InvalidAck;
                const value = try Codec.string(req.params, "delivery");
                var buf: [20]u8 = undefined;
                const expected = try std.fmt.bufPrint(&buf, "{d}", .{client.delivery});
                if (!client.backend.inflight or !std.mem.eql(u8, value, expected)) return error.InvalidAck;
                try client.reply(.{ .acked = value });
                client.backend.inflight = false;
                server.shell_manager.dirty();
            },
            .command => {
                if (client.backend.subscribed) return client.reject(req.id, "invalid");
                const command = Codec.command(a, req.params) catch |err| return client.reject(req.id, if (err == error.Unsupported) "unsupported" else "invalid");
                if (server.lock_manager.state != .unlocked) return client.reject(req.id, "locked");
                if (server.aqueous.mode != .internal) return client.reject(req.id, "unsupported");
                client.backend.queued = try command.clone(util.gpa);
                client.pending = true;
                server.shell_manager.dirty();
            },
        }
    }

    pub fn validateSession(client: *Client) bool {
        if (std.mem.eql(u8, &client.session, server.shell_manager.session[0..32])) return true;
        client.reject(client.request_id[0..client.request_len], "stale_session") catch client.fail();
        client.pending = false;
        return false;
    }

    pub fn commandResult(client: *Client, status: Types.Status, sequence: []const u8) !void {
        if (status == .applied or status == .accepted) return client.reply(.{ .status = @tagName(status), .sequence = sequence });
        try client.reject(client.request_id[0..client.request_len], @tagName(status));
        client.pending = false;
    }

    pub fn snapshotResult(client: *Client, batch: []const u8) !void {
        const bytes = try std.fmt.allocPrint(util.gpa, "{{\"ipc\":1,\"id\":\"{s}\",\"ok\":true,\"result\":{{\"batch\":{s}}}}}", .{ client.request_id[0..client.request_len], batch });
        defer util.gpa.free(bytes);
        try client.enqueue(bytes);
        client.pending = false;
        client.response_queued = true;
    }

    pub fn stateEvent(client: *Client, batch: []const u8) !void {
        client.delivery = std.math.add(u64, client.delivery, 1) catch return error.DeliveryOverflow;
        const bytes = try std.fmt.allocPrint(util.gpa, "{{\"ipc\":1,\"event\":\"state\",\"delivery\":\"{d}\",\"batch\":{s}}}", .{ client.delivery, batch });
        defer util.gpa.free(bytes);
        try client.enqueue(bytes);
    }

    pub fn exitAfterFlush(client: *Client) void {
        client.exiting = true;
        client.ipc.exit_timer.?.timerUpdate(1000) catch {
            server.wl_server.terminate();
        };
    }
};
