// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const c = @import("c");
const wlr = @import("wlroots");
const Manager = @import("DrmLeaseManager.zig");
const wl = @import("wayland").server.wl;
extern fn aqueous_drm_test_reset(bool, bool) void;
extern fn aqueous_drm_test_output(c_int, bool) *wlr.Output;
extern fn aqueous_drm_test_destroy_output(*wlr.Output) void;
extern fn aqueous_drm_test_request(c_int, bool) void;
extern fn aqueous_drm_test_destroy_manager() void;
extern var aqueous_drm_test_offers: c_uint;
extern var aqueous_drm_test_grants: c_uint;
extern var aqueous_drm_test_rejects: c_uint;
extern var aqueous_drm_test_revokes: c_uint;
var active_manager: *Manager = undefined;
export fn aqueous_drm_test_reoffer(output: *wlr.Output) void {
    std.debug.assert(active_manager.reserve(output));
}
fn cleanupOutputs(manager: *Manager) void {
    while (manager.outputs.first()) |entry| aqueous_drm_test_destroy_output(entry.output);
}
fn setActive(session: *wlr.Session, active: bool) void {
    session.active = active;
    c.wl_signal_emit_mutable(@ptrCast(&session.events.active), null);
}

test "DRM manager: reserve, multi-device grants, lock/VT revocation, shutdown and reentry" {
    aqueous_drm_test_reset(false, false);
    const display = try wl.Server.create();
    defer display.destroy();
    var backend: wlr.Backend = undefined; // API double never dereferences it.
    var session: wlr.Session = undefined;
    session.active = true;
    c.wl_signal_init(@ptrCast(&session.events.active));
    c.wl_signal_init(@ptrCast(&session.events.destroy));
    var manager: Manager = .{};
    active_manager = &manager;
    manager.init(display, &backend, &session);
    const desktop = aqueous_drm_test_output(0, false);
    try std.testing.expect(!manager.reserve(desktop));
    aqueous_drm_test_destroy_output(desktop);
    const nested = aqueous_drm_test_output(-1, true);
    try std.testing.expect(!manager.reserve(nested));
    aqueous_drm_test_destroy_output(nested);
    for (0..2) |i| {
        const output = aqueous_drm_test_output(@intCast(i), true);
        output.enabled = true; // Discovery can inherit a previous scanout.
        try std.testing.expect(manager.reserve(output));
        try std.testing.expect(!output.enabled);
    }
    try std.testing.expectEqual(2, aqueous_drm_test_offers);
    aqueous_drm_test_request(0, true); // Must reject before touching invalid pointers.
    try std.testing.expectEqual(1, aqueous_drm_test_rejects);
    aqueous_drm_test_request(0, false);
    aqueous_drm_test_request(1, false);
    try std.testing.expectEqual(2, aqueous_drm_test_grants);
    try std.testing.expectEqual(0, manager.outputs.length());
    manager.setLocked(true);
    try std.testing.expectEqual(2, aqueous_drm_test_revokes);
    try std.testing.expectEqual(2, manager.outputs.length());
    try std.testing.expectEqual(2, aqueous_drm_test_offers); // Reentry cannot offer during lock acquisition.
    setActive(&session, false);
    manager.outputs.first().?.output.enabled = true;
    setActive(&session, true);
    try std.testing.expect(!manager.outputs.first().?.output.enabled);
    try std.testing.expectEqual(2, aqueous_drm_test_offers); // VT return cannot unlock.
    manager.setLocked(false);
    try std.testing.expectEqual(4, aqueous_drm_test_offers);
    manager.setLocked(false);
    try std.testing.expectEqual(4, aqueous_drm_test_offers); // No duplicate offers.
    aqueous_drm_test_request(0, false);
    setActive(&session, false);
    try std.testing.expectEqual(3, aqueous_drm_test_revokes);
    try std.testing.expectEqual(4, aqueous_drm_test_offers);
    setActive(&session, true);
    try std.testing.expectEqual(6, aqueous_drm_test_offers);
    aqueous_drm_test_request(0, false);
    manager.stop();
    try std.testing.expectEqual(4, aqueous_drm_test_revokes);
    try std.testing.expectEqual(6, aqueous_drm_test_offers);
    cleanupOutputs(&manager);
    manager.deinit();
    aqueous_drm_test_destroy_manager();
    try std.testing.expect(c.wl_list_empty(@ptrCast(&session.events.active.listener_list)) != 0);
    try std.testing.expect(c.wl_list_empty(@ptrCast(&session.events.destroy.listener_list)) != 0);
}

test "DRM manager: absent device and failed offers keep headsets reserved" {
    std.testing.log_level = .err; // A failed offer deliberately emits a warning.
    const display = try wl.Server.create();
    defer display.destroy();
    var backend: wlr.Backend = undefined;
    for ([_]bool{ true, false }) |missing| {
        aqueous_drm_test_reset(missing, !missing);
        var manager: Manager = .{};
        manager.init(display, &backend, null);
        const output = aqueous_drm_test_output(0, true);
        output.enabled = true;
        try std.testing.expect(manager.reserve(output));
        manager.state.active = true;
        manager.setLocked(false);
        try std.testing.expect(!output.enabled);
        try std.testing.expectEqual(1, manager.outputs.length());
        try std.testing.expectEqual(0, aqueous_drm_test_offers);
        manager.stop();
        cleanupOutputs(&manager);
        if (!missing) aqueous_drm_test_destroy_manager(); // Native destruction before wrapper deinit.
        manager.deinit();
    }
}
