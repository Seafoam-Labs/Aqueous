const q = @import("quark");
const model = @import("../../model/theme.zig");
pub fn resolve(snapshot: model.Snapshot) q.Theme {
    const p = snapshot.palette;
    const height = q.Size.fixed(@max(36, snapshot.font.pixels + 20));
    const radius = q.Size.fixed(@min(snapshot.radius, 18));
    return .{
        .Button = .{ .color = q.Theme.hex(p.surface_container_high), .focus_color = q.Theme.hex(p.primary_container), .text_color = q.Theme.hex(p.on_surface), .height = height, .radius = radius },
        .Text = .{ .color = q.Theme.hex(p.on_surface) },
        .TextField = .{ .color = q.Theme.hex(p.surface_container), .text_color = q.Theme.hex(p.on_surface), .placeholder_text_color = q.Theme.hex(p.on_surface_variant), .cursor_color = q.Theme.hex(p.primary), .border = .{ .color = q.Theme.hex(p.outline), .focus_color = q.Theme.hex(p.primary) }, .height = height },
        .Dropdown = .{ .color = q.Theme.hex(p.surface_container), .focus_color = q.Theme.hex(p.primary_container), .text_color = q.Theme.hex(p.on_surface), .item_color = q.Theme.hex(p.surface_container_high), .item_focus_color = q.Theme.hex(p.primary_container), .height = height, .radius = radius },
        .CheckBox = .{ .color = q.Theme.hex(p.surface_container), .select_color = q.Theme.hex(p.primary), .border = .{ .color = q.Theme.hex(p.outline), .focus_color = q.Theme.hex(p.primary) } },
        .Canvas = .{ .color = q.Theme.hex(p.surface_container), .radius = radius, .border = .{ .color = q.Theme.hex(p.outline) } },
        .ContextMenu = .{ .color = q.Theme.hex(p.surface_container_high), .focus_color = q.Theme.hex(p.primary_container), .text_color = q.Theme.hex(p.on_surface), .radius = radius },
        .Modal = .{ .color = q.Theme.hex(p.background) },
        .Slider = .{ .color = q.Theme.hex(p.surface_container_high), .filled_color = q.Theme.hex(p.primary), .handle = .{ .color = q.Theme.hex(p.primary), .focus_color = q.Theme.hex(p.primary_container), .select_color = q.Theme.hex(p.primary) } },
    };
}
// Update layout constraints in place. Widget identities and editing state survive.
pub fn restyle(widget: *q.Widget, snapshot: model.Snapshot, window_height: f32) void {
    const height = q.Size.fixed(@max(36, snapshot.font.pixels + 20));
    switch (widget.*) {
        .button => |*w| w.theme.height = height,
        .dropdown => |*w| w.theme.height = height,
        .textfield => |*w| {
            if (w.theme.height) |h| {
                if ((h.preferred orelse 36) > 100) {
                    w.theme.height = q.Size.fixed(@max(120, @min(380, window_height - 260 - @max(0, snapshot.font.pixels - 16) * 8)));
                } else w.theme.height = height;
            }
        },
        .column => |*w| {
            if (w.background_color != null) w.background_color = q.Theme.hex(snapshot.palette.surface_container_high);
            for (w.children.items) |*child| restyle(&child.widget, snapshot, window_height);
        },
        .row => |*w| for (w.children.items) |*child| restyle(&child.widget, snapshot, window_height),
        .scrollview => |*w| {
            w.scrollbar_track.color = q.Theme.hex(snapshot.palette.surface_container_high);
            w.scrollbar_handle.color = q.Theme.hex(snapshot.palette.outline);
            restyle(w.child, snapshot, window_height);
        },
        .modal => |*w| restyle(w.child, snapshot, window_height),
        else => {},
    }
}

pub fn replaceText(widget: *q.Widget, old: []const u8, new: []const u8) void {
    switch (widget.*) {
        .text => |*w| {
            if (@import("std").mem.eql(u8, w.text, old)) {
                const replacement = w.allocator.dupe(u8, new) catch return;
                w.allocator.free(w.text);
                w.text = replacement;
            }
        },
        .column => |*w| for (w.children.items) |*child| replaceText(&child.widget, old, new),
        .row => |*w| for (w.children.items) |*child| replaceText(&child.widget, old, new),
        .scrollview => |*w| replaceText(w.child, old, new),
        .modal => |*w| replaceText(w.child, old, new),
        else => {},
    }
}
