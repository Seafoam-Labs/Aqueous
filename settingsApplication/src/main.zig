const std = @import("std");
const q = @import("quark");
const app_mod = @import("app.zig");
const shells = @import("services/shell_adapter.zig");
const preferences = @import("services/preferences.zig");
const instance = @import("services/instance.zig");
var active: ?*app_mod.App = null;
fn render(_: *q.Parent) !void {
    if (active) |app| try app.drawCanvas();
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var shell: []const u8 = "auto";
    var page: usize = 0;
    var explicit_page = false;
    var smoke = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Aqueous Settings\nUsage: aqueous-settings [--page overview|appearance|layouts|input|displays|rules|keybinds|advanced] [--shell auto|dms|noctalia|none]\n", .{});
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("aqueous-settings 0.1.0\n", .{});
            return;
        }
        if (std.mem.eql(u8, arg, "--smoke-test")) {
            smoke = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        i += 1;
        if (std.mem.eql(u8, arg, "--shell")) {
            shell = args[i];
            if (!std.mem.eql(u8, shell, "auto") and !std.mem.eql(u8, shell, "none") and !std.mem.eql(u8, shell, "dms") and !std.mem.eql(u8, shell, "noctalia")) return error.UnknownShell;
        } else if (std.mem.eql(u8, arg, "--page")) {
            explicit_page = true;
            var found = false;
            for (app_mod.pages, 0..) |name, p| if (std.mem.eql(u8, name, args[i])) {
                page = p;
                found = true;
                break;
            };
            if (!found) return error.UnknownPage;
        } else if (std.mem.eql(u8, arg, "--sync-dms")) {
            try shells.syncDms(a, args[i]);
            var out = std.Io.File.stdout().writer(init.io, &.{});
            try out.interface.writeAll("DMS saved: family, weight and normal text size synchronized. Exact face, slant, width and separate bar scales remain partial.\n");
            return;
        } else return error.UnknownArgument;
    }
    const prefs_path = try preferences.path(a, init.environ_map);
    const prefs = preferences.load(a, init.io, prefs_path);
    if (!explicit_page) page = prefs.page;
    const runtime = init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
    const display = init.environ_map.get("WAYLAND_DISPLAY") orelse "wayland-0";
    if (!smoke) {
        const mode = instance.aq_instance_start(try a.dupeZ(u8, runtime), try a.dupeZ(u8, display), @intCast(page));
        if (mode == 1) {
            instance.activate(a) catch |err| std.log.warn("Settings is already open; activation: {s}", .{@errorName(err)});
            return;
        }
        if (mode < 0) return error.InstanceEndpointUnavailable;
    }
    defer if (!smoke) instance.aq_instance_close();
    if (std.mem.eql(u8, shell, "auto")) shell = try shells.detect(a);
    const state = init.environ_map.get("XDG_STATE_HOME") orelse try std.fs.path.join(a, &.{ init.environ_map.get("HOME") orelse return error.MissingHome, ".local/state" });
    const backup = try std.fs.path.join(a, &.{ state, "aqueous/settings-application/backups" });
    var themes = try @import("services/theme/service.zig").Service.init(init.io, init.environ_map);
    defer themes.deinit();
    var window = try q.Parent.init("Aqueous Settings", "0.1.0", "org.aqueous.Settings", prefs.width, prefs.height, .{ .font_size = 16 });
    var app = app_mod.App.init(&window, init.io, shell, backup, page);
    defer app.deinit();
    defer window.deinit();
    app.inspect_path = init.environ_map.get("AQUEOUS_SETTINGS_TEST_INSPECT") orelse "";
    app.themes = &themes;
    app.theme_choice = prefs.theme_source;
    app.prefs_path = prefs_path;
    try app.applyTheme(.{}, @splat(null), false);
    try app.selectTheme();
    active = &app;
    defer active = null;
    window.pre_render = render;
    try app.model.clear();
    try app.load();
    try app.build();
    var frames: usize = 0;
    var ready_frame: ?usize = null;
    while (!app.quitting) {
        if (window.update() == null) {
            if (!window.state.platform.running) {
                app.closeRequested();
                if (!app.quitting) {
                    window.state.platform.running = true;
                    window.state.platform.handle.linux.window_state.running = true;
                }
            } else return error.RenderingFailed;
        }
        if (!smoke) {
            const target = instance.aq_instance_poll();
            if (target >= 0) {
                app.page = @intCast(target);
                app.search = "";
                app.rendered_search = "";
                app.search_due = 0;
                app.highlight = "";
                app.rebuilt = true;
            }
        }
        try app.tick();
        frames += 1;
        if (smoke and frames > 20 and !app.client.busy() and ready_frame == null) {
            if (app.model.snapshot == .null) return error.SnapshotNotLoaded;
            for (window.state.textfields.items) |field| {
                if (!std.math.isFinite(field.rect.x) or !std.math.isFinite(field.rect.y) or !std.math.isFinite(field.rect.width) or !std.math.isFinite(field.rect.height)) return error.InvalidWidgetGeometry;
            }
            std.debug.print("AQUEOUS_SETTINGS_READY\n", .{});
            ready_frame = frames;
        }
        if (ready_frame) |f| {
            if (frames > f + 75) break;
        }
    }
    if (!smoke) app.savePreferences() catch |err| std.log.warn("Unable to save window preferences: {s}", .{@errorName(err)});
    if (smoke and app.model.snapshot == .null) return error.SnapshotNotLoaded;
}
