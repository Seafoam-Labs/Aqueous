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
fn activeState(ctx: *Context, name: []const u8) ![]const u8 {
    return std.mem.trim(u8, try ctx.run(&.{ "systemctl", "--user", "show", "--property=ActiveState", "--value", name }, null), " \t\r\n");
}

pub fn start(ctx: *Context, shell: []const u8) !void {
    try activate(ctx, shell, false);
}

pub fn switchShell(ctx: *Context, shell: []const u8) !void {
    if (instance.suffix.len == 0) return ctx.fail("Shell switching is only available in Aqueous Git sessions", .{});
    if (!session.valid(shell) or u.eq(u8, shell, "none")) return ctx.fail("Choose pearl, dms, or noctalia", .{});
    if (!u.eq(u8, u.env("AQUEOUS_INSTANCE") orelse "", instance.name)) return ctx.fail("Run this command in the matching Aqueous Git session", .{});
    try activate(ctx, shell, true);
}

fn activate(ctx: *Context, shell: []const u8, switching: bool) !void {
    if (!session.valid(shell)) return ctx.fail("Unknown desktop", .{});
    if (!available()) return ctx.fail("Start your selected desktop from its Aqueous session, or log out and back in.", .{});
    if (switching) try ctx.mkdir(try ctx.state());
    const lock = u.c.open(try ctx.path(&.{ try ctx.state(), "welcome.lock" }), u.c.O_RDWR | u.c.O_NOFOLLOW | u.c.O_CLOEXEC | (if (switching) @as(c_int, u.c.O_CREAT) else 0), @as(u.c.mode_t, 0o600));
    if (lock < 0) return ctx.fail("Complete setup before starting the desktop", .{});
    defer u.close(lock);
    if (u.c.flock(lock, u.c.LOCK_EX | u.c.LOCK_NB) != 0) return ctx.fail("Another setup operation is running", .{});
    if (!switching and !u.eq(u8, try session.selection(ctx), shell)) return ctx.fail("Desktop selection changed; review setup again", .{});
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
    if (switching) {
        const marker = try std.fmt.allocPrint(ctx.a, "AQUEOUS_INSTANCE={s}", .{instance.name});
        lines = std.mem.splitScalar(u8, environment, '\n');
        var matching_instance = false;
        while (lines.next()) |line| if (u.eq(u8, line, marker)) {
            matching_instance = true;
        };
        if (!matching_instance) return ctx.fail("The service manager belongs to a different Aqueous instance", .{});
    }
    _ = try ctx.run(&.{ "systemctl", "--user", "daemon-reload" }, null);
    const selected_unit = try unit(ctx, shell);
    if (!u.eq(u8, shell, "none")) {
        if (!try ctx.which(session.shellCommand(shell))) return ctx.fail("The selected desktop executable is missing; install {s} and aqueous-shell-{s}" ++ instance.suffix, .{ session.package(shell).?, shell });
        const load = try ctx.run(&.{ "systemctl", "--user", "show", "--property=LoadState", "--value", selected_unit }, null);
        const load_state = std.mem.trim(u8, load, " \t\r\n");
        if (!u.eq(u8, load_state, "loaded")) {
            if (u.eq(u8, load_state, "not-found")) return ctx.fail("systemd cannot find {s} (LoadState=not-found), even after daemon-reload. The unit is provided by aqueous-integration-{s}" ++ instance.suffix ++ "; check that package's installed files and the user unit search path.", .{ selected_unit, shell });
            return ctx.fail("Cannot start {s}: LoadState={s}. Inspect it with: systemctl --user status {s}. An installed preset does not guarantee that its service can be loaded.", .{ selected_unit, if (load_state.len == 0) "<empty response>" else load_state, selected_unit });
        }
        if (!switching) _ = try ctx.run(&.{ "systemctl", "--user", "enable", selected_unit }, null);
    }
    const snapshot = try ctx.runtime();
    const before = try ctx.read(snapshot);
    const selection_path = try ctx.path(&.{ try ctx.config(), instance.name ++ "/session.toml" });
    const selection_before = if (switching) try ctx.read(selection_path) else null;
    const previous = if (switching) try session.selection(ctx) else shell;
    if (switching) {
        const state = try ctx.parse(before orelse return ctx.fail("No active Git session snapshot; log out and back in", .{}));
        if (!session.valid(u.string(state, "shell")) or !u.eq(u8, u.string(state, "display"), u.env("WAYLAND_DISPLAY").?))
            return ctx.fail("The active desktop snapshot belongs to a different display", .{});
    }
    var selection_written = false;
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
        if (selection_written) {
            if (selection_before) |bytes| {
                ctx.atomic(selection_path, bytes) catch {
                    restored = false;
                };
            } else if (u.c.unlink(selection_path) != 0 and std.c._errno().* != u.c.ENOENT) restored = false;
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
        if (u.eq(u8, other, shell)) continue;
        const name = try unit(ctx, other);
        const state = try activeState(ctx, name);
        if (u.eq(u8, state, "inactive")) continue;
        // is-active excludes starting/restarting units, which may already have
        // a Quickshell child. Stop every non-inactive managed unit and wait.
        // Restore only units that were meant to be running before this switch.
        if (!u.eq(u8, state, "failed") and !u.eq(u8, state, "deactivating"))
            try stopped.append(ctx.a, name);
        _ = try ctx.run(&.{ "systemctl", "--user", "stop", name }, null);
        const after = try activeState(ctx, name);
        // A failed unit can retain its failure state after a stop job.
        if (!u.eq(u8, after, "inactive") and !u.eq(u8, after, "failed"))
            return ctx.fail("Desktop service {s} did not stop (ActiveState={s}); the new shell was not started", .{ name, after });
    }
    if (!switching and !u.eq(u8, try session.selection(ctx), shell)) return ctx.fail("Desktop selection changed; review setup again", .{});
    if (switching) {
        if (!u.bytesSame(try ctx.read(selection_path), selection_before) or !u.eq(u8, try session.selection(ctx), previous))
            return ctx.fail("Desktop selection changed during switching; retry", .{});
        const state = try ctx.parse(before.?);
        if (already_active and stopped.items.len == 0 and u.eq(u8, previous, shell) and u.eq(u8, u.string(state, "shell"), shell)) return;
        selection_written = true;
        try ctx.atomic(selection_path, try std.fmt.allocPrint(ctx.a, "version = 1\nshell = \"{s}\"\n", .{shell}));
        // Switching never seeds or edits any shell's own configuration.
        try ctx.jsonWrite(snapshot, try ctx.value(.{ .shell = shell, .display = u.env("WAYLAND_DISPLAY").? }));
    } else try session.prepare(ctx);
    if (!u.eq(u8, shell, "none")) {
        attempted_start = true;
        _ = try ctx.run(&.{ "systemctl", "--user", "start", selected_unit }, null);
        _ = ctx.run(&.{ "systemctl", "--user", "is-active", "--quiet", selected_unit }, null) catch return ctx.fail("The selected desktop service did not become active. Review its user service journal and retry.", .{});
    }
    // Losing the UI after success must not undo the requested activation.
    if (!switching) ctx.emit(.{ .kind = "activated", .message = "Your selected desktop is ready." }) catch {};
}
