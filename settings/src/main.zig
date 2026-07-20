const std = @import("std");
const quark = @import("quark");
const config = @import("config.zig");

const Settings = config.Settings;

const App = struct {
    allocator: std.mem.Allocator,
    store: config.Store,
    draft: Settings,
    applied: Settings,
    status: []const u8 = "Loaded from Aqueous configuration",

    fn init(allocator: std.mem.Allocator) !App {
        var store = try config.Store.init(allocator);
        errdefer store.deinit();
        const settings = try store.load();
        return .{
            .allocator = allocator,
            .store = store,
            .draft = settings,
            .applied = settings,
        };
    }

    fn deinit(self: *App) void {
        self.store.deinit();
    }

    fn view(self: *App) !quark.Widget {
        var root = quark.widget.Column.init(self.allocator, .{
            .spacing = 18,
            .padding = 36,
            .alignment = .stretch,
        });

        _ = try root.add(self.text("Aqueous Settings", true, 0xECE9FB));
        _ = try root.add(self.text(
            "Configure the most common desktop options.",
            false,
            0xA8A2C7,
        ));
        _ = try root.add(try self.settingsCard());
        _ = try root.add(.{
            .spacer = quark.widget.Spacer.flexible(),
        });
        _ = try root.add(try self.footer());

        return .{ .column = root };
    }

    fn settingsCard(self: *App) !quark.Widget {
        var card = quark.widget.Column.init(self.allocator, .{
            .spacing = 16,
            .padding = 24,
            .alignment = .stretch,
            .background_color = quark.Theme.hex(0x1D1927),
            .border_radius = 8,
        });

        _ = try card.add(self.text("Appearance", true, 0xECE9FB));
        _ = try card.add(self.checkbox(
            "Enable background blur",
            self.draft.blur,
            toggleBlur,
        ));
        _ = try card.add(self.checkbox(
            "Animate workspace transitions",
            self.draft.animations,
            toggleAnimations,
        ));
        _ = try card.add(.{
            .spacer = quark.widget.Spacer.fixedHeight(10),
        });
        _ = try card.add(self.text("Touchpad", true, 0xECE9FB));
        _ = try card.add(self.checkbox(
            "Natural scrolling",
            self.draft.natural_scroll,
            toggleNaturalScroll,
        ));
        _ = try card.add(self.checkbox(
            "Tap to click",
            self.draft.tap_to_click,
            toggleTapToClick,
        ));

        return .{ .column = card };
    }

    fn footer(self: *App) !quark.Widget {
        var row = quark.widget.Row.init(self.allocator, .{
            .spacing = 12,
            .alignment = .center,
        });

        _ = try row.add(self.text(self.status, false, 0x8F88B0));
        _ = try row.add(.{
            .spacer = quark.widget.Spacer.flexible(),
        });
        _ = try row.add(self.button(
            "Reset",
            quark.action.bind(self, reset),
            false,
        ));
        _ = try row.add(self.button(
            "Apply",
            quark.action.bind(self, apply),
            true,
        ));

        return .{ .row = row };
    }

    fn text(
        self: *App,
        value: []const u8,
        bold: bool,
        color: u32,
    ) quark.Widget {
        return .{
            .text = quark.widget.Text.init(self.allocator, .{
                .text = value,
                .theme = .{
                    .color = quark.Theme.hex(color),
                    .font_style = .{ .bold = bold },
                },
            }),
        };
    }

    fn checkbox(
        self: *App,
        label: []const u8,
        checked: bool,
        comptime handler: anytype,
    ) quark.Widget {
        return .{
            .checkbox = quark.widget.CheckBox.init(.{
                .text = label,
                .checked = checked,
                .on_action = quark.action.bind(self, handler),
            }),
        };
    }

    fn button(
        self: *App,
        label: []const u8,
        handler: quark.action.Handler,
        primary: bool,
    ) quark.Widget {
        return .{
            .button = quark.widget.Button.init(.{
                .content = .{
                    .text = quark.widget.Text.init(self.allocator, .{
                        .text = label,
                    }),
                },
                .theme = .{
                    .color = quark.Theme.hex(
                        if (primary) 0x463699 else 0x252033,
                    ),
                    .focus_color = quark.Theme.hex(0x584AA3),
                },
                .on_action = handler,
            }),
        };
    }

    fn setChanged(self: *App) void {
        self.status = "Unsaved changes";
    }

    fn toggleBlur(self: *App, action: quark.Action) void {
        if (action == .toggle) {
            self.draft.blur = action.toggle;
            self.setChanged();
        }
    }

    fn toggleAnimations(self: *App, action: quark.Action) void {
        if (action == .toggle) {
            self.draft.animations = action.toggle;
            self.setChanged();
        }
    }

    fn toggleNaturalScroll(self: *App, action: quark.Action) void {
        if (action == .toggle) {
            self.draft.natural_scroll = action.toggle;
            self.setChanged();
        }
    }

    fn toggleTapToClick(self: *App, action: quark.Action) void {
        if (action == .toggle) {
            self.draft.tap_to_click = action.toggle;
            self.setChanged();
        }
    }

    fn apply(self: *App, _: quark.Action) void {
        self.store.save(self.applied, self.draft) catch {
            self.status = "Unable to write Aqueous configuration";
            return;
        };
        self.applied = self.draft;
        self.status = "Saved to Aqueous configuration";
    }

    fn reset(self: *App, _: quark.Action) void {
        self.draft = self.applied;
        self.status = "Changes reset";
    }
};

pub fn main() !void {
    var window = try quark.Parent.init(
        "Aqueous Settings",
        "0.1.0",
        "org.aqueous.Settings",
        760,
        540,
        .{
            .font_size = 18,
            .window_color = quark.Theme.hex(0x17141F),
        },
    );
    defer window.deinit();

    var app = try App.init(window.allocator);
    defer app.deinit();
    window.setLayout(try app.view());

    while (window.update()) |event| {
        if (event != null) window.setLayout(try app.view());
    }
}
