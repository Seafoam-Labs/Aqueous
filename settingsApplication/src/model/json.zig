const std = @import("std");
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;
pub fn object(a: Allocator) Value {
    _ = a;
    return .{ .object = .empty };
}
pub fn array(a: Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(a) };
}
pub fn get(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn text(v: Value, key: []const u8) []const u8 {
    return str(get(v, key));
}
pub fn boolean(v: Value) bool {
    return v == .bool and v.bool;
}
pub fn number(v: Value) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => 0,
    };
}
pub fn items(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}
pub fn put(a: Allocator, v: *Value, key: []const u8, value: Value) !void {
    try v.object.put(a, key, value);
}
pub fn string(a: Allocator, value: []const u8) !Value {
    return .{ .string = try a.dupe(u8, value) };
}
pub fn parse(a: Allocator, value: []const u8) !Value {
    return try std.json.parseFromSliceLeaky(Value, a, value, .{ .allocate = .alloc_always });
}
pub fn encode(a: Allocator, value: anytype) ![]const u8 {
    return try std.json.Stringify.valueAlloc(a, value, .{});
}
pub fn clone(a: Allocator, value: Value) !Value {
    return try parse(a, try encode(a, value));
}
pub fn eq(a: Allocator, x: Value, y: Value) !bool {
    return std.mem.eql(u8, try encode(a, x), try encode(a, y));
}
