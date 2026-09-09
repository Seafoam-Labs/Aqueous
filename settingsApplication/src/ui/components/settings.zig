const std = @import("std");
const q = @import("quark");
const model = @import("../../model/theme.zig");
const style = @import("../style.zig");
const a = std.heap.page_allocator;
pub fn column() q.widget.Column {
    return q.widget.Column.init(a, .{ .spacing = style.spacing, .alignment = .stretch });
}
pub fn row() q.widget.Row {
    return q.widget.Row.init(a, .{ .spacing = 12, .alignment = .center });
}
pub fn label(text: []const u8, bold: bool) q.Widget {
    return .{ .text = q.widget.Text.init(a, .{ .text = text, .wrap = true, .theme = .{ .font_style = .{ .bold = bold } } }) };
}
pub fn card(palette: model.Palette, radius: f32) q.widget.Column {
    return q.widget.Column.init(a, .{ .padding = 20, .spacing = 16, .alignment = .stretch, .background_color = q.Theme.hex(palette.surface_container), .border_radius = @max(8, radius) });
}
pub fn title(text: []const u8) q.Widget {
    return label(text, true);
}

// Original vector icons; no shell icon font or third-party asset dependency.
fn box(canvas: anytype, x: f32, y: f32, w: f32, h: f32, color: [3]f32) !void {
    try canvas.drawRect(a, x, y, w, 2, color);
    try canvas.drawRect(a, x, y + h - 2, w, 2, color);
    try canvas.drawRect(a, x, y, 2, h, color);
    try canvas.drawRect(a, x + w - 2, y, 2, h, color);
}
pub fn drawIcon(canvas: anytype, index: usize, color: [3]f32) !void {
    switch (index) {
        0 => {
            for (0..2) |r| for (0..2) |c| try box(canvas, 4 + @as(f32, @floatFromInt(c)) * 11, 4 + @as(f32, @floatFromInt(r)) * 11, 8, 8, color);
        },
        1 => {
            for (0..3) |i| {
                const x = 5 + @as(f32, @floatFromInt(i)) * 7;
                try canvas.drawRect(a, x, 5, 3, 18, color);
                try canvas.drawRect(a, x - 2, 8 + @as(f32, @floatFromInt(i)) * 4, 7, 4, color);
            }
        },
        2 => {
            try box(canvas, 4, 5, 9, 18, color);
            try box(canvas, 15, 5, 9, 8, color);
            try box(canvas, 15, 15, 9, 8, color);
        },
        3 => {
            try box(canvas, 3, 7, 22, 15, color);
            for (0..4) |i| try canvas.drawRect(a, 6 + @as(f32, @floatFromInt(i)) * 5, 11, 2, 3, color);
            try canvas.drawRect(a, 8, 17, 12, 2, color);
        },
        4 => {
            try box(canvas, 3, 4, 22, 16, color);
            try canvas.drawRect(a, 13, 20, 2, 4, color);
            try canvas.drawRect(a, 8, 24, 12, 2, color);
        },
        5 => {
            for (0..3) |i| {
                const y = 5 + @as(f32, @floatFromInt(i)) * 7;
                try box(canvas, 4, y, 4, 4, color);
                try canvas.drawRect(a, 11, y + 1, 13, 2, color);
            }
        },
        6 => {
            try box(canvas, 3, 5, 11, 11, color);
            try canvas.drawRect(a, 12, 12, 12, 3, color);
            try canvas.drawRect(a, 18, 14, 3, 6, color);
            try canvas.drawRect(a, 23, 14, 2, 4, color);
        },
        else => {
            try box(canvas, 3, 4, 22, 20, color);
            try canvas.drawRect(a, 7, 9, 3, 3, color);
            try canvas.drawRect(a, 10, 12, 3, 3, color);
            try canvas.drawRect(a, 7, 15, 3, 3, color);
            try canvas.drawRect(a, 15, 18, 6, 2, color);
        },
    }
}
