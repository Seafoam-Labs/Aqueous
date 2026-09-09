const std = @import("std");
const runtime_layout_model = @import("../../model/runtime_layout.zig");
const q = @import("quark");
const j = @import("../../model/json.zig");
const app_mod = @import("../../app.zig");
const Binding = app_mod.Binding;
const files = app_mod.files;
const transforms = app_mod.transforms;
const theme_choices = app_mod.theme_choices;
const components = @import("../components/settings.zig");

pub fn build(self: anytype, col: *q.widget.Column) !void {
    _ = try col.add(self.label("Change the current workspace layout immediately", true));
    const outputs = j.items(j.get(self.model.snapshot, "live_outputs"));
    const names = try self.ui.allocator().alloc([]const u8, outputs.len);
    for (outputs, 0..) |o, i| names[i] = j.text(o, "name");
    if (outputs.len > 0) {
        if (self.runtime_output.len == 0) self.runtime_output = try self.own(names[0]);
        _ = try col.add(try self.dropdown(names, self.runtime_output, .{ .app = self, .kind = .runtime_output }));
        if (self.live_layout.failed) {
            _ = try col.add(self.label("Current layout unavailable; retrying compositor query…", false));
        } else if (self.live_layout.selected) |index| {
            _ = try col.add(self.label(try std.fmt.allocPrint(self.ui.allocator(), "Workspace {d}: {s}", .{ self.live_layout.workspace.?, runtime_layout_model.choices[self.live_layout.active.?] }), false));
            _ = try col.add(try self.dropdown(&runtime_layout_model.choices, runtime_layout_model.choices[index], .{ .app = self, .kind = .runtime_layout }));
            _ = try col.add(try self.button("Switch layout now", .runtime_apply, "", 0));
        } else _ = try col.add(self.label("Reading current workspace layout…", false));
    } else _ = try col.add(self.label("No live outputs available. Persistent settings remain editable.", false));
    _ = try col.add(self.label("Configuration files and diagnostics", true));
    const paths = j.get(self.model.snapshot, "files");
    if (paths == .object) {
        for (paths.object.keys(), paths.object.values()) |key, v| {
            _ = try col.add(self.label(try std.fmt.allocPrint(self.ui.allocator(), "{s}: {s}", .{ key, j.text(v, "path") }), false));
        }
    }
    for (j.items(j.get(self.model.snapshot, "warnings"))) |warning| _ = try col.add(self.label(j.str(warning), false));
}
