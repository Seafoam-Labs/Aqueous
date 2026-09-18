// SPDX-License-Identifier: GPL-3.0-only
const Manager = @This();
const std = @import("std");
const wl = @import("wayland").server.wl;
const aq = @import("wayland").server.aqueous;
const wlr = @import("wlroots");
const util = @import("util.zig");
const policy = @import("input_activity.zig");
const server = &@import("main.zig").server;
const build_options = @import("build_options");
const Protocol = aq.InputActivityManagerV1;
const Subscription = aq.InputActivityV1;
const Inhibitor = aq.InputActivityInhibitorV1;
extern fn aq_activity_bootstrap_create([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn aq_activity_bootstrap_destroy(?*anyopaque) void;
extern fn aq_activity_bootstrap_tick(?*anyopaque) void;
extern fn aq_activity_claim(?*anyopaque, c_int, c_int) bool;
extern fn aq_activity_owner_alive(?*anyopaque) bool;
extern fn aq_activity_revoke(?*anyopaque) void;
extern fn aq_activity_test_owner(?*anyopaque, c_int) void;
extern fn wl_client_get_credentials(*wl.Client, *c_int, *u32, *u32) void;

pub const Category = policy.Category;
/// The benchmark bypass is compiled out of production; no public toggle.
pub inline fn observeInput() bool {
    return if (comptime build_options.input_activity_testing) @import("InputActivityTest.zig").observation_enabled else true;
}
global: ?*wl.Global = null,
timer: ?*wl.EventSource = null,
bootstrap: ?*anyopaque = null,
owner: ?*Binding = null,
subscription: ?*Sub = null,
bindings: usize = 0,
subscriptions: usize = 0,
inhibitors: usize = 0,
state: policy.State = .{},
session: ?*wlr.Session = null,
session_active: wl.Listener(void) = .init(activeChanged),
session_destroy: wl.Listener(*wlr.Session) = .init(sessionDestroyed),
test_active: bool = true,

const Binding = struct {
    manager: *Manager,
    resource: *Protocol,
    requests: u32 = 0,
    request_epoch: i64 = 0,
    fn admit(self: *Binding) bool {
        const time = now();
        if (time - self.request_epoch >= 1000) {
            self.request_epoch = time;
            self.requests = 0;
        }
        self.requests += 1;
        if (self.requests <= 64) return true;
        self.resource.getClient().postImplementationError("input activity request limit exceeded");
        return false;
    }
};
const Sub = struct {
    manager: *Manager,
    resource: *Subscription,
    binding: ?*Binding,
    inhibits: usize = 0,
    children: std.ArrayList(*Inhibit) = .empty,
    requests: u32 = 0,
    request_epoch: i64 = 0,
    fn admit(self: *Sub) bool {
        const time = now();
        if (time - self.request_epoch >= 1000) {
            self.request_epoch = time;
            self.requests = 0;
        }
        self.requests += 1;
        if (self.requests <= 64) return true;
        self.resource.getClient().postImplementationError("input activity request limit exceeded");
        return false;
    }
};
const Inhibit = struct { manager: *Manager, resource: *Inhibitor, sub: ?*Sub };
fn now() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
}
fn join(hi: u32, lo: u32) u64 {
    return (@as(u64, hi) << 32) | lo;
}
pub fn init(self: *Manager) !void {
    self.* = .{};
    self.timer = try server.wl_server.getEventLoop().addTimer(*Manager, tick, self);
    errdefer self.timer.?.remove();
    self.global = try wl.Global.create(server.wl_server, Protocol, 1, *Manager, self, bind);
    self.session = server.session;
    if (self.session) |session| {
        session.events.active.add(&self.session_active);
        session.events.destroy.add(&self.session_destroy);
    }
    try self.timer.?.timerUpdate(25);
}
pub fn start(self: *Manager, ipc: [:0]const u8) void {
    self.bootstrap = aq_activity_bootstrap_create(ipc, build_options.instance_name ++ "-pearl.service");
}
pub fn stop(self: *Manager) void {
    self.revoke();
    if (self.timer) |timer| timer.remove();
    self.timer = null;
    aq_activity_bootstrap_destroy(self.bootstrap);
    self.bootstrap = null;
    if (self.session != null) {
        self.session_active.link.remove();
        self.session_destroy.link.remove();
        self.session = null;
    }
}
fn bind(client: *wl.Client, self: *Manager, version: u32, id: u32) void {
    if (self.bindings >= 16) {
        client.postImplementationError("input activity manager limit exceeded");
        return;
    }
    const resource = Protocol.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const b = util.gpa.create(Binding) catch {
        resource.destroy();
        client.postNoMemory();
        return;
    };
    b.* = .{ .manager = self, .resource = resource };
    self.bindings += 1;
    resource.setHandler(*Binding, request, bindingDestroyed, b);
    resource.sendCapabilities(policy.interval_ms, 3);
}
fn request(resource: *Protocol, req: Protocol.Request, b: *Binding) void {
    const self = b.manager;
    // FDs must be closed even when admission fails.
    defer {
        if (req == .authorize) _ = std.c.close(req.authorize.capability);
    }
    if (req == .destroy) {
        resource.destroy();
        return;
    }
    if (!b.admit()) return;
    switch (req) {
        .destroy => unreachable,
        .authorize => |args| {
            var pid: c_int = 0;
            var uid: u32 = 0;
            var gid: u32 = 0;
            wl_client_get_credentials(resource.getClient(), &pid, &uid, &gid);
            if (self.owner == null and server.security_context_manager.lookupClient(resource.getClient()) == null and
                aq_activity_claim(self.bootstrap, args.capability, pid))
            {
                self.owner = b;
                resource.sendAuthorization(.available);
            } else resource.sendAuthorization(.permission_denied);
        },
        .get_subscription => |args| {
            if (self.subscriptions >= 16) {
                resource.getClient().postImplementationError("input activity subscription limit exceeded");
                return;
            }
            const sub_resource = Subscription.create(resource.getClient(), 1, args.id) catch {
                resource.postNoMemory();
                return;
            };
            const sub = util.gpa.create(Sub) catch {
                sub_resource.destroy();
                resource.postNoMemory();
                return;
            };
            const allowed = self.owner == b and self.subscription == null and aq_activity_owner_alive(self.bootstrap);
            sub.* = .{ .manager = self, .resource = sub_resource, .binding = if (allowed) b else null };
            self.subscriptions += 1;
            sub_resource.setHandler(*Sub, subRequest, subDestroyed, sub);
            if (allowed) {
                self.state.invalidate();
                self.subscription = sub;
                self.refresh();
            }
            self.sendState(sub, 0);
        },
    }
}
fn bindingDestroyed(_: *Protocol, b: *Binding) void {
    const self = b.manager;
    if (self.owner == b) self.revoke();
    self.bindings -= 1;
    util.gpa.destroy(b);
}
fn subRequest(resource: *Subscription, req: Subscription.Request, sub: *Sub) void {
    const self = sub.manager;
    if (req == .destroy) {
        resource.destroy();
        return;
    }
    if (!sub.admit()) return;
    if (sub.binding) |b| {
        if (!b.admit()) return;
    }
    // An inert subscription only accepts destructor and bounded inhibitor
    // creation (new_id must still become a valid inert object).
    if (req == .inhibit) {
        if (self.inhibitors >= 32) {
            resource.getClient().postImplementationError("input activity inhibitor limit exceeded");
            return;
        }
        const child_resource = Inhibitor.create(resource.getClient(), 1, req.inhibit.id) catch {
            resource.postNoMemory();
            return;
        };
        const child = util.gpa.create(Inhibit) catch {
            child_resource.destroy();
            resource.postNoMemory();
            return;
        };
        child.* = .{ .manager = self, .resource = child_resource, .sub = sub };
        sub.children.append(util.gpa, child) catch {
            util.gpa.destroy(child);
            child_resource.destroy();
            resource.postNoMemory();
            return;
        };
        self.inhibitors += 1;
        sub.inhibits += 1;
        child_resource.setHandler(*Inhibit, inhibitRequest, inhibitDestroyed, child);
        if (self.subscription == sub) self.refresh();
        self.sendState(sub, req.inhibit.serial);
        return;
    }
    if (self.subscription != sub or sub.binding == null) return;
    self.refresh();
    switch (req) {
        .set_ready => |args| {
            if (args.ready <= 1) _ = self.state.setReady(join(args.generation_hi, args.generation_lo), args.ready == 1, now());
            self.sendState(sub, args.serial);
            if (self.timer) |timer| timer.timerUpdate(1) catch self.revoke();
        },
        .ack => |args| {
            _ = self.state.ack(join(args.generation_hi, args.generation_lo), args.sequence);
        },
        .destroy, .inhibit => unreachable,
    }
}
fn subDestroyed(_: *Subscription, sub: *Sub) void {
    const self = sub.manager;
    if (self.subscription == sub) {
        self.state.invalidate();
        self.subscription = null;
    }
    for (sub.children.items) |child| child.sub = null;
    sub.children.deinit(util.gpa);
    self.subscriptions -= 1;
    util.gpa.destroy(sub);
}
fn inhibitRequest(resource: *Inhibitor, _: Inhibitor.Request, _: *Inhibit) void {
    resource.destroy();
}
fn inhibitDestroyed(_: *Inhibitor, child: *Inhibit) void {
    const self = child.manager;
    if (child.sub) |sub| {
        sub.inhibits -= 1;
        for (sub.children.items, 0..) |item, i| if (item == child) {
            _ = sub.children.swapRemove(i);
            break;
        };
        if (self.subscription == sub) self.refresh();
    }
    self.inhibitors -= 1;
    util.gpa.destroy(child);
}
fn supported(self: *Manager) bool {
    return self.session != null or build_options.input_activity_testing;
}
fn gate(self: *Manager) bool {
    const active = if (self.session) |s| s.active else if (build_options.input_activity_testing) self.test_active else false;
    return active and server.lock_manager.state == .unlocked and self.owner != null and
        aq_activity_owner_alive(self.bootstrap) and if (self.subscription) |sub| sub.inhibits == 0 else false;
}
fn sendState(self: *Manager, sub: *Sub, serial: u32) void {
    const authorized = self.subscription == sub and sub.binding != null;
    const status: Protocol.Availability = if (!authorized) .permission_denied else if (!self.supported()) .unsupported else if (self.state.available()) .available else .suspended;
    const generation: u64 = if (authorized) self.state.generation else 0;
    sub.resource.sendState(status, @truncate(generation >> 32), @truncate(generation), serial);
}
pub fn refresh(self: *Manager) void {
    if (self.owner != null and !aq_activity_owner_alive(self.bootstrap)) {
        self.revoke();
        return;
    }
    if (self.state.setGate(self.gate())) if (self.subscription) |sub| self.sendState(sub, 0);
}
fn revoke(self: *Manager) void {
    self.state.invalidate();
    self.state.gate = false;
    self.owner = null;
    if (self.subscription) |sub| {
        sub.binding = null;
        self.subscription = null;
        self.sendState(sub, 0);
    }
    aq_activity_revoke(self.bootstrap);
}
pub fn noteActivity(self: *Manager, category: Category) void {
    if (self.timer == null) return;
    self.refresh();
    self.state.note(category, now());
}
fn tick(self: *Manager) c_int {
    aq_activity_bootstrap_tick(self.bootstrap);
    self.refresh();
    const generation = self.state.generation;
    if (self.state.tick(now())) |categories| {
        if (self.subscription) |sub| sub.resource.sendActivity(@truncate(self.state.generation >> 32), @truncate(self.state.generation), self.state.sequence, @bitCast(categories));
    } else if (self.state.generation != generation) {
        if (self.subscription) |sub| self.sendState(sub, 0);
    }
    const time = now();
    const delay: c_int = if (self.state.available() and self.state.next_emit > time)
        @intCast(@min(100, self.state.next_emit - time))
    else
        250;
    if (self.timer) |timer| timer.timerUpdate(delay) catch self.revoke();
    return 0;
}
fn activeChanged(listener: *wl.Listener(void)) void {
    const self: *Manager = @fieldParentPtr("session_active", listener);
    self.refresh();
}
fn sessionDestroyed(listener: *wl.Listener(*wlr.Session), _: *wlr.Session) void {
    const self: *Manager = @fieldParentPtr("session_destroy", listener);
    self.session_active.link.remove();
    self.session_destroy.link.remove();
    self.session = null;
    self.refresh();
}
pub fn testOwner(self: *Manager, pid: c_int) void {
    if (comptime build_options.input_activity_testing) aq_activity_test_owner(self.bootstrap, pid);
}

pub fn testRevoke(self: *Manager) void {
    if (comptime build_options.input_activity_testing) self.revoke();
}
