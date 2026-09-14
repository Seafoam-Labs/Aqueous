//! Bounded worker I/O. The worker runs before GTK initializes, in its own process.
const std = @import("std");
const instance = @import("../instance.zig");
pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/file.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("pty.h");
    @cInclude("termios.h");
    @cInclude("time.h");
});
pub const Value = std.json.Value;
pub const limit = 1024 * 1024;
pub const eq = std.mem.eql;
pub fn str(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn get(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn string(v: Value, key: []const u8) []const u8 {
    return str(get(v, key));
}
pub fn yes(v: Value) bool {
    return v == .bool and v.bool;
}
pub fn items(v: Value) []Value {
    return if (v == .array) v.array.items else &.{};
}
pub fn same(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => eq(u8, a.number_string, b.number_string),
        .string => eq(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!same(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!same(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}
pub fn bytesSame(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |x| return if (b) |y| eq(u8, x, y) else false;
    return b == null;
}
pub fn close(fd: c_int) void {
    if (fd >= 0) _ = c.close(fd);
}
pub fn write(fd: c_int, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = c.write(fd, data[offset..].ptr, data.len - offset);
        if (n < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
pub fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
pub fn env(name: [:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}
pub fn exists(path: [:0]const u8) bool {
    var st: c.struct_stat = undefined;
    return c.lstat(path, &st) == 0;
}
pub fn executable(path: [:0]const u8) bool {
    return c.access(path, c.X_OK) == 0;
}

pub const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    message: ?[]const u8 = null,
    pub fn fail(self: *Context, comptime fmt: []const u8, args: anytype) error{SetupFailed} {
        self.message = std.fmt.allocPrint(self.a, fmt, args) catch "Setup failed";
        return error.SetupFailed;
    }
    pub fn z(self: *Context, s: []const u8) ![:0]u8 {
        if (std.mem.indexOfScalar(u8, s, 0) != null) return self.fail("Invalid embedded NUL", .{});
        return self.a.dupeZ(u8, s);
    }
    pub fn path(self: *Context, parts: []const []const u8) ![:0]u8 {
        return self.z(try std.fs.path.join(self.a, parts));
    }
    pub fn config(self: *Context) ![:0]u8 {
        return self.z(env("XDG_CONFIG_HOME") orelse try self.path(&.{ env("HOME") orelse return error.HomeNotSet, ".config" }));
    }
    pub fn state(self: *Context) ![:0]u8 {
        return self.path(&.{ env("XDG_STATE_HOME") orelse try self.path(&.{ env("HOME") orelse return error.HomeNotSet, ".local/state" }), instance.name });
    }
    pub fn runtime(self: *Context) ![:0]u8 {
        return self.path(&.{ env("XDG_RUNTIME_DIR") orelse return self.fail("XDG_RUNTIME_DIR is required", .{}), instance.name ++ "/welcome-session.json" });
    }
    pub fn parse(self: *Context, bytes: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, self.a, bytes, .{ .allocate = .alloc_always }) catch return self.fail("Invalid JSON from setup transport or recovery file", .{});
    }
    pub fn json(self: *Context, data: anytype) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.a, data, .{});
    }
    pub fn value(self: *Context, data: anytype) !Value {
        return self.parse(try self.json(data));
    }
    pub fn object(_: *Context) Value {
        return .{ .object = .empty };
    }
    pub fn array(self: *Context) Value {
        return .{ .array = std.array_list.Managed(Value).init(self.a) };
    }
    pub fn emit(self: *Context, data: anytype) !void {
        try write(1, try self.json(data));
        try write(1, "\n");
    }
    pub fn reply(self: *Context) !Value {
        var line: std.ArrayList(u8) = .empty;
        while (line.items.len < limit) {
            var byte: [1]u8 = undefined;
            const n = c.read(0, &byte, 1);
            if (n < 0 and std.c._errno().* == c.EINTR) continue;
            if (n <= 0) return self.fail("Setup window disconnected", .{});
            if (byte[0] == '\n') {
                const result = try self.parse(line.items);
                if (yes(get(result, "cancel"))) return self.fail("Setup cancelled", .{});
                return result;
            }
            try line.append(self.a, byte[0]);
        }
        return self.fail("Response exceeded size limit", .{});
    }
    pub fn read(self: *Context, path_: []const u8) !?[]const u8 {
        const path_z = try self.z(path_);
        const fd = c.open(path_z, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
        if (fd < 0) {
            if (std.c._errno().* == c.ENOENT) return null;
            return self.fail("Cannot read configuration (symlinks are refused): {s}", .{path_});
        }
        defer close(fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG or st.st_size > limit)
            return self.fail("Not a bounded regular configuration file: {s}", .{path_});
        return try self.readFd(fd, limit);
    }
    pub fn readFd(self: *Context, fd: c_int, max: usize) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = c.read(fd, &chunk, chunk.len);
            if (n < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return error.ReadFailed;
            }
            if (n == 0) return buf.toOwnedSlice(self.a);
            if (buf.items.len + @as(usize, @intCast(n)) > max) return self.fail("Query or file exceeded size limit", .{});
            try buf.appendSlice(self.a, chunk[0..@intCast(n)]);
        }
    }
    pub fn mkdir(self: *Context, path_: []const u8) !void {
        const path_z = try self.z(path_);
        if (c.mkdir(path_z, 0o700) == 0) return;
        if (std.c._errno().* == c.EEXIST) return;
        if (std.c._errno().* != c.ENOENT) return self.fail("Cannot create directory: {s}", .{path_});
        try self.mkdir(std.fs.path.dirname(path_) orelse return error.InvalidPath);
        if (c.mkdir(path_z, 0o700) != 0 and std.c._errno().* != c.EEXIST) return error.CreateFailed;
    }
    pub fn atomic(self: *Context, path_: []const u8, data: []const u8) !void {
        const directory = std.fs.path.dirname(path_) orelse return error.InvalidPath;
        try self.mkdir(directory);
        _ = try self.read(path_);
        const temporary = try self.path(&.{ directory, ".welcome-XXXXXX" });
        const fd = c.mkostemp(temporary, c.O_CLOEXEC);
        if (fd < 0) return error.CreateFailed;
        defer close(fd);
        defer _ = c.unlink(temporary);
        try write(fd, data);
        if (c.fsync(fd) != 0) return error.SyncFailed;
        if (c.rename(temporary, try self.z(path_)) != 0) return error.RenameFailed;
        try self.syncDir(directory);
    }
    pub fn syncDir(self: *Context, path_: []const u8) !void {
        const fd = c.open(try self.z(path_), c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return error.OpenFailed;
        defer close(fd);
        if (c.fsync(fd) != 0) return error.SyncFailed;
    }
    pub fn jsonWrite(self: *Context, path_: []const u8, v: Value) !void {
        try self.atomic(path_, try self.json(v));
    }
    pub fn argv(self: *Context, args: []const []const u8) ![:null]?[*:0]const u8 {
        const result = try self.a.allocSentinel(?[*:0]const u8, args.len, null);
        for (args, 0..) |arg, i| result[i] = (try self.z(arg)).ptr;
        return result;
    }
    pub fn which(self: *Context, name: []const u8) !bool {
        var paths = std.mem.splitScalar(u8, env("PATH") orelse "/usr/bin:/bin", ':');
        while (paths.next()) |dir| if (executable(try self.path(&.{ dir, name }))) return true;
        return false;
    }
    pub fn run(self: *Context, args: []const []const u8, request: ?Value) ![]const u8 {
        const argv_z = try self.argv(args);
        const input = c.tmpfile() orelse return error.CreateFailed;
        defer _ = c.fclose(input);
        const output = c.tmpfile() orelse return error.CreateFailed;
        defer _ = c.fclose(output);
        const errors = c.tmpfile() orelse return error.CreateFailed;
        defer _ = c.fclose(errors);
        const fds = [_]c_int{ c.fileno(input), c.fileno(output), c.fileno(errors) };
        for (fds) |fd| _ = c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
        if (request) |v| try write(fds[0], try self.json(v));
        _ = c.lseek(fds[0], 0, c.SEEK_SET);
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            for (fds, 0..) |fd, i| {
                if (c.dup2(fd, @intCast(i)) < 0) c._exit(126);
            }
            _ = c.execvp(argv_z[0].?, @ptrCast(argv_z.ptr));
            c._exit(127);
        }
        const until = now() + 30000;
        var status: c_int = 0;
        while (true) {
            const result = c.waitpid(pid, &status, c.WNOHANG);
            if (result == pid) break;
            if (result < 0 and std.c._errno().* != c.EINTR) return error.WaitFailed;
            var st: c.struct_stat = undefined;
            const oversized = c.fstat(fds[1], &st) != 0 or st.st_size > 16 * limit;
            const err_oversized = c.fstat(fds[2], &st) != 0 or st.st_size > 16 * limit;
            if (now() > until or oversized or err_oversized) {
                _ = c.kill(pid, c.SIGKILL);
                while (c.waitpid(pid, &status, 0) < 0 and std.c._errno().* == c.EINTR) {}
                return self.fail("{s} timed out or exceeded the output limit", .{args[0]});
            }
            _ = c.poll(null, 0, 10);
        }
        _ = c.lseek(fds[1], 0, c.SEEK_SET);
        const result = try self.readFd(fds[1], 16 * limit);
        if (status != 0) {
            _ = c.lseek(fds[2], 0, c.SEEK_SET);
            const diagnostics = try self.readFd(fds[2], 16 * limit);
            const detail = if (diagnostics.len > 0) diagnostics[0..@min(4096, diagnostics.len)] else result[0..@min(4096, result.len)];
            return self.fail("{s} failed (status {d}): {s}", .{ args[0], status, if (std.unicode.utf8ValidateSlice(detail)) detail else "invalid diagnostic encoding" });
        }
        return result;
    }
    pub fn helper(self: *Context, command: []const u8, request: ?Value) !Value {
        const args = if (request != null) &[_][]const u8{ "aqueous-config" ++ instance.suffix, command, "--shell", "none", "--request", "-" } else &[_][]const u8{ "aqueous-config" ++ instance.suffix, command, "--shell", "none" };
        const v = try self.parse(try self.run(args, request));
        if (v != .object) return self.fail("Invalid aqueous-config response", .{});
        const ok = get(v, "ok");
        if (ok == .bool and !ok.bool) return self.fail("{s}", .{string(v, "message")});
        return v;
    }
};
