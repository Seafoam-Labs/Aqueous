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
    _ = try col.add(self.label("Apply or discard each rule move before other rule edits.", false));
    var controls = self.newRow();
    _ = try controls.add(try self.button("Add rule", .add_rule, "", 0));
    _ = try controls.add(try self.button("Remove", .remove_rule, "", 0));
    _ = try controls.add(try self.button("Move up", .move_up, "", 0));
    _ = try controls.add(try self.button("Move down", .move_down, "", 0));
    _ = try col.add(try self.actionRow(controls));
    const rows = j.items(try self.model.rows("window_rules", "window_rule_changes"));
    if (rows.len == 0) return;
    self.selected_rule = @min(self.selected_rule, rows.len - 1);
    const labels = try self.ui.allocator().alloc([]const u8, rows.len);
    for (rows, 0..) |r, i| labels[i] = try std.fmt.allocPrint(self.ui.allocator(), "{d}: {s} {s}", .{ i + 1, j.text(j.get(r, "values"), "app_id"), j.text(j.get(r, "values"), "title") });
    _ = try col.add(try self.dropdown(labels, labels[self.selected_rule], .{ .app = self, .kind = .select_rule }));
    const selected = rows[self.selected_rule];
    const fields = try j.parse(self.ui.allocator(), @embedFile("../../model/rule-fields.json"));
    for (j.items(fields)) |f| {
        const key = j.text(f, "key");
        const binding = Binding{ .app = self, .kind = .rule_field, .id = j.text(selected, "id"), .key = key, .value = f };
        const options = j.items(j.get(f, "options"));
        if (options.len > 0) {
            _ = try col.add(self.label(j.text(f, "label"), false));
            const choices = try self.ui.allocator().alloc([]const u8, options.len + 1);
            choices[0] = "(unset)";
            for (options, 0..) |v, i| choices[i + 1] = j.str(v);
            _ = try col.add(try self.dropdown(choices, j.text(j.get(selected, "values"), key), binding));
        } else if (std.mem.eql(u8, j.text(f, "type"), "boolean")) {
            _ = try col.add(self.label(j.text(f, "label"), false));
            const v = j.get(j.get(selected, "values"), key);
            _ = try col.add(try self.dropdown(&.{ "(unset)", "true", "false" }, if (v == .null) "(unset)" else if (j.boolean(v)) "true" else "false", binding));
        } else try self.scalar(col, j.text(f, "label"), j.get(j.get(selected, "values"), key), j.text(f, "type"), binding);
    }
}
