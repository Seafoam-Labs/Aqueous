const std = @import("std");
const q = @import("quark");
const j = @import("../../model/json.zig");
const V = j.Value;
const app_mod = @import("../../app.zig");
const Binding = app_mod.Binding;
const files = app_mod.files;
const transforms = app_mod.transforms;
const theme_choices = app_mod.theme_choices;
const components = @import("../components/settings.zig");
const a = std.heap.page_allocator;

pub fn build(self: anytype, col: *q.widget.Column) !void {
    var buttons = self.newRow();
    _ = try buttons.add(try self.button("Add snap layout", .add_layout, "", 0));
    _ = try buttons.add(try self.button("Migrate A–D", .migrate, "", 0));
    _ = try buttons.add(try self.button("Normalize Stacking aliases", .flag, "normalize_stacking", 0));
    _ = try col.add(try self.actionRow(buttons));
    _ = try col.add(self.label("Legacy A–D snap zones", true));
    for ([_][]const u8{ "a", "b", "c", "d" }) |id| {
        var original: V = .null;
        for (j.items(j.get(self.model.snapshot, "snap_zones"))) |zone| if (std.mem.eql(u8, j.text(zone, "id"), id)) {
            original = zone;
            break;
        };
        var zone = j.get(j.get(self.model.draft, "snap_zone_changes"), id);
        if (zone == .null) zone = original;
        _ = try col.add(self.label(id, true));
        var legacy_buttons = self.newRow();
        _ = try legacy_buttons.add(try self.button("Bind", .legacy_binding, id, 0));
        _ = try legacy_buttons.add(try self.button("Remove", .legacy_remove, id, 0));
        _ = try legacy_buttons.add(try self.button("Undo", .legacy_undo, id, 0));
        _ = try col.add(try self.actionRow(legacy_buttons));
        if (!std.mem.eql(u8, j.text(zone, "op"), "delete")) for ([_][]const u8{ "x", "y", "width", "height" }) |key| {
            const v = j.get(zone, key);
            try self.scalar(col, key, if (v == .null) V{ .float = if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y")) 0 else 0.5 } else v, "double", .{ .app = self, .kind = .legacy_zone, .key = key, .id = id, .value = zone });
        };
    }
    _ = try col.add(self.label("Named snap layouts", true));
    _ = try col.add(self.label(try std.fmt.allocPrint(self.ui.allocator(), "Default: {s}", .{if (j.get(self.model.draft, "default_snap_layout") != .null) j.text(self.model.draft, "default_snap_layout") else j.text(self.model.snapshot, "default_snap_layout")}), false));
    const rows = j.items(self.snapLayouts());
    if (rows.len == 0) return;
    self.selected_layout = @min(self.selected_layout, rows.len - 1);
    const names = try self.ui.allocator().alloc([]const u8, rows.len);
    for (rows, 0..) |r, i| names[i] = j.text(r, "name");
    _ = try col.add(try self.dropdown(names, names[self.selected_layout], .{ .app = self, .kind = .select_layout }));
    const layout = rows[self.selected_layout];
    for ([_][]const u8{ "id", "name", "padding" }) |key| try self.scalar(col, key, j.get(layout, key), "string", .{ .app = self, .kind = .layout_field, .key = key, .id = j.text(layout, "id") });
    buttons = self.newRow();
    _ = try buttons.add(try self.button("Use as default", .make_default, "", 0));
    _ = try buttons.add(try self.button("Remove layout", .remove_layout, "", 0));
    _ = try buttons.add(try self.button("Add zone", .add_zone, "", 0));
    _ = try col.add(try self.actionRow(buttons));
    buttons = self.newRow();
    for ([_][]const u8{ "Halves", "Thirds", "Quarters" }, 0..) |name, i| _ = try buttons.add(try self.button(name, .preset, "", i + 2));
    _ = try col.add(try self.actionRow(buttons));
    _ = try col.add(try self.button("Create layout cycle binding", .snap_binding, "cycle", 0));
    _ = try col.add(try self.button("Create layout selection binding", .snap_binding, "layout", 0));
    for (j.items(j.get(layout, "zones")), 0..) |zone, i| {
        _ = try col.add(self.label("Snap zone", true));
        for ([_][]const u8{ "id", "name", "x", "y", "width", "height" }) |key| try self.scalar(col, key, j.get(zone, key), "string", .{ .app = self, .kind = .zone_field, .key = key, .id = try std.fmt.allocPrint(self.ui.allocator(), "{s}/{s}", .{ j.text(layout, "id"), j.text(zone, "id") }), .index = i });
        buttons = self.newRow();
        _ = try buttons.add(try self.button("Remove zone", .remove_zone, "", i));
        _ = try buttons.add(try self.button("Create zone binding", .snap_binding, "zone", i));
        _ = try col.add(try self.actionRow(buttons));
    }
}
