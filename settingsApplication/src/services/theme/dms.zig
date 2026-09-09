const std = @import("std");
const theme = @import("../../model/theme.zig");
pub fn typography(a: std.mem.Allocator, bytes: []const u8, snapshot: *theme.Snapshot) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettings;
    const obj = parsed.value.object;
    if (obj.get("fontFamily")) |v| {
        if (v != .string) return error.InvalidFont;
        try snapshot.font.setName(v.string);
    }
    if (obj.get("fontScale")) |v| try snapshot.font.setPixels(14 * try number(v));
    if (obj.get("fontWeight")) |v| snapshot.font.weight = @intFromFloat(std.math.clamp(try number(v), 100, 900));
    if (obj.get("cornerRadius")) |v| snapshot.radius = @floatCast(std.math.clamp(try number(v), 0, 18));
}
fn number(value: std.json.Value) !f64 {
    const result: f64 = switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => return error.InvalidSettings,
    };
    if (!std.math.isFinite(result)) return error.InvalidSettings;
    return result;
}
test "DMS typography uses logical pixels and finite values" {
    var snapshot: theme.Snapshot = .{};
    try typography(std.testing.allocator, "{\"fontFamily\":\"Test Sans\",\"fontScale\":1.5,\"fontWeight\":600,\"cornerRadius\":12}", &snapshot);
    try std.testing.expectEqualStrings("Test Sans", snapshot.font.name());
    try std.testing.expectEqual(@as(f32, 21), snapshot.font.pixels);
    try std.testing.expectEqual(@as(u16, 600), snapshot.font.weight);
}
