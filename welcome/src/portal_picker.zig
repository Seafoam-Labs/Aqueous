//! Standalone dmenu-compatible source picker. No setup worker or shell selection.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const options = @import("build_options");
pub const aqueous_instance_name = options.instance_name;
const instance = @import("instance.zig");
const a = std.heap.c_allocator;

const State = struct {
    app: *gtk.Application,
    lines: std.ArrayList([:0]const u8) = .empty,
    window: ?*gtk.Window = null,
    selected: ?*gtk.DropDown = null,
};

fn choose(_: *gtk.Button, self: *State) callconv(.c) void {
    const index = self.selected.?.getSelected();
    if (index < self.lines.items.len) glib.print("%s\n", self.lines.items[index].ptr);
    self.window.?.destroy();
}

fn cancel(_: *gtk.Button, self: *State) callconv(.c) void {
    self.window.?.close();
}

fn key(_: *gtk.EventControllerKey, symbol: c_uint, _: c_uint, _: gdk.ModifierType, self: *State) callconv(.c) c_int {
    if (symbol != 0xff1b) return 0; // Escape cancels without writing a selection.
    self.window.?.close();
    return 1;
}

fn smokeClose(data: ?*anyopaque) callconv(.c) c_int {
    const self: *State = @ptrCast(@alignCast(data.?));
    if (options.test_hooks) if (glib.getenv("AQUEOUS_PICKER_TEST_CHOOSE_INDEX")) |index| {
        const value = std.fmt.parseInt(c_uint, std.mem.span(index), 10) catch std.math.maxInt(c_uint);
        if (value >= self.lines.items.len) {
            self.window.?.close();
            return 0;
        }
        self.selected.?.setSelected(value);
        choose(undefined, self);
        return 0;
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
    window.setTitle("Select a source to share");
    window.setDefaultSize(480, 160);
    const outer = gtk.Box.new(.vertical, 16);
    const widget = outer.as(gtk.Widget);
    widget.setMarginTop(24);
    widget.setMarginBottom(24);
    widget.setMarginStart(24);
    widget.setMarginEnd(24);
    window.setChild(widget);
    outer.append(gtk.Label.new("Select a source to share").as(gtk.Widget));
    var strings: std.ArrayList(?[*:0]const u8) = .empty;
    defer strings.deinit(a);
    for (self.lines.items) |line| strings.append(a, line.ptr) catch return;
    strings.append(a, null) catch return;
    const dropdown = gtk.DropDown.newFromStrings(@ptrCast(strings.items.ptr));
    self.selected = dropdown;
    outer.append(dropdown.as(gtk.Widget));
    const row = gtk.Box.new(.horizontal, 12);
    const cancel_button = gtk.Button.newWithLabel("Cancel");
    _ = gtk.Button.signals.clicked.connect(cancel_button, *State, cancel, self, .{});
    row.append(cancel_button.as(gtk.Widget));
    const share_button = gtk.Button.newWithLabel("Share selected source");
    _ = gtk.Button.signals.clicked.connect(share_button, *State, choose, self, .{});
    row.append(share_button.as(gtk.Widget));
    outer.append(row.as(gtk.Widget));
    const keys = gtk.EventControllerKey.new();
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *State, key, self, .{});
    window.as(gtk.Widget).addController(keys.as(gtk.EventController));
    window.present();
    if (options.test_hooks) if (glib.getenv("AQUEOUS_PICKER_TEST_CLOSE_MS")) |ms| {
        _ = glib.timeoutAdd(std.fmt.parseInt(c_uint, std.mem.span(ms), 10) catch 500, smokeClose, self);
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
            glib.print("aqueous-portal-picker: read source lines from stdin; print the selected line, or nothing on cancellation.\n");
            return;
        }
        return error.UnknownArgument;
    }
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.stdin().readStreaming(init.io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        if (buffer.items.len + n > 1024 * 1024) return error.SourceListTooLarge;
        if (std.mem.indexOfScalar(u8, chunk[0..n], 0) != null) return error.InvalidSource;
        try buffer.appendSlice(a, chunk[0..n]);
    }
    if (buffer.items.len == 0) return;
    const id = if (instance.suffix.len == 0) "org.aqueous.PortalPicker" else if (std.mem.eql(u8, instance.suffix, "-git")) "org.aqueous.Git.PortalPicker" else "org.aqueous.IntelGit.PortalPicker";
    const app = gtk.Application.new(id, .{ .non_unique = true });
    defer app.unref();
    var self: State = .{ .app = app };
    defer {
        for (self.lines.items) |line| a.free(line);
        self.lines.deinit(a);
    }
    var lines = std.mem.splitScalar(u8, buffer.items, '\n');
    while (lines.next()) |line| if (line.len != 0) {
        try self.lines.append(a, try a.dupeZ(u8, line));
    };
    if (self.lines.items.len == 0) return;
    _ = gio.Application.signals.activate.connect(app.as(gio.Application), *State, activate, &self, .{});
    const result = app.as(gio.Application).run(0, null);
    if (result != 0) std.process.exit(@intCast(result));
}
