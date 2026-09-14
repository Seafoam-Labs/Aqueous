//! Shelly's framed protocol and private sudo terminal, independent of GTK.
const std = @import("std");
const u = @import("common.zig");
const c = u.c;
const Context = u.Context;
const Value = u.Value;
const get = u.get;
const string = u.string;
const eq = u.eq;

pub fn encode(ctx: *Context, v: Value) ![]const u8 {
    const json = try ctx.json(v);
    const encoded = try ctx.a.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    _ = std.base64.standard.Encoder.encode(encoded, json);
    return std.fmt.allocPrint(ctx.a, "[JSON]{s}[/JSON]\n", .{encoded});
}
pub const Frames = struct {
    buffer: std.ArrayList(u8) = .empty,
    pub fn deinit(self: *Frames, a: std.mem.Allocator) void {
        self.buffer.deinit(a);
    }
    fn consume(self: *Frames, n: usize) void {
        std.mem.copyForwards(u8, self.buffer.items, self.buffer.items[n..]);
        self.buffer.items.len -= n;
    }
    pub fn feed(self: *Frames, a: std.mem.Allocator, data: []const u8) !void {
        if (self.buffer.items.len + data.len > u.limit) return error.FrameTooLarge;
        try self.buffer.appendSlice(a, data);
    }
    pub fn next(self: *Frames, ctx: *Context) !?Value {
        const start = std.mem.indexOf(u8, self.buffer.items, "[JSON]") orelse {
            self.consume(self.buffer.items.len - @min(5, self.buffer.items.len));
            return null;
        };
        const end = std.mem.indexOfPos(u8, self.buffer.items, start + 6, "[/JSON]") orelse {
            self.consume(start);
            return null;
        };
        const text = self.buffer.items[start + 6 .. end];
        const decoded = try ctx.a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(text) catch return error.InvalidFrame);
        std.base64.standard.Decoder.decode(decoded, text) catch return error.InvalidFrame;
        const result = try ctx.parse(decoded);
        if (result != .object) return error.InvalidFrame;
        self.consume(end + 7);
        return result;
    }
};
pub fn optionalAnswer(ctx: *Context, event: Value) !Value {
    var selected = ctx.array();
    for (u.items(get(event, "Options"))) |option| if (!u.yes(get(option, "IsInstalled"))) {
        if (get(option, "Index") != .integer) return error.InvalidOption;
        try selected.array.append(get(option, "Index"));
    };
    return ctx.value(.{ .@"$kind" = "a.optdeps", .QuestionId = get(event, "QuestionId"), .SelectedIndices = selected });
}
pub fn questionAnswer(ctx: *Context, event: Value, response: Value) !Value {
    const kind = string(event, "$kind");
    if (!std.mem.startsWith(u8, kind, "q.")) return ctx.fail("Invalid Shelly question", .{});
    var answer = try ctx.value(.{ .@"$kind" = try std.fmt.allocPrint(ctx.a, "a.{s}", .{kind[2..]}), .QuestionId = get(event, "QuestionId") });
    if (eq(u8, kind, "q.provider")) {
        const choice = get(response, "choice");
        var found = false;
        for (u.items(get(event, "Options"))) |option| if (choice == .integer and u.same(choice, get(option, "Index"))) {
            found = true;
        };
        if (!found) return ctx.fail("Choose a valid package provider", .{});
        try answer.object.put(ctx.a, "SelectedIndex", choice);
    } else if (eq(u8, kind, "q.yesno") or eq(u8, kind, "q.transaction") or eq(u8, kind, "q.pkgbuilddiff")) {
        try answer.object.put(ctx.a, if (eq(u8, kind, "q.pkgbuilddiff")) "ProceedWithUpdate" else "Accept", .{ .bool = u.yes(get(response, "accept")) });
    } else return ctx.fail("Unsupported Shelly question: {s}", .{kind});
    return answer;
}
fn details(ctx: *Context, v: Value, depth: usize) anyerror![]const u8 {
    if (depth > 8) return ctx.fail("Package review is nested too deeply", .{});
    var out: std.ArrayList(u8) = .empty;
    switch (v) {
        .object => {
            var it = v.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (eq(u8, key, "$kind") or eq(u8, key, "QuestionId") or eq(u8, key, "QuestionText") or eq(u8, key, "Index") or entry.value_ptr.* == .null) continue;
                for (key, 0..) |ch, i| {
                    if (i > 0 and std.ascii.isLower(key[i - 1]) and std.ascii.isUpper(ch)) try out.append(ctx.a, ' ');
                    try out.append(ctx.a, ch);
                }
                try out.appendSlice(ctx.a, ": ");
                try out.appendSlice(ctx.a, try details(ctx, entry.value_ptr.*, depth + 1));
                try out.append(ctx.a, '\n');
            }
        },
        .array => for (v.array.items) |item| {
            try out.append(ctx.a, '\n');
            try out.appendSlice(ctx.a, try details(ctx, item, depth + 1));
            try out.append(ctx.a, '\n');
        },
        .string => return v.string,
        else => return ctx.json(v),
    }
    return out.toOwnedSlice(ctx.a);
}
fn sudoPrompt(bytes: []const u8) bool {
    const prefix = "[sudo] password for ";
    const start = std.mem.lastIndexOf(u8, bytes, prefix) orelse return false;
    const rest = std.mem.trimEnd(u8, bytes[start + prefix.len ..], " ");
    if (rest.len < 2 or rest[rest.len - 1] != ':') return false;
    return std.mem.indexOfAny(u8, rest[0 .. rest.len - 1], "\r\n:") == null;
}
fn pipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
    return fds;
}

fn progress(ctx: *Context, cancelled: *bool, event: anytype) !void {
    ctx.emit(event) catch |err| switch (err) {
        // Losing the UI during commit requests cancellation after the current
        // transaction. Continue draining Shelly instead of interrupting it.
        error.WriteFailed => cancelled.* = true,
        else => return err,
    };
}

pub fn install(ctx: *Context, args: []const []const u8) !void {
    const argv = try ctx.argv(args);
    var master: c_int = -1;
    var slave: c_int = -1;
    if (c.openpty(&master, &slave, null, null, null) != 0) return error.TerminalFailed;
    defer u.close(master);
    defer u.close(slave);
    _ = c.fcntl(master, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
    _ = c.fcntl(slave, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
    var attrs: c.struct_termios = undefined;
    if (c.tcgetattr(slave, &attrs) != 0) return error.TerminalFailed;
    attrs.c_lflag &= ~@as(c.tcflag_t, c.ECHO | c.ECHONL);
    if (c.tcsetattr(slave, c.TCSANOW, &attrs) != 0) return error.TerminalFailed;
    var input = try pipe();
    defer for (input) |fd| u.close(fd);
    var output = try pipe();
    defer for (output) |fd| u.close(fd);
    var errors = try pipe();
    defer for (errors) |fd| u.close(fd);
    if (c.setenv("LC_ALL", "C", 1) != 0 or c.setenv("SHELLY_ELEVATOR", "sudo", 1) != 0) return error.EnvironmentFailed;
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        if (c.setsid() < 0 or c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0)) < 0) c._exit(126);
        // Keep the slave alive until sudo opens /dev/tty. Otherwise the master
        // reports a hangup in the gap between exec and the authentication prompt.
        if (c.fcntl(slave, c.F_SETFD, @as(c_int, 0)) < 0) c._exit(126);
        if (c.dup2(input[0], 0) < 0 or c.dup2(output[1], 1) < 0 or c.dup2(errors[1], 2) < 0) c._exit(126);
        // Do not inherit the worker's ignored SIGPIPE into package tools.
        _ = c.signal(c.SIGPIPE, c.SIG_DFL);
        _ = c.signal(c.SIGINT, c.SIG_DFL);
        _ = c.signal(c.SIGTERM, c.SIG_DFL);
        _ = c.signal(c.SIGHUP, c.SIG_DFL);
        _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    u.close(slave);
    slave = -1;
    u.close(input[0]);
    input[0] = -1;
    u.close(output[1]);
    output[1] = -1;
    u.close(errors[1]);
    errors[1] = -1;
    var polls = [_]c.struct_pollfd{
        .{ .fd = master, .events = c.POLLIN, .revents = 0 },
        .{ .fd = output[0], .events = c.POLLIN, .revents = 0 },
        .{ .fd = errors[0], .events = c.POLLIN, .revents = 0 },
        .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
    };
    var status: c_int = 0;
    var reaped = false;
    defer if (!reaped) {
        u.close(input[1]);
        input[1] = -1;
        _ = c.kill(-pid, c.SIGINT);
        const started = u.now();
        var warned = false;
        // Keep draining pipes while Shelly unwinds; never SIGKILL an ALPM commit.
        while (c.waitpid(pid, &status, c.WNOHANG) != pid) {
            if (!warned and u.now() - started > 20000) {
                ctx.emit(.{ .kind = "progress", .message = "Waiting for Shelly to release its transaction…" }) catch {};
                warned = true;
            }
            var drain = [_]c.struct_pollfd{ polls[0], polls[1], polls[2] };
            _ = c.poll(&drain, drain.len, 200);
            var bytes: [8192]u8 = undefined;
            for (&drain) |*p| if (p.fd >= 0 and p.revents != 0) {
                _ = c.read(p.fd, &bytes, bytes.len);
            };
        }
    };
    var decoder: Frames = .{};
    defer decoder.deinit(ctx.a);
    var input_buffer: std.ArrayList(u8) = .empty;
    defer {
        @memset(input_buffer.items, 0);
        input_buffer.deinit(ctx.a);
    }
    var tty_buffer: std.ArrayList(u8) = .empty;
    defer tty_buffer.deinit(ctx.a);
    var pending_arena = std.heap.ArenaAllocator.init(ctx.a);
    defer pending_arena.deinit();
    var pending: ?Value = null;
    var password = false;
    var number: usize = 0;
    var cancelled = false;
    var outcome: enum { missing, done, failed, cancelled } = .missing;
    var tty_started: ?i64 = null;
    while (!reaped or polls[1].fd >= 0 or polls[2].fd >= 0) {
        if (!reaped) {
            const result = c.waitpid(pid, &status, c.WNOHANG);
            if (result == pid) reaped = true else if (result < 0 and std.c._errno().* != c.EINTR) return error.WaitFailed;
        }
        if (tty_started) |started| if (u.now() - started > 3000) return ctx.fail("Unsupported elevation prompt; Shelly requires the standard sudo password conversation", .{});
        const ready = c.poll(&polls, polls.len, 200);
        if (ready < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.PollFailed;
        }
        for (&polls, 0..) |*p, channel| {
            if (p.fd < 0 or p.revents == 0) continue;
            var data: [8192]u8 = undefined;
            defer @memset(&data, 0);
            const n = c.read(p.fd, &data, data.len);
            if (n <= 0) {
                if (n < 0 and std.c._errno().* == c.EINTR) continue;
                p.fd = -1;
                if (channel == 3) {
                    cancelled = true;
                    if (pending != null or password) return ctx.fail("Setup window disconnected during a question", .{});
                }
                continue;
            }
            var arena = std.heap.ArenaAllocator.init(ctx.a);
            defer arena.deinit();
            var temp = ctx.*;
            temp.a = arena.allocator();
            // Transfer diagnostics out of the temporary arena on any failure.
            errdefer if (temp.message) |message| {
                ctx.message = ctx.a.dupe(u8, message) catch null;
            };
            const bytes = data[0..@intCast(n)];
            switch (channel) {
                3 => {
                    if (input_buffer.items.len + bytes.len > u.limit) return ctx.fail("Response exceeded size limit", .{});
                    try input_buffer.appendSlice(ctx.a, bytes);
                    while (std.mem.indexOfScalar(u8, input_buffer.items, '\n')) |end| {
                        const response = try temp.parse(input_buffer.items[0..end]);
                        defer {
                            // Erase both the wire buffer and decoded password.
                            const secret = get(response, "password");
                            if (secret == .string) @memset(@constCast(secret.string), 0);
                            const remaining = input_buffer.items.len - end - 1;
                            std.mem.copyForwards(u8, input_buffer.items, input_buffer.items[end + 1 ..]);
                            @memset(input_buffer.items[remaining..], 0);
                            input_buffer.items.len = remaining;
                        }
                        if (u.yes(get(response, "cancel"))) {
                            cancelled = true;
                            if (pending != null or password) return ctx.fail("Setup cancelled", .{});
                            try progress(&temp, &cancelled, .{ .kind = "progress", .message = "Finishing the active package transaction before stopping…" });
                            continue;
                        }
                        const id = try std.fmt.allocPrint(temp.a, "{d}", .{number});
                        if ((!password and pending == null) or !eq(u8, string(response, "id"), id)) return ctx.fail("Stale or unsolicited response", .{});
                        if (password) {
                            const secret = string(response, "password");
                            if (secret.len == 0 or secret.len > 4096 or std.mem.indexOfAny(u8, secret, "\r\n\x00") != null) return ctx.fail("Invalid password response", .{});
                            if (c.tcgetattr(master, &attrs) != 0 or attrs.c_lflag & (c.ECHO | c.ECHONL) != 0) return ctx.fail("Authentication terminal unexpectedly enabled echo", .{});
                            try u.write(master, secret);
                            try u.write(master, "\n");
                            password = false;
                        } else try u.write(input[1], try encode(&temp, try questionAnswer(&temp, pending.?, response)));
                        pending = null;
                        _ = pending_arena.reset(.free_all);
                    }
                },
                0 => {
                    if (tty_buffer.items.len + bytes.len > 8192) return ctx.fail("Unsupported authentication conversation", .{});
                    try tty_buffer.appendSlice(ctx.a, bytes);
                    if (tty_started == null) tty_started = u.now();
                    if (sudoPrompt(tty_buffer.items)) {
                        if (pending != null or password) return ctx.fail("Overlapping authentication requests", .{});
                        if (cancelled) return ctx.fail("Setup cancelled before authentication", .{});
                        number += 1;
                        password = true;
                        try temp.emit(.{ .kind = "password", .id = try std.fmt.allocPrint(temp.a, "{d}", .{number}), .message = "Enter your password to allow Shelly to install packages." });
                        tty_buffer.clearRetainingCapacity();
                        tty_started = null;
                    } else if (std.mem.endsWith(u8, tty_buffer.items, "\n")) {
                        tty_buffer.clearRetainingCapacity();
                        tty_started = null;
                    }
                },
                2 => {}, // Drain diagnostics; never forward an authentication transcript.
                1 => {
                    try decoder.feed(ctx.a, bytes);
                    while (try decoder.next(&temp)) |event| {
                        const kind = string(event, "$kind");
                        for ([_][]const u8{ kind, string(event, "Status"), string(event, "EventType") }) |terminal| {
                            if (eq(u8, terminal, "TransactionDone") and outcome == .missing) outcome = .done;
                            if (eq(u8, terminal, "TransactionFailed")) outcome = .failed;
                            if (eq(u8, terminal, "TransactionCancelled")) outcome = .cancelled;
                        }
                        if (eq(u8, kind, "q.optdeps")) {
                            if (pending != null or password) return ctx.fail("Overlapping package questions", .{});
                            try u.write(input[1], try encode(&temp, try optionalAnswer(&temp, event)));
                            try progress(&temp, &cancelled, .{ .kind = "progress", .message = "Selecting all optional dependencies…" });
                        } else if (std.mem.startsWith(u8, kind, "q.")) {
                            if (cancelled) return ctx.fail("Setup cancelled before transaction approval", .{});
                            if (pending != null or password) return ctx.fail("Overlapping package questions", .{});
                            if (!eq(u8, kind, "q.provider") and !eq(u8, kind, "q.yesno") and !eq(u8, kind, "q.transaction") and !eq(u8, kind, "q.pkgbuilddiff")) return ctx.fail("Unsupported Shelly question: {s}", .{kind});
                            number += 1;
                            var pctx = ctx.*;
                            pctx.a = pending_arena.allocator();
                            pending = try pctx.parse(try temp.json(event));
                            const message = if (string(event, "QuestionText").len > 0) string(event, "QuestionText") else if (string(event, "Message").len > 0) string(event, "Message") else "Review Shelly's package request";
                            try temp.emit(.{ .kind = "question", .id = try std.fmt.allocPrint(temp.a, "{d}", .{number}), .event = event, .details = try details(&temp, event, 0), .message = message });
                        } else {
                            var message: []const u8 = "Installing…";
                            for ([_][]const u8{ "ErrorMessage", "Message", "Status", "PackageName" }) |key| if (string(event, key).len > 0) {
                                message = string(event, key);
                                break;
                            };
                            try progress(&temp, &cancelled, .{ .kind = "progress", .message = message[0..@min(message.len, 4096)], .percent = if (get(event, "Percentage") != .null) get(event, "Percentage") else get(event, "Percent") });
                        }
                    }
                },
                else => unreachable,
            }
        }
    }
    if (cancelled or outcome == .cancelled) return ctx.fail("Installation cancelled; installed packages were retained.", .{});
    if (status != 0 or outcome != .done or pending != null or password) return ctx.fail("Shelly did not complete installation", .{});
}
