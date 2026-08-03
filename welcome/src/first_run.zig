const std = @import("std");

pub const marker_name = "welcome-v1";
pub const autostart_name = "org.aqueous.Welcome.desktop";

pub fn isAqueousDesktop(environ: *const std.process.Environ.Map) bool {
    const desktops = environ.get("XDG_CURRENT_DESKTOP") orelse return false;
    var iterator = std.mem.splitScalar(u8, desktops, ':');
    while (iterator.next()) |desktop| {
        if (std.ascii.eqlIgnoreCase(desktop, "Aqueous")) return true;
    }
    return false;
}

pub fn stateDirectory(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    if (environ.get("XDG_STATE_HOME")) |state_home| {
        return std.fs.path.join(allocator, &.{ state_home, "aqueous" });
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "aqueous" });
}

pub fn markerPath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const directory = try stateDirectory(allocator, environ);
    defer allocator.free(directory);
    return std.fs.path.join(allocator, &.{ directory, marker_name });
}

pub fn isComplete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) bool {
    const path = markerPath(allocator, environ) catch return false;
    defer allocator.free(path);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn markComplete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !void {
    const directory = try stateDirectory(allocator, environ);
    defer allocator.free(directory);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, directory);

    var dir = try std.Io.Dir.openDirAbsolute(io, directory, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, marker_name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, "Aqueous welcome completed\n");
    try atomic.replace(io);

    // Best effort: the marker alone already keeps the window from reopening.
    writeAutostartOverride(allocator, io, environ) catch {};
}

pub fn autostartDirectory(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    if (environ.get("XDG_CONFIG_HOME")) |config_home| {
        return std.fs.path.join(allocator, &.{ config_home, "autostart" });
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".config", "autostart" });
}

/// Overrides the packaged /etc/xdg/autostart entry so future sessions do not
/// launch the welcome app at all.
pub fn writeAutostartOverride(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !void {
    const directory = try autostartDirectory(allocator, environ);
    defer allocator.free(directory);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, directory);

    var dir = try std.Io.Dir.openDirAbsolute(io, directory, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, autostart_name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Welcome to Aqueous
        \\Hidden=true
        \\
    );
    try atomic.replace(io);
}

test "state directory honors XDG_STATE_HOME" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_STATE_HOME", "/tmp/aqueous-state-test");
    const directory = try stateDirectory(std.testing.allocator, &environ);
    defer std.testing.allocator.free(directory);
    try std.testing.expectEqualStrings("/tmp/aqueous-state-test/aqueous", directory);
}

test "desktop detection accepts colon-separated desktop names" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_CURRENT_DESKTOP", "Aqueous:wlroots");
    try std.testing.expect(isAqueousDesktop(&environ));
}

test "completion writes an XDG autostart override that hides the entry" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const current = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(current);
    const config_home = try std.fs.path.join(std.testing.allocator, &.{
        current,
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
    });
    defer std.testing.allocator.free(config_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", config_home);
    try writeAutostartOverride(std.testing.allocator, std.testing.io, &environ);

    const path = try std.fs.path.join(std.testing.allocator, &.{
        config_home,
        "autostart",
        autostart_name,
    });
    defer std.testing.allocator.free(path);

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var buffer: [512]u8 = undefined;
    const length = try file.readStreaming(std.testing.io, &.{&buffer});
    const content = buffer[0..length];
    try std.testing.expect(std.mem.indexOf(u8, content, "[Desktop Entry]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Hidden=true") != null);
}

test "completion marker is written atomically and detected" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const current = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(current);
    const state_home = try std.fs.path.join(std.testing.allocator, &.{
        current,
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
    });
    defer std.testing.allocator.free(state_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_STATE_HOME", state_home);
    try markComplete(std.testing.allocator, std.testing.io, &environ);
    try std.testing.expect(isComplete(std.testing.allocator, std.testing.io, &environ));
}
