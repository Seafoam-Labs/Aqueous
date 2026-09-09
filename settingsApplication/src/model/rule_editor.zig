const std = @import("std");
const j = @import("json.zig");

pub const match_keys = [_][]const u8{ "app_id", "class", "title", "content_type" };

pub fn label(a: std.mem.Allocator, values: j.Value, index: usize) ![]const u8 {
    var result = try std.fmt.allocPrint(a, "{d}", .{index + 1});
    var matched = false;
    for (match_keys, [_][]const u8{ "App", "Class", "Title", "Content" }) |key, name| {
        if (j.get(values, key) == .null) continue;
        matched = true;
        result = try std.fmt.allocPrint(a, "{s} · {s}: {s}", .{ result, name, if (j.text(values, key).len == 0) "(empty)" else j.text(values, key) });
    }
    return if (matched) result else try std.fmt.allocPrint(a, "{s} · No matching conditions", .{result});
}

// Dropdown labels are presentation only: index zero removes the property.
pub fn choice(a: std.mem.Allocator, field: j.Value, index: usize) !j.Value {
    if (index == 0) return .null;
    if (std.mem.eql(u8, j.text(field, "type"), "boolean")) {
        if (index > 2) return error.InvalidRuleChoice;
        return .{ .bool = index == 1 };
    }
    const options = j.items(j.get(field, "options"));
    if (index > options.len) return error.InvalidRuleChoice;
    return try j.clone(a, options[index - 1]);
}

pub fn input(a: std.mem.Allocator, field: j.Value, text: []const u8) !j.Value {
    if (text.len == 0) return .null;
    if (!std.mem.eql(u8, j.text(field, "type"), "number")) return try j.string(a, text);
    const key = j.text(field, "key");
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, key, "opacity") or std.mem.eql(u8, key, "scale")) {
        const n = std.fmt.parseFloat(f64, trimmed) catch return error.InvalidNumber;
        if (!std.math.isFinite(n)) return error.InvalidNumber;
        if (std.mem.eql(u8, key, "opacity")) {
            if (n < 0 or n > 1) return error.InvalidOpacity;
        } else if (n <= 0 or n > 16) return error.InvalidScale;
        return .{ .float = n };
    }
    const n = std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidInteger;
    if (std.mem.eql(u8, key, "workspace")) {
        if (n < 1 or n > std.math.maxInt(u32)) return error.InvalidWorkspace;
    } else if (std.mem.eql(u8, key, "width") or std.mem.eql(u8, key, "height")) {
        if (n < 1 or n > 100_000) return error.InvalidSize;
    } else if (n < -100_000 or n > 100_000) return error.InvalidPosition;
    return .{ .integer = n };
}

pub fn indexOf(rows: []const j.Value, id: []const u8) ?usize {
    for (rows, 0..) |row, i| if (std.mem.eql(u8, j.text(row, "id"), id)) return i;
    return null;
}

test "rule choices distinguish removing an override from turning it off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const boolean = try j.parse(a, "{\"type\":\"boolean\"}");
    try std.testing.expect(try choice(a, boolean, 0) == .null);
    try std.testing.expect((try choice(a, boolean, 1)).bool);
    try std.testing.expect(!(try choice(a, boolean, 2)).bool);
    const select = try j.parse(a, "{\"options\":[\"none\",\"photo\"]}");
    try std.testing.expectEqualStrings("none", j.str(try choice(a, select, 1)));
    try std.testing.expectError(error.InvalidRuleChoice, choice(a, select, 3));
    // Literal string matchers must not be interpreted as dropdown sentinels.
    try std.testing.expectEqualStrings("(unset)", j.str(try input(a, .null, "(unset)")));
}

test "rule numeric edits accept fractions and enforce backend bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = try j.parse(a, @embedFile("rule-fields.json"));
    for (j.items(fields)) |field| {
        const key = j.text(field, "key");
        if (std.mem.eql(u8, key, "opacity") or std.mem.eql(u8, key, "scale")) {
            try std.testing.expectEqual(@as(f64, 0.75), (try input(a, field, "0.75")).float);
            try std.testing.expectError(error.InvalidNumber, input(a, field, "nan"));
            try std.testing.expect(try input(a, field, "") == .null);
        }
        if (std.mem.eql(u8, key, "opacity")) try std.testing.expectError(error.InvalidOpacity, input(a, field, "1.1"));
        if (std.mem.eql(u8, key, "scale")) try std.testing.expectError(error.InvalidScale, input(a, field, "0"));
        if (std.mem.eql(u8, key, "width")) {
            try std.testing.expectError(error.InvalidSize, input(a, field, "0"));
            try std.testing.expectError(error.InvalidInteger, input(a, field, "12.5"));
        }
    }
}

test "rule labels identify class-only and content-only rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2 · Class: Steam", try label(a, try j.parse(a, "{\"class\":\"Steam\"}"), 1));
    try std.testing.expectEqualStrings("1 · Content: game", try label(a, try j.parse(a, "{\"content_type\":\"game\"}"), 0));
    try std.testing.expectEqualStrings("1 · No matching conditions", try label(a, .null, 0));
}
