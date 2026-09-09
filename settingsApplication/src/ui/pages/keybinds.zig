const std = @import("std");
const q = @import("quark");
const j = @import("../../model/json.zig");
const app_mod = @import("../../app.zig");
const Binding = app_mod.Binding;
const files = app_mod.files;
const transforms = app_mod.transforms;
const theme_choices = app_mod.theme_choices;
const components = @import("../components/settings.zig");

pub fn build(self: anytype, col: *q.widget.Column) !void {
    _ = try col.add(self.richLabel("Click a shortcut to record the keys you press. Changes stay pending until Apply.", .muted));
    _ = try col.add(try self.button("Add custom binding", .add_keybind, "", 0));
    const rows = try self.model.rows("custom_keybinds", "custom_keybind_changes");
    for (j.items(rows)) |r| {
        const id = j.text(r, "id");
        _ = try col.add(self.label("Custom binding", true));
        _ = try col.add(self.label("Shortcut", false));
        _ = try col.add(try self.shortcutButton(.{ .app = self, .kind = .keybind, .id = id, .key = "chord" }, j.get(r, "chord")));
        try self.scalar(col, "Command", j.get(r, "command"), "string", .{ .app = self, .kind = .keybind, .id = id, .key = "command" });
        _ = try col.add(try self.button("Remove binding", .remove_keybind, id, 0));
    }
}
