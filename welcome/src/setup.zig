//! Native setup worker entry point. No GTK initialization or elevated worker.
const std = @import("std");
const instance = @import("instance.zig");
const u = @import("setup/common.zig");
const session = @import("setup/session.zig");
const configuration = @import("setup/configuration.zig");
const shelly = @import("setup/shelly.zig");
const activation = @import("setup/activation.zig");
const Context = u.Context;
const Value = u.Value;
const get = u.get;
const eq = u.eq;
const caps = [_][]const u8{ "shell_none", "schema_fields", "validate", "generation_check", "stdin_requests", "apply_result_v1", "operation_receipts_v1", "candidate_impact_v1", "recoverable_commit_v1" };
const Package = struct { backend: []const u8, name: []const u8 };
fn installed(ctx: *Context, backend: []const u8) !Value {
    const rows = try ctx.parse(try ctx.run(&.{ "shelly", "list", backend, "--json" }, null));
    if (rows != .array) return ctx.fail("Unsupported Shelly package-list format", .{});
    var names = ctx.array();
    for (rows.array.items) |row| {
        const name = get(row, if (eq(u8, backend, "flatpak")) "Id" else "Name");
        if (name != .string) continue;
        try names.array.append(name);
        if (eq(u8, backend, "standard") and eq(u8, name.string, "dms-aqueous")) try names.array.append(.{ .string = "dms-shell" });
    }
    return names;
}
fn has(names: Value, name: []const u8) bool {
    for (u.items(names)) |value| if (eq(u8, u.str(value), name)) return true;
    return false;
}
fn addPackage(ctx: *Context, packages: *std.ArrayList(Package), package: Package) !void {
    for (packages.items) |existing| if (eq(u8, existing.backend, package.backend) and eq(u8, existing.name, package.name)) return;
    try packages.append(ctx.a, package);
}
fn parsePackage(spec: []const u8) !Package {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.InvalidPackage;
    const backend = spec[0..colon];
    const name = spec[colon + 1 ..];
    if (!(eq(u8, backend, "standard") or eq(u8, backend, "aur") or eq(u8, backend, "flatpak")) or name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return error.InvalidPackage;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "@._+-", ch) == null) return error.InvalidPackage;
    return .{ .backend = backend, .name = name };
}
fn installBatch(ctx: *Context, backend: []const u8, names: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(ctx.a, &.{ "shelly", "install", backend });
    try args.appendSlice(ctx.a, names);
    try args.append(ctx.a, "--ui-mode");
    if (eq(u8, backend, "flatpak")) try args.appendSlice(ctx.a, &.{ "--user", "--remote", "flathub" });
    try shelly.install(ctx, args.items);
    const actual = try installed(ctx, backend);
    for (names) |name| if (!has(actual, name)) return ctx.fail("Shelly exited but selected packages are still missing", .{});
}
fn setup(ctx: *Context, shell: []const u8, specs: []const [:0]const u8) !void {
    if (!session.valid(shell)) return ctx.fail("Unknown desktop", .{});
    var packages: std.ArrayList(Package) = .empty;
    if (session.package(shell)) |name| {
        // Request and verify the selected shell itself, including when its
        // preset was already installed but the shell package is missing.
        try addPackage(ctx, &packages, .{ .backend = "standard", .name = name });
        // Git welcome belongs to the split desktop even during recovery from
        // a missing runtime. Do not fall back to a legacy shell-only install.
        if (instance.suffix.len > 0 or try session.runtime(ctx) != null)
            try addPackage(ctx, &packages, .{ .backend = "standard", .name = try std.fmt.allocPrint(ctx.a, "aqueous-shell-{s}" ++ instance.suffix, .{shell}) });
    }
    for (specs) |spec| try addPackage(ctx, &packages, parsePackage(spec) catch return ctx.fail("Invalid package identity", .{}));
    try ctx.mkdir(try ctx.state());
    const lock = u.c.open(try ctx.path(&.{ try ctx.state(), "welcome.lock" }), u.c.O_CREAT | u.c.O_RDWR | u.c.O_NOFOLLOW | u.c.O_CLOEXEC, @as(u.c.mode_t, 0o600));
    if (lock < 0) return ctx.fail("Cannot open setup lock", .{});
    defer u.close(lock);
    if (u.c.flock(lock, u.c.LOCK_EX | u.c.LOCK_NB) != 0) return ctx.fail("Another setup operation is running", .{});
    var journal = try configuration.Journal.init(ctx);
    try journal.recover();
    const conflicts = try configuration.startupConflicts(ctx);
    if (conflicts.len > 0) return ctx.fail("Review custom shell startup before switching:\n{s}", .{conflicts});
    const snapshot = try ctx.helper("snapshot", null);
    const selection_path = try ctx.path(&.{ try ctx.config(), instance.name ++ "/session.toml" });
    const selection_before = try ctx.read(selection_path);
    if (eq(u8, shell, "pearl")) for (caps) |cap| {
        if (!has(get(snapshot, "capabilities"), cap)) return ctx.fail("This aqueous-config build lacks Pearl's required configuration capabilities", .{});
    };
    const proposed = try configuration.request(ctx, snapshot);
    var request = proposed.value;
    const portal = try configuration.portal(ctx);
    const portal_before = try ctx.read(portal.path);
    const candidate = try ctx.helper("validate", request);
    var statuses = ctx.object();
    for (packages.items) |package| if (!statuses.object.contains(package.backend)) {
        try statuses.object.put(ctx.a, package.backend, try installed(ctx, package.backend));
    };
    var review: std.ArrayList(u8) = .empty;
    try review.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "Desktop: {s} — active next login.\nAll optional dependencies offered by Shelly will be selected.\n", .{if (eq(u8, shell, "none")) "Nothing" else shell}));
    for (packages.items) |package| try review.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "{s} ({s}; {s})\n", .{ package.name, package.backend, if (has(get(statuses, package.backend), package.name)) "installed, check optional dependencies" else "install" }));
    try review.appendSlice(ctx.a, "Existing shell settings and packages will be kept.\nManaged launcher, screenshot and lock commands will follow your active shell.\n");
    for (u.items(proposed.preserved)) |key| try review.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "Keep custom command: {s}\n", .{u.str(key)}));
    try review.appendSlice(ctx.a, portal.note orelse "The screen-sharing picker will follow your active desktop.");
    try review.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "\nBackups and recovery journal: {s}", .{journal.path}));
    try ctx.emit(.{ .kind = "review", .message = review.items });
    if (!u.yes(get(try ctx.reply(), "accept"))) return ctx.fail("Setup cancelled before making changes", .{});
    if (session.inAqueous() and u.env("XDG_RUNTIME_DIR") != null and !u.exists(try ctx.runtime()))
        try ctx.jsonWrite(try ctx.runtime(), try ctx.value(.{ .shell = try session.selection(ctx), .display = u.env("WAYLAND_DISPLAY") }));
    try journal.value.object.put(ctx.a, "shell", .{ .string = shell });
    var package_values = ctx.array();
    for (packages.items) |package| try package_values.array.append(try ctx.value([_][]const u8{ package.backend, package.name }));
    try journal.value.object.put(ctx.a, "packages", package_values);
    try journal.phase("installing");
    for ([_][]const u8{ "standard", "aur", "flatpak" }) |backend| {
        var names: std.ArrayList([]const u8) = .empty;
        for (packages.items) |package| if (eq(u8, package.backend, backend)) {
            try names.append(ctx.a, package.name);
        };
        if (eq(u8, backend, "flatpak")) {
            for (names.items) |name| try installBatch(ctx, backend, &.{name});
        } else if (names.items.len > 0) try installBatch(ctx, backend, names.items);
    }
    if (!eq(u8, shell, "none") and !try ctx.which(session.shellCommand(shell))) return ctx.fail("The installed shell executable is missing", .{});
    _ = try ctx.helper("validate", request);
    try journal.phase("configuring");
    if (!u.bytesSame(try ctx.read(selection_path), selection_before)) return ctx.fail("Desktop selection changed after review; review setup again", .{});
    if (!u.bytesSame(try ctx.read(portal.path), portal_before)) return ctx.fail("Portal configuration changed after review; review setup again", .{});
    if (portal.data) |data| try journal.write(portal.path, data);
    if (u.items(get(request, "changes")).len > 0 or u.items(get(request, "custom_keybind_changes")).len > 0) {
        if (get(snapshot, "raw_files") != .object or get(candidate, "raw_files") != .object) return ctx.fail("Helper omitted canonical recovery sources", .{});
        try journal.value.object.put(ctx.a, "canonical", try ctx.value(.{ .before = get(snapshot, "raw_files"), .after = get(candidate, "raw_files") }));
        try journal.save();
        try request.object.put(ctx.a, "backup_dir", .{ .string = try ctx.path(&.{ try ctx.state(), "welcome-backups", u.string(journal.value, "id") }) });
        _ = try ctx.helper("apply", request);
    }
    try journal.write(selection_path, try std.fmt.allocPrint(ctx.a, "version = 1\nshell = \"{s}\"\n", .{shell}));
    try journal.phase("complete");
    try session.complete(ctx);
    try ctx.emit(.{ .kind = "done", .selected = shell, .can_activate = activation.available(), .message = if (activation.available()) "Setup complete. Use the Close Welcome button to apply your choice to this session." else "Setup complete. Close Welcome, then log out and back in to use your selected desktop." });
}
fn inspect(ctx: *Context) !void {
    const selected = try session.selection(ctx);
    const explicit = u.exists(try ctx.path(&.{ try ctx.config(), instance.name ++ "/session.toml" }));
    var status: std.ArrayList(u8) = .empty;
    if (installed(ctx, "standard")) |names| {
        for (session.shells[0..3], 0..) |shell, i| {
            if (i != 0) try status.appendSlice(ctx.a, "; ");
            try status.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "{s}: {s}", .{ shell, if (has(names, session.package(shell).?)) "installed" else "not installed" }));
        }
    } else |_| {
        ctx.message = null;
        try status.appendSlice(ctx.a, "Package status unknown — Shelly is unavailable or could not query packages. Nothing remains available.");
    }
    try ctx.emit(.{ .kind = "inspection", .selected = if (explicit or !eq(u8, selected, "none")) selected else "", .message = status.items });
}
fn dispatch(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0) return ctx.fail("Missing worker command", .{});
    if (eq(u8, args[0], "activate")) {
        if (args.len != 2) return error.InvalidArguments;
        try activation.start(ctx, args[1]);
        return 0;
    }
    if (eq(u8, args[0], "setup")) {
        if (args.len < 2) return ctx.fail("Choose a desktop", .{});
        try setup(ctx, args[1], args[2..]);
        return 0;
    }
    if (eq(u8, args[0], "inspect")) {
        if (args.len != 1) return error.InvalidArguments;
        try inspect(ctx);
        return 0;
    }
    if (args.len > 2) return error.InvalidArguments;
    return session.command(ctx, args[0], if (args.len > 1) args[1] else "");
}
pub fn run(init: std.process.Init, executable: []const u8, args: []const [:0]const u8) u8 {
    _ = u.c.signal(u.c.SIGPIPE, u.c.SIG_IGN);
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    var ctx: Context = .{ .a = arena.allocator(), .io = init.io, .executable = executable };
    return dispatch(&ctx, args) catch |err| {
        const message = ctx.message orelse @errorName(err);
        if (args.len > 0 and (eq(u8, args[0], "setup") or eq(u8, args[0], "inspect") or eq(u8, args[0], "activate")))
            ctx.emit(.{ .kind = "error", .message = message }) catch {}
        else {
            u.write(2, message) catch {};
            u.write(2, "\n") catch {};
        }
        return 1;
    };
}
test {
    _ = @import("setup/tests.zig");
}
