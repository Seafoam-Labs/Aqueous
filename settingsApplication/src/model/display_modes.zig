const std = @import("std");
const j = @import("json.zig");
const V = j.Value;
pub const Mode = struct { width: u32, height: u32, refresh: ?f64 = null };
pub fn parse(s: []const u8) !Mode {
    var mode = std.mem.splitScalar(u8, s, '@');
    const dimensions = mode.next().?;
    var parts = std.mem.splitScalar(u8, dimensions, 'x');
    const w = parts.next().?;
    const h = parts.next() orelse return error.InvalidMode;
    if (parts.next() != null) return error.InvalidMode;
    const width = std.fmt.parseInt(u32, w, 10) catch return error.InvalidMode;
    const height = std.fmt.parseInt(u32, h, 10) catch return error.InvalidMode;
    if (width == 0 or height == 0 or width > 32768 or height > 32768) return error.InvalidMode;
    var refresh: ?f64 = null;
    if (mode.next()) |r| {
        refresh = std.fmt.parseFloat(f64, r) catch return error.InvalidMode;
        if (!std.math.isFinite(refresh.?) or refresh.? <= 0 or refresh.? > 1000) return error.InvalidMode;
    }
    if (mode.next() != null) return error.InvalidMode;
    return .{ .width = width, .height = height, .refresh = refresh };
}
pub fn format(a: std.mem.Allocator, v: V) ![]const u8 {
    const w = j.number(j.get(v, "width"));
    const h = j.number(j.get(v, "height"));
    var hz = j.number(j.get(v, "refresh_mhz")) / 1000;
    if (hz == 0) hz = j.number(j.get(v, "refresh_hz"));
    if (hz == 0) hz = j.number(j.get(v, "refresh"));
    if (w <= 0 or h <= 0) return "";
    return if (hz > 0) try std.fmt.allocPrint(a, "{d}x{d}@{d}", .{ @as(u32, @intFromFloat(w)), @as(u32, @intFromFloat(h)), hz }) else try std.fmt.allocPrint(a, "{d}x{d}", .{ @as(u32, @intFromFloat(w)), @as(u32, @intFromFloat(h)) });
}
pub fn monitors(a: std.mem.Allocator, snapshot: V, draft: V) !V {
    var result = try j.clone(a, j.get(snapshot, "monitors"));
    if (result != .array) result = j.array(a);
    for (j.items(j.get(snapshot, "live_outputs"))) |live| {
        var found: ?usize = null;
        for (result.array.items, 0..) |r, i| if (std.mem.eql(u8, j.text(r, "name"), j.text(live, "name"))) {
            found = i;
            break;
        };
        if (found == null) {
            var r = j.object(a);
            try j.put(a, &r, "id", try j.string(a, try std.fmt.allocPrint(a, "live:{s}", .{j.text(live, "name")})));
            try j.put(a, &r, "name", j.get(live, "name"));
            try result.array.append(r);
            found = result.array.items.len - 1;
        }
        const r = &result.array.items[found.?];
        try j.put(a, r, "connected", .{ .bool = true });
        try j.put(a, r, "modes", j.get(live, "modes"));
        for ([_][]const u8{ "scale", "transform", "mirror_of", "mirror_error", "mirror_status" }) |key| if (j.get(r.*, key) == .null or (std.mem.eql(u8, key, "scale") and !j.boolean(j.get(r.*, "scale_configured")))) {
            if (j.get(live, key) != .null) try j.put(a, r, key, j.get(live, key));
        };
        for ([_][]const u8{ "x", "y" }) |key| if (j.get(r.*, key) == .null) try j.put(a, r, key, j.get(j.get(live, "position"), key));
        if (j.text(r.*, "mode").len == 0) for (j.items(j.get(live, "modes"))) |m| if (j.boolean(j.get(m, "current"))) {
            try j.put(a, r, "mode", try j.string(a, try format(a, m)));
            break;
        };
    }
    // Keep draft-only outputs editable after they disconnect.
    const monitor_drafts = j.get(draft, "monitor_changes");
    if (monitor_drafts == .object) for (monitor_drafts.object.values()) |change| {
        var found = false;
        for (result.array.items) |row| if (std.mem.eql(u8, j.text(row, "id"), j.text(change, "id"))) {
            found = true;
            break;
        };
        if (!found) try result.array.append(try j.clone(a, change));
    };
    for (result.array.items) |*r| {
        for ([_][]const u8{ "x", "y" }) |key| if (j.get(r.*, key) == .null) try j.put(a, r, key, .{ .integer = 0 });
        if (j.text(r.*, "transform").len == 0) try j.put(a, r, "transform", try j.string(a, "normal"));
        if (j.number(j.get(r.*, "scale")) <= 0) try j.put(a, r, "scale", .{ .integer = 1 });
        const changes = j.get(j.get(draft, "monitor_changes"), j.text(r.*, "id"));
        if (changes == .object) for (changes.object.keys(), changes.object.values()) |key, v| try j.put(a, r, key, v);
    }
    return result;
}
pub fn size(v: V) struct { w: f32, h: f32 } {
    const mode = parse(j.text(v, "mode")) catch Mode{ .width = 1920, .height = 1080 };
    const scale = @max(0.1, j.number(j.get(v, "scale")));
    const transform = j.text(v, "transform");
    const rotated = std.mem.indexOf(u8, transform, "90") != null or std.mem.indexOf(u8, transform, "270") != null;
    return .{ .w = @floatCast(@as(f64, @floatFromInt(if (rotated) mode.height else mode.width)) / scale), .h = @floatCast(@as(f64, @floatFromInt(if (rotated) mode.width else mode.height)) / scale) };
}
test "fractional custom display modes and rotated logical dimensions" {
    try std.testing.expectEqual(@as(?f64, 59.94), (try parse("1920x1080@59.94")).refresh);
    try std.testing.expectError(error.InvalidMode, parse("1920x0@nan"));
    try std.testing.expectEqual(@as(?f64, null), (try parse("1920x1080")).refresh);
}
