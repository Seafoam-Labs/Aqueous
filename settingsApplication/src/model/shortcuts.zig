const std = @import("std");
const j = @import("json.zig");

// Names supported by Aqueous's chord parser. Keep Shift separate from the
// unshifted key (Shift+1, not Shift+exclam), including on non-US layouts.
pub fn format(a: std.mem.Allocator, sym: u32, mods: u32, alt_primary: bool) ![]const u8 {
    const name = try keyName(a, sym);
    return try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{
        if (mods & 64 != 0) (if (alt_primary) "Meta+" else "Super+") else "",
        if (mods & 4 != 0) "Ctrl+" else "",
        if (mods & 8 != 0) "Alt+" else "",
        if (mods & 1 != 0) "Shift+" else "",
        name,
    });
}

fn keyName(a: std.mem.Allocator, sym: u32) ![]const u8 {
    const named = .{
        .{ 0xff0d, "Return" },                    .{ 0x20, "Space" },                       .{ 0xff09, "Tab" },
        .{ 0xff1b, "Escape" },                    .{ 0xff08, "BackSpace" },                 .{ 0xffff, "Delete" },
        .{ 0xffe5, "CapsLock" },                  .{ 0xff61, "Print" },                     .{ 0xff51, "Left" },
        .{ 0xff52, "Up" },                        .{ 0xff53, "Right" },                     .{ 0xff54, "Down" },
        .{ 0xff50, "Home" },                      .{ 0xff57, "End" },                       .{ 0xff55, "PageUp" },
        .{ 0xff56, "PageDown" },                  .{ 0x2b, "Plus" },                        .{ 0x2c, "Comma" },
        .{ 0x1008ff13, "XF86AudioRaiseVolume" },  .{ 0x1008ff11, "XF86AudioLowerVolume" },  .{ 0x1008ff12, "XF86AudioMute" },
        .{ 0x1008ffb2, "XF86AudioMicMute" },      .{ 0x1008ff14, "XF86AudioPlay" },         .{ 0x1008ff31, "XF86AudioPause" },
        .{ 0x1008ff15, "XF86AudioStop" },         .{ 0x1008ff17, "XF86AudioNext" },         .{ 0x1008ff16, "XF86AudioPrev" },
        .{ 0x1008ff02, "XF86MonBrightnessUp" },   .{ 0x1008ff03, "XF86MonBrightnessDown" }, .{ 0x1008ff05, "XF86KbdBrightnessUp" },
        .{ 0x1008ff06, "XF86KbdBrightnessDown" }, .{ 0x1008ff59, "XF86Display" },           .{ 0x1008ff1b, "XF86Search" },
        .{ 0x1008ff41, "XF86Launch1" },
    };
    inline for (named) |entry| if (sym == entry[0]) return entry[1];
    if (sym >= 0xffbe and sym <= 0xffd5) return try std.fmt.allocPrint(a, "F{d}", .{sym - 0xffbe + 1});
    if (sym >= 0x21 and sym <= 0x7e) return try std.fmt.allocPrint(a, "{c}", .{std.ascii.toUpper(@intCast(sym))});
    return error.UnsupportedShortcutKey;
}

pub fn replace(a: std.mem.Allocator, list: *j.Value, index: usize, chord: []const u8) !void {
    for (j.items(list.*), 0..) |item, i| if (i != index and std.ascii.eqlIgnoreCase(j.str(item), chord)) return error.DuplicateShortcut;
    const value = try j.string(a, chord);
    if (index < list.array.items.len) list.array.items[index] = value else try list.array.append(value);
}

test "recorded shortcuts preserve modifiers and special keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Super+Ctrl+Alt+Shift+1", try format(a, '1', 77, false));
    try std.testing.expectEqualStrings("Meta+Left", try format(a, 0xff51, 64, true));
    try std.testing.expectEqualStrings("F12", try format(a, 0xffc9, 0, false));
    try std.testing.expectEqualStrings("XF86AudioMute", try format(a, 0x1008ff12, 0, false));
    try std.testing.expectEqualStrings("Ctrl+Plus", try format(a, '+', 4, false));
    try std.testing.expectEqualStrings("Super+Comma", try format(a, ',', 64, false));
    try std.testing.expectError(error.UnsupportedShortcutKey, format(a, 0xffe1, 1, false));
}

test "replacing one shortcut retains alternatives and rejects duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list = try j.parse(a, "[\"Super+Return\",\"Super+T\"]");
    try replace(a, &list, 0, "Ctrl+F12");
    try std.testing.expectEqualStrings("Super+T", j.str(list.array.items[1]));
    try replace(a, &list, 2, "Alt+F2");
    try std.testing.expectEqual(@as(usize, 3), list.array.items.len);
    try std.testing.expectError(error.DuplicateShortcut, replace(a, &list, 0, "super+t"));
}
