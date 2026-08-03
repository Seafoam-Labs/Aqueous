const std = @import("std");
const quark = @import("quark");
const catalog = @import("catalog.zig");
const registry = @import("sections.zig");
const install_plan = @import("install_plan.zig");
const shelly = @import("shelly_client.zig");
const protocol = @import("shelly_protocol.zig");
const first_run = @import("first_run.zig");
const noctalia = @import("noctalia.zig");

const shelly_path = "/usr/bin/shelly";
const noctalia_path = "/usr/bin/noctalia";
const wallpaper_directory = "/usr/share/aqueous/wallpapers";

const Mutex = struct {
    value: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.value.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.value.unlock();
    }
};

const Result = enum {
    none,
    pending,
    running,
    succeeded,
    failed,
};

const WorkerMode = enum {
    idle,
    discovering,
    ready,
    unavailable,
    installing,
    complete,
};

const CustomChange = union(enum) {
    theme_mode: noctalia.ThemeMode,
    palette: struct {
        source: noctalia.Source,
        name: [64]u8 = @splat(0),
        len: usize = 0,
    },
    wallpaper: struct {
        path: [256]u8 = @splat(0),
        len: usize = 0,
    },
};

const Runtime = struct {
    mutex: Mutex = .{},
    mode: WorkerMode = .idle,
    revision: u64 = 0,
    installed: shelly.Installed = @splat(false),
    selection: install_plan.Selection = @splat(false),
    results: [registry.application_count]Result = @splat(.none),
    noctalia_state: noctalia.State = .{},
    pending_change: ?CustomChange = null,
    custom_running: bool = false,
    status: [256]u8 = @splat(0),
    status_len: usize = 0,
    percent: u8 = 0,

    fn setStatusLocked(self: *Runtime, message: []const u8) void {
        self.status_len = @min(message.len, self.status.len);
        @memcpy(self.status[0..self.status_len], message[0..self.status_len]);
    }

    fn updateStatus(self: *Runtime, message: []const u8, percent: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.percent == percent and std.mem.eql(
            u8,
            self.status[0..self.status_len],
            message[0..@min(message.len, self.status.len)],
        )) return;
        self.percent = percent;
        self.setStatusLocked(message);
        self.revision += 1;
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    window: *quark.Parent,
    runtime: *Runtime,
    worker: ?std.Thread = null,
    custom_worker: ?std.Thread = null,
    screen: Screen = .loading,
    installed: shelly.Installed = @splat(false),
    selected: install_plan.Selection = @splat(false),
    results: [registry.application_count]Result = @splat(.none),
    noctalia_state: noctalia.State = .{},
    wallpapers: [][]const u8 = &.{},
    status: [256]u8 = @splat(0),
    status_len: usize = 0,
    percent: u8 = 0,
    seen_revision: u64 = 0,
    needs_rebuild: bool = false,
    callbacks: std.ArrayList(*Callback) = .empty,

    const Screen = enum { loading, customize, selection, review, installing, results };
    const Callback = struct { app: *App, value: u64 };

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *std.process.Environ.Map,
        window: *quark.Parent,
    ) !App {
        const runtime = try allocator.create(Runtime);
        runtime.* = .{};
        var app: App = .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .window = window,
            .runtime = runtime,
        };
        app.wallpapers = noctalia.listWallpapers(allocator, io, wallpaper_directory) catch
            try allocator.dupe([]const u8, &.{});
        app.setStatus("Checking installed applications…");
        return app;
    }

    fn deinit(self: *App) void {
        if (self.worker) |thread| thread.join();
        if (self.custom_worker) |thread| thread.join();
        for (self.wallpapers) |name| self.allocator.free(name);
        self.allocator.free(self.wallpapers);
        for (self.callbacks.items) |callback| self.allocator.destroy(callback);
        self.callbacks.deinit(self.allocator);
        self.allocator.destroy(self.runtime);
    }

    fn startDiscovery(self: *App) !void {
        self.joinCompletedWorker();
        if (self.worker != null) return error.WorkerBusy;
        self.runtime.mutex.lock();
        self.runtime.mode = .discovering;
        self.runtime.percent = 0;
        self.runtime.setStatusLocked("Checking installed applications…");
        self.runtime.revision += 1;
        self.runtime.mutex.unlock();
        self.screen = .loading;
        self.worker = try std.Thread.spawn(.{}, discoveryWorker, .{self.runtime});
    }

    fn startInstall(self: *App) !void {
        self.joinCompletedWorker();
        if (self.worker != null) return error.WorkerBusy;
        self.runtime.mutex.lock();
        self.runtime.selection = self.selected;
        self.runtime.results = @splat(.none);
        for (self.selected, self.installed, 0..) |selected, installed, index| {
            if (selected and !installed) self.runtime.results[index] = .pending;
        }
        self.runtime.mode = .installing;
        self.runtime.percent = 0;
        self.runtime.setStatusLocked("Preparing Shelly transactions…");
        self.runtime.revision += 1;
        self.runtime.mutex.unlock();
        self.screen = .installing;
        self.needs_rebuild = true;
        self.worker = try std.Thread.spawn(.{}, installWorker, .{self.runtime});
    }

    fn tick(self: *App) void {
        self.runtime.mutex.lock();
        const revision = self.runtime.revision;
        if (revision == self.seen_revision) {
            self.runtime.mutex.unlock();
            return;
        }
        self.seen_revision = revision;
        self.installed = self.runtime.installed;
        self.results = self.runtime.results;
        self.noctalia_state = self.runtime.noctalia_state;
        self.percent = self.runtime.percent;
        self.status_len = self.runtime.status_len;
        @memcpy(self.status[0..self.status_len], self.runtime.status[0..self.status_len]);
        const mode = self.runtime.mode;
        self.runtime.mutex.unlock();

        switch (mode) {
            .ready => if (self.screen == .loading) {
                self.screen = .customize;
            },
            .unavailable => self.screen = .customize,
            .installing => self.screen = .installing,
            .complete => self.screen = .results,
            else => {},
        }
        self.needs_rebuild = true;
        if (mode == .ready or mode == .unavailable or mode == .complete) {
            self.joinCompletedWorker();
        }
    }

    fn joinCompletedWorker(self: *App) void {
        if (self.worker) |thread| {
            self.runtime.mutex.lock();
            const done = switch (self.runtime.mode) {
                .ready, .unavailable, .complete => true,
                else => false,
            };
            self.runtime.mutex.unlock();
            if (done) {
                thread.join();
                self.worker = null;
            }
        }
    }

    fn setStatus(self: *App, message: []const u8) void {
        self.status_len = @min(message.len, self.status.len);
        @memcpy(self.status[0..self.status_len], message[0..self.status_len]);
    }

    fn statusText(self: *const App) []const u8 {
        return self.status[0..self.status_len];
    }

    fn setLayout(self: *App) !void {
        self.window.setLayout(try self.view());
    }

    fn view(self: *App) !quark.Widget {
        var root = quark.widget.Column.init(self.allocator, .{
            .spacing = 14,
            .padding = 24,
            .alignment = .stretch,
        });

        var heading = quark.widget.Row.init(self.allocator, .{
            .spacing = 12,
            .alignment = .center,
        });
        _ = try heading.add(self.text("Welcome to Aqueous", true, 0xF1EFF8));
        _ = try heading.add(.{ .spacer = quark.widget.Spacer.flexible() });
        _ = try heading.add(self.text(self.stepLabel(), false, 0x9A94B5));
        _ = try root.add(.{ .row = heading });
        _ = try root.add(self.text(
            "Make Aqueous yours with a few useful desktop applications.",
            false,
            0xBBB6CF,
        ));

        const content = switch (self.screen) {
            .loading => try self.loadingView(),
            .customize => try self.customizeView(),
            .selection => try self.selectionView(),
            .review => try self.reviewView(),
            .installing => try self.installingView(),
            .results => try self.resultsView(),
        };
        _ = try root.addWithHeightConstraint(
            .{ .scrollview = try quark.widget.ScrollView.initOwned(content, self.allocator) },
            quark.Size.proportional(1),
        );
        _ = try root.add(try self.footerView());
        return .{ .column = root };
    }

    fn stepLabel(self: *const App) []const u8 {
        return switch (self.screen) {
            .loading => "Getting ready",
            .customize => "1 · Make Noctalia yours",
            .selection => "2 · Choose applications",
            .review => "3 · Review",
            .installing => "4 · Installing",
            .results => "5 · Finished",
        };
    }

    fn loadingView(self: *App) !quark.Widget {
        var card = self.newCard();
        _ = try card.add(self.text("Looking at what is already installed", true, 0xF1EFF8));
        _ = try card.add(self.text(self.statusText(), false, 0xBBB6CF));
        return .{ .column = card };
    }

    fn customizeView(self: *App) !quark.Widget {
        var content = quark.widget.Column.init(self.allocator, .{
            .spacing = 14,
            .padding = 4,
            .alignment = .stretch,
        });
        const status = self.statusText();
        if (status.len != 0 and !std.mem.eql(u8, status, "Choose the applications you would like to add.")) {
            _ = try content.add(try self.noticeCard(status, 0x5B2834));
        }
        if (!self.noctalia_state.available) {
            _ = try content.add(try self.noticeCard(
                "Noctalia is not responding, so the shell keeps its current appearance.",
                0x282344,
            ));
        }

        var appearance = self.newCard();
        _ = try appearance.add(self.text("Appearance", true, 0xF1EFF8));
        _ = try appearance.add(self.text("Noctalia themes the shell, the bar, and your applications.", false, 0x9A94B5));
        var modes = quark.widget.Row.init(self.allocator, .{
            .spacing = 10,
            .alignment = .center,
        });
        const mode_list = [_]noctalia.ThemeMode{ .dark, .light, .auto };
        for (mode_list, 0..) |mode, index| {
            _ = try modes.add(self.button(
                mode.label(),
                try self.bindValue(index, chooseThemeMode),
                self.noctalia_state.theme_mode == mode,
            ));
        }
        _ = try appearance.add(.{ .row = modes });
        _ = try content.add(.{ .column = appearance });

        var palette_card = self.newCard();
        _ = try palette_card.add(self.text("Color palette", true, 0xF1EFF8));
        _ = try palette_card.add(self.text("Pick a built-in palette, or generate colors from the wallpaper.", false, 0x9A94B5));
        var palette_row = quark.widget.Row.init(self.allocator, .{
            .spacing = 10,
            .alignment = .center,
        });
        const source_index: ?u32 = switch (self.noctalia_state.source) {
            .builtin => 0,
            .wallpaper => 1,
            else => null,
        };
        _ = try palette_row.addWithWidthConstraint(.{ .dropdown = quark.widget.Dropdown.init(.{
            .items = &.{ "Built-in palettes", "From wallpaper" },
            .selected_index = source_index,
            .placeholder = "Community or custom palette",
            .on_action = quark.action.bind(self, choosePaletteSource),
        }) }, quark.Size.proportional(1));
        const palette_items = self.paletteItems();
        _ = try palette_row.addWithWidthConstraint(.{ .dropdown = quark.widget.Dropdown.init(.{
            .items = palette_items,
            .selected_index = indexOfItem(palette_items, self.noctalia_state.paletteName()),
            .placeholder = "Select a palette",
            .on_action = quark.action.bind(self, choosePalette),
        }) }, quark.Size.proportional(1));
        _ = try palette_card.add(.{ .row = palette_row });
        _ = try content.add(.{ .column = palette_card });

        if (self.wallpapers.len != 0) {
            var wallpaper_card = self.newCard();
            _ = try wallpaper_card.add(self.text("Wallpaper", true, 0xF1EFF8));
            _ = try wallpaper_card.add(self.text("Bundled with Aqueous; Noctalia applies it immediately.", false, 0x9A94B5));
            _ = try wallpaper_card.add(.{ .dropdown = quark.widget.Dropdown.init(.{
                .items = self.wallpapers,
                .selected_index = indexOfItem(
                    self.wallpapers,
                    std.fs.path.basename(self.noctalia_state.wallpaperPath()),
                ),
                .placeholder = "Select a wallpaper",
                .on_action = quark.action.bind(self, chooseWallpaper),
            }) });
            _ = try content.add(.{ .column = wallpaper_card });
        }
        return .{ .column = content };
    }

    fn paletteItems(self: *const App) []const []const u8 {
        return if (self.noctalia_state.source == .wallpaper)
            noctalia.wallpaper_schemes
        else
            noctalia.builtin_palettes;
    }

    fn indexOfItem(items: []const []const u8, wanted: []const u8) ?u32 {
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item, wanted)) return @intCast(index);
        }
        return null;
    }

    fn selectionView(self: *App) !quark.Widget {
        var content = quark.widget.Column.init(self.allocator, .{
            .spacing = 14,
            .padding = 4,
            .alignment = .stretch,
        });
        if (!std.mem.eql(u8, self.statusText(), "Choose the applications you would like to add.")) {
            _ = try content.add(try self.noticeCard(self.statusText(), 0x5B2834));
        }
        for (registry.sections, 0..) |section, section_index| {
            _ = try content.add(try self.sectionView(section, section_index));
        }
        return .{ .column = content };
    }

    fn sectionView(self: *App, section: catalog.Section, section_index: usize) !quark.Widget {
        var card = self.newCard();
        _ = try card.add(self.text(section.title, true, 0xF1EFF8));
        _ = try card.add(self.text(section.description, false, 0x9A94B5));
        for (section.applications, 0..) |application, application_index| {
            const index = registry.globalIndex(section_index, application_index);
            var application_row = quark.widget.Row.init(self.allocator, .{
                .spacing = 12,
                .padding = 10,
                .alignment = .center,
                .background_color = quark.Theme.hex(0x252132),
                .border_radius = 8,
            });
            _ = try application_row.add(.{ .checkbox = quark.widget.CheckBox.init(.{
                .text = application.name,
                .checked = self.selected[index],
                .on_action = try self.bindValue(index, toggleApplication),
            }) });
            var details = quark.widget.Column.init(self.allocator, .{
                .spacing = 4,
                .alignment = .stretch,
            });
            _ = try details.add(self.text(application.description, false, 0xBBB6CF));
            _ = try details.add(self.text(application.package.backend.label(), false, 0x817AA3));
            _ = try application_row.addWithWidthConstraint(.{ .column = details }, quark.Size.proportional(1));
            _ = try application_row.add(self.text(
                if (self.installed[index]) "Installed" else "Available",
                self.installed[index],
                if (self.installed[index]) 0x72D6A0 else 0x817AA3,
            ));
            _ = try card.add(.{ .row = application_row });
        }
        return .{ .column = card };
    }

    fn reviewView(self: *App) !quark.Widget {
        var content = quark.widget.Column.init(self.allocator, .{
            .spacing = 14,
            .padding = 4,
            .alignment = .stretch,
        });
        _ = try content.add(try self.noticeCard(
            "Shelly will show a graphical authorization request for system packages.",
            0x282344,
        ));
        for (self.selected, self.installed, 0..) |selected, installed, index| {
            if (!selected or installed) continue;
            const application = registry.applicationAt(index).?;
            var row = quark.widget.Row.init(self.allocator, .{
                .spacing = 12,
                .padding = 14,
                .alignment = .center,
                .background_color = quark.Theme.hex(0x211D2C),
                .border_radius = 8,
            });
            _ = try row.add(self.text(application.name, true, 0xF1EFF8));
            _ = try row.add(.{ .spacer = quark.widget.Spacer.flexible() });
            _ = try row.add(self.text(application.package.name, false, 0xBBB6CF));
            _ = try row.add(self.text(application.package.backend.label(), false, 0x817AA3));
            _ = try content.add(.{ .row = row });
        }
        return .{ .column = content };
    }

    fn installingView(self: *App) !quark.Widget {
        var card = self.newCard();
        _ = try card.add(self.text("Installing your applications", true, 0xF1EFF8));
        _ = try card.add(self.text(self.statusText(), false, 0xBBB6CF));
        const progress_text = try std.fmt.allocPrint(self.allocator, "{d}% complete", .{self.percent});
        defer self.allocator.free(progress_text);
        _ = try card.add(self.text(progress_text, false, 0x8F82D8));
        _ = try card.add(self.text(
            "You may keep using Aqueous while this finishes. Closing this window waits for the active transaction instead of interrupting the package database.",
            false,
            0x817AA3,
        ));
        return .{ .column = card };
    }

    fn resultsView(self: *App) !quark.Widget {
        var content = quark.widget.Column.init(self.allocator, .{
            .spacing = 12,
            .padding = 4,
            .alignment = .stretch,
        });
        _ = try content.add(self.text("Setup results", true, 0xF1EFF8));
        for (self.results, 0..) |result, index| {
            if (result == .none) continue;
            const application = registry.applicationAt(index).?;
            var row = quark.widget.Row.init(self.allocator, .{
                .spacing = 12,
                .padding = 14,
                .alignment = .center,
                .background_color = quark.Theme.hex(0x211D2C),
                .border_radius = 8,
            });
            _ = try row.add(self.text(application.name, true, 0xF1EFF8));
            _ = try row.add(.{ .spacer = quark.widget.Spacer.flexible() });
            _ = try row.add(self.text(resultLabel(result), true, resultColor(result)));
            _ = try content.add(.{ .row = row });
        }
        return .{ .column = content };
    }

    fn footerView(self: *App) !quark.Widget {
        var row = quark.widget.Row.init(self.allocator, .{
            .spacing = 10,
            .alignment = .center,
        });
        switch (self.screen) {
            .loading => _ = try row.add(self.text("This only reads Shelly's installed-package lists.", false, 0x817AA3)),
            .customize => {
                _ = try row.add(self.button("Skip for now", quark.action.bind(self, skip), false));
                _ = try row.add(.{ .spacer = quark.widget.Spacer.flexible() });
                _ = try row.add(self.button("Continue", quark.action.bind(self, showSelection), true));
            },
            .selection => {
                _ = try row.add(self.button("Back", quark.action.bind(self, showCustomize), false));
                _ = try row.add(self.button("Skip for now", quark.action.bind(self, skip), false));
                _ = try row.add(.{ .spacer = quark.widget.Spacer.flexible() });
                const count = install_plan.selectedCount(self.selected, self.installed);
                const count_text = try std.fmt.allocPrint(self.allocator, "{d} selected", .{count});
                defer self.allocator.free(count_text);
                _ = try row.add(self.text(count_text, false, 0x9A94B5));
                if (count != 0) {
                    _ = try row.add(self.button("Review", quark.action.bind(self, showReview), true));
                }
            },
            .review => {
                _ = try row.add(self.button("Back", quark.action.bind(self, showSelection), false));
                _ = try row.add(.{ .spacer = quark.widget.Spacer.flexible() });
                _ = try row.add(self.button("Install selected", quark.action.bind(self, install), true));
            },
            .installing => {
                _ = try row.add(self.text("Installation is managed by Shelly.", false, 0x817AA3));
            },
            .results => {
                _ = try row.add(self.button("Choose more apps", quark.action.bind(self, chooseMore), false));
                if (self.hasFailures()) {
                    _ = try row.add(self.button("Retry failed", quark.action.bind(self, retryFailed), false));
                }
                _ = try row.add(.{ .spacer = quark.widget.Spacer.flexible() });
                _ = try row.add(self.button("Finish", quark.action.bind(self, finish), true));
            },
        }
        return .{ .row = row };
    }

    fn noticeCard(self: *App, message: []const u8, color: u32) !quark.Widget {
        var notice = quark.widget.Column.init(self.allocator, .{
            .spacing = 4,
            .padding = 14,
            .alignment = .stretch,
            .background_color = quark.Theme.hex(color),
            .border_radius = 8,
        });
        _ = try notice.add(self.text(message, false, 0xE4DFF1));
        return .{ .column = notice };
    }

    fn newCard(self: *App) quark.widget.Column {
        return quark.widget.Column.init(self.allocator, .{
            .spacing = 10,
            .padding = 16,
            .alignment = .stretch,
            .background_color = quark.Theme.hex(0x1E1A28),
            .border_radius = 10,
        });
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

    fn button(self: *App, label: []const u8, handler: quark.action.Handler, primary: bool) quark.Widget {
        return .{ .button = quark.widget.Button.init(.{
            .content = .{ .text = quark.widget.Text.init(self.allocator, .{ .text = label }) },
            .theme = .{
                .color = quark.Theme.hex(if (primary) 0x5141A6 else 0x292438),
                .focus_color = quark.Theme.hex(if (primary) 0x6757BD else 0x39324B),
                .height = quark.Size.fixed(40),
            },
            .on_action = handler,
        }) };
    }

    fn bindValue(self: *App, value: u64, comptime handler: anytype) !quark.action.Handler {
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

    fn toggleApplication(self: *App, raw_index: u64, action: quark.Action) !void {
        if (action != .toggle or raw_index >= registry.application_count) return;
        const index: usize = @intCast(raw_index);
        if (self.installed[index]) {
            self.selected[index] = false;
            self.needs_rebuild = true;
            return;
        }
        self.selected[index] = action.toggle;
        self.needs_rebuild = true;
    }

    fn showReview(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        if (!shelly.isAvailable(self.allocator, self.io, shelly_path)) {
            self.setStatus("Shelly is not available at /usr/bin/shelly. Install Shelly before continuing.");
            self.needs_rebuild = true;
            return;
        }
        self.screen = .review;
        self.needs_rebuild = true;
    }

    fn showSelection(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        self.screen = .selection;
        self.needs_rebuild = true;
    }

    fn showCustomize(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        self.screen = .customize;
        self.needs_rebuild = true;
    }

    fn chooseThemeMode(self: *App, raw_index: u64, action: quark.Action) !void {
        if (action != .click or raw_index > 2 or !self.noctalia_state.available) return;
        const mode: noctalia.ThemeMode = switch (raw_index) {
            0 => .dark,
            1 => .light,
            else => .auto,
        };
        self.runtime.mutex.lock();
        self.runtime.noctalia_state.theme_mode = mode;
        self.runtime.mutex.unlock();
        self.queueChange(.{ .theme_mode = mode });
        self.needs_rebuild = true;
    }

    fn choosePaletteSource(self: *App, action: quark.Action) !void {
        if (action != .select_index or !self.noctalia_state.available) return;
        const source: noctalia.Source = if (action.select_index == 0) .builtin else .wallpaper;
        const items: []const []const u8 = if (source == .wallpaper)
            noctalia.wallpaper_schemes
        else
            noctalia.builtin_palettes;
        const current = self.noctalia_state.paletteName();
        const name = if (self.noctalia_state.source == source and
            indexOfItem(items, current) != null)
            current
        else
            items[0];
        self.applyPalette(source, name);
    }

    fn choosePalette(self: *App, action: quark.Action) !void {
        if (action != .select_index or !self.noctalia_state.available) return;
        const items = self.paletteItems();
        if (action.select_index >= items.len) return;
        const source: noctalia.Source = if (self.noctalia_state.source == .wallpaper)
            .wallpaper
        else
            .builtin;
        self.applyPalette(source, items[action.select_index]);
    }

    fn applyPalette(self: *App, source: noctalia.Source, name: []const u8) void {
        var change: CustomChange = .{ .palette = .{ .source = source } };
        change.palette.len = @min(name.len, change.palette.name.len);
        @memcpy(change.palette.name[0..change.palette.len], name[0..change.palette.len]);
        self.runtime.mutex.lock();
        self.runtime.noctalia_state.source = source;
        self.runtime.noctalia_state.palette = @splat(0);
        self.runtime.noctalia_state.palette_len = change.palette.len;
        @memcpy(
            self.runtime.noctalia_state.palette[0..change.palette.len],
            name[0..change.palette.len],
        );
        self.runtime.mutex.unlock();
        self.queueChange(change);
        self.needs_rebuild = true;
    }

    fn chooseWallpaper(self: *App, action: quark.Action) !void {
        if (action != .select_index or !self.noctalia_state.available) return;
        if (action.select_index >= self.wallpapers.len) return;
        const name = self.wallpapers[action.select_index];
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ wallpaper_directory, name },
        );
        defer self.allocator.free(path);
        var change: CustomChange = .{ .wallpaper = .{} };
        change.wallpaper.len = @min(path.len, change.wallpaper.path.len);
        @memcpy(change.wallpaper.path[0..change.wallpaper.len], path[0..change.wallpaper.len]);
        self.runtime.mutex.lock();
        self.runtime.noctalia_state.wallpaper = @splat(0);
        self.runtime.noctalia_state.wallpaper_len = change.wallpaper.len;
        @memcpy(
            self.runtime.noctalia_state.wallpaper[0..change.wallpaper.len],
            path[0..change.wallpaper.len],
        );
        self.runtime.mutex.unlock();
        self.queueChange(change);
        self.needs_rebuild = true;
    }

    fn queueChange(self: *App, change: CustomChange) void {
        self.runtime.mutex.lock();
        self.runtime.pending_change = change;
        const spawn_needed = !self.runtime.custom_running;
        if (spawn_needed) self.runtime.custom_running = true;
        self.runtime.revision += 1;
        self.runtime.mutex.unlock();
        if (!spawn_needed) return;
        self.custom_worker = std.Thread.spawn(.{}, customWorker, .{self.runtime}) catch {
            self.runtime.mutex.lock();
            self.runtime.custom_running = false;
            self.runtime.pending_change = null;
            self.runtime.setStatusLocked("Unable to start the Noctalia worker.");
            self.runtime.revision += 1;
            self.runtime.mutex.unlock();
            return;
        };
    }

    fn install(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        self.startInstall() catch {
            self.setStatus("Unable to start the Shelly installation worker.");
            self.screen = .selection;
            self.needs_rebuild = true;
        };
    }

    fn chooseMore(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        self.selected = @splat(false);
        self.screen = .selection;
        self.needs_rebuild = true;
    }

    fn retryFailed(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        self.selected = @splat(false);
        for (self.results, 0..) |result, index| {
            if (result == .failed and !self.installed[index]) self.selected[index] = true;
        }
        self.screen = .review;
        self.needs_rebuild = true;
    }

    fn finish(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        first_run.markComplete(self.allocator, self.io, self.environ) catch {
            self.setStatus("Applications are installed, but setup completion could not be saved.");
            self.needs_rebuild = true;
            return;
        };
        self.window.close();
    }

    fn skip(self: *App, action: quark.Action) !void {
        if (action != .click) return;
        first_run.markComplete(self.allocator, self.io, self.environ) catch {};
        self.window.close();
    }

    fn hasFailures(self: *const App) bool {
        for (self.results) |result| if (result == .failed) return true;
        return false;
    }
};

fn discoveryWorker(runtime: *Runtime) void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var noctalia_state: noctalia.State = .{};
    noctalia.readState(allocator, io, noctalia_path, &noctalia_state) catch {};

    if (!shelly.isAvailable(allocator, io, shelly_path)) {
        runtime.mutex.lock();
        runtime.noctalia_state = noctalia_state;
        runtime.mode = .unavailable;
        runtime.setStatusLocked("Shelly is not available at /usr/bin/shelly. Install Shelly before continuing.");
        runtime.revision += 1;
        runtime.mutex.unlock();
        return;
    }

    var installed: shelly.Installed = @splat(false);
    shelly.discoverInstalled(allocator, io, shelly_path, &installed) catch {
        runtime.mutex.lock();
        runtime.noctalia_state = noctalia_state;
        runtime.installed = installed;
        runtime.mode = .ready;
        runtime.setStatusLocked("Some installed applications could not be detected; you can still continue.");
        runtime.revision += 1;
        runtime.mutex.unlock();
        return;
    };
    runtime.mutex.lock();
    runtime.noctalia_state = noctalia_state;
    runtime.installed = installed;
    runtime.mode = .ready;
    runtime.setStatusLocked("Choose the applications you would like to add.");
    runtime.revision += 1;
    runtime.mutex.unlock();
}

fn customWorker(runtime: *Runtime) void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    while (true) {
        runtime.mutex.lock();
        const change = runtime.pending_change;
        if (change == null) {
            runtime.custom_running = false;
            runtime.mutex.unlock();
            return;
        }
        runtime.pending_change = null;
        runtime.mutex.unlock();

        const applied = switch (change.?) {
            .theme_mode => |mode| noctalia.setThemeMode(allocator, io, noctalia_path, mode),
            .palette => |palette| noctalia.setColorScheme(
                allocator,
                io,
                noctalia_path,
                palette.source,
                palette.name[0..palette.len],
            ),
            .wallpaper => |wallpaper| noctalia.setWallpaper(
                allocator,
                io,
                noctalia_path,
                wallpaper.path[0..wallpaper.len],
            ),
        };
        applied catch {
            runtime.updateStatus("Noctalia did not apply the last change.", 0);
        };
    }
}

fn installWorker(runtime: *Runtime) void {
    const allocator = std.heap.page_allocator;
    runtime.mutex.lock();
    const selection = runtime.selection;
    const installed_before = runtime.installed;
    runtime.mutex.unlock();

    runBatch(runtime, allocator, selection, installed_before, .standard);
    runBatch(runtime, allocator, selection, installed_before, .aur);

    for (selection, installed_before, 0..) |selected, installed, index| {
        const application = registry.applicationAt(index).?;
        if (!selected or installed or application.package.backend != .flatpak) continue;
        setResult(runtime, index, .running, application.name);
        const argv = install_plan.buildFlatpakArgv(allocator, shelly_path, application) catch {
            setResult(runtime, index, .failed, "Could not prepare the Flatpak transaction.");
            continue;
        };
        defer allocator.free(argv);
        const success = shelly.runInstall(allocator, argv, .{
            .context = runtime,
            .function = progressCallback,
        }) catch false;
        setResult(runtime, index, if (success) .succeeded else .failed, application.name);
    }

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var installed_after = installed_before;
    const refreshed = refreshed: {
        shelly.discoverInstalled(
            allocator,
            threaded.io(),
            shelly_path,
            &installed_after,
        ) catch break :refreshed false;
        break :refreshed true;
    };

    runtime.mutex.lock();
    runtime.installed = installed_after;
    if (refreshed) {
        for (&runtime.results, installed_after) |*result, is_installed| {
            if (result.* == .failed and is_installed) result.* = .succeeded;
            if (result.* == .succeeded and !is_installed) result.* = .failed;
        }
    }
    runtime.mode = .complete;
    runtime.percent = 100;
    runtime.setStatusLocked("Application setup is complete.");
    runtime.revision += 1;
    runtime.mutex.unlock();
}

fn runBatch(
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    selection: install_plan.Selection,
    installed: shelly.Installed,
    backend: catalog.Backend,
) void {
    if (install_plan.backendCount(selection, installed, backend) == 0) return;
    setBackendResults(runtime, selection, installed, backend, .running);
    runtime.updateStatus(if (backend == .standard)
        "Installing repository applications…"
    else
        "Building and installing AUR applications…", 0);

    const argv = install_plan.buildBatchArgv(
        allocator,
        shelly_path,
        selection,
        installed,
        backend,
    ) catch {
        setBackendResults(runtime, selection, installed, backend, .failed);
        return;
    };
    defer allocator.free(argv);
    const success = shelly.runInstall(allocator, argv, .{
        .context = runtime,
        .function = progressCallback,
    }) catch false;
    setBackendResults(runtime, selection, installed, backend, if (success) .succeeded else .failed);
}

fn setBackendResults(
    runtime: *Runtime,
    selection: install_plan.Selection,
    installed: shelly.Installed,
    backend: catalog.Backend,
    result: Result,
) void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    for (selection, installed, 0..) |selected, is_installed, index| {
        if (selected and !is_installed and
            registry.applicationAt(index).?.package.backend == backend)
        {
            runtime.results[index] = result;
        }
    }
    runtime.revision += 1;
}

fn setResult(runtime: *Runtime, index: usize, result: Result, message: []const u8) void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    runtime.results[index] = result;
    runtime.setStatusLocked(message);
    runtime.revision += 1;
}

fn progressCallback(context: *anyopaque, progress: protocol.Progress) void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    runtime.updateStatus(progress.text(), progress.percent);
}

fn resultLabel(result: Result) []const u8 {
    return switch (result) {
        .none => "",
        .pending => "Pending",
        .running => "Installing",
        .succeeded => "Installed",
        .failed => "Failed",
    };
}

fn resultColor(result: Result) u32 {
    return switch (result) {
        .succeeded => 0x72D6A0,
        .failed => 0xF28B9A,
        else => 0x9A94B5,
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const first_run_only = for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--first-run")) break true;
    } else false;
    if (first_run_only and !first_run.isAqueousDesktop(init.environ_map)) return;
    if (first_run_only and first_run.isComplete(init.gpa, init.io, init.environ_map)) return;

    var window = try quark.Parent.init(
        "Welcome to Aqueous",
        "1.0.0",
        "org.aqueous.Welcome",
        1040,
        760,
        .{
            .font_size = 17,
            .window_color = quark.Theme.hex(0x15121D),
        },
    );
    defer window.deinit();

    var app = try App.init(window.allocator, init.io, init.environ_map, &window);
    defer app.deinit();
    try app.setLayout();
    try app.startDiscovery();

    while (window.update()) |_| {
        app.tick();
        if (app.needs_rebuild) {
            app.needs_rebuild = false;
            try app.setLayout();
        }
    }
}
