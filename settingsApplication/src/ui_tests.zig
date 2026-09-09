const std = @import("std");
const q = @import("quark");
const theme = @import("services/theme/quark.zig");
test "restyling preserves multiline height while fitting large fonts" {
    var field: q.Widget = .{ .textfield = q.widget.TextField.init(.{ .placeholder = "raw", .theme = .{ .height = q.Size.fixed(380) } }) };
    theme.restyle(&field, .{}, 720);
    try std.testing.expectEqual(@as(f32, 380), field.textfield.theme.height.?.preferred.?);
    theme.restyle(&field, .{ .font = .{ .pixels = 32 } }, 720);
    try std.testing.expect(field.textfield.theme.height.?.preferred.? > 100);
    try std.testing.expect(field.textfield.theme.height.?.preferred.? <= 332);
}
test "live status labels retain ownership through replacement and destruction" {
    var col = q.widget.Column.init(std.testing.allocator, .{});
    _ = try col.add(.{ .text = q.widget.Text.init(std.testing.allocator, .{ .text = "Loading theme" }) });
    var widget: q.Widget = .{ .column = col };
    defer widget.deinit(std.testing.allocator);
    theme.replaceText(&widget, "Loading theme", "Following DMS");
    try std.testing.expectEqualStrings("Following DMS", widget.column.children.items[0].widget.text.text);
    theme.replaceText(&widget, "Following DMS", "Theme unavailable");
}
