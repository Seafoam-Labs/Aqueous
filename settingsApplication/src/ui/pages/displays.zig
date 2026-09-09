const std = @import("std");
const q = @import("quark");
const j = @import("../../model/json.zig");
const modes = @import("../../model/display_modes.zig");
const app_mod = @import("../../app.zig");
const Binding = app_mod.Binding;
const files = app_mod.files;
const transforms = app_mod.transforms;
const theme_choices = app_mod.theme_choices;
const components = @import("../components/settings.zig");

pub fn build(self: anytype, col: *q.widget.Column) !void {
    self.monitor_rows = try modes.monitors(self.ui.allocator(), self.model.snapshot, self.model.draft);
    const rows = j.items(self.monitor_rows);
    _ = try col.add(try self.button("Refresh connected displays", .refresh_live, "", 0));
    _ = try col.add(self.label("Drag monitors to stage positions. Apply saves the entire draft.", false));
    if (rows.len == 0) {
        _ = try col.add(self.label("No configured or connected monitors.", false));
        return;
    }
    self.selected_monitor = @min(self.selected_monitor, rows.len - 1);
    _ = try col.add(.{ .canvas = q.widget.Canvas.init(.{ .id = 8100, .theme = .{ .height = q.Size.fixed(240) } }) });
    const names = try self.ui.allocator().alloc([]const u8, rows.len);
    for (rows, 0..) |r, i| names[i] = j.text(r, "name");
    _ = try col.add(try self.dropdown(names, names[self.selected_monitor], .{ .app = self, .kind = .select_monitor }));
    const r = rows[self.selected_monitor];
    const id = j.text(r, "id");
    for ([_][]const u8{ "x", "y", "scale", "mode" }) |key| try self.scalar(col, key, j.get(r, key), "string", .{ .app = self, .kind = .monitor, .id = id, .key = key, .value = r });
    _ = try col.add(try self.dropdown(&transforms, j.text(r, "transform"), .{ .app = self, .kind = .monitor, .id = id, .key = "transform", .value = r }));
    const mirror_names = try self.ui.allocator().alloc([]const u8, rows.len + 1);
    mirror_names[0] = "Extended desktop";
    var count: usize = 1;
    for (rows) |other| if (!std.mem.eql(u8, j.text(other, "id"), id)) {
        mirror_names[count] = j.text(other, "name");
        count += 1;
    };
    _ = try col.add(try self.dropdown(mirror_names[0..count], if (j.text(r, "mirror_of").len == 0) "Extended desktop" else j.text(r, "mirror_of"), .{ .app = self, .kind = .monitor, .id = id, .key = "mirror_of", .value = r }));
    var choices = std.ArrayList([]const u8).empty;
    for (j.items(j.get(r, "modes"))) |mode| {
        const formatted = try modes.format(self.ui.allocator(), mode);
        if (formatted.len > 0) try choices.append(self.ui.allocator(), formatted);
    }
    if (choices.items.len > 0) _ = try col.add(try self.dropdown(choices.items, j.text(r, "mode"), .{ .app = self, .kind = .monitor_mode, .id = id, .key = "mode", .value = r }));
    _ = try col.add(self.label("Mode: WIDTHxHEIGHT for automatic refresh, or WIDTHxHEIGHT@Hz. Offline custom modes are accepted.", false));
    _ = try col.add(self.label(j.text(r, "mirror_error"), false));
}
