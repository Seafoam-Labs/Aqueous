const std = @import("std");
pub const Preferences = struct { page: usize = 0, width: u32 = 1100, height: u32 = 800, theme_source: @import("../model/theme.zig").Choice = .follow };
pub fn path(a: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    const config = env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingHome, ".config" });
    return std.fs.path.join(a, &.{ config, "aqueous/settings-application.json" });
}
pub fn load(a: std.mem.Allocator, io: std.Io, file: []const u8) Preferences {
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(4096)) catch return .{};
    defer a.free(text);
    return decode(a, text);
}
fn decode(a: std.mem.Allocator, text: []const u8) Preferences {
    const Stored = struct { page: usize = 0, width: u32 = 1100, height: u32 = 800, theme_source: std.json.Value = .null };
    const parsed = std.json.parseFromSlice(Stored, a, text, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    const value = parsed.value;
    var result: Preferences = .{ .page = value.page, .width = value.width, .height = value.height, .theme_source = if (value.theme_source == .string) std.meta.stringToEnum(@import("../model/theme.zig").Choice, value.theme_source.string) orelse .follow else .follow };
    if (result.page >= 8) result.page = 0;
    result.width = std.math.clamp(result.width, 760, 2400);
    result.height = std.math.clamp(result.height, 520, 1600);
    return result;
}
pub fn save(a: std.mem.Allocator, io: std.Io, file: []const u8, prefs: Preferences) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(file).?);
    const temporary = try std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ file, std.c.getpid() });
    defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = try std.json.Stringify.valueAlloc(a, prefs, .{}), .flags = .{ .exclusive = true } });
    try std.Io.Dir.renameAbsolute(temporary, file, io);
}

test "appearance preference migrates independently of window geometry" {
    const old = decode(std.testing.allocator, "{\"page\":2,\"width\":1200}");
    try std.testing.expectEqual(@as(usize, 2), old.page);
    try std.testing.expectEqual(@as(u32, 1200), old.width);
    try std.testing.expectEqual(@import("../model/theme.zig").Choice.follow, old.theme_source);
    const future = decode(std.testing.allocator, "{\"page\":3,\"theme_source\":\"future\"}");
    try std.testing.expectEqual(@as(usize, 3), future.page);
    try std.testing.expectEqual(@import("../model/theme.zig").Choice.follow, future.theme_source);
}
