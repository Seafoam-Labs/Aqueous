const std = @import("std");
pub const Section = struct { id: []const u8, title: []const u8, page: usize, keywords: []const u8 = "" };
pub const sections = [_]Section{
    .{ .id = "theme", .title = "Application theme", .page = 1, .keywords = "colors dark light noctalia dms" },
    .{ .id = "font", .title = "Desktop typography", .page = 1, .keywords = "font text size family" },
    .{ .id = "cursor", .title = "Cursor", .page = 1, .keywords = "pointer size theme" },
    .{ .id = "opacity", .title = "Window opacity", .page = 1, .keywords = "transparency translucent" },
    .{ .id = "blur", .title = "Backdrop blur", .page = 1 },
    .{ .id = "space", .title = "Reserved space", .page = 1, .keywords = "struts bar maximize fullscreen" },
    .{ .id = "bell", .title = "System bell", .page = 1, .keywords = "sound audio feedback volume" },
    .{ .id = "animation", .title = "Workspace animation", .page = 1, .keywords = "motion transition" },
    .{ .id = "default", .title = "Default layout and gaps", .page = 2 },
    .{ .id = "borders", .title = "Window borders", .page = 2, .keywords = "decoration color radius" },
    .{ .id = "slots", .title = "Layout shortcuts", .page = 2 },
    .{ .id = "scrolling", .title = "Scrolling layout", .page = 2 },
    .{ .id = "dwindle", .title = "Dwindle layouts", .page = 2 },
    .{ .id = "monocle", .title = "Monocle layout", .page = 2 },
    .{ .id = "stacking", .title = "Stacking layout", .page = 2, .keywords = "floating float" },
    .{ .id = "keyboard", .title = "Keyboard", .page = 3 },
    .{ .id = "pointer", .title = "Pointer", .page = 3, .keywords = "mouse acceleration" },
    .{ .id = "touchpad", .title = "Touchpad", .page = 3 },
    .{ .id = "display", .title = "Display policy", .page = 4 },
    .{ .id = "game", .title = "Game Mode defaults", .page = 5 },
    .{ .id = "commands", .title = "Application commands", .page = 6 },
    .{ .id = "shortcuts", .title = "Built-in shortcuts", .page = 6 },
};
pub fn section(id: []const u8) []const u8 {
    const mappings = .{
        .{ "bell.", "bell" },
        .{ "desktop.font.", "font" },
        .{ "desktop.cursor.", "cursor" },
        .{ "opacity.", "opacity" },
        .{ "blur.", "blur" },
        .{ "struts.", "space" },
        .{ "state.", "space" },
        .{ "workspace_transition.", "animation" },
        .{ "layout.border", "borders" },
        .{ "layout.force_ssd", "borders" },
        .{ "layout.slots.", "slots" },
        .{ "layout.options.scrolling.", "scrolling" },
        .{ "layout.options.reverse-dwindle.", "dwindle" },
        .{ "layout.options.dwindle.", "dwindle" },
        .{ "layout.options.monocle.", "monocle" },
        .{ "layout.options.stacking.", "stacking" },
        .{ "layout.", "default" },
        .{ "input.keyboard.", "keyboard" },
        .{ "input.touchpad.", "touchpad" },
        .{ "input.pointer.", "pointer" },
        .{ "input.mouse.", "pointer" },
        .{ "display.", "display" },
        .{ "game_mode.", "game" },
        .{ "actions.", "commands" },
        .{ "keybinds.", "shortcuts" },
    };
    inline for (mappings) |m| if (std.mem.startsWith(u8, id, m[0])) return m[1];
    return "other";
}
pub fn special(id: []const u8) bool {
    return std.mem.eql(u8, id, "desktop.font.family") or std.mem.eql(u8, id, "desktop.font.style");
}
pub fn percent(id: []const u8) bool {
    return std.mem.startsWith(u8, id, "opacity.") and !std.mem.endsWith(u8, id, "enabled") and !std.mem.endsWith(u8, id, "focus_sensitive");
}
pub fn stableId(kind: []const u8, key: []const u8, item: []const u8, index: usize) u32 {
    var hash = std.hash.Wyhash.init(0x41515545);
    for ([_][]const u8{ kind, key, item }) |part| {
        hash.update(part);
        hash.update("\x00");
    }
    if (item.len == 0) hash.update(std.mem.asBytes(&index));
    return @as(u32, @truncate(hash.final())) | 0x80000000;
}
pub fn toDisplay(id: []const u8, value: f64) f64 {
    return if (percent(id)) value * 100 else value;
}
pub fn fromDisplay(id: []const u8, value: f64) f64 {
    return if (percent(id)) value / 100 else value;
}
pub fn parseColor(text: []const u8) !u32 {
    if (text.len != 10 or !std.mem.startsWith(u8, text, "0x")) return error.InvalidColor;
    for (text[2..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidColor;
    return std.fmt.parseInt(u32, text[2..], 16);
}
test "presentation retains ARGB and stable semantic identity" {
    try std.testing.expectEqual(@as(u32, 0x804488cc), try parseColor("0x804488CC"));
    try std.testing.expectError(error.InvalidColor, parseColor("#4488cc"));
    try std.testing.expect(stableId("field", "opacity.value", "", 0) != stableId("reset", "opacity.value", "", 0));
    try std.testing.expectEqualStrings("opacity", section("opacity.value"));
    try std.testing.expectEqualStrings("other", section("future.setting"));
}

test "numeric presentation preserves precision and collection identity survives reorder" {
    const value: f64 = 0.123456789;
    try std.testing.expectApproxEqAbs(value, fromDisplay("opacity.value", toDisplay("opacity.value", value)), 1e-15);
    try std.testing.expectEqual(@as(f64, 42), toDisplay("blur.radius", 42));
    try std.testing.expectEqual(stableId("zone_field", "x", "layout/zone", 0), stableId("zone_field", "x", "layout/zone", 3));
}
