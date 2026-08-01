const std = @import("std");
const quark = @import("quark");
const catalog = @import("catalog.zig");
const registry = @import("sections.zig");
const install_plan = @import("install_plan.zig");
const shelly = @import("shelly_client.zig");
const protocol = @import("shelly_protocol.zig");
const first_run = @import("first_run.zig");

const shelly_path = "/usr/bin/shelly";

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

const Runtime = struct {
    mutex: Mutex = .{},
    mode: WorkerMode = .idle,
    revision: u64 = 0,
    installed: shelly.Installed = @splat(false),
    selection: install_plan.Selection = @splat(false),
    results: [registry.application_count]Result = @splat(.none),
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
    screen: Screen = .loading,
    installed: shelly.Installed = @splat(false),
    selected: install_plan.Selection = @splat(false),
    results: [registry.application_count]Result = @splat(.none),
    status: [256]u8 = @splat(0),
    status_len: usize = 0,
    percent: u8 = 0,
    seen_revision: u64 = 0,
    needs_rebuild: bool = false,
    callbacks: std.ArrayList(*Callback) = .empty,

    const Screen = enum { loading, selection, review, installing, results };
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
        app.setStatus("Checking installed applications…");
        return app;
    }

    fn deinit(self: *App) void {
        if (self.worker) |thread| thread.join();
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
        self.percent = self.runtime.percent;
        self.status_len = self.runtime.status_len;
        @memcpy(self.status[0..self.status_len], self.runtime.status[0..self.status_len]);
        const mode = self.runtime.mode;
        self.runtime.mutex.unlock();

        switch (mode) {
            .ready => if (self.screen == .loading) {
                self.screen = .selection;
            },
            .unavailable => self.screen = .selection,
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
            .selection => "1 · Choose applications",
            .review => "2 · Review",
            .installing => "3 · Installing",
            .results => "4 · Finished",
        };
    }

    fn loadingView(self: *App) !quark.Widget {
        var card = self.newCard();
        _ = try card.add(self.text("Looking at what is already installed", true, 0xF1EFF8));
        _ = try card.add(self.text(self.statusText(), false, 0xBBB6CF));
        return .{ .column = card };
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
            .selection => {
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
        if (action == .click) self.window.close();
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

    if (!shelly.isAvailable(allocator, io, shelly_path)) {
        runtime.mutex.lock();
        runtime.mode = .unavailable;
        runtime.setStatusLocked("Shelly is not available at /usr/bin/shelly. Install Shelly before continuing.");
        runtime.revision += 1;
        runtime.mutex.unlock();
        return;
    }

    var installed: shelly.Installed = @splat(false);
    shelly.discoverInstalled(allocator, io, shelly_path, &installed) catch {
        runtime.mutex.lock();
        runtime.mode = .ready;
        runtime.setStatusLocked("Some installed applications could not be detected; you can still continue.");
        runtime.revision += 1;
        runtime.mutex.unlock();
        return;
    };
    runtime.mutex.lock();
    runtime.installed = installed;
    runtime.mode = .ready;
    runtime.setStatusLocked("Choose the applications you would like to add.");
    runtime.revision += 1;
    runtime.mutex.unlock();
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
