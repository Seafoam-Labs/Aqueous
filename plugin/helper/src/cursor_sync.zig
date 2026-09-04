const std = @import("std");
const config = @import("aqueous_config_document");

const Allocator = std.mem.Allocator;

pub const target_count = 6;

pub const CursorSpec = struct {
    managed: bool,
    theme: []const u8,
    size: u32,
};

pub const TargetStatus = struct {
    id: []const u8,
    available: bool,
    active: bool,
    synced: bool,
    state: []const u8,
};

pub const Report = struct {
    targets: [target_count]TargetStatus,

    pub fn failedCount(self: *const Report) usize {
        var count: usize = 0;
        for (self.targets) |target| if (std.mem.eql(u8, target.state, "failed")) {
            count += 1;
        };
        return count;
    }
};

pub const LiveState = struct {
    available: bool = false,
    theme: []const u8 = "",
    size: u32 = 0,
};

pub fn validateTheme(theme: []const u8) !void {
    const trimmed = std.mem.trim(u8, theme, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyCursorTheme;
    if (trimmed.len > 255) return error.CursorThemeTooLong;
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) return error.InvalidCursorTheme;
    for (trimmed) |byte| {
        if (byte == 0 or byte == '\n' or byte == '\r' or byte == '/' or byte == '\\') return error.InvalidCursorTheme;
    }
}

pub fn installedThemes(allocator: Allocator, io: std.Io, current: []const u8) ![]const []const u8 {
    var themes = std.ArrayList([]const u8).empty;
    errdefer {
        for (themes.items) |theme| allocator.free(theme);
        themes.deinit(allocator);
    }
    try appendTheme(allocator, &themes, "default");
    try appendTheme(allocator, &themes, current);

    if (getenv("XCURSOR_PATH")) |path| {
        var roots = std.mem.splitScalar(u8, path, ':');
        while (roots.next()) |root| if (root.len > 0) try scanIconRoot(allocator, io, &themes, root);
    }
    if (getenv("HOME")) |home| {
        const legacy = try std.fmt.allocPrint(allocator, "{s}/.icons", .{home});
        defer allocator.free(legacy);
        try scanIconRoot(allocator, io, &themes, legacy);
    }
    if (getenv("XDG_DATA_HOME")) |root| {
        const icons = try std.fmt.allocPrint(allocator, "{s}/icons", .{root});
        defer allocator.free(icons);
        try scanIconRoot(allocator, io, &themes, icons);
    } else if (getenv("HOME")) |home| {
        const icons = try std.fmt.allocPrint(allocator, "{s}/.local/share/icons", .{home});
        defer allocator.free(icons);
        try scanIconRoot(allocator, io, &themes, icons);
    }
    const data_dirs = getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var roots = std.mem.splitScalar(u8, data_dirs, ':');
    while (roots.next()) |root| {
        if (root.len == 0) continue;
        const icons = try std.fmt.allocPrint(allocator, "{s}/icons", .{root});
        defer allocator.free(icons);
        try scanIconRoot(allocator, io, &themes, icons);
    }

    std.mem.sort([]const u8, themes.items, {}, lessThanIgnoreCase);
    return themes.toOwnedSlice(allocator);
}

pub fn validateInstalledTheme(allocator: Allocator, theme: []const u8) !void {
    try validateTheme(theme);
    if (std.ascii.eqlIgnoreCase(theme, "default")) return;
    if (themeExists(allocator, theme)) return;
    return error.CursorThemeNotInstalled;
}

pub fn themeExists(allocator: Allocator, theme: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(theme, "default")) return true;
    if (getenv("XCURSOR_PATH")) |path| {
        var roots = std.mem.splitScalar(u8, path, ':');
        while (roots.next()) |root| if (root.len > 0 and themeExistsInRoot(allocator, root, theme)) return true;
    }
    if (getenv("HOME")) |home| {
        const legacy = std.fmt.allocPrint(allocator, "{s}/.icons", .{home}) catch return false;
        defer allocator.free(legacy);
        if (themeExistsInRoot(allocator, legacy, theme)) return true;
    }
    if (getenv("XDG_DATA_HOME")) |root| {
        const icons = std.fmt.allocPrint(allocator, "{s}/icons", .{root}) catch return false;
        defer allocator.free(icons);
        if (themeExistsInRoot(allocator, icons, theme)) return true;
    } else if (getenv("HOME")) |home| {
        const icons = std.fmt.allocPrint(allocator, "{s}/.local/share/icons", .{home}) catch return false;
        defer allocator.free(icons);
        if (themeExistsInRoot(allocator, icons, theme)) return true;
    }
    const data_dirs = getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var roots = std.mem.splitScalar(u8, data_dirs, ':');
    while (roots.next()) |root| {
        if (root.len == 0) continue;
        const icons = std.fmt.allocPrint(allocator, "{s}/icons", .{root}) catch continue;
        defer allocator.free(icons);
        if (themeExistsInRoot(allocator, icons, theme)) return true;
    }
    return false;
}

pub fn queryLive(allocator: Allocator, io: std.Io) LiveState {
    if (!commandExists("aqueousctl")) return .{};
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = &.{ "aqueousctl", "cursor", "--json" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return .{};
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    if (!succeeded(result.term)) return .{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const ok = jsonBool(parsed.value.object.get("ok")) orelse false;
    const theme = jsonString(parsed.value.object.get("theme")) orelse return .{};
    const size = jsonInteger(parsed.value.object.get("size")) orelse return .{};
    if (!ok or size < 1 or size > 512) return .{};
    return .{ .available = true, .theme = allocator.dupe(u8, theme) catch return .{}, .size = @intCast(size) };
}

pub fn inspect(allocator: Allocator, io: std.Io, spec: *const CursorSpec) Report {
    if (!spec.managed) return unmanagedReport();
    const live = queryLive(allocator, io);
    const expected_env = envContents(allocator, spec) catch "";
    const env_path = uwsmPath(allocator) catch "";
    const theme_size = std.fmt.allocPrint(allocator, "{d}", .{spec.size}) catch "";
    const gtk3_path = configPath(allocator, "gtk-3.0/settings.ini") catch "";
    const gtk4_path = configPath(allocator, "gtk-4.0/settings.ini") catch "";
    const activation_available = commandExists("systemctl") and commandExists("dbus-update-activation-environment");
    const gsettings_available = commandExists("gsettings");
    return .{ .targets = .{
        status("aqueous", live.available, live.available, live.available and std.mem.eql(u8, live.theme, spec.theme) and live.size == spec.size),
        status("uwsm", true, true, fileMatches(allocator, env_path, expected_env)),
        status("activation", activation_available, activation_available, activation_available and activationMatches(io, spec)),
        status("gtk3", true, true, documentMatches(allocator, gtk3_path, spec)),
        status("gtk4", true, true, documentMatches(allocator, gtk4_path, spec)),
        status("gsettings", gsettings_available, gsettings_available, gsettings_available and gsettingsMatches(io, spec, theme_size)),
    } };
}

pub fn apply(allocator: Allocator, io: std.Io, spec: *const CursorSpec) Report {
    if (!spec.managed) {
        const removed = removeUwsmFile(allocator, io);
        var report = unmanagedReport();
        report.targets[1] = appliedStatus("uwsm", true, true, removed);
        return report;
    }

    const env_ok = writeUwsmFile(allocator, spec);
    const size_text = std.fmt.allocPrint(allocator, "{d}", .{spec.size}) catch "";
    const aqueous_available = commandExists("aqueousctl");
    const aqueous_ok = aqueous_available and runQuiet(io, &.{
        "aqueousctl", "cursor", "set", "--theme", spec.theme, "--size", size_text, "--json",
    });

    const systemd_available = commandExists("systemctl");
    const dbus_available = commandExists("dbus-update-activation-environment");
    const theme_assignment = std.fmt.allocPrint(allocator, "XCURSOR_THEME={s}", .{spec.theme}) catch "";
    const size_assignment = std.fmt.allocPrint(allocator, "XCURSOR_SIZE={d}", .{spec.size}) catch "";
    const systemd_ok = !systemd_available or runQuiet(io, &.{
        "systemctl", "--user", "set-environment", theme_assignment, size_assignment,
    });
    const dbus_ok = !dbus_available or runQuiet(io, &.{
        "dbus-update-activation-environment", "--systemd", theme_assignment, size_assignment,
    });
    const activation_available = systemd_available and dbus_available;

    const gtk3_path = configPath(allocator, "gtk-3.0/settings.ini") catch "";
    const gtk4_path = configPath(allocator, "gtk-4.0/settings.ini") catch "";
    const gtk3_ok = updateGtk(allocator, gtk3_path, spec, size_text);
    const gtk4_ok = updateGtk(allocator, gtk4_path, spec, size_text);
    const gsettings_available = commandExists("gsettings");
    const gsettings_ok = !gsettings_available or (runQuiet(io, &.{
        "gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", spec.theme,
    }) and runQuiet(io, &.{
        "gsettings", "set", "org.gnome.desktop.interface", "cursor-size", size_text,
    }));

    return .{ .targets = .{
        appliedStatus("aqueous", aqueous_available, aqueous_available, aqueous_ok),
        appliedStatus("uwsm", true, true, env_ok),
        appliedStatus("activation", activation_available, activation_available, systemd_ok and dbus_ok),
        appliedStatus("gtk3", true, true, gtk3_ok),
        appliedStatus("gtk4", true, true, gtk4_ok),
        appliedStatus("gsettings", gsettings_available, gsettings_available, gsettings_ok),
    } };
}

fn unmanagedReport() Report {
    return .{ .targets = .{
        unmanagedStatus("aqueous"), unmanagedStatus("uwsm"), unmanagedStatus("activation"),
        unmanagedStatus("gtk3"),    unmanagedStatus("gtk4"), unmanagedStatus("gsettings"),
    } };
}

fn scanIconRoot(allocator: Allocator, io: std.Io, themes: *std.ArrayList([]const u8), root: []const u8) !void {
    var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch return) |entry| {
        validateTheme(entry.name) catch continue;
        const cursors = std.fs.path.join(allocator, &.{ root, entry.name, "cursors" }) catch continue;
        defer allocator.free(cursors);
        if (!pathExists(cursors)) continue;
        try appendTheme(allocator, themes, entry.name);
    }
}

fn themeExistsInRoot(allocator: Allocator, root: []const u8, theme: []const u8) bool {
    const cursors = std.fs.path.join(allocator, &.{ root, theme, "cursors" }) catch return false;
    defer allocator.free(cursors);
    return pathExists(cursors);
}

fn appendTheme(allocator: Allocator, themes: *std.ArrayList([]const u8), raw: []const u8) !void {
    const theme = std.mem.trim(u8, raw, " \t\r\n");
    validateTheme(theme) catch return;
    for (themes.items) |existing| if (std.ascii.eqlIgnoreCase(existing, theme)) return;
    try themes.append(allocator, try allocator.dupe(u8, theme));
}

fn lessThanIgnoreCase(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(lhs, rhs);
}

fn envContents(allocator: Allocator, spec: *const CursorSpec) ![]u8 {
    const quoted = try shellQuote(allocator, spec.theme);
    defer allocator.free(quoted);
    return std.fmt.allocPrint(allocator, "# Generated by Aqueous Settings. Manual edits may be replaced.\nexport XCURSOR_THEME={s}\nexport XCURSOR_SIZE='{d}'\n", .{ quoted, spec.size });
}

fn shellQuote(allocator: Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try result.appendSlice(allocator, "'\"'\"'") else try result.append(allocator, byte);
    }
    try result.append(allocator, '\'');
    return result.toOwnedSlice(allocator);
}

fn writeUwsmFile(allocator: Allocator, spec: *const CursorSpec) bool {
    const path = uwsmPath(allocator) catch return false;
    const source = envContents(allocator, spec) catch return false;
    var document = config.Document.init(allocator, source) catch return false;
    defer document.deinit();
    return if (document.write(path)) true else |_| false;
}

fn removeUwsmFile(allocator: Allocator, io: std.Io) bool {
    const path = uwsmPath(allocator) catch return false;
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| return err == error.FileNotFound;
    return true;
}

fn uwsmPath(allocator: Allocator) ![]u8 {
    return configPath(allocator, "uwsm/env-aqueous.d/90-aqueous-cursor");
}

fn updateGtk(allocator: Allocator, path: []const u8, spec: *const CursorSpec, size: []const u8) bool {
    if (path.len == 0) return false;
    var document = config.Document.read(allocator, path) catch return false;
    defer document.deinit();
    document.setRaw("Settings", "gtk-cursor-theme-name", spec.theme) catch return false;
    document.setRaw("Settings", "gtk-cursor-theme-size", size) catch return false;
    document.write(path) catch return false;
    return true;
}

fn documentMatches(allocator: Allocator, path: []const u8, spec: *const CursorSpec) bool {
    if (!pathExists(path)) return false;
    var document = config.Document.read(allocator, path) catch return false;
    defer document.deinit();
    const theme = document.getRaw("Settings", "gtk-cursor-theme-name") orelse return false;
    const size = document.getRaw("Settings", "gtk-cursor-theme-size") orelse return false;
    return std.mem.eql(u8, unquote(theme), spec.theme) and
        (std.fmt.parseInt(u32, unquote(size), 10) catch 0) == spec.size;
}

fn fileMatches(allocator: Allocator, path: []const u8, expected: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(16 * 1024)) catch return false;
    return std.mem.eql(u8, source, expected);
}

fn activationMatches(io: std.Io, spec: *const CursorSpec) bool {
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = &.{ "systemctl", "--user", "show-environment" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    if (!succeeded(result.term)) return false;
    var theme_ok = false;
    var size_ok = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "XCURSOR_THEME=")) theme_ok = std.mem.eql(u8, line[14..], spec.theme);
        if (std.mem.startsWith(u8, line, "XCURSOR_SIZE=")) size_ok = (std.fmt.parseInt(u32, line[13..], 10) catch 0) == spec.size;
    }
    return theme_ok and size_ok;
}

fn gsettingsMatches(io: std.Io, spec: *const CursorSpec, size_text: []const u8) bool {
    return gsettingsValueMatches(io, "cursor-theme", spec.theme) and gsettingsValueMatches(io, "cursor-size", size_text);
}

fn gsettingsValueMatches(io: std.Io, key: []const u8, expected: []const u8) bool {
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", key },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return false;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    return succeeded(result.term) and std.mem.eql(u8, unquote(std.mem.trim(u8, result.stdout, " \t\r\n")), expected);
}

fn status(id: []const u8, available: bool, active: bool, synced: bool) TargetStatus {
    return .{ .id = id, .available = available, .active = active, .synced = synced, .state = if (!available) "unavailable" else if (synced) "synced" else "drifted" };
}

fn appliedStatus(id: []const u8, available: bool, active: bool, synced: bool) TargetStatus {
    return .{ .id = id, .available = available, .active = active, .synced = synced, .state = if (!available) "unavailable" else if (synced) "synced" else "failed" };
}

fn unmanagedStatus(id: []const u8) TargetStatus {
    return .{ .id = id, .available = true, .active = false, .synced = false, .state = "unmanaged" };
}

fn runQuiet(io: std.Io, argv: []const []const u8) bool {
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    return succeeded(result.term);
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn commandExists(name: []const u8) bool {
    const candidate = commandPath(std.heap.c_allocator, name) orelse return false;
    std.heap.c_allocator.free(candidate);
    return true;
}

fn commandPath(allocator: Allocator, name: []const u8) ?[]u8 {
    const path = getenv("PATH") orelse return null;
    var parts = std.mem.splitScalar(u8, path, ':');
    while (parts.next()) |directory| {
        const candidate = std.fs.path.join(allocator, &.{ if (directory.len == 0) "." else directory, name }) catch continue;
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn configPath(allocator: Allocator, suffix: []const u8) ![]u8 {
    if (getenv("XDG_CONFIG_HOME")) |root| return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix });
    const home = getenv("HOME") orelse return error.HomeUnavailable;
    return std.fmt.allocPrint(allocator, "{s}/.config/{s}", .{ home, suffix });
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return if (item == .string) item.string else null;
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    const item = value orelse return null;
    return if (item == .integer) item.integer else null;
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const item = value orelse return null;
    return if (item == .bool) item.bool else null;
}

fn unquote(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2 and ((value[0] == '\'' and value[value.len - 1] == '\'') or
        (value[0] == '"' and value[value.len - 1] == '"'))) return value[1 .. value.len - 1];
    return value;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

fn pathExists(path: []const u8) bool {
    if (path.len == 0) return false;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "cursor validation accepts display names but rejects paths" {
    try validateTheme("Bibata Modern Ice");
    try validateTheme("Zoey's Cursor");
    try std.testing.expectError(error.EmptyCursorTheme, validateTheme("  "));
    try std.testing.expectError(error.InvalidCursorTheme, validateTheme("../theme"));
    try std.testing.expectError(error.InvalidCursorTheme, validateTheme("theme/name"));
}

test "cursor environment values are shell quoted" {
    const allocator = std.testing.allocator;
    const result = try envContents(allocator, &.{ .managed = true, .theme = "Zoey's Cursor", .size = 32 });
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "export XCURSOR_THEME='Zoey'\"'\"'s Cursor'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "export XCURSOR_SIZE='32'") != null);
}
