const std = @import("std");
pub const Preferences = struct { page: usize = 0, width: u32 = 1100, height: u32 = 800 };
pub fn path(a: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    const config = env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingHome, ".config" });
    return std.fs.path.join(a, &.{ config, "aqueous/settings-application.json" });
}
pub fn load(a: std.mem.Allocator, io: std.Io, file: []const u8) Preferences {
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(4096)) catch return .{};
    const parsed = std.json.parseFromSlice(Preferences, a, text, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    var result = parsed.value;
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
