// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

pub const Mode = enum { visual, sound, both, off };
pub const Config = struct {
    mode: Mode = .visual,
    volume: f64 = 0.5,
    sound_file: [4096:0]u8 = @splat(0),

    pub fn path(config: *const Config) [:0]const u8 {
        return std.mem.sliceTo(&config.sound_file, 0);
    }

    pub fn setPath(config: *Config, value: []const u8) bool {
        if (value.len >= config.sound_file.len or std.mem.indexOfScalar(u8, value, 0) != null) return false;
        @memset(&config.sound_file, 0);
        @memcpy(config.sound_file[0..value.len], value);
        return true;
    }

    /// The settings backend emits JSON-compatible TOML basic strings. Decode
    /// escapes for filenames, while preserving TOML literal single-quoted paths.
    pub fn applyPathToml(config: *Config, raw: []const u8) void {
        if (raw.len >= 2 and raw[0] == '"') {
            var buffer: [8192]u8 = undefined;
            var allocator = std.heap.FixedBufferAllocator.init(&buffer);
            const decoded = std.json.parseFromSliceLeaky([]const u8, allocator.allocator(), raw, .{}) catch return;
            _ = config.setPath(decoded);
        } else if (raw.len >= 2 and raw[0] == 39 and raw[raw.len - 1] == 39) {
            _ = config.setPath(raw[1 .. raw.len - 1]);
        } else _ = config.setPath(raw);
    }

    pub fn apply(config: *Config, key: []const u8, value: []const u8) void {
        if (std.mem.eql(u8, key, "mode")) config.mode = std.meta.stringToEnum(Mode, value) orelse config.mode;
        if (std.mem.eql(u8, key, "sound_file")) _ = config.setPath(value);
        if (std.mem.eql(u8, key, "volume")) {
            const volume = std.fmt.parseFloat(f64, value) catch return;
            if (std.math.isFinite(volume) and volume >= 0 and volume <= 1) config.volume = volume;
        }
    }

    pub fn resolve(config: *Config, allocator: std.mem.Allocator, config_path: []const u8) void {
        if (config.path().len == 0) return;
        var cwd: [4096]u8 = undefined;
        const prefix = if (std.fs.path.isAbsolute(config_path)) "/" else blk: {
            const len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd) catch {
                _ = config.setPath("");
                return;
            };
            break :blk cwd[0..len];
        };
        const resolved = std.fs.path.resolve(allocator, &.{ prefix, std.fs.path.dirname(config_path) orelse ".", config.path() }) catch {
            _ = config.setPath("");
            return;
        };
        defer allocator.free(resolved);
        if (!config.setPath(resolved)) _ = config.setPath("");
    }

    pub fn eql(a: *const Config, b: *const Config) bool {
        return a.mode == b.mode and a.volume == b.volume and std.mem.eql(u8, a.path(), b.path());
    }

    pub fn visual(config: *const Config) bool {
        return config.mode == .visual or config.mode == .both;
    }

    pub fn sound(config: *const Config) bool {
        return (config.mode == .sound or config.mode == .both) and config.volume > 0 and config.path().len > 0;
    }
};

test "bell configuration rejects invalid values and resolves literal relative paths" {
    var config: Config = .{};
    config.apply("mode", "both");
    config.apply("volume", "0.25");
    config.apply("sound_file", "sounds/a $b.wav");
    config.resolve(std.testing.allocator, "/tmp/custom/wm.toml");
    try std.testing.expectEqualStrings("/tmp/custom/sounds/a $b.wav", config.path());
    try std.testing.expect(config.visual() and config.sound());
    for ([_][]const u8{ "nan", "inf", "-1", "1.1", "bad" }) |value| config.apply("volume", value);
    config.apply("mode", "bad");
    try std.testing.expectEqual(@as(f64, 0.25), config.volume);
    try std.testing.expectEqual(Mode.both, config.mode);
    config.apply("volume", "0");
    try std.testing.expect(!config.sound());
    _ = config.setPath("/var/tmp/a.wav");
    config.resolve(std.testing.allocator, "/tmp/custom/wm.toml");
    try std.testing.expectEqualStrings("/var/tmp/a.wav", config.path());
}

test "relative config overrides still produce absolute sound paths" {
    var config: Config = .{};
    _ = config.setPath("effects/tone.wav");
    config.resolve(std.testing.allocator, "configs/wm.toml");
    try std.testing.expect(std.fs.path.isAbsolute(config.path()));
    try std.testing.expect(std.mem.endsWith(u8, config.path(), "/configs/effects/tone.wav"));
}

test "bell sound paths decode basic strings and preserve literal strings" {
    var config: Config = .{};
    config.applyPathToml(
        \\"sounds/a \"quote\" \\ bell.wav"
    );
    try std.testing.expectEqualStrings("sounds/a \"quote\" \\ bell.wav", config.path());
    config.applyPathToml("'sounds/a \\ bell.wav'");
    try std.testing.expectEqualStrings("sounds/a \\ bell.wav", config.path());
    config.applyPathToml("\"bad\\u0000path\"");
    try std.testing.expectEqualStrings("sounds/a \\ bell.wav", config.path());
}
