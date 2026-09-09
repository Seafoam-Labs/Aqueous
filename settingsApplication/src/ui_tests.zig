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

test "partial clipping preserves image UVs and excludes pointer hits" {
    const Rectangle = q.components.Rectangle;
    const rect: Rectangle = .{ .x = 0, .y = 0, .width = 100, .height = 80, .color = .{ 1, 1, 1 }, .clip = .{ .x = 20, .y = 10, .width = 30, .height = 40 } };
    try std.testing.expect(!rect.contains(10, 20));
    try std.testing.expect(rect.contains(25, 20));
    var vertices = rect.toImageVertices(200, 160);
    try std.testing.expect(Rectangle.clipVertices(&vertices, rect, 200, 160));
    try std.testing.expectEqual(@as(f32, 20), vertices[0].pos_px[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), vertices[0].uv[0], 0.0001);
    try std.testing.expectEqual(@as(f32, 100), vertices[2].rect_max[0]);
    Rectangle.render_clip = .{ .x = 150, .y = 100, .width = 10, .height = 10 };
    defer Rectangle.render_clip = null;
    try std.testing.expect(!Rectangle.clipVertices(&vertices, rect, 200, 160));
}

test "wrapped labels measure multiple lines and never split UTF8" {
    const bytes = q.Font.bundledRegular();
    var fonts = try q.Font.Family.init(.{ .regular_bytes = bytes, .bold_bytes = bytes, .italic_bytes = bytes, .bold_italic_bytes = bytes, .pixel_height = 16, .allocator = std.testing.allocator });
    defer fonts.deinit();
    var widget: q.Widget = .{ .text = q.widget.Text.init(std.testing.allocator, .{ .text = "A long description with café and configuration/path/that/must/wrap", .wrap = true }) };
    defer widget.deinit(std.testing.allocator);
    const narrow = try widget.text.measureSize(std.testing.allocator, .{ .max_width = 80, .max_height = 1000 }, &fonts);
    const wide = try widget.text.measureSize(std.testing.allocator, .{ .max_width = 800, .max_height = 1000 }, &fonts);
    try std.testing.expect(narrow.height > wide.height * 2);
    var row = q.widget.Row.init(std.testing.allocator, .{ .spacing = 12 });
    _ = try row.add(.{ .text = q.widget.Text.init(std.testing.allocator, .{ .text = "Alpha" }) });
    _ = try row.addWithWidthConstraint(.{ .slider = q.widget.Slider.init(.{ .min_value = 0, .max_value = 255, .initial_value = 128 }) }, q.Size.proportional(1));
    var row_widget: q.Widget = .{ .row = row };
    defer row_widget.deinit(std.testing.allocator);
    _ = try row_widget.row.measureSize(std.testing.allocator, .{ .max_width = 400, .max_height = 100 }, &fonts);
    try std.testing.expect(row_widget.row.children.items[1].widget.slider.layout.width > 300);
    var cursor: usize = 0;
    while (cursor < widget.text.text.len) {
        const end = try q.widget.Text.lineEnd(&fonts.regular, widget.text.text, cursor, 80);
        try std.testing.expect(end > cursor);
        try std.testing.expect(std.unicode.utf8ValidateSlice(widget.text.text[cursor..end]));
        cursor = end;
    }
}

test "role fonts release partial loads and support repeated replacement" {
    const Fonts = @import("ui/style.zig").Fonts;
    for ([_]f32{ 16, 32, 18 }) |size| {
        var fonts = try Fonts.prepare(@splat(null), size);
        fonts.deinit();
        try std.testing.expect(fonts.title == null and fonts.description == null);
    }
    try std.testing.expectError(error.InvalidFont, Fonts.prepare(.{ "invalid", null, null, null }, 16));
}
