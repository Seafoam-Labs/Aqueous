const std = @import("std");
const q = @import("quark");
pub const spacing: f32 = 16;
pub fn compact(width: f32, pixels: f32) bool {
    return width < @max(980, pixels * 58);
}
pub fn stacked(width: f32, pixels: f32) bool {
    return width < @max(1120, pixels * 70);
}
pub const Role = enum { body, muted, title, accent, error_text };
pub const Fonts = struct {
    title: ?q.Font = null,
    description: ?q.Font = null,
    pub fn deinit(self: *Fonts) void {
        if (self.title) |*f| f.deinit();
        if (self.description) |*f| f.deinit();
        self.* = .{};
    }
    pub fn prepare(bytes: [4]?[]const u8, pixels: f32) !Fonts {
        var result: Fonts = .{};
        errdefer result.deinit();
        result.title = try q.Font.init(bytes[1] orelse q.Font.bundledBold(), pixels * 1.35, std.heap.page_allocator);
        result.description = try q.Font.init(bytes[0] orelse q.Font.bundledRegular(), @max(10, pixels * 0.875), std.heap.page_allocator);
        return result;
    }
};
