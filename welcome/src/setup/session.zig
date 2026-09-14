//! Native compatibility for legacy session callers; split sessions own a shell runtime.
const std = @import("std");
const u = @import("common.zig");
const c = u.c;
const Context = u.Context;
const eq = u.eq;
pub const shells = [_][]const u8{ "pearl", "dms", "noctalia", "none" };
pub fn valid(shell: []const u8) bool {
    for (shells) |s| if (eq(u8, s, shell)) return true;
    return false;
}
pub fn package(shell: []const u8) ?[]const u8 {
    if (eq(u8, shell, "pearl")) return "pearl-de";
    if (eq(u8, shell, "dms")) return "dms-shell";
    if (eq(u8, shell, "noctalia")) return "noctalia";
    return null;
}
pub fn runtime(ctx: *Context) !?[:0]const u8 {
    const path = try ctx.z(u.env("AQUEOUS_SESSION_RUNTIME") orelse try ctx.path(&.{ std.fs.path.dirname(std.fs.path.dirname(ctx.executable).?).?, "lib/aqueous/session-runtime.sh" }));
    return if (u.exists(path)) path else null;
}
pub fn inAqueous() bool {
    var it = std.mem.splitScalar(u8, u.env("XDG_CURRENT_DESKTOP") orelse "", ':');
    while (it.next()) |s| if (std.ascii.eqlIgnoreCase(s, "aqueous")) return true;
    return false;
}
pub fn nested() bool {
    return eq(u8, u.env("AQUEOUS_NESTED") orelse "0", "1");
}
// Selection is a versioned two-field document. Recognize quoted keys, basic and
// literal strings, CRLF and comments. Refuse duplicates instead of guessing.
pub fn parseSelection(ctx: *Context, bytes: []const u8) ![]const u8 {
    var version = false;
    var selected: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var quote: u8 = 0;
        var escape = false;
        var end = line.len;
        for (line, 0..) |ch, i| {
            if (escape) {
                escape = false;
                continue;
            }
            if (quote == '"' and ch == '\\') {
                escape = true;
                continue;
            }
            if (quote != 0) {
                if (ch == quote) quote = 0;
            } else if (ch == '"' or ch == '\'') quote = ch else if (ch == '#') {
                end = i;
                break;
            }
        }
        const text = std.mem.trim(u8, line[0..end], " \t\r");
        if (text.len == 0) continue;
        if (quote != 0) return ctx.fail("Invalid Aqueous session selection", .{});
        const equal = std.mem.indexOfScalar(u8, text, '=') orelse return ctx.fail("Invalid Aqueous session selection", .{});
        var key = std.mem.trim(u8, text[0..equal], " \t");
        if (key.len >= 2 and (key[0] == '"' or key[0] == '\'') and key[key.len - 1] == key[0]) key = key[1 .. key.len - 1];
        const value = std.mem.trim(u8, text[equal + 1 ..], " \t");
        if (eq(u8, key, "version")) {
            if (version or !(eq(u8, value, "1") or eq(u8, value, "+1") or eq(u8, value, "0x1") or eq(u8, value, "0o1") or eq(u8, value, "0b1"))) return ctx.fail("Invalid Aqueous session version", .{});
            version = true;
        } else if (eq(u8, key, "shell")) {
            if (selected != null or value.len < 2) return ctx.fail("Invalid Aqueous session selection", .{});
            if (value[0] == '\'' and value[value.len - 1] == '\'') selected = value[1 .. value.len - 1] else if (value[0] == '"') selected = u.str(try ctx.parse(value)) else return ctx.fail("Invalid Aqueous session selection", .{});
        } else return ctx.fail("Unsupported session selection field: {s}; review session.toml", .{key});
    }
    if (!version or selected == null or !valid(selected.?)) return ctx.fail("Invalid Aqueous session selection", .{});
    return selected.?;
}
pub fn selection(ctx: *Context) ![]const u8 {
    if (try runtime(ctx)) |path| {
        const result = std.mem.trim(u8, try ctx.run(&.{ path, "selection" }, null), " \r\n\t");
        if (!valid(result)) return ctx.fail("Invalid session runtime response", .{});
        return result;
    }
    if (try ctx.read(try ctx.path(&.{ try ctx.config(), "aqueous/session.toml" }))) |bytes| return parseSelection(ctx, bytes);
    var found: ?[]const u8 = null;
    var count: usize = 0;
    if (try ctx.read(try ctx.path(&.{ try ctx.config(), "aqueous/wm.toml" }))) |bytes| {
        for (shells[0..3]) |shell| {
            const legacy_command = if (eq(u8, shell, "pearl")) "pearlctl " else try std.fmt.allocPrint(ctx.a, "{s} ", .{shell});
            if (std.mem.indexOf(u8, bytes, legacy_command) != null) {
                count += 1;
                found = shell;
            }
        }
        if (count == 1 and try ctx.which(found.?)) return found.?;
    }
    // Legacy completed installations may not yet have an explicit selection.
    if (u.exists(try ctx.path(&.{ try ctx.state(), "welcome-v1" }))) {
        count = 0;
        for (shells[0..3]) |shell| if (try ctx.which(shell)) {
            count += 1;
            found = shell;
        };
        if (count == 1) return found.?;
    }
    return "none";
}
pub fn active(ctx: *Context) ![]const u8 {
    if (try runtime(ctx)) |path| {
        const result = std.mem.trim(u8, try ctx.run(&.{ path, "active-selection" }, null), " \r\n\t");
        if (!valid(result)) return error.InvalidSelection;
        return result;
    }
    if (u.env("XDG_RUNTIME_DIR") != null) {
        const bytes = ctx.read(try ctx.runtime()) catch null;
        if (bytes) |data| {
            const value = ctx.parse(data) catch .null;
            const shell = u.string(value, "shell");
            if (valid(shell) and eq(u8, u.string(value, "display"), u.env("WAYLAND_DISPLAY") orelse "")) return shell;
        }
    }
    return selection(ctx);
}
pub fn complete(ctx: *Context) !void {
    try ctx.atomic(try ctx.path(&.{ try ctx.state(), "welcome-v1" }), "Aqueous welcome completed\n");
    try ctx.atomic(try ctx.path(&.{ try ctx.config(), "autostart/org.aqueous.Welcome.desktop" }), "[Desktop Entry]\nType=Application\nName=Welcome to Aqueous\nHidden=true\n");
}
pub fn exec(ctx: *Context, args: []const []const u8) !void {
    const argv = try ctx.argv(args);
    _ = c.signal(c.SIGPIPE, c.SIG_DFL);
    _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
    return ctx.fail("Cannot execute {s}", .{args[0]});
}
fn recover(ctx: *Context) !void {
    const argv = try ctx.argv(&.{ ctx.executable, "--message", "Your selected shell is missing. Run setup to install it or choose another desktop." });
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const fd = c.open("/dev/null", c.O_RDWR);
        if (fd < 0) c._exit(126);
        for (0..3) |i| _ = c.dup2(fd, @intCast(i));
        u.close(fd);
        _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
}
pub fn prepare(ctx: *Context) !void {
    if (!inAqueous() or nested()) return;
    var shell = try selection(ctx);
    if (!eq(u8, shell, "none") and !try ctx.which(shell)) {
        shell = "none";
        try recover(ctx);
    }
    try ctx.jsonWrite(try ctx.runtime(), try ctx.value(.{ .shell = shell, .display = u.env("WAYLAND_DISPLAY") }));
    if (eq(u8, shell, "noctalia")) {
        const destination = try ctx.path(&.{ try ctx.config(), "noctalia/config.toml" });
        const source = try ctx.path(&.{ u.env("AQUEOUS_SHARE_DIR") orelse "/usr/share/aqueous", "noctalia/config.toml" });
        if (!u.exists(destination)) if (try ctx.read(source)) |bytes| {
            try ctx.atomic(destination, bytes);
        };
    }
}
pub fn action(ctx: *Context, name: []const u8) !void {
    const shell = try active(ctx);
    if (eq(u8, name, "screenshot")) {
        const geometry = std.mem.trim(u8, try ctx.run(&.{"slurp"}, null), " \t\r\n");
        if (geometry.len == 0) return;
        const image = try ctx.argv(&.{ "grim", "-g", geometry, "-" });
        const copy = try ctx.argv(&.{ "wl-copy", "--type", "image/png" });
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
        defer for (fds) |fd| u.close(fd);
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = c.dup2(fds[1], 1);
            _ = c.execvp(image[0].?, @ptrCast(image.ptr));
            c._exit(127);
        }
        u.close(fds[1]);
        fds[1] = -1;
        const copier = c.fork();
        if (copier < 0) {
            _ = c.kill(pid, c.SIGTERM);
            _ = c.waitpid(pid, null, 0);
            return error.ForkFailed;
        }
        if (copier == 0) {
            _ = c.dup2(fds[0], 0);
            _ = c.execvp(copy[0].?, @ptrCast(copy.ptr));
            c._exit(127);
        }
        u.close(fds[0]);
        fds[0] = -1;
        var status: c_int = 0;
        var copy_status: c_int = 0;
        while (c.waitpid(pid, &status, 0) < 0 and std.c._errno().* == c.EINTR) {}
        while (c.waitpid(copier, &copy_status, 0) < 0 and std.c._errno().* == c.EINTR) {}
        if (status != 0 or copy_status != 0) return ctx.fail("Screenshot failed", .{});
        return;
    }
    if (eq(u8, name, "chooser")) {
        if (eq(u8, shell, "dms")) return exec(ctx, &.{try ctx.path(&.{ std.fs.path.dirname(std.fs.path.dirname(ctx.executable).?).?, "lib/aqueous/aqueous-dms-portal-chooser" })});
        if (eq(u8, shell, "noctalia")) return exec(ctx, &.{ "noctalia", "dmenu", "-p", "Select a source to share:" });
        return exec(ctx, &.{ ctx.executable, "--choose" });
    }
    const lock = eq(u8, name, "lock");
    if (!lock and !eq(u8, name, "launcher")) return ctx.fail("Unknown action: {s}", .{name});
    if (eq(u8, shell, "pearl")) return exec(ctx, if (lock) &.{ "pearlctl", "lock" } else &.{ "pearlctl", "launcher", "toggle" });
    if (eq(u8, shell, "dms")) return exec(ctx, if (lock) &.{ "dms", "ipc", "call", "lock", "lock" } else &.{ "dms", "ipc", "call", "spotlight", "toggle" });
    if (eq(u8, shell, "noctalia")) return exec(ctx, if (lock) &.{ "noctalia", "msg", "lock" } else &.{ "noctalia", "msg", "panel-toggle", "launcher" });
    return exec(ctx, if (lock) &.{ ctx.executable, "--message", "No screen locker is configured for this shell-free session." } else &.{ctx.executable});
}
pub fn command(ctx: *Context, cmd: []const u8, arg: []const u8) !u8 {
    if (try runtime(ctx)) |path| {
        try exec(ctx, if (arg.len > 0) &.{ path, cmd, arg } else &.{ path, cmd });
        return 0;
    }
    if (eq(u8, cmd, "prepare-session")) {
        try prepare(ctx);
        return 0;
    }
    if (eq(u8, cmd, "external-condition")) return if (inAqueous()) 1 else 0;
    if (eq(u8, cmd, "condition")) return if (inAqueous() and !nested() and eq(u8, try active(ctx), arg)) 0 else 1;
    if (eq(u8, cmd, "selection")) {
        try u.write(1, try selection(ctx));
        try u.write(1, "\n");
        return 0;
    }
    if (eq(u8, cmd, "active-selection")) {
        try u.write(1, try active(ctx));
        try u.write(1, "\n");
        return 0;
    }
    if (eq(u8, cmd, "action")) {
        try action(ctx, arg);
        return 0;
    }
    return ctx.fail("Unknown worker command: {s}", .{cmd});
}
