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
    _ = try col.add(try self.dropdown(&files, files[self.selected_file], .{ .app = self, .kind = .select_file }));
    _ = try col.add(self.label("Raw and typed edits to the same file must be resolved before Apply.", false));
    _ = try col.add(try self.textfield(self.model.rawText(files[self.selected_file]), .{ .app = self, .kind = .raw, .key = files[self.selected_file] }, true));
    const recovery = j.get(self.model.snapshot, "recovery");
    if (recovery != .null) {
        _ = try col.add(self.label("Saved state after uncertain Apply (read only)", true));
        var lines = std.mem.splitScalar(u8, j.text(j.get(recovery, "raw_files"), files[self.selected_file]), '\n');
        while (lines.next()) |line| _ = try col.add(self.label(line, false));
        _ = try col.add(try self.button("Discard drafts and load saved state", .discard, "", 0));
    }
}
