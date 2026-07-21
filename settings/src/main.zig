const std = @import("std");
const quark = @import("quark");
const config = @import("config.zig");

const App = struct {
    allocator: std.mem.Allocator,
    files: config.ConfigFiles,
    selected_file: usize = 0,
    status: []const u8 = "Loaded Aqueous configuration",
    needs_rebuild: bool = false,
    editor_epoch: bool = false,
    add_target: []u8,
    add_key: []u8,
    add_value: []u8,
    stable_strings: std.ArrayList([]u8) = .empty,
    callbacks: std.ArrayList(*Callback) = .empty,

    const Callback = struct {
        app: *App,
        value: u64,
    };

    fn init(allocator: std.mem.Allocator) !App {
        var files = try config.ConfigFiles.init(allocator);
        errdefer files.deinit();
        const target = try allocator.dupe(u8, "");
        errdefer allocator.free(target);
        const key = try allocator.dupe(u8, "");
        errdefer allocator.free(key);
        return .{
            .allocator = allocator,
            .files = files,
            .add_target = target,
            .add_key = key,
            .add_value = try allocator.dupe(u8, ""),
        };
    }

    fn deinit(self: *App) void {
        self.files.deinit();
        self.allocator.free(self.add_target);
        self.allocator.free(self.add_key);
        self.allocator.free(self.add_value);
        for (self.stable_strings.items) |value| self.allocator.free(value);
        self.stable_strings.deinit(self.allocator);
        for (self.callbacks.items) |callback| self.allocator.destroy(callback);
        self.callbacks.deinit(self.allocator);
    }

    fn view(self: *App) !quark.Widget {
        var root = quark.widget.Column.init(self.allocator, .{
            .spacing = 12,
            .padding = 22,
            .alignment = .stretch,
        });

        var heading = quark.widget.Row.init(self.allocator, .{
            .spacing = 12,
            .alignment = .center,
        });
        _ = try heading.add(self.text("Aqueous Settings", true, 0xECE9FB));
        _ = try heading.add(.{ .spacer = quark.widget.Spacer.flexible() });
        _ = try heading.add(self.text(self.status, false, 0x8F88B0));
        _ = try root.add(.{ .row = heading });
        _ = try root.add(try self.navigation());

        const content = try self.fileView();
        _ = try root.addWithHeightConstraint(
            .{ .scrollview = try quark.widget.ScrollView.initOwned(content, self.allocator) },
            quark.Size.proportional(1),
        );

        var footer = quark.widget.Row.init(self.allocator, .{
            .spacing = 10,
            .alignment = .center,
        });
        _ = try footer.add(self.text(
            "Values use TOML syntax; changes remain drafts until Save all.",
            false,
            0x8F88B0,
        ));
        _ = try footer.add(.{ .spacer = quark.widget.Spacer.flexible() });
        _ = try footer.add(self.button(
            "Reload",
            quark.action.bind(self, reload),
            false,
        ));
        _ = try footer.add(self.button(
            "Save all",
            quark.action.bind(self, save),
            true,
        ));
        _ = try root.add(.{ .row = footer });
        return .{ .column = root };
    }

    fn navigation(self: *App) !quark.Widget {
        var row = quark.widget.Row.init(self.allocator, .{
            .spacing = 8,
            .alignment = .center,
        });
        for (self.files.items, 0..) |file, index| {
            _ = try row.add(self.button(
                file.name,
                try self.bindValue(index, selectFile),
                index == self.selected_file,
            ));
        }
        return .{ .row = row };
    }

    fn fileView(self: *App) !quark.Widget {
        const file = &self.files.items[self.selected_file];
        const tables = try file.document.tables(self.allocator);
        defer self.allocator.free(tables);
        const entries = try file.document.entries(self.allocator);
        defer self.allocator.free(entries);

        var content = quark.widget.Column.init(self.allocator, .{
            .spacing = 14,
            .padding = 4,
            .alignment = .stretch,
        });
        _ = try content.add(self.text(file.path, false, 0xA8A2C7));
        _ = try content.add(try self.addEditor());

        for (tables) |table| {
            var has_entries = false;
            for (entries) |entry| {
                if (entry.table_index == table.index) {
                    has_entries = true;
                    break;
                }
            }
            if (table.index == 0 and !has_entries) continue;
            _ = try content.add(try self.tableCard(table, entries));
        }

        if (entries.len == 0) {
            _ = try content.add(self.text(
                "This file is empty. Add its first table and key above.",
                false,
                0xA8A2C7,
            ));
        }
        return .{ .column = content };
    }

    fn addEditor(self: *App) !quark.Widget {
        var card = quark.widget.Column.init(self.allocator, .{
            .spacing = 9,
            .padding = 16,
            .alignment = .stretch,
            .background_color = quark.Theme.hex(0x1D1927),
            .border_radius = 8,
        });
        _ = try card.add(self.text("Add setting", true, 0xECE9FB));
        _ = try card.add(self.text(
            "Target: section name, [[repeated.table]], or the table number shown below.",
            false,
            0xA8A2C7,
        ));
        if (self.editor_epoch) {
            _ = try card.add(.{ .spacer = quark.widget.Spacer.fixedHeight(0) });
        }

        _ = try card.add(self.text("Target table", false, 0xD5D0E8));
        _ = try card.add(try self.textField(
            self.add_target,
            "blur, [[window]], or 3",
            quark.action.bind(self, changeTarget),
        ));
        _ = try card.add(self.text("Key", false, 0xD5D0E8));
        _ = try card.add(try self.textField(
            self.add_key,
            "key",
            quark.action.bind(self, changeKey),
        ));
        _ = try card.add(self.text("Value", false, 0xD5D0E8));
        _ = try card.add(try self.textField(
            self.add_value,
            "TOML value",
            quark.action.bind(self, changeValue),
        ));
        _ = try card.add(self.button(
            "Add",
            quark.action.bind(self, addSetting),
            true,
        ));
        return .{ .column = card };
    }

    fn tableCard(
        self: *App,
        table: config.Document.Table,
        entries: []const config.Document.Entry,
    ) !quark.Widget {
        var card = quark.widget.Column.init(self.allocator, .{
            .spacing = 9,
            .padding = 16,
            .alignment = .stretch,
            .background_color = quark.Theme.hex(0x1D1927),
            .border_radius = 8,
        });

        const label = if (table.index == 0)
            try std.fmt.allocPrint(self.allocator, "0 · top level", .{})
        else if (table.repeated)
            try std.fmt.allocPrint(self.allocator, "{d} · [[{s}]]", .{ table.index, table.name })
        else
            try std.fmt.allocPrint(self.allocator, "{d} · [{s}]", .{ table.index, table.name });
        defer self.allocator.free(label);

        var heading = quark.widget.Row.init(self.allocator, .{
            .spacing = 8,
            .alignment = .center,
        });
        _ = try heading.add(self.text(label, true, 0xECE9FB));
        _ = try heading.add(.{ .spacer = quark.widget.Spacer.flexible() });
        if (table.index != 0) {
            _ = try heading.add(self.button(
                "Remove table",
                try self.bindValue(table.index, removeTable),
                false,
            ));
        }
        _ = try card.add(.{ .row = heading });

        for (entries) |entry| {
            if (entry.table_index != table.index) continue;
            _ = try card.add(try self.entryRow(entry));
        }
        return .{ .column = card };
    }

    fn entryRow(self: *App, entry: config.Document.Entry) !quark.Widget {
        var editor = quark.widget.Column.init(self.allocator, .{
            .spacing = 7,
            .padding = 10,
            .alignment = .stretch,
            .background_color = quark.Theme.hex(0x252033),
            .border_radius = 6,
        });
        if (parseBool(entry.value)) |checked| {
            _ = try editor.add(.{
                .checkbox = quark.widget.CheckBox.init(.{
                    .text = try self.stable(entry.key),
                    .checked = checked,
                    .on_action = try self.bindValue(entry.index, toggleEntry),
                }),
            });
        } else {
            _ = try editor.add(self.text(entry.key, false, 0xD5D0E8));
            _ = try editor.add(try self.textField(
                entry.value,
                "TOML value",
                try self.bindValue(entry.index, changeEntry),
            ));
        }
        _ = try editor.add(self.button(
            "Delete",
            try self.bindValue(entry.index, deleteEntry),
            false,
        ));
        return .{ .column = editor };
    }

    fn text(self: *App, value: []const u8, bold: bool, color: u32) quark.Widget {
        return .{ .text = quark.widget.Text.init(self.allocator, .{
            .text = value,
            .theme = .{
                .color = quark.Theme.hex(color),
                .font_style = .{ .bold = bold },
            },
        }) };
    }

    fn textField(
        self: *App,
        initial_text: []const u8,
        placeholder: []const u8,
        handler: quark.action.Handler,
    ) !quark.Widget {
        const initial = try self.stable(initial_text);
        var field = quark.widget.TextField.init(.{
            .placeholder = placeholder,
            .text = initial,
            .on_action = handler,
        });
        field.theme.width = quark.Size.fill();
        field.theme.height = quark.Size.fixed(38);
        return .{ .textfield = field };
    }

    fn setLayout(self: *App, window: *quark.Parent) !void {
        window.setLayout(try self.view());
    }

    fn button(
        self: *App,
        label: []const u8,
        handler: quark.action.Handler,
        primary: bool,
    ) quark.Widget {
        return .{ .button = quark.widget.Button.init(.{
            .content = .{ .text = quark.widget.Text.init(self.allocator, .{
                .text = label,
            }) },
            .theme = .{
                .color = quark.Theme.hex(if (primary) 0x463699 else 0x252033),
                .focus_color = quark.Theme.hex(0x584AA3),
                .height = quark.Size.fixed(38),
            },
            .on_action = handler,
        }) };
    }

    fn stable(self: *App, value: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);
        try self.stable_strings.append(self.allocator, copy);
        return copy;
    }

    fn bindValue(
        self: *App,
        value: u64,
        comptime handler: anytype,
    ) !quark.action.Handler {
        const callback = try self.allocator.create(Callback);
        errdefer self.allocator.destroy(callback);
        callback.* = .{ .app = self, .value = value };
        try self.callbacks.append(self.allocator, callback);
        return quark.action.bind(callback, struct {
            fn invoke(context: *Callback, action: quark.Action) !void {
                try @call(.auto, handler, .{ context.app, context.value, action });
            }
        }.invoke);
    }

    fn currentFile(self: *App) *config.ConfigFiles.File {
        return &self.files.items[self.selected_file];
    }

    fn markChanged(self: *App) void {
        self.currentFile().dirty = true;
        self.status = "Unsaved changes";
    }

    fn selectFile(self: *App, raw_index: u64, action: quark.Action) !void {
        if (action != .click or raw_index >= self.files.items.len) return;
        self.selected_file = @intCast(raw_index);
        try self.clearEditor();
        self.status = "Loaded Aqueous configuration";
        self.needs_rebuild = true;
    }

    fn changeEntry(self: *App, raw_index: u64, action: quark.Action) !void {
        if (action != .change_text) return;
        try self.currentFile().document.setEntryRaw(@intCast(raw_index), action.change_text);
        self.markChanged();
    }

    fn toggleEntry(self: *App, raw_index: u64, action: quark.Action) !void {
        if (action != .toggle) return;
        try self.currentFile().document.setEntryRaw(
            @intCast(raw_index),
            if (action.toggle) "true" else "false",
        );
        self.markChanged();
    }

    fn deleteEntry(self: *App, raw_index: u64, action: quark.Action) !void {
        if (action != .click) return;
        try self.currentFile().document.deleteEntry(@intCast(raw_index));
        self.markChanged();
        self.needs_rebuild = true;
    }

    fn removeTable(self: *App, raw_index: u64, action: quark.Action) !void {
        if (action != .click) return;
        try self.currentFile().document.deleteTable(@intCast(raw_index));
        self.markChanged();
        self.needs_rebuild = true;
    }

    fn changeTarget(self: *App, action: quark.Action) !void {
        if (action == .change_text) try self.replaceEditorValue(&self.add_target, action.change_text);
    }

    fn changeKey(self: *App, action: quark.Action) !void {
        if (action == .change_text) try self.replaceEditorValue(&self.add_key, action.change_text);
    }

    fn changeValue(self: *App, action: quark.Action) !void {
        if (action == .change_text) try self.replaceEditorValue(&self.add_value, action.change_text);
    }

    fn addSetting(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        const target = std.mem.trim(u8, self.add_target, " \t\r\n");
        const key = std.mem.trim(u8, self.add_key, " \t\r\n");
        const value = std.mem.trim(u8, self.add_value, " \t\r\n");
        if (target.len == 0 or key.len == 0 or value.len == 0) {
            self.status = "Target, key, and TOML value are required";
            self.needs_rebuild = true;
            return;
        }

        const document = &self.currentFile().document;
        if (std.fmt.parseInt(usize, target, 10)) |table_index| {
            document.addToTable(table_index, key, value) catch |err| switch (err) {
                error.TableNotFound => {
                    self.status = "That table number does not exist";
                    self.needs_rebuild = true;
                    return;
                },
                else => return err,
            };
        } else |_| if (std.mem.startsWith(u8, target, "[[") and
            std.mem.endsWith(u8, target, "]]"))
        {
            document.appendTable(target, key, value) catch |err| switch (err) {
                error.InvalidTableHeader => {
                    self.status = "The repeated table header is invalid";
                    self.needs_rebuild = true;
                    return;
                },
                else => return err,
            };
        } else {
            var section = target;
            if (section.len >= 2 and section[0] == '[' and section[section.len - 1] == ']') {
                section = std.mem.trim(u8, section[1 .. section.len - 1], " \t");
            }
            try document.setRaw(section, key, value);
        }
        self.markChanged();
        try self.clearEditor();
        self.status = "Setting added; Save all to apply";
        self.needs_rebuild = true;
    }

    fn save(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        self.files.save() catch {
            self.status = "Unable to save one or more configuration files";
            self.needs_rebuild = true;
            return;
        };
        self.status = "All Aqueous configuration files saved";
        self.needs_rebuild = true;
    }

    fn reload(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        self.files.reload() catch {
            self.status = "Unable to reload configuration files";
            self.needs_rebuild = true;
            return;
        };
        try self.clearEditor();
        self.status = "Reloaded configuration from disk";
        self.needs_rebuild = true;
    }

    fn replaceEditorValue(self: *App, destination: *[]u8, value: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, value);
        self.allocator.free(destination.*);
        destination.* = replacement;
    }

    fn clearEditor(self: *App) !void {
        try self.replaceEditorValue(&self.add_target, "");
        try self.replaceEditorValue(&self.add_key, "");
        try self.replaceEditorValue(&self.add_value, "");
        self.editor_epoch = !self.editor_epoch;
    }
};

fn initializeTextFields(window: *quark.Parent) !void {
    if (window.state.root_widget) |*root| try initializeWidgetText(window, root);
}

fn initializeWidgetText(window: *quark.Parent, widget: *quark.Widget) !void {
    switch (widget.*) {
        .textfield => |*text_field| {
            const initial = text_field.text orelse return;
            for (window.state.textfields.items) |*runtime_field| {
                if (runtime_field.id != text_field.id) continue;
                runtime_field.max_length = 16 * 1024;
                try runtime_field.setText(initial);
                text_field.text = null;
                return;
            }
        },
        .column => |*column| {
            for (column.children.items) |*child| {
                try initializeWidgetText(window, &child.widget);
            }
        },
        .row => |*row| {
            for (row.children.items) |*child| {
                try initializeWidgetText(window, &child.widget);
            }
        },
        .overlay => |*overlay| {
            try initializeWidgetText(window, overlay.base);
            try initializeWidgetText(window, overlay.overlay);
        },
        .scrollview => |*scroll_view| try initializeWidgetText(window, scroll_view.child),
        .modal => |*modal| try initializeWidgetText(window, modal.child),
        else => {},
    }
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

pub fn main() !void {
    var window = try quark.Parent.init(
        "Aqueous Settings",
        "0.2.0",
        "org.aqueous.Settings",
        1100,
        760,
        .{
            .font_size = 17,
            .window_color = quark.Theme.hex(0x17141F),
        },
    );
    defer window.deinit();
    window.pre_render = initializeTextFields;

    var app = try App.init(window.allocator);
    defer app.deinit();
    try app.setLayout(&window);

    while (window.update()) |event| {
        if (event != null and app.needs_rebuild) {
            app.needs_rebuild = false;
            try app.setLayout(&window);
        }
    }
}
