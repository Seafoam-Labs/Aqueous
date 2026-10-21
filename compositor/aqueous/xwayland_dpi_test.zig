// SPDX-License-Identifier: GPL-3.0-only
// Standalone harness also re-execs itself as the real worker on private Xvfb.
const std = @import("std");
const dpi = @import("xwayland_dpi.zig");
const c = dpi.c;
const allocator = std.heap.c_allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const equalStrings = std.testing.expectEqualStrings;

fn unitTests() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();
    const original = "! keep this comment\nApp.color: blue\n Xft.dpi : 110\nApp.font: monospace\n";
    const saved = try dpi.resources(gpa, original, "", true);
    defer gpa.free(saved);
    try equalStrings(" Xft.dpi : 110\n", saved);
    var buffer: [64]u8 = undefined;
    const text = dpi.dpiText(&buffer, 120 * 1024 + 1023);
    try equalStrings("Xft.dpi: 120.9990234375\n", text);
    const changed = try dpi.resources(gpa, original, text, false);
    defer gpa.free(changed);
    try expect(std.mem.indexOf(u8, changed, "App.color: blue\n") != null);
    try expect(std.mem.indexOf(u8, changed, "App.font: monospace\n") != null);
    const restored = try dpi.resources(gpa, changed, saved, false);
    defer gpa.free(restored);
    try expect(std.mem.indexOf(u8, restored, " Xft.dpi : 110\n") != null);
    try expect(std.mem.indexOf(u8, restored, "120.") == null);
    try std.testing.expectError(error.ContinuedResource, dpi.resources(gpa, "App.text: continued\\\nvalue\n", "", false));
    var data: [64]u8 = undefined;
    try equal(@as(usize, 20), dpi.setting(&data, "Xft/DPI", 120 * 1024, 9));
    try equalStrings("\x00\x00\x07\x00Xft/DPI\x00\x09\x00\x00\x00\x00\xe0\x01\x00", data[0..20]);
    std.debug.print("PASS resource preservation, precise fractional DPI and XSettings framing\n", .{});
}

fn awaitStatus(supervisor: *dpi.Supervisor, value: u32, expected: dpi.State) !dpi.Status {
    const until = dpi.nowMs() + 9000;
    while (true) {
        const s = supervisor.tick(value);
        if (s.state == expected and (expected != .applied or s.dpi == value)) return s;
        if (dpi.nowMs() >= until) {
            std.debug.print("state={s} dpi={d} expected={s}/{d}\n", .{ @tagName(s.state), s.dpi, @tagName(expected), value });
            return error.Timeout;
        }
        _ = c.poll(null, 0, 20);
    }
}
fn expectProperty(w: *dpi.Worker, expected: []const u8) !void {
    const value = try w.property(w.resource);
    defer allocator.free(value);
    try equalStrings(expected, value);
}
fn integrationTests(display: [*:0]const u8) !void {
    const connection = c.xcb_connect(display, null) orelse return error.X11;
    defer c.xcb_disconnect(connection);
    try equal(@as(c_int, 0), c.xcb_connection_has_error(connection));
    var w: dpi.Worker = .{ .connection = connection, .root = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection)).data.*.root };
    w.selection = try w.atom("_XSETTINGS_S0");
    w.settings = try w.atom("_XSETTINGS_SETTINGS");
    const initial = "App.color: blue\nXft.dpi: 110\n";
    try w.put(w.root, w.resource, c.XCB_ATOM_STRING, initial);
    {
        const supervisor = try dpi.Supervisor.create(display);
        defer supervisor.destroy();
        var s: dpi.Status = .{};
        for ([_]u32{ 96, 120, 144, 192, 120 }) |value| {
            s = try awaitStatus(supervisor, value * 1024, .applied);
            const text = try w.property(w.resource);
            defer allocator.free(text);
            var buffer: [64]u8 = undefined;
            try expect(std.mem.indexOf(u8, text, dpi.dpiText(&buffer, value * 1024)) != null);
            try expect(std.mem.indexOf(u8, text, "App.color: blue\n") != null);
            const reply = c.xcb_get_property_reply(connection, c.xcb_get_property(connection, 0, try w.owner(), w.settings, w.settings, 0, 1024), null);
            try expect(reply != null);
            defer c.free(reply);
            try expect(reply.*.format == 8 and c.xcb_get_property_value_length(reply) >= 32);
            const bytes: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
            try equal(value * 1024, std.mem.readInt(u32, bytes[28..32], .little));
            try expect(bytes[0] == 0 and bytes[8] == 3);
        }
        std.debug.print("PASS live 100/125/150/200 percent DPI updates and revert\n", .{});
        _ = c.kill(s.pid, c.SIGKILL);
        _ = try awaitStatus(supervisor, 144 * 1024, .failed);
        s = try awaitStatus(supervisor, 144 * 1024, .applied);
        try expect(s.pid > 0);
    }
    try expectProperty(&w, initial);
    try equal(@as(u32, c.XCB_WINDOW_NONE), try w.owner());
    std.debug.print("PASS worker crash/restart and restoration of preexisting DPI\n", .{});

    try w.createWindow();
    const external = w.window;
    try w.checked(c.xcb_set_selection_owner_checked(connection, external, w.selection, c.XCB_CURRENT_TIME));
    {
        const supervisor = try dpi.Supervisor.create(display);
        defer supervisor.destroy();
        _ = try awaitStatus(supervisor, 192 * 1024, .external);
        try expectProperty(&w, initial);
        try equal(external, try w.owner());
        try w.checked(c.xcb_set_selection_owner_checked(connection, c.XCB_WINDOW_NONE, w.selection, c.XCB_CURRENT_TIME));
        _ = try awaitStatus(supervisor, 192 * 1024, .applied);
        try w.checked(c.xcb_set_selection_owner_checked(connection, external, w.selection, c.XCB_CURRENT_TIME));
        _ = try awaitStatus(supervisor, 192 * 1024, .external);
        try expectProperty(&w, initial);
    }
    try equal(external, try w.owner());
    std.debug.print("PASS existing owner, owner departure and ownership loss\n", .{});

    try w.checked(c.xcb_set_selection_owner_checked(connection, c.XCB_WINDOW_NONE, w.selection, c.XCB_CURRENT_TIME));
    const edited = "App.color: green\nXft.dpi: 133\n";
    {
        const supervisor = try dpi.Supervisor.create(display);
        defer supervisor.destroy();
        _ = try awaitStatus(supervisor, 120 * 1024, .applied);
        try w.put(w.root, w.resource, c.XCB_ATOM_STRING, edited);
    }
    try expectProperty(&w, edited);
    std.debug.print("PASS external resource edits survive cleanup\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "-xwayland-dpi-worker")) std.process.exit(dpi.run(args[2]));
    try unitTests();
    if (args.len > 1) try integrationTests(args[1]);
}
