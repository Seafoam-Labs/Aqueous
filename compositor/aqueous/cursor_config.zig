// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const default_theme = "default";
pub const default_size: u32 = 24;
pub const max_size: u32 = 512;
pub const max_theme_bytes: usize = 255;

pub const Error = error{
    InvalidTheme,
    InvalidSize,
};

/// Validated, allocation-free cursor configuration. Keeping the theme in a
/// fixed buffer makes it safe to retain values received through Wayland after
/// the request resource has gone away.
pub const Config = struct {
    theme_buffer: [max_theme_bytes + 1]u8 = [_]u8{0} ** (max_theme_bytes + 1),
    theme_len: u16 = 0,
    size: u32 = default_size,

    pub fn init(theme_name: []const u8, size: u32) Error!Config {
        if (theme_name.len == 0 or theme_name.len > max_theme_bytes or std.mem.indexOfScalar(u8, theme_name, 0) != null) {
            return error.InvalidTheme;
        }
        if (size == 0 or size > max_size) return error.InvalidSize;

        var config: Config = .{ .theme_len = @intCast(theme_name.len), .size = size };
        @memcpy(config.theme_buffer[0..theme_name.len], theme_name);
        config.theme_buffer[theme_name.len] = 0;
        return config;
    }

    pub fn defaults() Config {
        return init(default_theme, default_size) catch unreachable;
    }

    pub fn theme(config: *const Config) []const u8 {
        return config.theme_buffer[0..config.theme_len];
    }

    pub fn themeZ(config: *const Config) [:0]const u8 {
        return config.theme_buffer[0..config.theme_len :0];
    }
};

pub const Environment = struct {
    theme: ?[]const u8 = null,
    size: ?[]const u8 = null,
};

pub const Resolution = struct {
    config: Config,
    invalid_theme: bool = false,
    invalid_size: bool = false,
};

/// Resolve the standard cursor variables independently. One malformed value
/// must not discard the other valid value.
pub fn resolveEnvironment(environment: Environment) Resolution {
    var resolution: Resolution = .{ .config = Config.defaults() };

    if (environment.theme) |theme| {
        if (theme.len != 0 and theme.len <= max_theme_bytes and std.mem.indexOfScalar(u8, theme, 0) == null) {
            resolution.config = Config.init(theme, resolution.config.size) catch unreachable;
        } else if (theme.len != 0) {
            resolution.invalid_theme = true;
        }
    }

    if (environment.size) |raw_size| {
        if (raw_size.len != 0) {
            const parsed = std.fmt.parseInt(u32, raw_size, 10) catch 0;
            if (parsed != 0 and parsed <= max_size) {
                resolution.config.size = parsed;
            } else {
                resolution.invalid_size = true;
            }
        }
    }

    return resolution;
}

pub fn fromProcessEnvironment() Resolution {
    return resolveEnvironment(.{
        .theme = getenv("XCURSOR_THEME"),
        .size = getenv("XCURSOR_SIZE"),
    });
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "explicit cursor configuration validates theme and size" {
    const config = try Config.init("Bibata-Modern-Ice", 32);
    try std.testing.expectEqualStrings("Bibata-Modern-Ice", config.theme());
    try std.testing.expectEqualStrings("Bibata-Modern-Ice", config.themeZ());
    try std.testing.expectEqual(@as(u32, 32), config.size);

    try std.testing.expectError(error.InvalidTheme, Config.init("", 24));
    const overlong = [_]u8{'x'} ** (max_theme_bytes + 1);
    try std.testing.expectError(error.InvalidTheme, Config.init(&overlong, 24));
    try std.testing.expectError(error.InvalidSize, Config.init("default", 0));
    try std.testing.expectError(error.InvalidSize, Config.init("default", max_size + 1));
}

test "cursor environment values override defaults independently" {
    const both = resolveEnvironment(.{ .theme = "Sweet-cursors", .size = "48" });
    try std.testing.expectEqualStrings("Sweet-cursors", both.config.theme());
    try std.testing.expectEqual(@as(u32, 48), both.config.size);
    try std.testing.expect(!both.invalid_theme);
    try std.testing.expect(!both.invalid_size);

    const bad_size = resolveEnvironment(.{ .theme = "Vimix-cursors", .size = "huge" });
    try std.testing.expectEqualStrings("Vimix-cursors", bad_size.config.theme());
    try std.testing.expectEqual(default_size, bad_size.config.size);
    try std.testing.expect(bad_size.invalid_size);

    const empty = resolveEnvironment(.{ .theme = "", .size = "" });
    try std.testing.expectEqualStrings(default_theme, empty.config.theme());
    try std.testing.expectEqual(default_size, empty.config.size);
    try std.testing.expect(!empty.invalid_theme);
    try std.testing.expect(!empty.invalid_size);
}
