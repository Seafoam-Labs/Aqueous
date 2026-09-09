const std = @import("std");
const q = @import("quark");
const draft = @import("model/draft.zig");
const j = draft.j;
const V = j.Value;
const Client = @import("services/backend_client.zig").Client;
const modes = @import("model/display_modes.zig");
const shells = @import("services/shell_adapter.zig");
const theme_model = @import("model/theme.zig");
const theme_service = @import("services/theme/service.zig");
const theme_quark = @import("services/theme/quark.zig");
const preferences = @import("services/preferences.zig");
const a = std.heap.page_allocator;
pub const pages = [_][]const u8{ "overview", "appearance", "layouts", "input", "displays", "rules", "keybinds", "advanced" };
pub const theme_choices = [_][]const u8{ "Follow shell", "DMS", "Noctalia", "Built-in" };
const presentation = @import("model/presentation.zig");
const search_model = @import("model/search.zig");
const style = @import("ui/style.zig");
const components = @import("ui/components/settings.zig");
const runtime_layout_model = @import("model/runtime_layout.zig");
const titles = [_][]const u8{ "Overview", "Appearance", "Layouts", "Input", "Displays", "Rules", "Keybinds", "Advanced" };
pub const files = [_][]const u8{ "wm", "layout", "input", "outputs", "rules", "appearance" };
pub const transforms = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };
pub const Action = enum { search_open, section_toggle, number_step, number_slide, color_open, color_channel, color_accept, color_cancel, theme_source, page, search, field, reset, raw, apply, validate, reload, cancel, discard, close, confirm_apply, shell, monitor, monitor_mode, select_monitor, rule_field, add_rule, remove_rule, move_up, move_down, select_rule, keybind, add_keybind, remove_keybind, layout_field, zone_field, select_layout, add_layout, migrate, remove_layout, add_zone, remove_zone, preset, make_default, snap_binding, flag, legacy_zone, legacy_remove, legacy_undo, legacy_binding, font_family, font_face, runtime_layout, runtime_output, runtime_apply, select_file, refresh_live, cancel_job };
pub const Binding = struct { app: *App, kind: Action, key: []const u8 = "", id: []const u8 = "", index: usize = 0, value: V = .null, options: []const []const u8 = &.{}, edited: ?[]u8 = null };
pub const App = struct {
    window: *q.Parent,
    theme: theme_model.Snapshot = .{},
    theme_choice: theme_model.Choice = .follow,
    themes: ?*theme_service.Service = null,
    prefs_path: []const u8 = "",
    role_fonts: style.Fonts = .{},
    view_state: @import("model/ui_state.zig").State = .{},
    highlight: []const u8 = "",
    reveal_id: ?u32 = null,
    search_view: bool = false,
    search_due: i64 = 0,
    rendered_search: []const u8 = "",
    last_width: f32 = 0,
    color_key: []const u8 = "",
    color_text: []const u8 = "",
    color_value: u32 = 0xff000000,
    slider_rebuild: bool = false,
    inspect_path: []const u8 = "",
    color_error: []const u8 = "",
    theme_status: []const u8 = "Built-in application theme.",
    model: draft.Model,
    client: Client,
    layout_client: Client,
    live_layout: runtime_layout_model.State = .{},
    layout_query_generation: u64 = 0,
    next_layout_query: i64 = 0,
    ui: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(a),
    bindings: std.ArrayList(*Binding) = .empty,
    shell: []const u8,
    backup: []const u8,
    page: usize = 0,
    selected_monitor: usize = 0,
    selected_rule: usize = 0,
    selected_layout: usize = 0,
    selected_file: usize = 0,
    rendered_page: usize = 0,
    search: []const u8 = "",
    status: []const u8 = "Loading configuration…",
    shell_status: []const u8 = "",
    confirm: enum { none, reload, close } = .none,
    close_after_apply: bool = false,
    uncertain: bool = false,
    rebuilt: bool = true,
    quitting: bool = false,
    runtime_output: []const u8 = "",
    monitor_rows: V = .null,
    drag_index: ?usize = null,
    drag_x: f32 = 0,
    drag_y: f32 = 0,
    drag_origin_x: f64 = 0,
    drag_origin_y: f64 = 0,
    canvas_scale: f32 = 1,
    canvas_min_x: f32 = 0,
    canvas_min_y: f32 = 0,
    was_down: bool = false,
    pub fn init(window: *q.Parent, io: std.Io, shell: []const u8, backup: []const u8, page: usize) App {
        return .{ .window = window, .model = draft.Model.init(a), .client = Client.init(io), .layout_client = Client.init(io), .shell = shell, .backup = backup, .page = page };
    }
    pub fn deinit(self: *App) void {
        self.role_fonts.deinit();
        self.view_state.deinit(a);
        self.client.deinit();
        self.layout_client.deinit();
        for (self.bindings.items) |b| {
            if (b.edited) |text| a.free(text);
        }
        self.bindings.deinit(a);
        self.ui.deinit();
        self.model.deinit();
    }
    pub fn own(self: *App, s: []const u8) ![]const u8 {
        return try self.model.allocator().dupe(u8, s);
    }
    pub fn label(self: *App, s: []const u8, bold: bool) q.Widget {
        _ = self;
        return components.label(s, bold);
    }
    pub fn column(self: *App) q.widget.Column {
        _ = self;
        return components.column();
    }
    pub fn newRow(self: *App) q.widget.Row {
        _ = self;
        return components.row();
    }
    pub fn bind(self: *App, data: Binding) !q.action.Handler {
        const b = try self.ui.allocator().create(Binding);
        b.* = data;
        try self.bindings.append(a, b);
        return q.action.bind(b, dispatch);
    }
    pub fn button(self: *App, text: []const u8, kind: Action, key: []const u8, index: usize) !q.Widget {
        var result: q.Widget = .{ .button = q.widget.Button.init(.{ .content = .{ .text = self.label(text, false).text }, .on_action = try self.bind(.{ .app = self, .kind = kind, .key = key, .index = index }), .theme = .{ .height = q.Size.fixed(@max(36, self.theme.font.pixels + 20)) } }) };
        result.button.id = presentation.stableId(@tagName(kind), key, "", index);
        return result;
    }
    pub fn textfield(self: *App, value: []const u8, b: Binding, tall: bool) !q.Widget {
        const key = try self.inputKey(b);
        const edited = if (j.get(self.model.inputs, key) != .null) j.text(self.model.inputs, key) else value;
        var result: q.Widget = .{ .textfield = q.widget.TextField.init(.{ .placeholder = b.key, .text = edited, .on_action = try self.bind(b), .theme = .{ .height = q.Size.fixed(if (tall) @max(120, @min(380, self.window.height() - 260)) else @max(36, self.theme.font.pixels + 20)) } }) };
        result.textfield.id = presentation.stableId(@tagName(b.kind), b.key, b.id, b.index);
        return result;
    }
    pub fn inputKey(self: *App, b: Binding) ![]const u8 {
        return try std.fmt.allocPrint(self.ui.allocator(), "{s}/{s}/{s}/{d}", .{ @tagName(b.kind), b.id, b.key, b.index });
    }
    pub fn dropdown(self: *App, choices: []const []const u8, current: []const u8, b: Binding) !q.Widget {
        var binding = b;
        binding.options = choices;
        var selected: ?u32 = null;
        for (choices, 0..) |s, i| if (std.mem.eql(u8, s, current)) {
            selected = @intCast(i);
            break;
        };
        var result: q.Widget = .{ .dropdown = q.widget.Dropdown.init(.{ .items = choices, .selected_index = selected, .placeholder = current, .on_action = try self.bind(binding), .theme = .{ .height = q.Size.fixed(@max(36, self.theme.font.pixels + 20)) } }) };
        result.dropdown.id = presentation.stableId(@tagName(b.kind), b.key, b.id, b.index);
        return result;
    }
    pub fn actionRow(self: *App, row: q.widget.Row) !q.Widget {
        if (!style.stacked(self.window.width(), self.theme.font.pixels)) return .{ .row = row };
        var stacked = self.column();
        var owned = row;
        for (owned.children.items) |child| _ = try stacked.add(child.widget);
        owned.children.deinit(a);
        return .{ .column = stacked };
    }
    pub fn scalar(self: *App, col: *q.widget.Column, name: []const u8, value: V, kind: []const u8, b: Binding) !void {
        var field = if (std.mem.eql(u8, kind, "boolean")) q.Widget{ .checkbox = q.widget.CheckBox.init(.{ .text = "", .checked = j.boolean(value), .on_action = try self.bind(b) }) } else try self.textfield(try self.display(value), b, false);
        if (field == .checkbox) field.checkbox.id = presentation.stableId(@tagName(b.kind), b.key, b.id, b.index);
        if (style.stacked(self.window.width(), self.theme.font.pixels)) {
            _ = try col.add(self.label(name, false));
            _ = try col.add(field);
        } else {
            var row = self.newRow();
            _ = try row.addWithWidthConstraint(self.label(name, false), q.Size.proportional(1));
            _ = try row.addWithWidthConstraint(field, q.Size.proportional(1));
            _ = try col.add(.{ .row = row });
        }
    }

    pub fn display(self: *App, v: V) ![]const u8 {
        return if (v == .string) v.string else if (v == .null) "" else try j.encode(self.ui.allocator(), v);
    }
    pub fn load(self: *App) !void {
        try self.backendOp("snapshot", "");
    }
    pub fn savePreferences(self: *App) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try preferences.save(arena.allocator(), self.client.io, self.prefs_path, .{ .page = self.page, .width = @intFromFloat(self.window.width()), .height = @intFromFloat(self.window.height()), .theme_source = self.theme_choice });
    }
    pub fn selectTheme(self: *App) !void {
        const service = self.themes orelse return;
        const source = theme_model.resolve(self.theme_choice, self.shell);
        if (source == service.source) return;
        service.select(source);
        try self.applyTheme(.{}, @splat(null), true);
        self.setThemeStatus(if (source == .builtin) "Built-in application theme." else "Loading application theme…");
    }
    pub fn applyTheme(self: *App, snapshot: theme_model.Snapshot, fonts: [4]?[]const u8, fonts_changed: bool) !void {
        if (fonts_changed or self.role_fonts.title == null) {
            var replacement = try style.Fonts.prepare(fonts, snapshot.font.pixels);
            errdefer replacement.deinit();
            if (fonts_changed) try self.window.setFonts(fonts, snapshot.font.pixels);
            self.role_fonts.deinit();
            self.role_fonts = replacement;
        }
        if (style.compact(self.window.width(), self.theme.font.pixels) != style.compact(self.window.width(), snapshot.font.pixels) or style.stacked(self.window.width(), self.theme.font.pixels) != style.stacked(self.window.width(), snapshot.font.pixels)) self.rebuilt = true;
        self.theme = snapshot;
        self.window.state.window_color = q.Theme.hex(snapshot.palette.background);
        self.window.setTheme(theme_quark.resolve(snapshot));
        if (self.window.state.root_widget) |*root| theme_quark.restyle(root, snapshot, self.window.height());
    }
    pub fn tickTheme(self: *App) !void {
        const service = self.themes orelse return;
        // Delay layout/font changes while a pointer operation is active.
        if (self.window.state.mouse_down or self.window.state.scroll_dragging or self.drag_index != null) return;
        for (self.window.state.dropdowns.items) |chooser| if (chooser.is_open) return;
        try self.selectTheme();
        if (!try service.poll()) return;
        const result = &service.result;
        if (result.valid) {
            self.applyTheme(result.snapshot, result.fonts, result.fonts_changed) catch {
                self.applyTheme(result.snapshot, @splat(null), true) catch {
                    self.setThemeStatus("Theme font could not load; keeping the previous appearance.");
                    return;
                };
                self.setThemeStatus("Shell colors loaded; using the bundled fallback font.");
                return;
            };
        }
        self.setThemeStatus(switch (result.status) {
            .builtin => "Built-in application theme.",
            .loading => "Loading application theme…",
            .applied => if (service.source == .dms) "Following DMS application theme." else "Following Noctalia application theme.",
            .font_fallback => "Shell colors loaded; using a fallback font.",
            .missing => "Theme export missing. Enable the Aqueous Settings template in your shell (see README).",
            .invalid => "Theme update is invalid; keeping the last valid appearance.",
        });
    }
    pub fn setThemeStatus(self: *App, status: []const u8) void {
        if (std.mem.eql(u8, self.theme_status, status)) return;
        if (self.window.state.root_widget) |*root| theme_quark.replaceText(root, self.theme_status, status);
        self.theme_status = status;
        self.window.state.layout_dirty = true;
    }
    pub fn backendOp(self: *App, op: []const u8, request: []const u8) !void {
        if (self.client.busy()) return error.Busy;
        try self.client.startBackend(op, self.shell, request);
        self.status = if (std.mem.eql(u8, op, "apply")) "Saving configuration…" else if (std.mem.eql(u8, op, "validate")) "Validating drafts…" else "Loading configuration…";
        self.rebuilt = true;
    }
    pub fn tick(self: *App) !void {
        if (self.slider_rebuild and !self.window.state.mouse_down) {
            self.slider_rebuild = false;
            self.rebuilt = true;
        }
        if (self.last_width != self.window.width()) {
            self.last_width = self.window.width();
            self.rebuilt = true;
        }
        if (self.search_due != 0 and std.Io.Clock.awake.now(self.client.io).toMilliseconds() >= self.search_due) {
            self.search_due = 0;
            self.rendered_search = try self.own(self.search);
            self.rebuilt = true;
        }
        if (self.window.state.search_requested) {
            self.window.state.search_requested = false;
            self.reveal_id = presentation.stableId("search", "Search settings", "", 0);
        }
        if (self.window.state.escape_requested) {
            self.window.state.escape_requested = false;
            if (self.color_key.len > 0) self.color_key = "" else {
                self.search = "";
                self.rendered_search = "";
                self.search_due = 0;
            }
            self.rebuilt = true;
        }
        try self.reveal();
        try self.tickTheme();
        try self.tickLayout();
        if (self.client.poll()) {
            var completed = self.client.result;
            self.client.result = .{};
            defer completed.deinit();
            const op = self.client.operation;
            const result = &completed;
            if (std.mem.eql(u8, op, "runtime")) {
                self.status = if (result.status == 0 and result.exit_code == 0) "Live workspace layout changed." else "Live action failed; configuration drafts are unchanged.";
                self.live_layout.reset();
                self.next_layout_query = 0;
            } else if (std.mem.eql(u8, op, "dms-sync")) {
                self.shell_status = try self.own(if (result.status == 0 and result.exit_code == 0) result.stdout() else "DMS typography synchronization failed. Retry from Appearance.");
            } else if (result.status != 0 or result.stdout().len == 0) {
                self.uncertain = self.uncertain or result.uncertain;
                self.status = if (self.uncertain) "Apply outcome is uncertain. Inspect saved state before retrying; drafts retained." else if (result.status == 2) "Configuration operation timed out. Drafts retained." else "Unable to complete configuration operation. Drafts retained.";
                self.close_after_apply = false;
            } else {
                var parsed_arena = std.heap.ArenaAllocator.init(a);
                defer parsed_arena.deinit();
                const response = j.parse(parsed_arena.allocator(), result.stdout()) catch .null;
                const compatibility_error: ?anyerror = blk: {
                    draft.compatible(response, self.shell) catch |err| break :blk err;
                    break :blk null;
                };
                if (response == .null or !j.boolean(j.get(response, "ok")) or result.exit_code != 0) {
                    self.status = try self.own(if (response == .null) "Invalid configuration response. Drafts retained." else j.text(response, "message"));
                    if (std.mem.eql(u8, op, "apply")) self.uncertain = result.uncertain;
                    self.close_after_apply = false;
                } else if (compatibility_error) |err| {
                    self.status = try self.own(try std.fmt.allocPrint(parsed_arena.allocator(), "Invalid backend result: {s}. Drafts retained.", .{@errorName(err)}));
                    if (std.mem.eql(u8, op, "apply")) self.uncertain = true;
                    self.close_after_apply = false;
                } else if (std.mem.eql(u8, op, "refresh-live")) {
                    try j.put(self.model.allocator(), &self.model.snapshot, "live_outputs", try j.clone(self.model.allocator(), j.get(response, "live_outputs")));
                    self.status = "Connected displays refreshed. Existing drafts and their base generation are retained.";
                } else if (std.mem.eql(u8, op, "validate")) {
                    self.status = "Validation passed. Drafts retained; no files written.";
                } else if (std.mem.eql(u8, op, "inspect")) {
                    // Do not replace the draft's base generation during recovery.
                    self.status = try self.own(try std.fmt.allocPrint(parsed_arena.allocator(), "Saved generation: {s}; draft base: {s}. Review saved files below, then explicitly reload/discard to reconcile.", .{ j.text(response, "generation"), j.text(self.model.snapshot, "generation") }));
                    // Keep a separate read-only saved snapshot for the recovery view.
                    try j.put(self.model.allocator(), &self.model.snapshot, "recovery", try j.clone(self.model.allocator(), response));
                } else {
                    self.model.accept(result.stdout(), self.shell) catch |err| {
                        if (std.mem.eql(u8, op, "apply")) self.uncertain = true;
                        self.close_after_apply = false;
                        self.status = @errorName(err);
                        self.rebuilt = true;
                        return;
                    };
                    self.search = "";
                    self.runtime_output = "";
                    self.live_layout.reset();
                    self.next_layout_query = 0;
                    self.shell_status = "";
                    self.uncertain = false;
                    const applied = std.mem.eql(u8, op, "apply");
                    self.status = if (applied) "Saved. Aqueous reloaded the configuration." else "Configuration loaded. Edits remain drafts until Apply.";
                    const typography = j.get(self.model.snapshot, "desktop_typography");
                    if (j.number(j.get(typography, "failed_count")) > 0 or j.number(j.get(j.get(self.model.snapshot, "desktop_cursor"), "failed_count")) > 0) {
                        self.status = "Configuration saved/loaded; some appearance targets need attention.";
                        self.close_after_apply = false;
                    }
                    if (applied and result.reload != .applied) {
                        self.status = "Saved; compositor reload was not confirmed. Check aqueousctl session reload --json; Apply retries reload.";
                        self.close_after_apply = false;
                    }
                    if (applied and std.mem.eql(u8, self.shell, "dms") and j.boolean(j.get(typography, "applied"))) {
                        self.close_after_apply = false;
                        try self.client.start("dms-sync", &.{ "/proc/self/exe", "--sync-dms", try j.encode(parsed_arena.allocator(), typography) }, "");
                    }
                    if (applied and self.close_after_apply) self.quitting = true;
                }
            }
            self.rebuilt = true;
        }
        if (!self.client.busy() and self.confirm == .none and self.page == 4) try self.canvasInteraction();
        if (self.rebuilt) {
            try self.build();
            self.rebuilt = false;
        }
    }
    pub fn closeRequested(self: *App) void {
        if (self.client.busy() or self.model.count() > 0 or self.model.errors.object.count() > 0) {
            self.confirm = .close;
            self.rebuilt = true;
        } else self.quitting = true;
    }
    pub fn tickLayout(self: *App) !void {
        // Do not dismiss an open chooser or disrupt pointer/scroll interaction.
        if (self.confirm != .none or self.window.state.mouse_down or self.window.state.scroll_dragging) return;
        for (self.window.state.dropdowns.items) |chooser| if (chooser.is_open) return;
        if (self.layout_client.poll()) {
            defer self.layout_client.result.deinit();
            if (self.layout_query_generation == self.live_layout.generation) {
                const before = self.live_layout;
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const result = &self.layout_client.result;
                const response = if (result.status == 0 and result.exit_code == 0) j.parse(arena.allocator(), result.stdout()) catch .null else .null;
                self.live_layout.accept(response, self.runtime_output, self.layout_query_generation) catch {
                    self.live_layout.failed = true;
                };
                if (self.page == 0 and !std.meta.eql(before, self.live_layout)) self.rebuilt = true;
            }
        }
        const now = std.Io.Clock.awake.now(self.client.io).toMilliseconds();
        if (self.page != 0 or self.confirm != .none or self.client.busy() or self.layout_client.busy() or self.runtime_output.len == 0 or now < self.next_layout_query) return;
        self.next_layout_query = now + 1000;
        self.layout_query_generation = self.live_layout.generation;
        try self.layout_client.start("layout-query", &.{ "aqueousctl", "layout", "--output", self.runtime_output, "--json" }, "");
    }
    pub fn build(self: *App) !void {
        // Keep old callback memory alive until Quark releases the previous tree.
        for (self.window.state.scrollviews.items) |sv| if (sv.id == 200 and !self.search_view) {
            self.view_state.scroll[self.rendered_page] = sv.scroll_y;
        };
        self.rendered_page = self.page;
        self.search_view = self.rendered_search.len > 0;
        const previous_bindings = self.bindings;
        self.bindings = .empty;
        var previous = self.ui;
        self.ui = std.heap.ArenaAllocator.init(a);
        defer {
            for (previous_bindings.items) |b| {
                if (b.edited) |text| a.free(text);
            }
            var old = previous_bindings;
            old.deinit(a);
            previous.deinit();
        }
        var root = self.column();
        root.padding = if (self.window.height() < 600) 12 else 18;
        root.spacing = 12;
        var header = self.newRow();
        _ = try header.add(self.richLabel(if (style.compact(self.window.width(), self.theme.font.pixels)) "Settings" else "Aqueous Settings", .title));
        _ = try header.add(.{ .spacer = q.widget.Spacer.flexible() });
        _ = try header.addWithWidthConstraint(try self.dropdown(&.{ "none", "dms", "noctalia" }, self.shell, .{ .app = self, .kind = .shell }), q.Size.fixed(150));
        _ = try header.add(try self.button("Close", .close, "", 0));
        _ = try root.add(.{ .row = header });
        const compact = style.compact(self.window.width(), self.theme.font.pixels);
        var body = self.newRow();
        body.alignment = .start;
        body.spacing = 20;
        if (!compact) {
            var sidebar = self.column();
            sidebar.padding = 12;
            sidebar.tone = 2;
            sidebar.background_color = q.Theme.hex(self.theme.palette.surface_container_high);
            sidebar.border_radius = 12;
            _ = try sidebar.add(try self.textfield(self.search, .{ .app = self, .kind = .search, .key = "Search settings" }, false));
            _ = try sidebar.add(self.richLabel("SETTINGS", .muted));
            for (titles, 0..) |title, i| {
                var navrow = self.newRow();
                navrow.spacing = 0;
                _ = try navrow.addWithWidthConstraint(.{ .canvas = q.widget.Canvas.init(.{ .id = @intCast(9000 + i), .theme = .{ .height = q.Size.fixed(28), .color = q.Theme.hex(self.theme.palette.surface_container_high), .border = .{ .size = q.Size.fixed(0) } } }) }, q.Size.fixed(28));
                var item = try self.button(title, .page, "", i);
                item.button.tone = if (self.page == i) 5 else 2;
                item.button.theme.text_alignment = .left;
                _ = try navrow.addWithWidthConstraint(item, q.Size.proportional(1));
                _ = try sidebar.add(.{ .row = navrow });
            }
            var navscroll = try q.widget.ScrollView.initOwned(.{ .column = sidebar }, a);
            navscroll.id = 201;
            _ = try body.addWithWidthConstraint(.{ .scrollview = navscroll }, q.Size.fixed(@max(220, self.theme.font.pixels * 12)));
        }
        var content = self.column();
        content.padding = if (compact) 4 else 12;
        if (compact) {
            var top = self.newRow();
            _ = try top.addWithWidthConstraint(try self.dropdown(&titles, titles[self.page], .{ .app = self, .kind = .page }), q.Size.proportional(1));
            _ = try top.addWithWidthConstraint(try self.textfield(self.search, .{ .app = self, .kind = .search, .key = "Search settings" }, false), q.Size.proportional(1));
            _ = try content.add(.{ .row = top });
        }
        _ = try content.add(self.richLabel(if (self.rendered_search.len > 0) "Search settings" else titles[self.page], .title));
        const descriptions = [_][]const u8{ "Live workspace controls and session information.", "Personalize your desktop and this application's appearance.", "Configure saved layouts, window borders, and snap zones.", "Adjust your keyboard, pointer, and touchpad.", "Arrange monitors and configure saved display settings.", "Match windows and customize their placement and appearance.", "Manage keyboard shortcuts and application commands.", "Edit configuration files and inspect validation or recovery details." };
        _ = try content.add(self.richLabel(if (self.rendered_search.len > 0) "Search across pages, descriptions, and setting names." else descriptions[self.page], .muted));
        if (self.model.snapshot != .null) {
            if (self.rendered_search.len > 0) {
                const results = try search_model.find(self.ui.allocator(), j.get(self.model.snapshot, "fields"), self.rendered_search);
                if (results.len == 0) _ = try content.add(self.richLabel("No matching settings.", .muted));
                for (results) |result| {
                    var card = components.card(self.theme.palette, self.theme.radius);
                    card.tone = 1;
                    _ = try card.add(try self.button(result.label, .search_open, result.id, result.page));
                    _ = try card.add(self.richLabel(try std.fmt.allocPrint(self.ui.allocator(), "{s} / {s}", .{ titles[result.page], result.section }), .muted));
                    _ = try content.add(.{ .column = card });
                }
            } else {
                if (self.page == 1) try self.appearance(&content);
                if (self.page > 0 and self.page < 4) try self.schema(&content);
                if (self.page != 1 and self.page != 3) {
                    const section_titles = [_][]const u8{ "Session and workspace", "", "Snap layouts and legacy zones", "", "Monitor arrangement", "Window rules", "Custom shortcuts", "Raw configuration" };
                    var card = components.card(self.theme.palette, self.theme.radius);
                    card.tone = 1;
                    _ = try card.add(self.label(section_titles[self.page], true));
                    switch (self.page) {
                        0 => try self.overview(&card),
                        2 => try self.layoutsPage(&card),
                        4 => try self.displays(&card),
                        5 => try self.rules(&card),
                        6 => try self.keybinds(&card),
                        7 => try self.advanced(&card),
                        else => {},
                    }
                    _ = try content.add(.{ .column = card });
                }
                if (self.page >= 4 and self.page < 7) try self.schema(&content);
            }
        }
        var scroll = try q.widget.ScrollView.initOwned(.{ .column = content }, a);
        scroll.id = 200;
        scroll.scroll_y = if (self.rendered_search.len > 0) 0 else self.view_state.scroll[self.page];
        _ = try body.addWithWidthConstraint(.{ .scrollview = scroll }, q.Size.proportional(1));
        _ = try root.addWithHeightConstraint(.{ .row = body }, q.Size.proportional(1));
        _ = try root.add(self.richLabel(self.status, .muted));
        var footer = self.newRow();
        _ = try footer.add(self.label(try std.fmt.allocPrint(self.ui.allocator(), "{d} pending", .{self.model.count()}), false));
        _ = try footer.add(.{ .spacer = q.widget.Spacer.flexible() });
        _ = try footer.add(try self.button(if (self.uncertain) "Inspect saved state" else if (compact) "Discard" else "Discard / Reload", .reload, "", 0));
        _ = try footer.add(try self.button("Validate", .validate, "", 0));
        var apply_button = try self.button(if (self.client.busy()) "Cancel" else "Apply", if (self.client.busy()) .cancel_job else .apply, "", 0);
        apply_button.button.tone = 5;
        _ = try footer.add(apply_button);
        _ = try root.add(.{ .row = footer });
        if (self.confirm != .none) {
            var dialog = self.column();
            dialog.padding = 24;
            dialog.background_color = q.Theme.hex(self.theme.palette.surface_container_high);
            _ = try dialog.add(self.label(if (self.client.busy()) "An operation is running. Wait for completion before closing." else "There are unsaved edits. Apply, discard, or keep editing.", true));
            var buttons = self.newRow();
            _ = try buttons.add(try self.button("Cancel", .cancel, "", 0));
            if (!self.client.busy()) {
                _ = try buttons.add(try self.button("Discard", .discard, "", 0));
                _ = try buttons.add(try self.button("Apply", .confirm_apply, "", 0));
            }
            _ = try dialog.add(.{ .row = buttons });
            var modal_scroll = try q.widget.ScrollView.initOwned(.{ .column = dialog }, a);
            modal_scroll.id = 202;
            modal_scroll.shrink = true;
            _ = try root.add(.{ .modal = try q.widget.Modal.initOwned(.{ .scrollview = modal_scroll }, true, a) });
        }
        if (self.color_key.len > 0 and self.confirm == .none) {
            var dialog = components.card(self.theme.palette, self.theme.radius);
            dialog.tone = 4;
            _ = try dialog.add(self.richLabel("Choose color", .title));
            _ = try dialog.add(self.richLabel("Preview changes here, then choose Use color to stage them.", .muted));
            _ = try dialog.add(.{ .canvas = q.widget.Canvas.init(.{ .id = 8999, .theme = .{ .height = q.Size.fixed(40) } }) });
            _ = try dialog.add(try self.textfield(self.color_text, .{ .app = self, .kind = .color_channel, .key = "hex" }, false));
            for ([_][]const u8{ "Blue", "Green", "Red", "Alpha" }, 0..) |name, i| {
                var row = self.newRow();
                _ = try row.add(self.label(name, false));
                _ = try row.addWithWidthConstraint(.{ .slider = q.widget.Slider.init(.{ .id = presentation.stableId("color_channel", "", "", i), .min_value = 0, .max_value = 255, .initial_value = @floatFromInt((self.color_value >> @as(u5, @intCast(i * 8))) & 255), .theme = .{ .height = q.Size.fixed(24) }, .on_action = try self.bind(.{ .app = self, .kind = .color_channel, .index = i }) }) }, q.Size.proportional(1));
                _ = try dialog.add(.{ .row = row });
            }
            _ = try dialog.add(self.richLabel(if (self.color_error.len > 0) self.color_error else " ", .error_text));
            var actions = self.newRow();
            _ = try actions.add(try self.button("Cancel", .color_cancel, "", 0));
            _ = try actions.add(try self.button("Use color", .color_accept, "", 0));
            _ = try dialog.add(.{ .row = actions });
            var modal_scroll = try q.widget.ScrollView.initOwned(.{ .column = dialog }, a);
            modal_scroll.id = 202;
            modal_scroll.shrink = true;
            _ = try root.add(.{ .modal = try q.widget.Modal.initOwned(.{ .scrollview = modal_scroll }, true, a) });
        }
        self.window.setLayout(.{ .column = root });
        if (self.reveal_id == null) {
            if (self.window.state.focused_textfield_id) |id| {
                if (self.window.state.root_widget) |*widget| {
                    if (@import("ui/components/tree.zig").find(widget, id) != null) self.reveal_id = id;
                }
            }
        }
        if (self.window.state.root_widget) |*widget| theme_quark.restyle(widget, self.theme, self.window.height());
    }
    pub fn openSearch(self: *App, id: []const u8, page: usize) !void {
        self.page = page;
        self.search = "";
        self.rendered_search = "";
        self.search_due = 0;
        self.highlight = try self.own(id);
        self.view_state.open(presentation.section(id));
        self.reveal_id = if (std.mem.eql(u8, id, "desktop.font.family")) presentation.stableId("font_family", "", "", 0) else if (std.mem.eql(u8, id, "desktop.font.style")) presentation.stableId("font_face", "", "", 0) else if (id.len > 0 and id[0] != '@') presentation.stableId("field", id, id, 0) else null;
        if (std.mem.eql(u8, id, "@layouts")) self.reveal_id = presentation.stableId("add_layout", "", "", 0);
        if (self.reveal_id == null) self.view_state.scroll[page] = 0;
        self.rebuilt = true;
    }
    pub fn reveal(self: *App) !void {
        const id = self.reveal_id orelse return;
        if (self.rebuilt) return;
        const tree = @import("ui/components/tree.zig");
        if (self.window.state.root_widget) |*root| {
            if (tree.find(root, id)) |node| {
                var bounds = tree.bounds(node);
                if (node.* == .checkbox) {
                    bounds.width = 44;
                    bounds.height = 24;
                }
                if (bounds.height <= 0) return;
                for (self.window.state.scrollviews.items) |sv| if (sv.id == (if (self.color_key.len > 0 or self.confirm != .none) @as(u32, 202) else 200) and (id != presentation.stableId("search", "Search settings", "", 0) or style.compact(self.window.width(), self.theme.font.pixels))) {
                    if (bounds.y < sv.layout.y or bounds.y + bounds.height > sv.layout.y + sv.layout.height) {
                        sv.scroll_y = std.math.clamp(sv.scroll_y + bounds.y - sv.layout.y - 24, 0, @max(0, sv.child_layout.height - sv.layout.height));
                        self.window.state.layout_dirty = true;
                        return;
                    }
                };
                self.window.state.keyboard_focus_id = id;
                self.window.state.focused_textfield_id = null;
                for (self.window.state.textfields.items) |*tf| {
                    tf.focused = tf.id == id;
                    if (tf.focused) self.window.state.focused_textfield_id = id;
                }
                self.reveal_id = null;
            }
        }
    }
    pub fn inspect(self: *App) !void {
        if (self.inspect_path.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var output: std.Io.Writer.Allocating = .init(arena.allocator());
        var json: std.json.Stringify = .{ .writer = &output.writer };
        try json.beginObject();
        try json.objectField("page");
        try json.write(pages[self.page]);
        try json.objectField("focus");
        try json.write(self.window.state.focused_textfield_id orelse self.window.state.keyboard_focus_id);
        try json.objectField("pending");
        try json.write(self.model.count());
        try json.objectField("width");
        try json.write(self.window.width());
        try json.objectField("height");
        try json.write(self.window.height());
        try json.objectField("viewport");
        if (self.window.state.root_widget) |*root| {
            if (@import("ui/components/tree.zig").find(root, 200)) |node| {
                const bounds = @import("ui/components/tree.zig").bounds(node);
                try json.write(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height });
            } else try json.write(null);
        } else try json.write(null);
        try json.objectField("controls");
        try json.beginArray();
        const tree = @import("ui/components/tree.zig");
        if (self.window.state.root_widget) |*root| for (self.bindings.items) |binding| {
            const id = presentation.stableId(@tagName(binding.kind), binding.key, binding.id, binding.index);
            if (tree.find(root, id)) |node| {
                var bounds = tree.bounds(node);
                if (node.* == .checkbox) {
                    bounds.width = 44;
                    bounds.height = 24;
                }
                const selected: []const u8 = if (node.* == .dropdown and node.dropdown.selected_index != null and node.dropdown.selected_index.? < node.dropdown.items.len) node.dropdown.items[node.dropdown.selected_index.?] else "";
                var text: []const u8 = "";
                for (self.window.state.textfields.items) |tf| if (tf.id == id) {
                    text = tf.text.items;
                    break;
                };
                try json.write(.{ .id = id, .action = @tagName(binding.kind), .key = binding.key, .item = binding.id, .index = binding.index, .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height, .selected = selected, .text = text, .checked = if (node.* == .checkbox) @as(?bool, node.checkbox.initial_checked) else null });
            }
        };
        try json.endArray();
        try json.endObject();
        const tmp = try std.fmt.allocPrint(arena.allocator(), "{s}.tmp", .{self.inspect_path});
        try std.Io.Dir.cwd().writeFile(self.client.io, .{ .sub_path = tmp, .data = output.written() });
        try std.Io.Dir.renameAbsolute(tmp, self.inspect_path, self.client.io);
    }
    pub fn richLabel(self: *App, text: []const u8, role: style.Role) q.Widget {
        var result = self.label(text, role == .title);
        result.text.tone = @intFromEnum(role);
        if (role == .title) {
            if (self.role_fonts.title) |*font| result.text.font = font;
        }
        if (role == .muted) {
            if (self.role_fonts.description) |*font| result.text.font = font;
        }
        return result;
    }
    pub fn schema(self: *App, col: *q.widget.Column) !void {
        for (presentation.sections) |section| if (section.page == self.page) try self.schemaSection(col, section.id, section.title);
        try self.schemaSection(col, "other", "Other settings");
    }
    pub fn schemaSection(self: *App, col: *q.widget.Column, id: []const u8, title: []const u8) !void {
        var count: usize = 0;
        var has_error = false;
        for (j.items(j.get(self.model.snapshot, "fields"))) |f| {
            if (!std.mem.eql(u8, j.text(f, "category"), pages[self.page]) or !std.mem.eql(u8, presentation.section(j.text(f, "id")), id) or presentation.special(j.text(f, "id"))) continue;
            count += 1;
            if (j.get(self.model.errors, try self.inputKey(.{ .app = self, .kind = .field, .id = j.text(f, "id"), .key = j.text(f, "id") })) != .null) has_error = true;
        }
        if (count == 0) return;
        var card = components.card(self.theme.palette, self.theme.radius);
        card.tone = 1;
        const collapsed = (self.view_state.collapsed.get(id) orelse false) and !has_error;
        var heading = try self.button(try std.fmt.allocPrint(self.ui.allocator(), "{s}  {s}", .{ if (collapsed) "+" else "−", title }), .section_toggle, id, 0);
        heading.button.theme.text_alignment = .left;
        _ = try card.add(heading);
        if (!collapsed) for (j.items(j.get(self.model.snapshot, "fields"))) |f| {
            const field_id = j.text(f, "id");
            if (!std.mem.eql(u8, j.text(f, "category"), pages[self.page]) or !std.mem.eql(u8, presentation.section(field_id), id) or presentation.special(field_id)) continue;
            try self.fieldRow(&card, f);
        };
        _ = try col.add(.{ .column = card });
    }
    pub fn fieldRow(self: *App, col: *q.widget.Column, f: V) !void {
        const id = j.text(f, "id");
        const kind = j.text(f, "type");
        const v = self.model.getValue(id);
        const binding = Binding{ .app = self, .kind = .field, .id = id, .key = id };
        var block = self.column();
        block.spacing = 8;
        if (std.mem.eql(u8, self.highlight, id)) {
            block.padding = 12;
            block.tone = 5;
            block.background_color = q.Theme.hex(self.theme.palette.primary_container);
            block.border_radius = 8;
        }
        var description = self.column();
        description.spacing = 4;
        _ = try description.add(self.label(j.text(f, "label"), true));
        if (j.text(f, "description").len > 0) _ = try description.add(self.richLabel(j.text(f, "description"), .muted));
        var controls = self.newRow();
        controls.spacing = 8;
        const opts = j.items(j.get(f, "options"));
        var control: q.Widget = undefined;
        if (opts.len > 0) {
            const choices = try self.ui.allocator().alloc([]const u8, opts.len);
            for (opts, 0..) |item, i| choices[i] = j.str(item);
            control = try self.dropdown(choices, j.str(v), binding);
        } else if (std.mem.eql(u8, kind, "boolean")) {
            control = .{ .checkbox = q.widget.CheckBox.init(.{ .text = "", .checked = j.boolean(v), .on_action = try self.bind(binding) }) };
            control.checkbox.id = presentation.stableId("field", id, id, 0);
        } else {
            var display_value = try self.display(v);
            if (presentation.percent(id)) display_value = try std.fmt.allocPrint(self.ui.allocator(), "{d}", .{presentation.toDisplay(id, j.number(v))});
            if (std.mem.eql(u8, kind, "string_list")) {
                const chords = try self.ui.allocator().alloc([]const u8, j.items(v).len);
                for (j.items(v), 0..) |chord, i| chords[i] = j.str(chord);
                display_value = try std.mem.join(self.ui.allocator(), ", ", chords);
            }
            control = try self.textfield(display_value, binding, false);
        }
        _ = try controls.addWithWidthConstraint(control, q.Size.proportional(1));
        if (std.mem.eql(u8, kind, "integer") or std.mem.eql(u8, kind, "double")) {
            if (presentation.percent(id)) _ = try controls.add(self.richLabel("%", .muted));
            _ = try controls.add(try self.button("−", .number_step, id, 0));
            _ = try controls.add(try self.button("+", .number_step, id, 1));
        }
        if (std.mem.eql(u8, kind, "color")) {
            var swatch = try self.button("Color…", .color_open, id, 0);
            if (presentation.parseColor(j.str(v))) |color| {
                swatch.button.theme.color = q.Theme.hex(color & 0xffffff);
                swatch.button.theme.text_color = q.Theme.hex(if ((color >> 16 & 255) + (color >> 8 & 255) + (color & 255) > 384) 0 else 0xffffff);
            } else |_| {}
            _ = try controls.add(swatch);
        }
        _ = try controls.add(try self.button("Reset", .reset, id, 0));
        if (style.stacked(self.window.width(), self.theme.font.pixels)) {
            _ = try block.add(.{ .column = description });
            _ = try block.add(.{ .row = controls });
        } else {
            var row = self.newRow();
            row.alignment = .start;
            _ = try row.addWithWidthConstraint(.{ .column = description }, q.Size.proportional(1));
            _ = try row.addWithWidthConstraint(.{ .row = controls }, q.Size.proportional(1));
            _ = try block.add(.{ .row = row });
        }
        if ((std.mem.eql(u8, kind, "integer") or std.mem.eql(u8, kind, "double")) and j.get(f, "min") != .null and j.get(f, "max") != .null and j.number(j.get(f, "max")) - j.number(j.get(f, "min")) <= 512) {
            var slider = q.widget.Slider.init(.{ .id = presentation.stableId("number_slide", id, "", 0), .min_value = @floatCast(j.number(j.get(f, "min"))), .max_value = @floatCast(j.number(j.get(f, "max"))), .initial_value = @floatCast(j.number(v)), .theme = .{ .height = q.Size.fixed(24) }, .on_action = try self.bind(.{ .app = self, .kind = .number_slide, .key = id }) });
            slider.value = @floatCast(j.number(v));
            _ = try block.add(.{ .slider = slider });
        }
        const err = j.text(self.model.errors, try self.inputKey(binding));
        if (err.len > 0) _ = try block.add(self.richLabel(err, .error_text));
        _ = try col.add(.{ .column = block });
    }
    pub fn overview(self: *App, col: *q.widget.Column) !void {
        try @import("ui/pages/overview.zig").build(self, col);
    }

    pub fn appearance(self: *App, parent: *q.widget.Column) !void {
        try @import("ui/pages/appearance.zig").build(self, parent);
    }

    pub fn fontControls(self: *App, col: *q.widget.Column) !void {
        const ty = j.get(self.model.snapshot, "desktop_typography");
        const families = j.items(j.get(ty, "families"));
        const names = try self.ui.allocator().alloc([]const u8, families.len);
        for (families, 0..) |v, i| names[i] = j.str(v);
        _ = try col.add(self.label("Installed font family and face", true));
        _ = try col.add(try self.dropdown(names, j.str(self.model.getValue("desktop.font.family")), .{ .app = self, .kind = .font_family }));
        var labels = std.ArrayList([]const u8).empty;
        try labels.append(self.ui.allocator(), "Automatic face");
        var faces = j.array(self.ui.allocator());
        for (j.items(j.get(ty, "faces"))) |face| if (std.mem.eql(u8, j.text(face, "family"), j.str(self.model.getValue("desktop.font.family")))) {
            try labels.append(self.ui.allocator(), j.text(face, "style"));
            try faces.array.append(face);
        };
        _ = try col.add(try self.dropdown(labels.items, if (j.str(self.model.getValue("desktop.font.style")).len == 0) "Automatic face" else j.str(self.model.getValue("desktop.font.style")), .{ .app = self, .kind = .font_face, .value = faces }));
        var reset_row = self.newRow();
        _ = try reset_row.add(try self.button("Reset family", .reset, "desktop.font.family", 0));
        _ = try reset_row.add(try self.button("Reset face", .reset, "desktop.font.style", 0));
        _ = try col.add(.{ .row = reset_row });
        for ([_][]const u8{ "desktop_typography", "desktop_cursor" }) |key| {
            _ = try col.add(self.label(if (std.mem.eql(u8, key, "desktop_cursor")) "Cursor synchronization" else "Typography synchronization", true));
            for (j.items(j.get(j.get(self.model.snapshot, key), "targets"))) |target| _ = try col.add(self.label(try std.fmt.allocPrint(self.ui.allocator(), "{s}: {s}", .{ j.text(target, "id"), j.text(target, "state") }), false));
            _ = try col.add(try self.button("Stage synchronization retry", .flag, if (std.mem.eql(u8, key, "desktop_cursor")) "sync_cursor" else "sync_typography", 0));
        }
        if (std.mem.eql(u8, self.shell, "dms")) _ = try col.add(self.label(if (self.shell_status.len > 0) self.shell_status else "DMS: family, weight and normal text size can synchronize; face/slant/width remain partial.", false));
    }
    pub fn advanced(self: *App, col: *q.widget.Column) !void {
        try @import("ui/pages/advanced.zig").build(self, col);
    }

    pub fn keybinds(self: *App, col: *q.widget.Column) !void {
        try @import("ui/pages/keybinds.zig").build(self, col);
    }

    pub fn rules(self: *App, col: *q.widget.Column) !void {
        try @import("ui/pages/rules.zig").build(self, col);
    }

    pub fn layoutsPage(self: *App, col: *q.widget.Column) !void {
        try @import("ui/pages/layouts.zig").build(self, col);
    }

    pub fn snapLayouts(self: *App) V {
        const value = j.get(self.model.draft, "snap_layouts");
        return if (value != .null) value else j.get(self.model.snapshot, "snap_layouts");
    }
    pub fn editLayouts(self: *App) !*V {
        const ma = self.model.allocator();
        if (j.get(self.model.draft, "snap_layouts") == .null) {
            var value = try j.clone(ma, j.get(self.model.snapshot, "snap_layouts"));
            if (value != .array) value = j.array(ma);
            try j.put(ma, &self.model.draft, "snap_layouts", value);
            try j.put(ma, &self.model.draft, "default_snap_layout", try j.clone(ma, j.get(self.model.snapshot, "default_snap_layout")));
        }
        return self.model.draft.object.getPtr("snap_layouts").?;
    }
    pub fn displays(self: *App, col: *q.widget.Column) !void {
        try @import("ui/pages/displays.zig").build(self, col);
    }

    pub fn drawCanvas(self: *App) !void {
        try self.inspect();
        for (0..8) |i| if (self.window.getCanvas(@intCast(9000 + i))) |canvas| {
            canvas.clear();
            try components.drawIcon(canvas, i, q.Theme.hex(self.theme.palette.primary));
        };
        if (self.window.getCanvas(8999)) |canvas| {
            canvas.clear();
            canvas.rect.color = q.Theme.hex(self.color_value & 0xffffff);
            canvas.bg_alpha = @as(f32, @floatFromInt(self.color_value >> 24)) / 255;
        }

        if (self.page != 4) return;
        const canvas = self.window.getCanvas(8100) orelse return;
        canvas.clear();
        const rows = j.items(self.monitor_rows);
        if (rows.len == 0) return;
        var min_x: f32 = 0;
        var min_y: f32 = 0;
        var max_x: f32 = 1;
        var max_y: f32 = 1;
        for (rows) |r| {
            const size = modes.size(r);
            const x: @TypeOf(min_x) = @floatCast(j.number(j.get(r, "x")));
            const y: f32 = @floatCast(j.number(j.get(r, "y")));
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x + size.w);
            max_y = @max(max_y, y + size.h);
        }
        self.canvas_scale = @max(0.0001, @min((canvas.rect.width - 24) / (max_x - min_x), (canvas.rect.height - 24) / (max_y - min_y)));
        self.canvas_min_x = min_x;
        self.canvas_min_y = min_y;
        for (rows, 0..) |r, i| {
            if (j.text(r, "mirror_of").len > 0) continue;
            const size = modes.size(r);
            const x = 12 + (@as(f32, @floatCast(j.number(j.get(r, "x")))) - min_x) * self.canvas_scale;
            const y = 12 + (@as(f32, @floatCast(j.number(j.get(r, "y")))) - min_y) * self.canvas_scale;
            try canvas.drawRect(a, x, y, size.w * self.canvas_scale - 2, size.h * self.canvas_scale - 2, q.Theme.hex(if (i == self.selected_monitor) self.theme.palette.primary_container else self.theme.palette.surface_container_high));
            try canvas.drawText(a, j.text(r, "name"), x + 8, y + 8, &self.window.state.fonts.regular, q.Theme.hex(if (i == self.selected_monitor) self.theme.palette.on_primary_container else self.theme.palette.on_surface));
        }
    }
    pub fn canvasInteraction(self: *App) !void {
        const canvas = self.window.getCanvas(8100) orelse return;
        const pos = canvas.toLocalCoords(self.window.mouseX(), self.window.mouseY());
        const down = self.window.state.mouse_down;
        if (down and !self.was_down and canvas.rect.contains(self.window.mouseX(), self.window.mouseY()) and pos.x >= 0 and pos.y >= 0 and pos.x < canvas.rect.width and pos.y < canvas.rect.height) {
            for (j.items(self.monitor_rows), 0..) |r, i| {
                if (j.text(r, "mirror_of").len > 0) continue;
                const size = modes.size(r);
                const x = 12 + (@as(f32, @floatCast(j.number(j.get(r, "x")))) - self.canvas_min_x) * self.canvas_scale;
                const y = 12 + (@as(f32, @floatCast(j.number(j.get(r, "y")))) - self.canvas_min_y) * self.canvas_scale;
                if (pos.x >= x and pos.y >= y and pos.x < x + size.w * self.canvas_scale and pos.y < y + size.h * self.canvas_scale) {
                    self.selected_monitor = i;
                    self.drag_index = i;
                    self.drag_x = pos.x;
                    self.drag_y = pos.y;
                    self.drag_origin_x = j.number(j.get(r, "x"));
                    self.drag_origin_y = j.number(j.get(r, "y"));
                    break;
                }
            }
        }
        if (!down and self.was_down) {
            if (self.drag_index) |i| {
                const r = j.items(self.monitor_rows)[i];
                try self.stageMonitor(r, "x", .{ .integer = @intFromFloat(@round(self.drag_origin_x + (pos.x - self.drag_x) / self.canvas_scale)) });
                try self.stageMonitor(r, "y", .{ .integer = @intFromFloat(@round(self.drag_origin_y + (pos.y - self.drag_y) / self.canvas_scale)) });
                self.rebuilt = true;
            }
            self.drag_index = null;
        }
        self.was_down = down;
    }
    pub fn stageMonitor(self: *App, r: V, key: []const u8, value: V) !void {
        const id = j.text(r, "id");
        for ([_][]const u8{ "name", "x", "y", "transform" }) |k| {
            const existing = j.get(j.get(j.get(self.model.draft, "monitor_changes"), id), k);
            if (existing == .null) try self.model.merge("monitor_changes", id, k, j.get(r, k));
        }
        try self.model.merge("monitor_changes", id, key, value);
    }
    pub fn handle(self: *App, b: *Binding, event: q.Action) !void {
        const ma = self.model.allocator();
        if (self.client.busy() and b.kind != .cancel and b.kind != .close and b.kind != .cancel_job) return;
        var text: []const u8 = "";
        var value: V = .null;
        switch (event) {
            .change_text => |s| {
                text = s;
                value = if (b.kind == .raw) .null else try j.string(ma, s);
            },
            .submit_text => |s| {
                text = s;
                value = if (b.kind == .raw) .null else try j.string(ma, s);
            },
            .select_index => |i| {
                if (i >= b.options.len) return;
                text = b.options[i];
                value = try j.string(ma, text);
            },
            .change_value => |v| value = .{ .float = v },
            .toggle => |v| value = .{ .bool = v },
            .click => {},
        }
        // Text callbacks update drafts in place; rebuild on submit/navigation to
        // keep the caret and scroll position stable while typing.
        self.rebuilt = event != .change_text;
        switch (b.kind) {
            .page => {
                self.page = if (event == .select_index) event.select_index else b.index;
                self.search = "";
                self.rendered_search = "";
                self.search_due = 0;
                self.highlight = "";
            },
            .search => {
                self.search = try self.own(text);
                self.search_due = std.Io.Clock.awake.now(self.client.io).toMilliseconds() + 160;
                self.rebuilt = false;
                if (event == .submit_text) {
                    const results = try search_model.find(self.ui.allocator(), j.get(self.model.snapshot, "fields"), self.search);
                    if (results.len > 0) try self.openSearch(results[0].id, results[0].page);
                }
            },
            .search_open => try self.openSearch(b.key, b.index),
            .section_toggle => try self.view_state.toggle(a, b.key),
            .number_step, .number_slide => {
                const f = self.model.field(b.key);
                const integer = std.mem.eql(u8, j.text(f, "type"), "integer");
                const step: f64 = if (integer) 1 else if (presentation.percent(b.key)) 0.01 else 0.05;
                var next = if (event == .change_value) j.number(value) else j.number(self.model.getValue(b.key)) + (if (b.index == 0) -step else step);
                if (integer) next = @round(next);
                if (j.get(f, "min") != .null) next = @max(next, j.number(j.get(f, "min")));
                if (j.get(f, "max") != .null) next = @min(next, j.number(j.get(f, "max")));
                try self.model.input(b.key, try std.fmt.allocPrint(self.ui.allocator(), "{d}", .{next}));
                const error_key = try self.inputKey(.{ .app = self, .kind = .field, .key = b.key, .id = b.key });
                _ = self.model.errors.object.swapRemove(error_key);
                _ = self.model.inputs.object.swapRemove(error_key);
                if (event == .change_value) {
                    self.rebuilt = false;
                    self.slider_rebuild = true;
                }
            },
            .color_open => {
                self.color_key = try self.own(b.key);
                self.color_value = try presentation.parseColor(j.str(self.model.getValue(b.key)));
                self.color_text = try self.own(j.str(self.model.getValue(b.key)));
                self.color_error = "";
            },
            .color_cancel => {
                self.color_key = "";
                self.color_error = "";
            },
            .color_accept => {
                if (self.color_error.len > 0) return error.InvalidColor;
                try self.model.input(self.color_key, try std.fmt.allocPrint(self.ui.allocator(), "0x{X:0>8}", .{self.color_value}));
                const field_key = try self.inputKey(.{ .app = self, .kind = .field, .id = self.color_key, .key = self.color_key });
                _ = self.model.inputs.object.swapRemove(field_key);
                _ = self.model.errors.object.swapRemove(field_key);
                self.color_key = "";
            },
            .color_channel => {
                if (event == .change_value) {
                    const shift: u5 = @intCast(b.index * 8);
                    const channel: u32 = @intFromFloat(@round(std.math.clamp(j.number(value), 0, 255)));
                    self.color_value = (self.color_value & ~(@as(u32, 255) << shift)) | (channel << shift);
                    self.color_text = try std.fmt.allocPrint(self.model.allocator(), "0x{X:0>8}", .{self.color_value});
                    self.color_error = "";
                    self.rebuilt = false;
                    self.slider_rebuild = true;
                } else {
                    self.color_text = try self.own(text);
                    self.color_value = presentation.parseColor(text) catch {
                        self.rebuilt = self.color_error.len == 0;
                        self.color_error = "Use 0xAARRGGBB (eight hexadecimal digits).";
                        return;
                    };
                    if (self.color_error.len > 0) self.rebuilt = true;
                    self.color_error = "";
                }
            },
            .field => {
                if (event == .toggle) try self.model.change(b.id, value) else if (presentation.percent(b.id)) {
                    const number = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
                    try self.model.input(b.id, try std.fmt.allocPrint(self.ui.allocator(), "{d}", .{presentation.fromDisplay(b.id, number)}));
                } else try self.model.input(b.id, text);
                _ = self.model.errors.object.swapRemove(b.id);
            },
            .reset => {
                try self.model.change(b.key, j.get(self.model.field(b.key), "default"));
                _ = self.model.errors.object.swapRemove(try self.inputKey(.{ .app = self, .kind = .field, .id = b.key, .key = b.key }));
                _ = self.model.inputs.object.swapRemove(try self.inputKey(.{ .app = self, .kind = .field, .id = b.key, .key = b.key }));
            },
            .raw => try self.model.raw(b.key, text),
            .apply, .validate, .confirm_apply => {
                if (self.uncertain) return error.InspectAndReconcileBeforeApply;
                if (b.kind == .confirm_apply) {
                    self.close_after_apply = self.confirm == .close;
                    self.confirm = .none;
                }
                const request = try self.model.request(self.backup);
                try self.backendOp(if (b.kind == .validate) "validate" else "apply", request);
            },
            .reload => {
                if (self.uncertain) {
                    try self.client.startBackend("inspect", self.shell, "");
                    self.page = 7;
                } else if (self.model.count() > 0 or self.model.errors.object.count() > 0) self.confirm = .reload else try self.load();
            },
            .cancel => self.confirm = .none,
            .cancel_job => {
                self.status = if (self.client.cancel()) "Cancellation requested before saving." else "Saving or synchronization is finishing. Wait for completion.";
            },
            .close => self.closeRequested(),
            .discard => {
                if (self.confirm == .close) {
                    self.quitting = true;
                    return;
                }
                self.confirm = .none;
                try self.load();
            },
            .theme_source => {
                self.rebuilt = false;
                self.theme_choice = switch (event) {
                    .select_index => |index| @enumFromInt(index),
                    else => return,
                };
                try self.selectTheme();
                self.savePreferences() catch {
                    self.setThemeStatus("Theme selected; unable to save application preference.");
                };
            },
            .shell => {
                if (self.model.count() > 0 or self.model.errors.object.count() > 0) return error.ApplyOrDiscardBeforeChangingShell;
                self.shell = if (std.mem.eql(u8, text, "dms")) "dms" else if (std.mem.eql(u8, text, "noctalia")) "noctalia" else "none";
                try self.load();
            },
            .flag => try self.model.flag(b.key),
            .legacy_binding => {
                try self.addBinding(try std.fmt.allocPrint(ma, "builtin:snap_zone:{s}", .{b.key}));
                self.page = 6;
            },
            .legacy_remove => try self.model.merge("snap_zone_changes", b.key, "op", try j.string(ma, "delete")),
            .legacy_undo => {
                _ = self.model.draft.object.getPtr("snap_zone_changes").?.object.swapRemove(b.key);
            },
            .legacy_zone => {
                const n = std.fmt.parseFloat(f64, text) catch return error.InvalidZone;
                if (!std.math.isFinite(n) or n < 0 or n > 1) return error.InvalidZone;
                for ([_][]const u8{ "x", "y", "width", "height" }) |key| {
                    if (j.get(j.get(j.get(self.model.draft, "snap_zone_changes"), b.id), key) == .null) {
                        const original = j.get(b.value, key);
                        try self.model.merge("snap_zone_changes", b.id, key, if (original == .null) V{ .float = if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y")) 0 else 0.5 } else original);
                    }
                }
                try self.model.merge("snap_zone_changes", b.id, "op", try j.string(ma, "update"));
                try self.model.merge("snap_zone_changes", b.id, b.key, .{ .float = n });
            },
            .select_file => self.selected_file = event.select_index,
            .select_monitor => self.selected_monitor = event.select_index,
            .select_rule => self.selected_rule = event.select_index,
            .select_layout => self.selected_layout = event.select_index,
            .monitor, .monitor_mode => {
                if (std.mem.eql(u8, b.key, "x") or std.mem.eql(u8, b.key, "y")) value = .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger };
                if (std.mem.eql(u8, b.key, "scale")) {
                    const n = std.fmt.parseFloat(f64, text) catch return error.InvalidScale;
                    if (!std.math.isFinite(n) or n <= 0 or n > 8) return error.InvalidScale;
                    value = .{ .float = n };
                }
                if (std.mem.eql(u8, b.key, "mode")) _ = try modes.parse(text);
                if (std.mem.eql(u8, b.key, "mirror_of") and std.mem.eql(u8, text, "Extended desktop")) value = try j.string(ma, "");
                try self.stageMonitor(b.value, b.key, value);
                _ = self.model.errors.object.swapRemove(b.key);
            },
            .add_keybind => try self.addBinding("spawn:"),
            .keybind => {
                try self.model.merge("custom_keybind_changes", b.id, "op", try j.string(ma, if (std.mem.startsWith(u8, b.id, "new:")) "add" else "update"));
                try self.model.merge("custom_keybind_changes", b.id, b.key, value);
                // The backend expects chord and command together.
                const current = j.get(j.get(self.model.draft, "custom_keybind_changes"), b.id);
                for (j.items(j.get(self.model.snapshot, "custom_keybinds"))) |r| if (std.mem.eql(u8, j.text(r, "id"), b.id)) {
                    for ([_][]const u8{ "chord", "command" }) |key| if (j.get(current, key) == .null) try self.model.merge("custom_keybind_changes", b.id, key, j.get(r, key));
                };
            },
            .remove_keybind => {
                if (std.mem.startsWith(u8, b.key, "new:")) {
                    _ = self.model.draft.object.getPtr("custom_keybind_changes").?.object.swapRemove(b.key);
                } else try self.model.merge("custom_keybind_changes", b.key, "op", try j.string(ma, "delete"));
            },
            .add_rule => {
                var op = try j.parse(ma, "{\"op\":\"add\",\"values\":{\"app_id\":\"\"}}");
                try j.put(ma, &op, "id", try j.string(ma, try self.model.unique("new-rule:")));
                try self.model.rule(op);
                self.selected_rule = j.items(try self.model.rows("window_rules", "window_rule_changes")).len - 1;
            },
            .remove_rule, .move_up, .move_down => {
                const rows = j.items(try self.model.rows("window_rules", "window_rule_changes"));
                if (self.selected_rule >= rows.len) return;
                var op = j.object(ma);
                try j.put(ma, &op, "id", j.get(rows[self.selected_rule], "id"));
                try j.put(ma, &op, "op", try j.string(ma, if (b.kind == .remove_rule) "delete" else "move"));
                if (b.kind != .remove_rule) try j.put(ma, &op, "direction", .{ .integer = if (b.kind == .move_up) -1 else 1 });
                try self.model.rule(op);
            },
            .rule_field => {
                const kind = j.text(b.value, "type");
                if (text.len == 0 or std.mem.eql(u8, text, "(unset)")) value = .null else if (std.mem.eql(u8, kind, "number")) value = .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger } else if (std.mem.eql(u8, kind, "boolean")) value = .{ .bool = std.mem.eql(u8, text, "true") };
                var op = j.object(ma);
                var values = j.object(ma);
                try j.put(ma, &values, b.key, value);
                try j.put(ma, &op, "values", values);
                try j.put(ma, &op, "id", try j.string(ma, b.id));
                try j.put(ma, &op, "op", try j.string(ma, "update"));
                try self.model.rule(op);
                _ = self.model.errors.object.swapRemove(b.key);
            },
            .font_family => {
                for ([_][]const u8{ "desktop.font.family", "desktop.font.style", "desktop.font.weight", "desktop.font.slant", "desktop.font.width" }) |id| {
                    const key = try self.inputKey(.{ .app = self, .kind = .field, .key = id, .id = id });
                    _ = self.model.inputs.object.swapRemove(key);
                    _ = self.model.errors.object.swapRemove(key);
                }
                try self.model.change("desktop.font.family", value);
                try self.model.change("desktop.font.style", try j.string(ma, ""));
                try self.model.change("desktop.font.weight", .{ .integer = 400 });
                try self.model.change("desktop.font.slant", try j.string(ma, "normal"));
                try self.model.change("desktop.font.width", try j.string(ma, "normal"));
            },
            .font_face => {
                for ([_][]const u8{ "desktop.font.style", "desktop.font.weight", "desktop.font.slant", "desktop.font.width" }) |id| {
                    const key = try self.inputKey(.{ .app = self, .kind = .field, .key = id, .id = id });
                    _ = self.model.inputs.object.swapRemove(key);
                    _ = self.model.errors.object.swapRemove(key);
                }
                const i = event.select_index;
                if (i == 0) {
                    for ([_][]const u8{ "desktop.font.style", "desktop.font.weight", "desktop.font.slant", "desktop.font.width" }) |id| try self.model.change(id, j.get(self.model.field(id), "default"));
                } else {
                    const face = j.items(b.value)[i - 1];
                    for ([_][]const u8{ "style", "weight", "slant", "width" }) |key| try self.model.change(try std.fmt.allocPrint(ma, "desktop.font.{s}", .{key}), j.get(face, key));
                }
            },
            .runtime_output => {
                self.runtime_output = try self.own(text);
                self.live_layout.reset();
                self.next_layout_query = 0;
            },
            .runtime_layout => self.live_layout.choose(event.select_index),
            .refresh_live => try self.client.startBackend("refresh-live", self.shell, ""),
            .runtime_apply => {
                const index = self.live_layout.selected orelse return error.LayoutUnavailable;
                if (self.live_layout.failed) return error.LayoutUnavailable;
                try self.client.start("runtime", &.{ "aqueousctl", "layout", "--output", self.runtime_output, "--set", runtime_layout_model.choices[index], "--json" }, "");
            },
            .add_layout, .migrate => {
                const layouts = try self.editLayouts();
                if (layouts.array.items.len >= 8) return error.TooManyLayouts;
                var layout = try j.parse(ma, "{\"name\":\"New layout\",\"padding\":0,\"zones\":[]}");
                try j.put(ma, &layout, "id", try j.string(ma, try self.model.unique("layout")));
                var zones = layout.object.getPtr("zones").?;
                if (b.kind == .migrate) {
                    for (j.items(j.get(self.model.snapshot, "snap_zones"))) |z| if (j.boolean(j.get(z, "complete"))) {
                        var zone = j.object(ma);
                        for ([_][]const u8{ "id", "x", "y", "width", "height" }) |key| try j.put(ma, &zone, key, j.get(z, key));
                        try j.put(ma, &zone, "name", j.get(z, "id"));
                        try zones.array.append(zone);
                    };
                }
                if (zones.array.items.len == 0) try zones.array.append(try self.newZone());
                try layouts.array.append(layout);
                self.selected_layout = layouts.array.items.len - 1;
                if (j.text(self.model.draft, "default_snap_layout").len == 0) try j.put(ma, &self.model.draft, "default_snap_layout", j.get(layout, "id"));
            },
            .layout_field, .zone_field, .remove_layout, .add_zone, .remove_zone, .preset, .make_default, .snap_binding => {
                const layouts = try self.editLayouts();
                if (self.selected_layout >= layouts.array.items.len) return;
                const layout = &layouts.array.items[self.selected_layout];
                if (b.kind == .layout_field) {
                    if (std.mem.eql(u8, b.key, "padding")) value = .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidPadding };
                    if (std.mem.eql(u8, b.key, "id") and std.mem.eql(u8, j.text(self.model.draft, "default_snap_layout"), j.text(layout.*, "id"))) try j.put(ma, &self.model.draft, "default_snap_layout", value);
                    try j.put(ma, layout, b.key, value);
                } else if (b.kind == .remove_layout) {
                    const removed = layouts.array.orderedRemove(self.selected_layout);
                    if (std.mem.eql(u8, j.text(removed, "id"), j.text(self.model.draft, "default_snap_layout"))) try j.put(ma, &self.model.draft, "default_snap_layout", if (layouts.array.items.len > 0) j.get(layouts.array.items[0], "id") else try j.string(ma, ""));
                } else if (b.kind == .make_default) try j.put(ma, &self.model.draft, "default_snap_layout", j.get(layout.*, "id")) else if (b.kind == .snap_binding) {
                    const command = if (std.mem.eql(u8, b.key, "cycle")) "builtin:cycle_snap_layout" else if (std.mem.eql(u8, b.key, "layout")) try std.fmt.allocPrint(ma, "builtin:set_snap_layout:{s}", .{j.text(layout.*, "id")}) else try std.fmt.allocPrint(ma, "builtin:snap_zone:{s}/{s}", .{ j.text(layout.*, "id"), j.text(j.items(j.get(layout.*, "zones"))[b.index], "id") });
                    try self.addBinding(command);
                    self.page = 6;
                } else {
                    const zones = layout.object.getPtr("zones").?;
                    if (b.kind == .zone_field) {
                        if (!std.mem.eql(u8, b.key, "id") and !std.mem.eql(u8, b.key, "name")) {
                            const n = std.fmt.parseFloat(f64, text) catch return error.InvalidZone;
                            if (!std.math.isFinite(n)) return error.InvalidZone;
                            value = .{ .float = n };
                        }
                        if (b.index < zones.array.items.len) try j.put(ma, &zones.array.items[b.index], b.key, value);
                    } else if (b.kind == .add_zone) {
                        if (zones.array.items.len >= 16) return error.TooManyZones;
                        try zones.array.append(try self.newZone());
                    } else if (b.kind == .remove_zone) {
                        if (b.index < zones.array.items.len) _ = zones.array.orderedRemove(b.index);
                    } else if (b.kind == .preset) {
                        zones.* = j.array(ma);
                        const n = b.index;
                        for (0..n) |i| {
                            var zone = try self.newZone();
                            try j.put(ma, &zone, "x", .{ .float = if (n == 4) @as(f64, @floatFromInt(i % 2)) / 2 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) });
                            try j.put(ma, &zone, "y", .{ .float = if (n == 4) @as(f64, @floatFromInt(i / 2)) / 2 else 0 });
                            try j.put(ma, &zone, "width", .{ .float = if (n == 4) 0.5 else 1 / @as(f64, @floatFromInt(n)) });
                            try j.put(ma, &zone, "height", .{ .float = if (n == 4) 0.5 else 1 });
                            try zones.array.append(zone);
                        }
                    }
                }
                _ = self.model.errors.object.swapRemove(b.key);
            },
        }
        if (event == .submit_text) _ = self.model.inputs.object.swapRemove(try self.inputKey(b.*));
        if (event == .change_text or event == .submit_text) {
            if (self.model.errors.object.swapRemove(try self.inputKey(b.*))) self.rebuilt = true;
        }
        if (event == .change_text) self.status = "Edits staged. Validate or Apply when ready.";
    }
    pub fn refreshChrome(self: *App) !void {
        if (self.window.state.root_widget) |*root| {
            if (root.* != .column or root.column.children.items.len < 4) return;
            const children = root.column.children.items;
            const offset: usize = if (self.confirm == .none and self.color_key.len == 0) 0 else 1;
            const status_widget = &children[children.len - 2 - offset].widget;
            if (status_widget.* == .text) {
                status_widget.text.deinit();
                status_widget.* = self.label(self.status, false);
            }
            const footer = &children[children.len - 1 - offset].widget;
            if (footer.* == .row and footer.row.children.items.len > 0) {
                const label_widget = &footer.row.children.items[0].widget;
                label_widget.deinit(a);
                label_widget.* = self.label(try std.fmt.allocPrint(self.ui.allocator(), "{d} pending", .{self.model.count()}), false);
            }
            self.window.state.layout_dirty = true;
        }
    }
    pub fn newZone(self: *App) !V {
        var zone = try j.parse(self.model.allocator(), "{\"name\":\"Zone\",\"x\":0,\"y\":0,\"width\":1,\"height\":1}");
        try j.put(self.model.allocator(), &zone, "id", try j.string(self.model.allocator(), try self.model.unique("zone")));
        return zone;
    }
    pub fn addBinding(self: *App, command: []const u8) !void {
        const id = try self.model.unique("new:");
        const ma = self.model.allocator();
        try self.model.merge("custom_keybind_changes", id, "op", try j.string(ma, "add"));
        try self.model.merge("custom_keybind_changes", id, "chord", try j.string(ma, ""));
        try self.model.merge("custom_keybind_changes", id, "command", try j.string(ma, command));
    }
};
fn syncText(widget: *q.Widget, b: *Binding, text: []const u8) void {
    switch (widget.*) {
        .textfield => |*field| {
            if (field.on_action) |handler| {
                if (handler.context == @intFromPtr(b)) field.text = text;
            }
        },
        .column => |*col| for (col.children.items) |*child| syncText(&child.widget, b, text),
        .row => |*row| for (row.children.items) |*child| syncText(&child.widget, b, text),
        .scrollview => |*sv| syncText(sv.child, b, text),
        .modal => |*modal| syncText(modal.child, b, text),
        else => {},
    }
}
fn dispatch(b: *Binding, event: q.Action) !void {
    if (b.app.client.busy() and b.kind != .cancel and b.kind != .close and b.kind != .cancel_job) {
        b.app.rebuilt = true;
        return;
    }
    if (event == .change_text) {
        switch (b.kind) {
            .field, .monitor, .rule_field, .keybind, .layout_field, .zone_field, .legacy_zone => {
                const key = try b.app.inputKey(b.*);
                try j.put(b.app.model.allocator(), &b.app.model.inputs, try b.app.own(key), try j.string(b.app.model.allocator(), event.change_text));
            },
            else => {},
        }
        const owned = try a.dupe(u8, event.change_text);
        if (b.app.window.state.root_widget) |*root| syncText(root, b, owned);
        if (b.edited) |old| a.free(old);
        b.edited = owned;
    }
    defer b.app.refreshChrome() catch {};
    b.app.handle(b, event) catch |err| {
        b.app.status = @errorName(err);
        if (event == .change_text or event == .submit_text) {
            const key = try b.app.inputKey(b.*);
            try j.put(b.app.model.allocator(), &b.app.model.inputs, try b.app.own(key), try j.string(b.app.model.allocator(), if (event == .change_text) event.change_text else event.submit_text));
            const first_error = j.get(b.app.model.errors, key) == .null;
            try j.put(b.app.model.allocator(), &b.app.model.errors, try b.app.own(key), try j.string(b.app.model.allocator(), @errorName(err)));
            b.app.rebuilt = event != .change_text or first_error;
        } else b.app.rebuilt = true;
    };
}
