const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const first_run = @import("first_run.zig");
const registry = @import("sections.zig");
const options = @import("build_options");
const a = std.heap.c_allocator;

const State = struct {
    app: *gtk.Application,
    window: ?*gtk.Window = null,
    page: *gtk.Box = undefined,
    status: *gtk.Label = undefined,
    progress: *gtk.ProgressBar = undefined,
    log_label: *gtk.Label = undefined,
    history: std.ArrayList(u8) = .empty,
    next: *gtk.Button = undefined,
    cancel: *gtk.Button = undefined,
    shells: [4]*gtk.CheckButton = undefined,
    apps: [registry.application_count]*gtk.CheckButton = undefined,
    worker: ?*gio.Subprocess = null,
    pending: std.ArrayList(u8) = .empty,
    terminal: bool = false,
    dialog: ?*gtk.Window = null,
    password: ?*gtk.PasswordEntry = null,
    request_id: []const u8 = "",
    choices: std.ArrayList(Choice) = .empty,
    helper: [:0]const u8,
    chooser: bool = false,
    source_lines: std.ArrayList([:0]const u8) = .empty,
    message: ?[:0]const u8 = null,
    selected_source: ?*gtk.DropDown = null,

    fn text(self: *State, value: []const u8) void {
        self.history.appendSlice(a, value) catch return;
        self.history.append(a, '\n') catch return;
        if (self.history.items.len > 64 * 1024) {
            const excess = self.history.items.len - 64 * 1024;
            const boundary = if (std.mem.indexOfScalarPos(u8, self.history.items, excess, '\n')) |end| end + 1 else self.history.items.len;
            const remaining = self.history.items.len - boundary;
            std.mem.copyForwards(u8, self.history.items[0..remaining], self.history.items[boundary..]);
            self.history.shrinkRetainingCapacity(remaining);
        }
        const log = a.dupeZ(u8, self.history.items) catch return;
        defer a.free(log);
        self.log_label.setText(log);
        const z = a.dupeZ(u8, if (value.len > 512) "See setup details below." else value) catch return;
        defer a.free(z);
        self.status.setText(z);
    }
    fn response(self: *State, value: anytype) void {
        const encoded = std.json.Stringify.valueAlloc(a, value, .{}) catch return;
        defer {
            @memset(encoded, 0);
            a.free(encoded);
        }
        const line = std.fmt.allocPrint(a, "{s}\n", .{encoded}) catch return;
        defer {
            @memset(line, 0);
            a.free(line);
        }
        if (self.worker) |worker| {
            var err: ?*glib.Error = null;
            var written: usize = 0;
            _ = worker.getStdinPipe().?.writeAll(line.ptr, line.len, &written, null, &err);
            if (err) |e| {
                self.text("Could not send the response to setup.");
                e.free();
            }
        }
    }
    fn closeDialog(self: *State) void {
        if (self.dialog) |dialog| dialog.destroy();
        self.dialog = null;
        self.password = null;
        if (self.request_id.len != 0) a.free(self.request_id);
        self.request_id = "";
        self.choices.clearRetainingCapacity();
    }
    fn begin(self: *State, mode: enum { setup, inspect }) void {
        if (self.worker != null) return;
        const names = [_][]const u8{ "pearl", "dms", "noctalia", "none" };
        var selected: ?usize = null;
        for (self.shells, 0..) |button, i| if (button.getActive() != 0) {
            selected = i;
        };
        if (mode == .setup and selected == null) {
            self.text("Choose Pearl, DMS, Noctalia, or Nothing first.");
            return;
        }
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        defer argv.deinit(a);
        var owned: std.ArrayList([:0]u8) = .empty;
        defer {
            for (owned.items) |s| a.free(s);
            owned.deinit(a);
        }
        argv.appendSlice(a, &.{ self.helper.ptr, "--worker", @tagName(mode) }) catch return;
        if (mode == .setup) {
            argv.append(a, @ptrCast(names[selected.?].ptr)) catch return;
            for (self.apps, 0..) |button, i| {
                if (button.getActive() == 0) continue;
                const pkg = registry.applicationAt(i).?.package;
                const spec = std.fmt.allocPrintSentinel(a, "{s}:{s}", .{ @tagName(pkg.backend), pkg.name }, 0) catch return;
                owned.append(a, spec) catch return;
                argv.append(a, spec.ptr) catch return;
            }
        }
        argv.append(a, null) catch return;
        var err: ?*glib.Error = null;
        self.worker = gio.Subprocess.newv(@ptrCast(argv.items.ptr), .{ .stdin_pipe = true, .stdout_pipe = true }, &err);
        if (err) |e| {
            self.text(std.mem.span(e.f_message orelse "Cannot start setup"));
            e.free();
            return;
        }
        self.terminal = false;
        self.next.as(gtk.Widget).setSensitive(0);
        self.page.as(gtk.Widget).setSensitive(0);
        self.cancel.as(gtk.Widget).setSensitive(1);
        self.text("Checking installed packages and configuration…");
        self.app.as(gio.Application).hold();
        self.read();
    }
    fn read(self: *State) void {
        self.worker.?.getStdoutPipe().?.readBytesAsync(8192, 0, null, readDone, self);
    }
    fn event(self: *State, data: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{ .allocate = .alloc_always }) catch {
            self.text("Invalid setup response");
            return;
        };
        defer parsed.deinit();
        const root = parsed.value;
        const kind = string(root, "kind");
        const message = string(root, "message");
        if (std.mem.eql(u8, kind, "inspection")) {
            self.terminal = true;
            const current = string(root, "selected");
            const names = [_][]const u8{ "pearl", "dms", "noctalia", "none" };
            for (names, 0..) |name, i| if (std.mem.eql(u8, current, name)) self.shells[i].setActive(1);
            self.text(message);
        } else if (std.mem.eql(u8, kind, "review") or std.mem.eql(u8, kind, "question") or std.mem.eql(u8, kind, "password")) {
            self.prompt(root);
        } else {
            self.text(message);
            if (std.mem.eql(u8, kind, "done") or std.mem.eql(u8, kind, "error")) self.terminal = true;
            if (root == .object) if (root.object.get("percent")) |v| {
                if (v == .integer) self.progress.setFraction(@as(f64, @floatFromInt(std.math.clamp(v.integer, 0, 100))) / 100.0);
            };
        }
    }
    fn prompt(self: *State, value: std.json.Value) void {
        self.closeDialog();
        self.request_id = a.dupe(u8, string(value, "id")) catch return;
        const kind = string(value, "kind");
        const is_password = std.mem.eql(u8, kind, "password");
        const dialog = gtk.Window.new();
        self.dialog = dialog;
        dialog.setTitle(if (is_password) "Authenticate Shelly" else "Review setup");
        dialog.setTransientFor(self.window);
        dialog.setModal(1);
        dialog.setDefaultSize(560, if (is_password) 200 else 450);
        const box = gtk.Box.new(.vertical, 16);
        margins(box.as(gtk.Widget), 24);
        dialog.setChild(box.as(gtk.Widget));
        const label = labelText(string(value, "message"));
        box.append(label.as(gtk.Widget));
        if (is_password) {
            const entry = gtk.PasswordEntry.new();
            self.password = entry;
            entry.setShowPeekIcon(1);
            box.append(entry.as(gtk.Widget));
            _ = entry.as(gtk.Widget).grabFocus();
        } else if (value.object.get("event")) |event_value| {
            const detail = string(value, "details");
            const scroll = gtk.ScrolledWindow.new();
            scroll.as(gtk.Widget).setVexpand(1);
            scroll.setChild(labelText(detail).as(gtk.Widget));
            box.append(scroll.as(gtk.Widget));
            if (std.mem.eql(u8, string(event_value, "$kind"), "q.provider")) {
                if (event_value.object.get("Options")) |opts| if (opts == .array) {
                    for (opts.array.items) |opt| {
                        const name = a.dupeZ(u8, string(opt, "Name")) catch return;
                        defer a.free(name);
                        const button = gtk.CheckButton.newWithLabel(name);
                        if (self.choices.items.len != 0) button.setGroup(self.choices.items[0].button);
                        box.append(button.as(gtk.Widget));
                        const index = opt.object.get("Index") orelse continue;
                        if (index == .integer) self.choices.append(a, .{ .button = button, .index = index.integer }) catch return;
                    }
                };
            }
        }
        const row = gtk.Box.new(.horizontal, 12);
        const no = gtk.Button.newWithLabel("Cancel");
        const yes = gtk.Button.newWithLabel(if (is_password) "Authenticate" else "Continue");
        yes.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(no, *State, cancelPrompt, self, .{});
        _ = gtk.Button.signals.clicked.connect(yes, *State, acceptPrompt, self, .{});
        _ = gtk.Window.signals.close_request.connect(dialog, *State, closePrompt, self, .{});
        row.append(no.as(gtk.Widget));
        row.append(yes.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        dialog.setDefaultWidget(yes.as(gtk.Widget));
        dialog.present();
        if (options.test_hooks) if (glib.getenv("AQUEOUS_WELCOME_TEST_SETUP") != null) {
            _ = glib.timeoutAdd(250, testAnswer, self);
        };
    }
};
const Choice = struct { button: *gtk.CheckButton, index: i64 };
fn string(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const v = value.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}
fn margins(widget: *gtk.Widget, size: c_int) void {
    widget.setMarginTop(size);
    widget.setMarginBottom(size);
    widget.setMarginStart(size);
    widget.setMarginEnd(size);
}
fn labelText(text: []const u8) *gtk.Label {
    const z = a.dupeZ(u8, text) catch unreachable;
    defer a.free(z);
    const label = gtk.Label.new(z);
    label.setWrap(1);
    label.setXalign(0);
    return label;
}
fn acceptPrompt(_: *gtk.Button, self: *State) callconv(.c) void {
    if (self.password) |entry| {
        const password = std.mem.span(entry.as(gtk.Editable).getText());
        self.response(.{ .id = self.request_id, .password = password });
        entry.as(gtk.Editable).setText("");
    } else if (self.choices.items.len != 0) {
        var found = false;
        for (self.choices.items) |choice| if (choice.button.getActive() != 0) {
            self.response(.{ .id = self.request_id, .choice = choice.index });
            found = true;
        };
        if (!found) return;
    } else self.response(.{ .id = self.request_id, .accept = true });
    self.closeDialog();
}
fn testAnswer(data: ?*anyopaque) callconv(.c) c_int {
    const self: *State = @ptrCast(@alignCast(data.?));
    if (self.dialog == null) return 0;
    if (self.password) |entry| entry.as(gtk.Editable).setText("fixture-secret");
    if (self.choices.items.len != 0) self.choices.items[0].button.setActive(1);
    acceptPrompt(undefined, self);
    return 0;
}
fn cancelPrompt(_: *gtk.Button, self: *State) callconv(.c) void {
    self.response(.{ .cancel = true });
    self.closeDialog();
}
fn closePrompt(_: *gtk.Window, self: *State) callconv(.c) c_int {
    self.response(.{ .cancel = true });
    self.closeDialog();
    return 1;
}
fn readDone(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(data.?));
    var err: ?*glib.Error = null;
    const bytes = gobject.ext.cast(gio.InputStream, source.?).?.readBytesFinish(result, &err);
    defer if (bytes) |b| b.unref();
    defer if (err) |e| e.free();
    var count: usize = 0;
    const raw = if (bytes) |b| b.getData(&count) else null;
    if (count == 0) {
        self.worker.?.waitAsync(null, waited, self);
        return;
    }
    const chunk: [*]const u8 = @ptrCast(raw.?);
    self.pending.appendSlice(a, chunk[0..count]) catch return;
    if (self.pending.items.len > 1024 * 1024) {
        self.text("Setup response exceeded the limit.");
        self.response(.{ .cancel = true });
        self.pending.clearRetainingCapacity();
    }
    while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |end| {
        self.event(self.pending.items[0..end]);
        const rest = self.pending.items.len - end - 1;
        std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[end + 1 ..]);
        self.pending.shrinkRetainingCapacity(rest);
    }
    self.read();
}
fn waited(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(data.?));
    var err: ?*glib.Error = null;
    _ = self.worker.?.waitFinish(result, &err);
    if (err) |e| e.free();
    if (!self.terminal) self.text("Setup stopped unexpectedly. Reopen Review and set up to retry safely.");
    self.closeDialog();
    self.worker.?.unref();
    self.worker = null;
    self.next.as(gtk.Widget).setSensitive(1);
    self.page.as(gtk.Widget).setSensitive(1);
    self.cancel.as(gtk.Widget).setSensitive(0);
    self.app.as(gio.Application).release();
    if (options.test_hooks) if (glib.getenv("AQUEOUS_WELCOME_TEST_SETUP") != null) {
        _ = glib.timeoutAdd(400, smokeClose, self);
    };
}
fn start(_: *gtk.Button, self: *State) callconv(.c) void {
    self.begin(.setup);
}
fn cancel(_: *gtk.Button, self: *State) callconv(.c) void {
    self.response(.{ .cancel = true });
}
fn close(_: *gtk.Window, self: *State) callconv(.c) c_int {
    if (self.worker != null) {
        self.text("Use Cancel setup and wait for the active package transaction to finish before closing.");
        return 1;
    }
    return 0;
}
fn choose(_: *gtk.Button, self: *State) callconv(.c) void {
    const index = self.selected_source.?.getSelected();
    if (index < self.source_lines.items.len) glib.print("%s\n", self.source_lines.items[index].ptr);
    self.window.?.destroy();
}
fn smokeClose(data: ?*anyopaque) callconv(.c) c_int {
    const self: *State = @ptrCast(@alignCast(data.?));
    if (options.test_hooks) if (self.chooser) {
        if (glib.getenv("AQUEOUS_WELCOME_TEST_CHOOSE_INDEX")) |index| {
            self.selected_source.?.setSelected(std.fmt.parseInt(c_uint, std.mem.span(index), 10) catch 0);
            choose(undefined, self);
            return 0;
        }
    };
    self.window.?.close();
    return 0;
}
fn activate(_: *gio.Application, self: *State) callconv(.c) void {
    if (self.window) |window| {
        window.present();
        return;
    }
    const window = gtk.ApplicationWindow.new(self.app).as(gtk.Window);
    self.window = window;
    window.setTitle(if (self.chooser) "Select a source to share" else "Welcome to Aqueous");
    window.setDefaultSize(760, 700);
    const outer = gtk.Box.new(.vertical, 16);
    margins(outer.as(gtk.Widget), 24);
    window.setChild(outer.as(gtk.Widget));
    if (self.chooser) {
        outer.append(labelText("Select a source to share").as(gtk.Widget));
        var strings: std.ArrayList(?[*:0]const u8) = .empty;
        defer strings.deinit(a);
        for (self.source_lines.items) |line| strings.append(a, line.ptr) catch return;
        strings.append(a, null) catch return;
        const dropdown = gtk.DropDown.newFromStrings(@ptrCast(strings.items.ptr));
        self.selected_source = dropdown;
        outer.append(dropdown.as(gtk.Widget));
        const button = gtk.Button.newWithLabel("Share selected source");
        _ = gtk.Button.signals.clicked.connect(button, *State, choose, self, .{});
        outer.append(button.as(gtk.Widget));
    } else {
        const title = labelText("Make Aqueous yours");
        title.as(gtk.Widget).addCssClass("title-1");
        outer.append(title.as(gtk.Widget));
        outer.append(labelText("Choose one desktop. Shelly installs the packages and all optional dependencies; your choice takes effect at the next login.").as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.as(gtk.Widget).setVexpand(1);
        self.page = gtk.Box.new(.vertical, 12);
        scroll.setChild(self.page.as(gtk.Widget));
        outer.append(scroll.as(gtk.Widget));
        const titles = [_][*:0]const u8{ "Pearl — native GTK desktop for Aqueous", "DMS — Dank Material Shell", "Noctalia — desktop shell", "Nothing — use Aqueous without a desktop shell" };
        for (titles, 0..) |title_text, i| {
            self.shells[i] = gtk.CheckButton.newWithLabel(title_text);
            if (i != 0) self.shells[i].setGroup(self.shells[0]);
            self.page.append(self.shells[i].as(gtk.Widget));
        }
        const expander = gtk.Expander.new("Optional applications");
        const apps = gtk.Box.new(.vertical, 8);
        expander.setChild(apps.as(gtk.Widget));
        for (0..registry.application_count) |i| {
            const application = registry.applicationAt(i).?;
            const text = std.fmt.allocPrintSentinel(a, "{s} — {s}", .{ application.name, application.description }, 0) catch return;
            defer a.free(text);
            self.apps[i] = gtk.CheckButton.newWithLabel(text);
            apps.append(self.apps[i].as(gtk.Widget));
        }
        self.page.append(expander.as(gtk.Widget));
        self.status = labelText(if (self.message) |msg| msg else "Choose Nothing to use Aqueous without a desktop shell.");
        outer.append(self.status.as(gtk.Widget));
        const log_expander = gtk.Expander.new("Setup details");
        const log_scroll = gtk.ScrolledWindow.new();
        log_scroll.setMinContentHeight(120);
        log_scroll.setMaxContentHeight(180);
        self.log_label = labelText("");
        self.log_label.setSelectable(1);
        log_scroll.setChild(self.log_label.as(gtk.Widget));
        log_expander.setChild(log_scroll.as(gtk.Widget));
        outer.append(log_expander.as(gtk.Widget));
        self.progress = gtk.ProgressBar.new();
        outer.append(self.progress.as(gtk.Widget));
        const row = gtk.Box.new(.horizontal, 12);
        self.next = gtk.Button.newWithLabel("Review and set up");
        self.cancel = gtk.Button.newWithLabel("Cancel setup");
        self.cancel.as(gtk.Widget).setSensitive(0);
        self.next.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(self.next, *State, start, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.cancel, *State, cancel, self, .{});
        _ = gtk.Window.signals.close_request.connect(window, *State, close, self, .{});
        row.append(self.cancel.as(gtk.Widget));
        row.append(self.next.as(gtk.Widget));
        outer.append(row.as(gtk.Widget));
    }
    window.present();
    var auto_setup = false;
    if (options.test_hooks) if (glib.getenv("AQUEOUS_WELCOME_TEST_SETUP")) |selected| {
        const names = [_][]const u8{ "pearl", "dms", "noctalia", "none" };
        for (names, 0..) |name, i| if (std.mem.eql(u8, std.mem.span(selected), name)) {
            self.shells[i].setActive(1);
            auto_setup = true;
            self.begin(.setup);
        };
    };
    if (!auto_setup and !self.chooser and self.message == null) self.begin(.inspect);
    if (options.test_hooks) if (glib.getenv("AQUEOUS_WELCOME_TEST_CLOSE_MS")) |ms| {
        _ = glib.timeoutAdd(std.fmt.parseInt(c_uint, std.mem.span(ms), 10) catch 500, smokeClose, self);
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const executable = try std.process.executablePathAlloc(init.io, a);
    defer a.free(executable);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--worker"))
        std.process.exit(@import("setup.zig").run(init, executable, args[2..]));
    var first = false;
    var chooser = false;
    var message: ?[:0]const u8 = null;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--first-run")) first = true;
        if (std.mem.eql(u8, arg, "--choose")) chooser = true;
        if (std.mem.eql(u8, arg, "--message") and i + 1 < args.len) message = args[i + 1];
        if (std.mem.eql(u8, arg, "--help")) {
            glib.print("aqueous-welcome [--first-run | --choose | --message TEXT]\n");
            return;
        }
    }
    if (first and (!first_run.isAqueousDesktop(init.environ_map) or first_run.isComplete(a, init.io, init.environ_map))) return;
    const helper_path = try a.dupeZ(u8, executable);
    defer a.free(helper_path);
    const app = gtk.Application.new("org.aqueous.Welcome", .{ .non_unique = chooser });
    defer app.unref();
    var self: State = .{ .app = app, .helper = helper_path, .chooser = chooser, .message = message };
    defer {
        self.pending.deinit(a);
        self.history.deinit(a);
        self.choices.deinit(a);
        for (self.source_lines.items) |s| a.free(s);
        self.source_lines.deinit(a);
    }
    if (chooser) {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(a);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.Io.File.stdin().readStreaming(init.io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try buffer.appendSlice(a, chunk[0..n]);
            if (buffer.items.len > 1024 * 1024) return error.SourceListTooLarge;
        }
        var lines = std.mem.splitScalar(u8, buffer.items, '\n');
        while (lines.next()) |line| if (line.len != 0) {
            try self.source_lines.append(a, try a.dupeZ(u8, line));
        };
        if (self.source_lines.items.len == 0) return;
    }
    _ = gio.Application.signals.activate.connect(app.as(gio.Application), *State, activate, &self, .{});
    const result = app.as(gio.Application).run(0, null);
    if (result != 0) std.process.exit(@intCast(result));
}
