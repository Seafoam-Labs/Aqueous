const std = @import("std");
const q = @import("quark");
const j = @import("../../model/json.zig");
const app_mod = @import("../../app.zig");
const Binding = app_mod.Binding;
const files = app_mod.files;
const transforms = app_mod.transforms;
const theme_choices = app_mod.theme_choices;
const components = @import("../components/settings.zig");

pub fn build(self: anytype, parent: *q.widget.Column) !void {
    var theme_card = components.card(self.theme.palette, self.theme.radius);
    theme_card.tone = 1;
    const col = &theme_card;
    _ = try col.add(self.label("Application theme", true));
    _ = try col.add(try self.dropdown(&theme_choices, theme_choices[@intFromEnum(self.theme_choice)], .{ .app = self, .kind = .theme_source }));
    _ = try col.add(self.label(self.theme_status, false));
    _ = try col.add(self.richLabel("This application preference saves immediately.", .muted));
    _ = try col.add(self.label("Follow uses the selected shell's app colors; Noctalia shell-only mode stays separate.", false));
    _ = try parent.add(.{ .column = theme_card });
    var font_card = components.card(self.theme.palette, self.theme.radius);
    font_card.tone = 1;
    try self.fontControls(&font_card);
    _ = try parent.add(.{ .column = font_card });
}
