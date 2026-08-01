const std = @import("std");
const catalog = @import("catalog.zig");
const registry = @import("sections.zig");

pub const Selection = [registry.application_count]bool;

pub fn emptySelection() Selection {
    return @splat(false);
}

pub fn selectedCount(selection: Selection, installed: Selection) usize {
    var result: usize = 0;
    for (selection, installed) |selected, is_installed| {
        if (selected and !is_installed) result += 1;
    }
    return result;
}

pub fn backendCount(
    selection: Selection,
    installed: Selection,
    backend: catalog.Backend,
) usize {
    var result: usize = 0;
    for (selection, installed, 0..) |selected, is_installed, index| {
        if (selected and !is_installed and
            registry.applicationAt(index).?.package.backend == backend)
        {
            result += 1;
        }
    }
    return result;
}

/// Builds one repository/AUR transaction. The returned slice owns only its
/// outer allocation; every argument points to static catalog data.
pub fn buildBatchArgv(
    allocator: std.mem.Allocator,
    shelly_path: []const u8,
    selection: Selection,
    installed: Selection,
    backend: catalog.Backend,
) ![][]const u8 {
    if (backend == .flatpak) return error.FlatpakIsNotBatchable;
    const count = backendCount(selection, installed, backend);
    if (count == 0) return error.EmptyTransaction;

    var argv = try allocator.alloc([]const u8, count + 6);
    var cursor: usize = 0;
    argv[cursor] = "pkexec";
    cursor += 1;
    argv[cursor] = shelly_path;
    cursor += 1;
    argv[cursor] = "install";
    cursor += 1;
    argv[cursor] = @tagName(backend);
    cursor += 1;
    for (selection, installed, 0..) |selected, is_installed, index| {
        const application = registry.applicationAt(index).?;
        if (selected and !is_installed and application.package.backend == backend) {
            argv[cursor] = application.package.name;
            cursor += 1;
        }
    }
    argv[cursor] = "--no-confirm";
    cursor += 1;
    argv[cursor] = "--ui-mode";
    cursor += 1;
    std.debug.assert(cursor == argv.len);
    return argv;
}

pub fn buildFlatpakArgv(
    allocator: std.mem.Allocator,
    shelly_path: []const u8,
    application: catalog.Application,
) ![][]const u8 {
    if (application.package.backend != .flatpak) return error.NotFlatpak;
    const privileged = !application.package.user_scope;
    const remote_count: usize = if (application.package.remote == null) 0 else 2;
    const user_count: usize = if (application.package.user_scope) 1 else 0;
    const prefix_count: usize = if (privileged) 2 else 1;
    var argv = try allocator.alloc(
        []const u8,
        prefix_count + 3 + user_count + remote_count + 2,
    );
    var cursor: usize = 0;
    if (privileged) {
        argv[cursor] = "pkexec";
        cursor += 1;
    }
    argv[cursor] = shelly_path;
    cursor += 1;
    argv[cursor] = "install";
    cursor += 1;
    argv[cursor] = "flatpak";
    cursor += 1;
    argv[cursor] = application.package.name;
    cursor += 1;
    if (application.package.user_scope) {
        argv[cursor] = "--user";
        cursor += 1;
    }
    if (application.package.remote) |remote| {
        argv[cursor] = "--remote";
        cursor += 1;
        argv[cursor] = remote;
        cursor += 1;
    }
    argv[cursor] = "--no-confirm";
    cursor += 1;
    argv[cursor] = "--ui-mode";
    cursor += 1;
    std.debug.assert(cursor == argv.len);
    return argv;
}

test "plan filters installed applications and batches repository packages" {
    var selection = emptySelection();
    var installed = emptySelection();
    selection[0] = true;
    selection[1] = true;
    installed[0] = true;

    try std.testing.expectEqual(@as(usize, 1), selectedCount(selection, installed));
    const argv = try buildBatchArgv(
        std.testing.allocator,
        "/usr/bin/shelly",
        selection,
        installed,
        .standard,
    );
    defer std.testing.allocator.free(argv);
    try expectArgv(&.{
        "pkexec",
        "/usr/bin/shelly",
        "install",
        "standard",
        "chromium",
        "--no-confirm",
        "--ui-mode",
    }, argv);
}

test "flatpak plan uses user scope and an explicit remote" {
    const telegram = registry.applicationAt(3).?;
    const argv = try buildFlatpakArgv(std.testing.allocator, "/usr/bin/shelly", telegram);
    defer std.testing.allocator.free(argv);
    try expectArgv(&.{
        "/usr/bin/shelly",
        "install",
        "flatpak",
        "org.telegram",
        "--user",
        "--remote",
        "flathub",
        "--no-confirm",
        "--ui-mode",
    }, argv);
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}
