// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const layout = @import("layout.zig");

const log = std.log.scoped(.aqueous);
const max_config_bytes = 1024 * 1024;

pub fn load(allocator: std.mem.Allocator) layout.Snapshot {
    var snapshot: layout.Snapshot = .{};
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const xdg = if (std.c.getenv("XDG_CONFIG_HOME")) |value| std.mem.span(value) else null;
    const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else null;
    if (resolvePath(&buffer, xdg, home, "wm.toml")) |path| applyFile(allocator, &snapshot, path);
    if (resolvePath(&buffer, xdg, home, "layout.toml")) |path| applyFile(allocator, &snapshot, path);
    return snapshot;
}

pub fn resolvePath(buffer: []u8, xdg_config_home: ?[]const u8, home: ?[]const u8, filename: []const u8) ?[]const u8 {
    if (xdg_config_home) |base| {
        if (base.len == 0) return null;
        return std.fmt.bufPrint(buffer, "{s}/aqueous/{s}", .{ base, filename }) catch null;
    }
    const base = home orelse return null;
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/aqueous/{s}", .{ base, filename }) catch null;
}

fn applyFile(allocator: std.mem.Allocator, snapshot: *layout.Snapshot, path: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("unable to read {s}: {}", .{ path, err });
            return;
        },
    };
    defer allocator.free(source);
    layout.apply(snapshot, source);
}

test "config paths prefer XDG and fall back to HOME" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/xdg/aqueous/wm.toml", resolvePath(&buffer, "/xdg", "/home/test", "wm.toml").?);
    try std.testing.expectEqualStrings("/home/test/.config/aqueous/layout.toml", resolvePath(&buffer, null, "/home/test", "layout.toml").?);
    try std.testing.expectEqual(@as(?[]const u8, null), resolvePath(&buffer, null, null, "wm.toml"));
}