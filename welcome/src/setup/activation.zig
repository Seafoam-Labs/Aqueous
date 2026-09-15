//! Explicit post-setup activation of the selected desktop in this session.
const std = @import("std");
const instance = @import("../instance.zig");
const u = @import("common.zig");
const session = @import("session.zig");
const Context = u.Context;

pub fn available() bool {
    const display = u.env("WAYLAND_DISPLAY") orelse return false;
    return session.inAqueous() and !session.nested() and display.len > 0;
}
fn unit(ctx: *Context, shell: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.a, instance.name ++ "-{s}.service", .{shell});
}
fn active(ctx: *Context, name: []const u8) bool {
    _ = ctx.run(&.{ "systemctl", "--user", "is-active", "--quiet", name }, null) catch {
        ctx.message = null;
        return false;
    };
    return true;
}
pub fn start(ctx: *Context, shell: []const u8) !void {
    if (!session.valid(shell)) return ctx.fail("Unknown desktop", .{});
    if (!available()) return ctx.fail("Start your selected desktop from its Aqueous session, or log out and back in.", .{});
    const lock = u.c.open(try ctx.path(&.{ try ctx.state(), "welcome.lock" }), u.c.O_RDWR | u.c.O_NOFOLLOW | u.c.O_CLOEXEC);
    if (lock < 0) return ctx.fail("Complete setup before starting the desktop", .{});
    defer u.close(lock);
    if (u.c.flock(lock, u.c.LOCK_EX | u.c.LOCK_NB) != 0) return ctx.fail("Another setup operation is running", .{});
    if (!u.eq(u8, try session.selection(ctx), shell)) return ctx.fail("Desktop selection changed; review setup again", .{});
    _ = try ctx.run(&.{ "systemctl", "--user", "is-active", "--quiet", "graphical-session.target" }, null);
    // A user manager is shared across logins. Do not start a shell on another
    // session's display or overwrite its imported environment.
    const environment = try ctx.run(&.{ "systemctl", "--user", "show-environment" }, null);
    const display = try std.fmt.allocPrint(ctx.a, "WAYLAND_DISPLAY={s}", .{u.env("WAYLAND_DISPLAY").?});
    var lines = std.mem.splitScalar(u8, environment, '\n');
    var matching_display = false;
    while (lines.next()) |line| if (u.eq(u8, line, display)) {
        matching_display = true;
    };
    if (!matching_display) return ctx.fail("The service manager belongs to a different display. Log out and back in to use your selection.", .{});
    _ = try ctx.run(&.{ "systemctl", "--user", "daemon-reload" }, null);
    const selected_unit = try unit(ctx, shell);
    if (!u.eq(u8, shell, "none")) {
        if (!try ctx.which(session.shellCommand(shell))) return ctx.fail("The selected desktop executable is missing", .{});
        const load = try ctx.run(&.{ "systemctl", "--user", "show", "--property=LoadState", "--value", selected_unit }, null);
        if (!u.eq(u8, std.mem.trim(u8, load, " \r\n"), "loaded")) return ctx.fail("The selected Aqueous desktop service is missing; reinstall its shell preset", .{});
        _ = try ctx.run(&.{ "systemctl", "--user", "enable", selected_unit }, null);
    }
    const snapshot = try ctx.runtime();
    const before = try ctx.read(snapshot);
    var stopped: std.ArrayList([]const u8) = .empty;
    const already_active = !u.eq(u8, shell, "none") and active(ctx, selected_unit);
    var attempted_start = false;
    errdefer {
        const reason = ctx.message;
        var restored = true;
        if (attempted_start and !already_active) {
            _ = ctx.run(&.{ "systemctl", "--user", "stop", selected_unit }, null) catch {
                restored = false;
            };
        }
        if (before) |bytes| {
            ctx.atomic(snapshot, bytes) catch {
                restored = false;
            };
        } else if (u.c.unlink(snapshot) != 0 and std.c._errno().* != u.c.ENOENT) restored = false;
        for (stopped.items) |name| {
            _ = ctx.run(&.{ "systemctl", "--user", "start", name }, null) catch {
                restored = false;
            };
        }
        ctx.message = if (restored) reason else std.fmt.allocPrint(ctx.a, "{s}\nThe previous desktop could not be fully restored. Log out and back in to recover.", .{reason orelse "Desktop activation failed"}) catch reason;
    }
    for (session.shells[0..3]) |other| {
        const name = try unit(ctx, other);
        if (!u.eq(u8, other, shell) and active(ctx, name)) {
            try stopped.append(ctx.a, name);
            _ = try ctx.run(&.{ "systemctl", "--user", "stop", name }, null);
        }
    }
    if (!u.eq(u8, try session.selection(ctx), shell)) return ctx.fail("Desktop selection changed; review setup again", .{});
    try session.prepare(ctx);
    if (!u.eq(u8, shell, "none")) {
        attempted_start = true;
        _ = try ctx.run(&.{ "systemctl", "--user", "start", selected_unit }, null);
        _ = ctx.run(&.{ "systemctl", "--user", "is-active", "--quiet", selected_unit }, null) catch return ctx.fail("The selected desktop service did not become active. Review its user service journal and retry.", .{});
    }
    // Losing the UI after success must not undo the requested activation.
    ctx.emit(.{ .kind = "activated", .message = "Your selected desktop is ready." }) catch {};
}
