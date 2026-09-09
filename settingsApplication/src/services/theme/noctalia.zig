const std = @import("std");
const Document = @import("backend").Document;
const theme = @import("../../model/theme.zig");
// Apply config first, then the persisted state overlay. These are Noctalia v5 keys.
pub fn typography(a: std.mem.Allocator, bytes: []const u8, snapshot: *theme.Snapshot) !void {
    var doc = try Document.init(a, bytes);
    defer doc.deinit();
    if (doc.getRaw("shell", "font_family")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r");
        if (value.len < 2) return error.InvalidFont;
        if (value[0] == '"') {
            const parsed = try std.json.parseFromSlice([]const u8, a, value, .{});
            defer parsed.deinit();
            try snapshot.font.setName(parsed.value);
        } else if (value[0] == '\'' and value[value.len - 1] == '\'') try snapshot.font.setName(value[1 .. value.len - 1]) else return error.InvalidFont;
    }
    if (doc.getRaw("accessibility", "ui_scale")) |value| {
        try snapshot.font.setPixels(16 * (std.fmt.parseFloat(f64, value) catch return error.InvalidFontSize));
    }
    if (doc.getRaw("shell", "corner_radius_scale")) |value| {
        const scale = std.fmt.parseFloat(f64, value) catch return error.InvalidRadius;
        if (!std.math.isFinite(scale) or scale < 0) return error.InvalidRadius;
        snapshot.radius = @floatCast(std.math.clamp(5 * scale, 0, 18));
    }
}
test "Noctalia state overrides config without resetting absent values" {
    var snapshot: theme.Snapshot = .{};
    try typography(std.testing.allocator, "[shell]\nfont_family = \"Test Sans\"\n[accessibility]\nui_scale = 1.25\n", &snapshot);
    try typography(std.testing.allocator, "[shell]\nfont_family = 'Other Sans'\n", &snapshot);
    try std.testing.expectEqualStrings("Other Sans", snapshot.font.name());
    try std.testing.expectEqual(@as(f32, 20), snapshot.font.pixels);
}
