const std = @import("std");
const q = @import("quark");
const j = @import("../../model/json.zig");
const editor = @import("../../model/rule_editor.zig");
const Binding = @import("../../app.zig").Binding;
const components = @import("../components/settings.zig");
const style = @import("../style.zig");

pub fn build(self: anytype, parent: *q.widget.Column) !void {
    const a = self.ui.allocator();
    const rows = j.items(try self.model.rows("window_rules", "window_rule_changes"));
    const operations = j.items(j.get(self.model.draft, "window_rule_changes"));
    var moving = false;
    for (operations) |op| if (std.mem.eql(u8, j.text(op, "op"), "move")) {
        moving = true;
    };

    var chooser = components.card(self.theme.palette, self.theme.radius);
    chooser.tone = 1;
    _ = try chooser.add(self.label("1. Choose a rule", true));
    _ = try chooser.add(self.richLabel("The first matching rule wins. Choose an existing rule, edit its settings below, then Apply to save and reload.", .muted));
    if (rows.len == 0) {
        _ = try chooser.add(self.label("No window rules. Add a rule to choose which windows to match and what to change.", false));
        _ = try chooser.add(try self.button("Add rule", .add_rule, "", 0));
        _ = try parent.add(.{ .column = chooser });
        return;
    }
    self.selected_rule = @min(self.selected_rule, rows.len - 1);
    const selected = rows[self.selected_rule];
    const id = j.text(selected, "id");
    const values = j.get(selected, "values");
    var saved: j.Value = .null;
    if (editor.indexOf(j.items(j.get(self.model.snapshot, "window_rules")), id)) |i| saved = j.get(j.items(j.get(self.model.snapshot, "window_rules"))[i], "values");
    var changes: j.Value = .null;
    var pending = false;
    for (operations) |op| if (std.mem.eql(u8, j.text(op, "id"), id)) {
        pending = true;
        changes = j.get(op, "values");
    };

    const labels = try a.alloc([]const u8, rows.len);
    for (rows, 0..) |row, i| labels[i] = try editor.label(a, j.get(row, "values"), i);
    _ = try chooser.add(try self.dropdown(labels, labels[self.selected_rule], .{ .app = self, .kind = .select_rule }));
    _ = try chooser.add(self.richLabel(try std.fmt.allocPrint(a, "Editing rule {d} of {d} · {s}", .{ self.selected_rule + 1, rows.len, if (saved == .null) "New rule — not saved" else if (pending) "Unsaved changes" else "Saved rule" }), if (pending) .accent else .muted));
    var controls = self.newRow();
    if (!moving) {
        _ = try controls.add(try self.button(if (self.rule_show_all) "Configured settings only" else "Show all settings", .rule_options, "", 0));
        _ = try controls.add(try self.button("Add rule", .add_rule, "", 0));
        _ = try controls.add(try self.button("Remove selected rule", .remove_rule, "", 0));
    }
    if (operations.len == 0) {
        if (self.selected_rule > 0) _ = try controls.add(try self.button("Move earlier", .move_up, "", 0));
        if (self.selected_rule + 1 < rows.len) _ = try controls.add(try self.button("Move later", .move_down, "", 0));
    }
    if (controls.children.items.len > 0) _ = try chooser.add(try self.actionRow(controls));
    if (operations.len > 0) _ = try chooser.add(self.richLabel(if (moving) "Order change staged. Apply or Discard before editing rules or changing their order again." else "Apply or Discard pending rule changes before changing rule order. Removing a rule is also staged until Apply.", .muted));
    _ = try parent.add(.{ .column = chooser });
    if (moving) return;

    const fields = j.items(try j.parse(a, @embedFile("../../model/rule-fields.json")));
    const groups = [_][]const u8{ "Match windows", "Layout and placement", "Size and position", "Appearance", "Focus and visibility", "Game mode" };
    var effects: usize = 0;
    for (groups, 0..) |group, group_index| {
        var card = components.card(self.theme.palette, self.theme.radius);
        card.tone = 1;
        var count: usize = 0;
        _ = try card.add(self.label(if (group_index == 0) "2. Match windows" else group, true));
        if (group_index == 0) {
            _ = try card.add(self.richLabel("All specified conditions must match. Matching is case-sensitive; * matches any text and ? matches one character. Blank fields impose no condition.", .muted));
            var has_match = false;
            for (editor.match_keys) |key| if (j.get(values, key) != .null) {
                has_match = true;
            };
            if (!has_match) _ = try card.add(self.richLabel("This rule has no matching conditions and will be ignored. Enter an app ID, class, title, or content type; use * to match all windows.", .accent));
            if (j.get(values, "content_type") != .null) _ = try card.add(self.richLabel("With a content type condition, layout, placement, focus, and game sizing settings are ignored. Use Appearance settings for this rule.", .accent));
        }
        for (fields) |field| {
            if (!std.mem.eql(u8, j.text(field, "group"), group)) continue;
            const key = j.text(field, "key");
            // Keep removed overrides visible until Apply, including invalid text drafts.
            const changed = changes == .object and changes.object.contains(key);
            const binding = Binding{ .app = self, .kind = .rule_field, .id = id, .key = key, .value = field };
            const input_key = try self.inputKey(binding);
            if (group_index != 0 and !self.rule_show_all and j.get(values, key) == .null and !changed and j.get(self.model.inputs, input_key) == .null) continue;
            count += 1;
            if (group_index != 0) effects += 1;
            const value = j.get(values, key);
            var details = self.column();
            details.spacing = 4;
            _ = try details.add(self.label(j.text(field, "label"), true));
            _ = try details.add(self.richLabel(j.text(field, "description"), .muted));
            if (changed and !(try j.eq(a, value, j.get(saved, key)))) {
                _ = try details.add(self.richLabel(try std.fmt.allocPrint(a, "Changed · Saved: {s}", .{try describe(self, j.get(saved, key), group_index == 0)}), .accent));
            }
            if (j.get(self.model.errors, input_key) != .null) _ = try details.add(self.richLabel("Invalid value. Follow the format and range above, or clear the field.", .error_text));
            const no_value = if (group_index == 0) "Any content type" else "No override";
            const options = j.items(j.get(field, "options"));
            var widget: q.Widget = undefined;
            if (options.len > 0) {
                const choices = try a.alloc([]const u8, options.len + 1);
                choices[0] = no_value;
                for (options, 0..) |option, i| choices[i + 1] = j.str(option);
                widget = try self.dropdown(choices, if (value == .null) no_value else j.str(value), binding);
            } else if (std.mem.eql(u8, j.text(field, "type"), "boolean")) {
                widget = try self.dropdown(&.{ "No override", "On", "Off" }, try describe(self, value, false), binding);
            } else {
                widget = try self.textfield(try self.display(value), binding, false);
                widget.textfield.placeholder = j.text(field, "placeholder");
            }
            if (style.stacked(self.window.width(), self.theme.font.pixels)) {
                _ = try card.add(.{ .column = details });
                _ = try card.add(widget);
            } else {
                var row = self.newRow();
                _ = try row.addWithWidthConstraint(.{ .column = details }, q.Size.proportional(1));
                _ = try row.addWithWidthConstraint(widget, q.Size.proportional(1));
                _ = try card.add(.{ .row = row });
            }
        }
        if (count > 0) _ = try parent.add(.{ .column = card }) else card.deinit();
        if (group_index == 0) {
            _ = try parent.add(self.label("3. Change window behavior", true));
            _ = try parent.add(self.richLabel(if (self.rule_show_all) "All available settings are shown. Clear a field or choose No override to remove that setting from this rule." else "Only configured settings are shown. Choose Show all settings to add more. Clear a field or choose No override to remove a setting.", .muted));
        }
    }
    if (effects == 0) _ = try parent.add(self.richLabel("No behavior settings are configured. Choose Show all settings to add an override.", .muted));
    _ = try parent.add(self.richLabel("Review your changes, then Apply. Discard in the footer removes all pending changes across the application.", .muted));
}

fn describe(self: anytype, value: j.Value, matcher: bool) ![]const u8 {
    return switch (value) {
        .null => if (matcher) "No condition" else "No override",
        .bool => if (value.bool) "On" else "Off",
        else => try self.display(value),
    };
}
