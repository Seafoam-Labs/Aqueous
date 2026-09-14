//! Shared schema primitives for collection editing, observation and impact.
const std = @import("std");
const schema = @import("schema.zig");
fn unquoteToml(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) return value[1 .. value.len - 1];
    return value;
}
fn valueIn(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}
pub const SnapTablePath = struct {
    layout_id: []const u8,
    zone_id: ?[]const u8 = null,
};

pub const rule_keys: []const []const u8 = &.{
    "app_id",               "class",         "title",         "content_type", "layout",         "output",        "workspace",
    "floating",             "fullscreen",    "ignore_struts", "width",        "height",         "x",             "y",
    "placement_policy",     "anchor",        "size",          "scale",        "blur",           "opacity",       "buffer_scale_policy",
    "hdr_expand",           "overlay_plane", "stack_layer",   "focus",        "fixed_position", "skip_switcher", "skip_taskbar",
    "scrolling_full_width", "tag",
};

pub fn parseSnapTablePath(name: []const u8) ?SnapTablePath {
    const prefixes = [_][]const u8{ "layout.snap-layout.", "layout.snap_layout." };
    var suffix: ?[]const u8 = null;
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) {
        suffix = name[prefix.len..];
        break;
    };
    const path = suffix orelse return null;
    if (std.mem.indexOf(u8, path, ".zone.")) |separator| {
        const layout_id = path[0..separator];
        const zone_id = path[separator + ".zone.".len ..];
        if (!validSnapId(layout_id) or !validSnapId(zone_id)) return null;
        return .{ .layout_id = layout_id, .zone_id = zone_id };
    }
    if (!validSnapId(path)) return null;
    return .{ .layout_id = path };
}

pub fn validSnapId(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return false;
    return true;
}

pub fn parseFinite(raw: ?[]const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, std.mem.trim(u8, raw orelse return null, " \t\r")) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

pub fn validSnapZone(x: ?f64, y: ?f64, width: ?f64, height: ?f64) bool {
    const actual_x = x orelse return false;
    const actual_y = y orelse return false;
    const actual_width = width orelse return false;
    const actual_height = height orelse return false;
    return actual_x >= 0 and actual_y >= 0 and actual_width > 0 and actual_height > 0 and
        actual_x + actual_width <= 1 and actual_y + actual_height <= 1;
}

pub fn ruleKnown(key: []const u8) bool {
    for (rule_keys) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

pub fn ruleBoolean(key: []const u8) bool {
    inline for (.{ "floating", "fullscreen", "scrolling_full_width", "ignore_struts", "blur", "hdr_expand", "focus", "fixed_position", "skip_switcher", "skip_taskbar" }) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

pub fn ruleInteger(key: []const u8) bool {
    inline for (.{ "workspace", "width", "height", "x", "y" }) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

pub fn ruleDouble(key: []const u8) bool {
    return std.mem.eql(u8, key, "scale") or std.mem.eql(u8, key, "opacity");
}

pub fn decodeRuleTag(raw: []const u8, buffer: []u8) ![]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len > 0 and value[0] == '"') {
        var storage = std.heap.FixedBufferAllocator.init(buffer);
        return std.json.parseFromSliceLeaky([]const u8, storage.allocator(), value, .{}) catch error.InvalidWindowRuleValue;
    }
    return unquoteToml(value);
}

pub fn validateRuleRaw(key: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, key, "tag")) {
        var buffer: [128 * 1024]u8 = undefined;
        _ = try decodeRuleTag(raw, &buffer);
        return;
    }
    if (ruleBoolean(key)) {
        const value = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidWindowRuleValue;
        return;
    }
    if (ruleInteger(key)) {
        const value = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r"), 10) catch return error.InvalidWindowRuleValue;
        if ((std.mem.eql(u8, key, "workspace") and (value < 1 or value > std.math.maxInt(u32))) or
            ((std.mem.eql(u8, key, "width") or std.mem.eql(u8, key, "height")) and (value < 1 or value > 100_000)) or
            ((std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y")) and (value < -100_000 or value > 100_000))) return error.InvalidWindowRuleValue;
        return;
    }
    if (ruleDouble(key)) {
        const value = std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r")) catch return error.InvalidWindowRuleValue;
        if (!std.math.isFinite(value) or
            (std.mem.eql(u8, key, "scale") and (value <= 0 or value > 16)) or
            (std.mem.eql(u8, key, "opacity") and (value < 0 or value > 1))) return error.InvalidWindowRuleValue;
        return;
    }
    var value = unquoteToml(raw);
    if (std.mem.eql(u8, key, "layout")) value = schema.normalizeLayout(value);
    if (!validRuleText(key, value)) return error.InvalidWindowRuleValue;
}

pub fn validRuleText(key: []const u8, value: []const u8) bool {
    const options = ruleOptions(key);
    if (options.len != 0) return valueIn(value, options);
    if (std.mem.eql(u8, key, "size")) return validRuleSize(value);
    return true;
}

pub fn validRuleSize(value: []const u8) bool {
    if (std.mem.eql(u8, value, "native")) return true;
    const split = std.mem.indexOfScalar(u8, value, 'x') orelse return false;
    const left = value[0..split];
    const right = value[split + 1 ..];
    if (std.mem.indexOfScalar(u8, left, '.') != null or std.mem.indexOfScalar(u8, right, '.') != null) {
        const width = std.fmt.parseFloat(f64, left) catch return false;
        const height = std.fmt.parseFloat(f64, right) catch return false;
        return std.math.isFinite(width) and std.math.isFinite(height) and width > 0 and width <= 1 and height > 0 and height <= 1;
    }
    // Match the native rule parser's pixel-size representation.
    const width = std.fmt.parseInt(i32, left, 10) catch return false;
    const height = std.fmt.parseInt(i32, right, 10) catch return false;
    return width > 0 and height > 0;
}

pub fn ruleOptions(key: []const u8) []const []const u8 {
    if (std.mem.eql(u8, key, "layout")) return &.{ "tile", "monocle", "grid", "rows", "dwindle", "reverse-dwindle", "scrolling", "stacking", "game-mode", "composable" };
    if (std.mem.eql(u8, key, "content_type")) return &.{ "none", "photo", "video", "game" };
    if (std.mem.eql(u8, key, "placement_policy")) return &.{ "cascade", "center", "under-pointer", "minimal-overlap" };
    if (std.mem.eql(u8, key, "anchor")) return &.{ "center", "top", "bottom", "left", "right" };
    if (std.mem.eql(u8, key, "buffer_scale_policy")) return &.{ "native", "integer-ceil" };
    if (std.mem.eql(u8, key, "overlay_plane")) return &.{ "off", "prefer" };
    if (std.mem.eql(u8, key, "stack_layer")) return &.{ "below", "normal", "above" };
    return &.{};
}
