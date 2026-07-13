// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Read-only Aqueous-specific extension of ext_foreign_toplevel_handle_v1.
//! Each request returns a one-shot snapshot and retains no Window pointer.

const WindowInfoManager = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const aqueous = @import("wayland").server.aqueous;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;
const Window = @import("Window.zig");
const util = @import("util.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(manager: *WindowInfoManager) !void {
    manager.* = .{
        .global = try wl.Global.create(
            server.wl_server,
            aqueous.WindowInfoManagerV1,
            1,
            *WindowInfoManager,
            manager,
            bind,
        ),
    };
    server.wl_server.addDestroyListener(&manager.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const manager: *WindowInfoManager = @fieldParentPtr("server_destroy", listener);
    manager.global.destroy();
}

fn bind(client: *wl.Client, _: *WindowInfoManager, version: u32, id: u32) void {
    const resource = aqueous.WindowInfoManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(?*anyopaque, handleManagerRequest, null, null);
}

fn handleManagerRequest(
    resource: *aqueous.WindowInfoManagerV1,
    request: aqueous.WindowInfoManagerV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .get_window_info => |args| sendSnapshot(resource, args.id, args.toplevel),
        .destroy => {},
    }
}

fn sendSnapshot(
    manager: *aqueous.WindowInfoManagerV1,
    id: u32,
    foreign_resource: *@import("wayland").server.ext.ForeignToplevelHandleV1,
) void {
    const foreign = wlr.ExtForeignToplevelHandleV1.fromResource(@ptrCast(foreign_resource)) orelse {
        manager.postError(.invalid_toplevel, "foreign toplevel is not owned by Aqueous");
        return;
    };
    const window: *Window = @ptrCast(@alignCast(foreign.data orelse {
        manager.postError(.invalid_toplevel, "foreign toplevel is no longer mapped");
        return;
    }));

    const info = aqueous.WindowInfoV1.create(manager.getClient(), manager.getVersion(), id) catch {
        manager.getClient().postNoMemory();
        return;
    };
    info.setHandler(?*anyopaque, handleInfoRequest, null, null);

    const snapshot = window.infoSnapshot();
    info.sendBackend(switch (snapshot.backend) {
        .xdg => .xdg,
        .xwayland => .xwayland,
    });
    if (snapshot.app_id) |app_id| info.sendAppId(app_id);
    if (snapshot.class) |class| info.sendClass(class);
    if (snapshot.output) |output| info.sendOutput(output);
    if (snapshot.workspace != 0) info.sendWorkspace(snapshot.workspace);
    info.sendGeometry(
        snapshot.geometry.x,
        snapshot.geometry.y,
        snapshot.geometry.width,
        snapshot.geometry.height,
    );
    info.sendState(.{
        .focused = snapshot.focused,
        .floating = snapshot.floating,
        .fullscreen = snapshot.fullscreen,
        .maximized = snapshot.maximized,
        .minimized = snapshot.minimized,
        .visible = snapshot.visible,
    });
    info.sendLayout(snapshot.layout.ptr);

    const fingerprint = window.matchedRuleFingerprint();
    if (fingerprint != 0) {
        for (server.aqueous.rules.rules, 0..) |rule, index| {
            if (rule.matcherFingerprint() != fingerprint) continue;
            info.sendMatchedRule(@intCast(index + 1));
            if (rule.app_id) |pattern| sendRuleMatcher(info, .app_id, pattern);
            if (rule.class) |pattern| sendRuleMatcher(info, .class, pattern);
            if (rule.title) |pattern| sendRuleMatcher(info, .title, pattern);
            break;
        }
    }
    info.sendDone();
}

fn handleInfoRequest(
    _: *aqueous.WindowInfoV1,
    request: aqueous.WindowInfoV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => {},
    }
}

fn sendRuleMatcher(
    info: *aqueous.WindowInfoV1,
    matcher: aqueous.WindowInfoV1.Matcher,
    pattern: []const u8,
) void {
    const terminated = util.gpa.dupeZ(u8, pattern) catch {
        log.err("out of memory while publishing rule matcher", .{});
        return;
    };
    defer util.gpa.free(terminated);
    info.sendRuleMatcher(matcher, terminated.ptr);
}
