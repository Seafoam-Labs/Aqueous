//! Portal dmenu adapter. stdout is exclusively the selected original label.
//! The DMS UI receives JSON over a private socket and returns an index.
const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("sys/file.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/random.h");
    @cInclude("sys/wait.h");
});

const allocator = std.heap.page_allocator;
const max_input = 1024 * 1024;
// Avoid glibc's transparent sockaddr unions in translated headers. These
// declarations have the POSIX pointer ABI and also work with musl.
extern "c" fn bind(c_int, *const c.struct_sockaddr_un, c.socklen_t) c_int;
extern "c" fn accept4(c_int, ?*c.struct_sockaddr, ?*c.socklen_t, c_int) c_int;
var interrupted = std.atomic.Value(bool).init(false);
var parent: c.pid_t = 0;

fn onSignal(_: c_int) callconv(.c) void {
    interrupted.store(true, .monotonic);
}

fn checkAlive() !void {
    if (interrupted.load(.monotonic) or c.getppid() != parent) return error.RequestClosed;
}

fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn ready(fd: c_int, events: c_short, deadline: ?i64) !void {
    while (true) {
        try checkAlive();
        if (deadline) |end| if (now() >= end) return error.TimedOut;
        var item = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const ret = c.poll(&item, 1, 100);
        if (ret > 0) return;
        if (ret < 0 and c.__errno_location().* != c.EINTR) return error.PollFailed;
    }
}

fn writeAll(fd: c_int, bytes: []const u8, deadline: ?i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try ready(fd, c.POLLOUT, deadline);
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR or c.__errno_location().* == c.EAGAIN) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn readAll(fd: c_int, limit: usize, deadline: ?i64) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        try ready(fd, c.POLLIN, deadline);
        const n = c.read(fd, &buffer, buffer.len);
        if (n == 0) return result.toOwnedSlice(allocator);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR or c.__errno_location().* == c.EAGAIN) continue;
            return error.ReadFailed;
        }
        if (result.items.len + @as(usize, @intCast(n)) > limit) return error.InputTooLarge;
        try result.appendSlice(allocator, buffer[0..@intCast(n)]);
    }
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    const result = std.mem.span(value);
    return if (result.len == 0) null else result;
}

// Each CLI call is bounded and uses argv, never a shell. Drain stdout before
// waiting so a large diagnostic cannot deadlock the child. Kill/reap on errors.
fn ipc(args: []const [:0]const u8) ![]u8 {
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    argv[0] = "dms";
    argv[1] = "ipc";
    argv[2] = "call";
    for (args, 3..) |arg, i| argv[i] = arg;
    var pipe: [2]c_int = undefined;
    if (c.pipe2(&pipe, c.O_CLOEXEC) != 0) return error.PipeFailed;
    defer _ = c.close(pipe[0]);
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        _ = c.dup2(pipe[1], 1);
        const devnull = c.open("/dev/null", c.O_RDONLY);
        if (devnull >= 0) _ = c.dup2(devnull, 0);
        _ = c.execvp("dms", @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.setpgid(pid, pid);
    _ = c.close(pipe[1]);
    var reaped = false;
    defer {
        if (!reaped) {
            _ = c.kill(-pid, c.SIGKILL);
            _ = c.kill(pid, c.SIGKILL);
            while (c.waitpid(pid, null, 0) < 0 and c.__errno_location().* == c.EINTR) {}
        }
    }
    const deadline = now() + 2000;
    const output = try readAll(pipe[0], 64 * 1024, deadline);
    errdefer allocator.free(output);
    var status: c_int = 0;
    while (true) {
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid) {
            reaped = true;
            break;
        }
        if (waited < 0 and c.__errno_location().* != c.EINTR) return error.WaitFailed;
        try checkAlive();
        if (now() >= deadline) return error.TimedOut;
        _ = c.poll(null, 0, 20);
    }
    if (status != 0) return error.DmsIpcFailed;
    return output;
}

fn explicitlyDisabled() !bool {
    var fallback: ?[]u8 = null;
    defer if (fallback) |value| allocator.free(value);
    const config = env("XDG_CONFIG_HOME") orelse blk: {
        const home = env("HOME") orelse return error.NoConfigHome;
        fallback = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        break :blk fallback.?;
    };
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/DankMaterialShell/plugin_settings.json", .{config}, 0);
    defer allocator.free(path);
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) {
        if (c.__errno_location().* == c.ENOENT) return false;
        return error.PluginSettingsUnreadable;
    }
    defer _ = c.close(fd);
    const bytes = try readAll(fd, max_input, now() + 1000);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.PluginSettingsInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.PluginSettingsInvalid;
    const plugin = parsed.value.object.get("aqueousPortal") orelse return false;
    if (plugin != .object) return error.PluginSettingsInvalid;
    const enabled = plugin.object.get("enabled") orelse return false;
    if (enabled != .bool) return error.PluginSettingsInvalid;
    return !enabled.bool;
}

fn ensurePlugin() !void {
    const deadline = now() + 10000;
    while (now() < deadline) {
        try checkAlive();
        if (try explicitlyDisabled()) return error.PluginDisabled;
        const status = ipc(&.{ "plugins", "status", "aqueousPortal" }) catch |err| {
            if (err == error.RequestClosed) return err;
            _ = c.poll(null, 0, 100);
            continue;
        };
        defer allocator.free(status);
        const value = std.mem.trim(u8, status, " \r\n\t");
        if (std.mem.eql(u8, value, "loaded")) return;
        if (std.mem.eql(u8, value, "disabled")) {
            // Only change this plugin through DMS. An explicit false in the
            // user's settings always wins, even on first use after an upgrade.
            if (try explicitlyDisabled()) return error.PluginDisabled;
            const output = try ipc(&.{ "plugins", "enable", "aqueousPortal" });
            allocator.free(output);
        }
        _ = c.poll(null, 0, 100);
    }
    return error.PluginNotReady;
}

fn privateDirectory(path: [:0]const u8) !c_int {
    if (c.mkdir(path, 0o700) != 0 and c.__errno_location().* != c.EEXIST) return error.RuntimeDirectoryFailed;
    const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.RuntimeDirectoryFailed;
    errdefer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_uid != c.getuid() or st.st_mode & 0o077 != 0) return error.RuntimeDirectoryPermissions;
    return fd;
}

fn openPicker(token: [:0]const u8) !void {
    // DMS can report a plugin as loaded one event-loop tick before creating
    // its daemon and registering IPC. Give the actual target time to appear.
    const deadline = now() + 5000;
    while (now() < deadline) {
        const output = ipc(&.{ "aqueousPortal", "open", token }) catch |err| {
            if (err == error.RequestClosed) return err;
            _ = c.poll(null, 0, 100);
            continue;
        };
        defer allocator.free(output);
        const value = std.mem.trim(u8, output, " \t\r\n");
        if (std.mem.eql(u8, value, "opened")) return;
        if (std.mem.eql(u8, value, "busy")) return error.ChooserBusy;
        _ = c.poll(null, 0, 100);
    }
    return error.PickerOpenFailed;
}

fn run() !void {
    parent = c.getppid();
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    _ = c.umask(0o077);
    const input = try readAll(0, max_input, now() + 5000);
    defer allocator.free(input);
    if (!std.unicode.utf8ValidateSlice(input) or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidLabels;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (lines.items.len >= 4096) return error.TooManyLabels;
        try lines.append(allocator, line);
    }
    if (lines.items.len == 0) return error.NoSources;
    const runtime = env("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
    if (!std.fs.path.isAbsolute(runtime)) return error.InvalidRuntimeDirectory;
    const dir = try std.fmt.allocPrintSentinel(allocator, "{s}/aqueous-portal", .{runtime}, 0);
    defer allocator.free(dir);
    const dirfd = try privateDirectory(dir);
    defer _ = c.close(dirfd);
    const lock = c.openat(dirfd, "lock", c.O_CREAT | c.O_RDWR | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (lock < 0) return error.LockFailed;
    defer _ = c.close(lock);
    if (c.flock(lock, c.LOCK_EX | c.LOCK_NB) != 0) return error.ChooserBusy;
    try ensurePlugin();
    var random: [16]u8 = undefined;
    if (c.getrandom(&random, random.len, 0) != random.len) return error.RandomFailed;
    const token = try std.fmt.allocPrintSentinel(allocator, "{s}", .{std.fmt.bytesToHex(random, .lower)}, 0);
    defer allocator.free(token);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.sock", .{ dir, token }, 0);
    defer allocator.free(path);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len >= address.sun_path.len) return error.SocketPathTooLong;
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..path.len], path);
    const server = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (server < 0) return error.SocketFailed;
    defer _ = c.close(server);
    if (bind(server, &address, @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
    defer _ = c.unlink(path);
    if (c.listen(server, 1) != 0) return error.ListenFailed;
    try openPicker(token);
    try ready(server, c.POLLIN, now() + 5000);
    const client = accept4(server, null, null, c.SOCK_CLOEXEC | c.SOCK_NONBLOCK);
    if (client < 0) return error.AcceptFailed;
    defer _ = c.close(client);
    var credentials: c.struct_ucred = undefined;
    var credential_len: c.socklen_t = @sizeOf(c.struct_ucred);
    if (c.getsockopt(client, c.SOL_SOCKET, c.SO_PEERCRED, &credentials, &credential_len) != 0 or credentials.uid != c.getuid()) return error.InvalidPeer;
    const request = try std.json.Stringify.valueAlloc(allocator, .{ .version = 1, .choices = lines.items }, .{});
    defer allocator.free(request);
    try writeAll(client, request, now() + 5000);
    try writeAll(client, "\n", now() + 5000);
    // One newline-terminated reply; do not depend on the UI closing its socket
    // before it has flushed the response. No user selection timeout.
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    while (true) {
        try ready(client, c.POLLIN, null);
        var byte: [1]u8 = undefined;
        const n = c.read(client, &byte, 1);
        if (n == 0) return error.PickerDisconnected;
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR or c.__errno_location().* == c.EAGAIN) continue;
            return error.ReadFailed;
        }
        if (byte[0] == '\n') break;
        if (reply.items.len >= 128) return error.InvalidResponse;
        try reply.append(allocator, byte[0]);
    }
    const parsed = std.json.parseFromSlice(struct { index: ?usize }, allocator, reply.items, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    const index = parsed.value.index orelse return;
    if (index >= lines.items.len) return error.InvalidResponse;
    try writeAll(1, lines.items[index], now() + 1000);
    try writeAll(1, "\n", now() + 1000);
}

pub fn main() void {
    run() catch |err| {
        std.debug.print("aqueous-dms-portal-chooser: {s}\n", .{@errorName(err)});
        c.exit(1);
    };
}
