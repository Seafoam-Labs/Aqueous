const q = @import("quark");
pub fn find(widget: *q.Widget, id: u32) ?*q.Widget {
    switch (widget.*) {
        .column => |*w| {
            for (w.children.items) |*child| if (find(&child.widget, id)) |result| return result;
        },
        .row => |*w| {
            for (w.children.items) |*child| if (find(&child.widget, id)) |result| return result;
        },
        .scrollview => |*w| {
            if (w.id == id) return widget;
            return find(w.child, id);
        },
        .modal => |*w| return find(w.child, id),
        inline else => |w| {
            if (comptime @hasField(@TypeOf(w), "id")) {
                if (w.id == id) return widget;
            }
        },
    }
    return null;
}
pub fn bounds(widget: *q.Widget) q.components.Rectangle {
    return switch (widget.*) {
        inline else => |w| .{ .x = w.layout.x, .y = w.layout.y, .width = w.layout.width, .height = w.layout.height, .color = .{ 0, 0, 0 } },
    };
}
