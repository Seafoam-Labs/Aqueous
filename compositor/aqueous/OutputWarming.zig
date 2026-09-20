// SPDX-License-Identifier: GPL-3.0-only
//! Generation-bound warming leases. wlroots calls the guards at actual submission;
//! scene preparation alone never acknowledges application or releases ownership.
const Self = @This();
const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const aq = @import("wayland").server.aqueous;
const c = @import("c");
const Protocol = aq.OutputWarmingManagerV1;
const OutputProtocol = aq.OutputWarmingOutputV1;
const LeaseProtocol = aq.OutputWarmingLeaseV1;
const Reason = OutputProtocol.Reason;
const Result = LeaseProtocol.Result;
extern fn wlr_aqueous_set_color_guard(
    ?*const fn (*wlr.Output, *const wlr.Output.State, ?*anyopaque) callconv(.c) bool,
    ?*const fn (*wlr.Output, ?*anyopaque) callconv(.c) bool,
    ?*const fn (*wlr.Output, ?*anyopaque) callconv(.c) void,
    ?*anyopaque,
) void;
extern fn wlr_renderer_is_vk(*wlr.Renderer) bool;
extern fn wlr_color_transform_init_matrix(*const [9]f32) ?*wlr.ColorTransform;
extern fn wlr_color_transform_init_linear_to_inverse_eotf(wlr.color.TransferFunction) ?*wlr.ColorTransform;
extern fn wlr_color_transform_init_pipeline([*]const *wlr.ColorTransform, usize) ?*wlr.ColorTransform;
extern fn wlr_color_transform_unref(?*wlr.ColorTransform) void;
extern fn getrandom(*anyopaque, usize, c_uint) isize;

allocator: std.mem.Allocator,
global: *wl.Global,
gamma: *wlr.GammaControlManagerV1,
outputs: wl.list.Head(Output, .link) = undefined,
bindings: wl.list.Head(Binding, .link) = undefined,
observers: wl.list.Head(Observer, .link) = undefined,
leases: wl.list.Head(Lease, .link) = undefined,
timer: *wl.EventSource,
gamma_changed: wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma) = .init(gammaChanged),
session: u64,
resources: usize = 0,
session_active: bool = true,

const Binding = struct {
    link: wl.list.Link = undefined,
    manager: *Self,
    resource: *Protocol,
};
const Observer = struct {
    link: wl.list.Link = undefined,
    manager: *Self,
    resource: *OutputProtocol,
    output: ?*Output,
    instance: u64 = 0,
    generation: u64 = 0,
    revision: u64 = 0,

    fn snapshot(v: *Observer) void {
        if (v.output) |o| {
            v.instance = o.instance;
            v.generation = o.generation;
            v.revision = o.revision;
        }
        var why = reason(v.output);
        var encoding: u32 = 0;
        var owner: u32 = 0;
        var qualification: u32 = 0;
        var committed_kelvin: u32 = 0;
        var pending_kelvin: u32 = 0;
        if (v.output) |o| {
            if (o.lease != null and why == .eligible) why = .busy;
            encoding = if (o.wlr.image_description) |desc| (if (desc.transfer_function == .st2084_pq) @as(u32, 2) else 0) else 1;
            owner = if (o.restoring) 3 else if (o.lease != null) 1 else if (o.manager.gamma.getControl(o.wlr) != null) 2 else 0;
            qualification = @intFromBool(o.qualified());
            committed_kelvin = o.committed_kelvin;
            pending_kelvin = if (o.pending_id != 0) o.target else 0;
        }
        v.resource.sendState(hi(v.manager.session), lo(v.manager.session), hi(v.instance), lo(v.instance), hi(v.generation), lo(v.generation), hi(v.revision), lo(v.revision), why, encoding, qualification, qualification, owner, committed_kelvin, pending_kelvin);
        v.resource.sendDone();
    }
};
const Lease = struct {
    link: wl.list.Link = undefined,
    manager: *Self,
    resource: *LeaseProtocol,
    output: ?*Output = null,
    last_id: u32 = 0,
    releasing: bool = false,

    fn validId(l: *Lease, id: u32) bool {
        if (id == 0 or id <= l.last_id) {
            @as(*wl.Resource, @ptrCast(l.resource)).postError(0, "warming request IDs must increase without wrap");
            return false;
        }
        l.last_id = id;
        return true;
    }

    fn set(l: *Lease, generation: u64, id: u32, kelvin: u32) void {
        if (!l.validId(id)) return;
        const why: Reason = if (l.output) |o|
            (if (l.releasing or generation != o.generation) .stale else if (kelvin < 2500 or kelvin > 6500) .invalid_value else reason(o))
        else
            .stale;
        if (why != .eligible) {
            result(l, id, .rejected, why, if (l.output) |o| o.generation else 0, 0, if (l.output) |o| o.committed_kelvin else 0);
            return;
        }
        const o = l.output.?;
        result(l, o.pending_id, .superseded, .eligible, o.generation, 0, o.committed_kelvin);
        o.clearPrepared();
        o.pending_id = id;
        o.target = kelvin;
        o.deadline = now() + 2000;
        wlr_color_transform_unref(o.transform);
        o.transform = null;
        o.lockPath();
        o.damage();
        o.publish();
    }

    fn release(l: *Lease, id: u32) void {
        if (!l.validId(id)) return;
        if (l.output == null or l.releasing) {
            result(l, id, .rejected, .stale, if (l.output) |o| o.generation else 0, 0, 0);
            return;
        }
        const o = l.output.?;
        result(l, o.pending_id, .superseded, .eligible, o.generation, 0, o.committed_kelvin);
        l.releasing = true;
        o.pending_id = id;
        // Even an unused lease needs an actual baseline commit acknowledgment.
        o.lockPath();
        o.restore();
        o.publish();
    }
};
const Output = struct {
    link: wl.list.Link = undefined,
    manager: *Self,
    wlr: *wlr.Output,
    scene: ?*wlr.SceneOutput = null,
    commit: wl.Listener(*wlr.Output.event.Commit) = .init(committed),
    scene_destroy: wl.Listener(void) = .init(sceneDestroyed),
    lease: ?*Lease = null,
    instance: u64,
    generation: u64 = 1,
    revision: u64 = 1,
    committed_kelvin: u32 = 0,
    target: u32 = 6500,
    pending_id: u32 = 0,
    prepared_id: u32 = 0,
    prepared_generation: u64 = 0,
    prepared_kelvin: u32 = 0,
    prepared: ?*wlr.Buffer = null,
    transform: ?*wlr.ColorTransform = null,
    locks: bool = false,
    restoring: bool = false,
    blocked_path: bool = false,
    retired: bool = false,
    deadline: i64 = 0,

    fn qualified(o: *Output) bool {
        // Eligibility is a runtime capability, independent of build profile or
        // backend. Unit tests mock only Vulkan's renderer predicate.
        const renderer = o.wlr.renderer orelse return false;
        return renderer.features.output_color_transform and
            (if (@import("builtin").is_test) true else wlr_renderer_is_vk(renderer));
    }
    fn advanceGeneration(o: *Output) void {
        if (o.generation == std.math.maxInt(u64)) o.retired = true else o.generation += 1;
    }
    fn publish(o: *Output) void {
        if (o.revision == std.math.maxInt(u64)) o.retired = true else o.revision += 1;
        var it = o.manager.observers.iterator(.forward);
        while (it.next()) |v| if (v.output == o) v.snapshot();
    }
    fn clearPrepared(o: *Output) void {
        if (o.prepared) |buffer| buffer.unlock();
        o.prepared = null;
        o.prepared_id = 0;
    }
    fn damage(o: *Output) void {
        if (o.scene) |scene| scene.damage_ring.addWhole();
        o.wlr.scheduleFrame();
    }
    fn lockPath(o: *Output) void {
        if (o.locks) return;
        o.locks = true;
        o.wlr.lockAttachRender(true);
        o.wlr.lockSoftwareCursors(true);
    }
    fn unlockPath(o: *Output) void {
        if (!o.locks) return;
        o.locks = false;
        o.wlr.lockSoftwareCursors(false);
        o.wlr.lockAttachRender(false);
    }
    fn restore(o: *Output) void {
        o.clearPrepared();
        o.target = 6500;
        o.restoring = o.locks;
        o.deadline = now() + 2000;
        wlr_color_transform_unref(o.transform);
        o.transform = null;
        o.damage();
    }
    fn revoke(o: *Output, why: Reason) void {
        o.advanceGeneration();
        if (o.lease) |l| {
            result(l, o.pending_id, .revoked, why, o.generation, 0, o.committed_kelvin);
            l.resource.sendRevoked(why, hi(o.generation), lo(o.generation));
            l.output = null;
            o.lease = null;
        }
        o.pending_id = 0;
        // Revoke for a color transition, never to satisfy a competing owner.
        if (o.manager.gamma.getControl(o.wlr)) |gamma| gamma.sendFailedAndDestroy();
        if (o.locks) o.restore() else o.clearPrepared();
        o.publish();
    }
    fn changesColor(o: *Output, s: *const wlr.Output.State) bool {
        const fields = s.committed;
        return fields.mode or fields.color_transform or
            (fields.enabled and s.enabled != o.wlr.enabled) or
            (fields.scale and s.scale != o.wlr.scale) or
            (fields.transform and s.transform != o.wlr.transform) or
            (fields.render_format and s.render_format != o.wlr.render_format) or
            (fields.image_description and (s.image_description != null or o.wlr.image_description != null));
    }
};

fn hi(value: u64) u32 {
    return @intCast(value >> 32);
}
fn lo(value: u64) u32 {
    return @truncate(value);
}
fn join(high: u32, low: u32) u64 {
    return (@as(u64, high) << 32) | low;
}
fn now() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
}
fn find(self: *Self, output: *wlr.Output) ?*Output {
    var it = self.outputs.iterator(.forward);
    while (it.next()) |o| if (o.wlr == output) return o;
    return null;
}
fn reason(output: ?*Output) Reason {
    const o = output orelse return .removed;
    if (o.retired) return .retired;
    if (!o.manager.session_active or !o.wlr.enabled) return .inactive;
    if (o.wlr.image_description) |desc| return if (desc.transfer_function == .st2084_pq) .hdr else .unsupported_path;
    if (o.blocked_path) return .unsupported_path;
    if (o.restoring) return .restoring;
    if (!o.qualified()) return .unqualified;
    if (o.manager.gamma.getControl(o.wlr) != null) return .busy;
    return .eligible;
}
fn result(lease: ?*Lease, id: u32, status: Result, why: Reason, generation: u64, seq: u32, kelvin: u32) void {
    if (lease) |l| if (id != 0) l.resource.sendResult(id, status, why, hi(generation), lo(generation), seq, kelvin);
}
fn guardCommit(output: *wlr.Output, state: *const wlr.Output.State, data: ?*anyopaque) callconv(.c) bool {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const o = self.find(output) orelse return true; // Unmanaged DRM leases.
    var prepared = o.prepared != null and state.buffer == o.prepared and o.prepared_generation == o.generation;
    var legacy_state = state.*;
    legacy_state.committed.color_transform = false;
    if (self.gamma.getControl(output) != null and o.changesColor(&legacy_state)) {
        o.revoke(.transition);
        prepared = false;
    }
    if (o.lease != null and (o.changesColor(state) or (!o.restoring and reason(o) != .eligible))) {
        o.revoke(.transition);
        prepared = false;
    }
    if (o.locks) {
        if (state.committed.enabled and !state.enabled) return true;
        // Restoration must never submit an old warm buffer, including buffers
        // supplied by output_ensure_buffer() during a modeset.
        if (!prepared and (state.committed.buffer or o.changesColor(state))) {
            o.damage();
            return false;
        }
    }
    return true;
}
fn guardGamma(output: *wlr.Output, data: ?*anyopaque) callconv(.c) bool {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const o = self.find(output) orelse return false;
    const why = reason(o);
    return o.lease == null and !o.locks and (why == .eligible or why == .busy);
}
fn gammaAcquired(output: *wlr.Output, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    if (self.find(output)) |o| o.publish();
}
fn gammaChanged(listener: *wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma), event: *wlr.GammaControlManagerV1.event.SetGamma) void {
    const self: *Self = @fieldParentPtr("gamma_changed", listener);
    const o = self.find(event.output) orelse return;
    o.advanceGeneration();
    if (event.control == null) {
        // The old owner's LUT/pixels may still be active. Reserve ownership
        // until the scene commits the baseline.
        o.lockPath();
        o.restore();
    }
    o.publish();
}
fn sceneDestroyed(listener: *wl.Listener(void)) void {
    const o: *Output = @fieldParentPtr("scene_destroy", listener);
    listener.link.remove();
    o.scene = null;
    o.revoke(.transition);
}
fn committed(listener: *wl.Listener(*wlr.Output.event.Commit), event: *wlr.Output.event.Commit) void {
    const o: *Output = @fieldParentPtr("commit", listener);
    const s = event.state;
    var changed = false;
    if (o.prepared != null and s.buffer == o.prepared and o.prepared_generation == o.generation) {
        changed = o.pending_id != 0 or o.restoring or o.committed_kelvin != o.prepared_kelvin;
        o.committed_kelvin = o.prepared_kelvin;
        result(o.lease, o.prepared_id, .committed, .eligible, o.generation, o.wlr.commit_seq, o.committed_kelvin);
        if (o.pending_id == o.prepared_id) o.pending_id = 0;
        o.clearPrepared();
        if (o.restoring) {
            o.restoring = false;
            if (o.lease) |l| {
                l.output = null;
                o.lease = null;
            }
            o.unlockPath();
        }
        o.deadline = 0;
    }
    const fields = s.committed;
    if (fields.mode or fields.enabled or fields.render_format or fields.image_description or fields.scale or fields.transform) {
        changed = true;
        o.advanceGeneration();
    }
    if (changed) o.publish();
}
fn makeTransform(kelvin: u32) ?*wlr.ColorTransform {
    const t = (6500.0 - @as(f32, @floatFromInt(kelvin))) / 4000.0;
    const matrix: [9]f32 = .{ 1, 0, 0, 0, 1 - 0.25 * t, 0, 0, 0, 1 - 0.65 * t };
    const gain = wlr_color_transform_init_matrix(&matrix) orelse return null;
    defer wlr_color_transform_unref(gain);
    const encoding = wlr_color_transform_init_linear_to_inverse_eotf(.gamma22) orelse return null;
    defer wlr_color_transform_unref(encoding);
    return wlr_color_transform_init_pipeline(&.{ gain, encoding }, 2);
}
pub fn prepare(self: *Self, output: *wlr.Output, scene: *wlr.SceneOutput, state: *wlr.Output.State, options: *c.struct_wlr_scene_output_state_options) bool {
    const o = self.find(output) orelse return true;
    if (o.scene != scene) {
        if (o.scene != null) o.scene_destroy.link.remove();
        o.scene = scene;
        scene.events.destroy.add(&o.scene_destroy);
    }
    o.clearPrepared();
    if (o.lease != null and (o.changesColor(state) or (!o.restoring and reason(o) != .eligible))) o.revoke(.transition);
    if (!o.locks) return true;
    options.layer_candidate = null;
    if (!o.restoring) {
        if (o.transform == null) o.transform = makeTransform(o.target);
        options.color_transform = @ptrCast(o.transform orelse return false);
    }
    o.prepared_generation = o.generation;
    o.prepared_kelvin = if (o.restoring) 6500 else o.target;
    o.prepared_id = o.pending_id;
    return true;
}
pub fn built(self: *Self, output: *wlr.Output, state: *wlr.Output.State, ok: bool) void {
    const o = self.find(output) orelse return;
    if (!o.locks) return;
    if (ok and state.buffer != null and o.prepared_generation == o.generation) {
        o.prepared = state.buffer.?.lock();
    } else o.clearPrepared();
}
fn admit(self: *Self, client: *wl.Client) bool {
    if (self.resources < 128) return true;
    client.postImplementationError("warming resource limit");
    return false;
}
fn leaseRequest(resource: *LeaseProtocol, request: LeaseProtocol.Request, l: *Lease) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set => |args| l.set(join(args.generation_hi, args.generation_lo), args.request_id, args.kelvin),
        .release => |args| l.release(args.request_id),
    }
}
fn leaseDestroyed(_: *LeaseProtocol, l: *Lease) void {
    if (l.output) |o| {
        o.lease = null;
        o.pending_id = 0;
        o.restore();
        o.publish();
    }
    l.link.remove();
    l.manager.resources -= 1;
    l.manager.allocator.destroy(l);
}
fn acquire(v: *Observer, id: u32, generation: u64) void {
    const self = v.manager;
    const client = v.resource.getClient();
    if (!self.admit(client)) return;
    const l = self.allocator.create(Lease) catch {
        client.postNoMemory();
        return;
    };
    const resource = LeaseProtocol.create(client, 1, id) catch {
        self.allocator.destroy(l);
        client.postNoMemory();
        return;
    };
    l.* = .{ .manager = self, .resource = resource };
    self.resources += 1;
    self.leases.prepend(l);
    resource.setHandler(*Lease, leaseRequest, leaseDestroyed, l);
    var why = reason(v.output);
    if (v.output) |o| {
        if (generation != o.generation) why = .stale else if (o.lease != null) why = .busy;
    }
    if (why != .eligible) {
        resource.sendDenied(why);
        return;
    }
    const o = v.output.?;
    l.output = o;
    o.lease = l;
    resource.sendAcquired(hi(o.generation), lo(o.generation));
    o.publish();
}
fn observerRequest(resource: *OutputProtocol, request: OutputProtocol.Request, v: *Observer) void {
    switch (request) {
        .destroy => resource.destroy(),
        .acquire => |args| acquire(v, args.id, join(args.generation_hi, args.generation_lo)),
    }
}
fn observerDestroyed(_: *OutputProtocol, v: *Observer) void {
    v.link.remove();
    v.manager.resources -= 1;
    v.manager.allocator.destroy(v);
}
fn observe(self: *Self, client: *wl.Client, id: u32, output: ?*Output) !*Observer {
    const v = try self.allocator.create(Observer);
    errdefer self.allocator.destroy(v);
    const resource = try OutputProtocol.create(client, 1, id);
    v.* = .{ .manager = self, .resource = resource, .output = output };
    self.observers.prepend(v);
    self.resources += 1;
    resource.setHandler(*Observer, observerRequest, observerDestroyed, v);
    v.snapshot();
    return v;
}
fn bindingRequest(resource: *Protocol, request: Protocol.Request, b: *Binding) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_output => |args| {
            const client = resource.getClient();
            if (!b.manager.admit(client)) return;
            _ = b.manager.observe(client, args.id, if (wlr.Output.fromWlOutput(args.output)) |output| b.manager.find(output) else null) catch client.postNoMemory();
        },
    }
}
fn bindingDestroyed(_: *Protocol, b: *Binding) void {
    b.link.remove();
    b.manager.resources -= 1;
    b.manager.allocator.destroy(b);
}
fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    if (!self.admit(client)) return;
    const b = self.allocator.create(Binding) catch {
        client.postNoMemory();
        return;
    };
    const resource = Protocol.create(client, version, id) catch {
        self.allocator.destroy(b);
        client.postNoMemory();
        return;
    };
    b.* = .{ .manager = self, .resource = resource };
    self.resources += 1;
    self.bindings.prepend(b);
    resource.setHandler(*Binding, bindingRequest, bindingDestroyed, b);
}
fn tick(self: *Self) c_int {
    var it = self.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (o.deadline != 0 and now() >= o.deadline) {
            result(o.lease, o.pending_id, .failed, .commit_failed, o.generation, 0, o.committed_kelvin);
            o.pending_id = 0;
            o.revoke(.commit_failed);
            // Stay blocked during recovery without an unbounded retry loop.
            o.deadline = 0;
        }
    }
    self.timer.timerUpdate(100) catch {};
    return 0;
}
pub fn init(allocator: std.mem.Allocator, display: *wl.Server, gamma: *wlr.GammaControlManagerV1) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    var session: u64 = 0;
    if (getrandom(&session, @sizeOf(u64), 0) != @sizeOf(u64) or session == 0) return error.RandomUnavailable;
    const timer = try display.getEventLoop().addTimer(*Self, tick, self);
    errdefer timer.remove();
    const global = try wl.Global.create(display, Protocol, 1, *Self, self, bind);
    errdefer global.destroy();
    self.* = .{ .allocator = allocator, .global = global, .gamma = gamma, .timer = timer, .session = session };
    self.outputs.init();
    self.observers.init();
    self.leases.init();
    self.bindings.init();
    try timer.timerUpdate(100);
    gamma.events.set_gamma.add(&self.gamma_changed);
    wlr_aqueous_set_color_guard(guardCommit, guardGamma, gammaAcquired, self);
    return self;
}
pub fn add(self: *Self, output: *wlr.Output, instance: u64) !void {
    if (instance == 0 or self.find(output) != null) return error.InvalidOutput;
    const o = try self.allocator.create(Output);
    o.* = .{ .manager = self, .wlr = output, .instance = instance };
    output.events.commit.add(&o.commit);
    self.outputs.prepend(o);
}
pub fn remove(self: *Self, output: *wlr.Output) void {
    const o = self.find(output) orelse return;
    o.revoke(.removed);
    var it = self.observers.iterator(.forward);
    while (it.next()) |v| {
        if (v.output == o) {
            v.output = null;
            v.snapshot();
        }
    }
    o.clearPrepared();
    o.unlockPath();
    wlr_color_transform_unref(o.transform);
    if (o.scene != null) o.scene_destroy.link.remove();
    o.commit.link.remove();
    o.link.remove();
    self.allocator.destroy(o);
}
pub fn active(self: *Self, enabled: bool) void {
    if (self.session_active == enabled) return;
    self.session_active = enabled;
    var it = self.outputs.iterator(.forward);
    while (it.next()) |o| o.revoke(.inactive);
}
pub fn invalidate(self: *Self, output: *wlr.Output) void {
    if (self.find(output)) |o| o.revoke(.transition);
}
pub fn path(self: *Self, output: *wlr.Output, blocked: bool) void {
    const o = self.find(output) orelse return;
    if (o.blocked_path != blocked) {
        o.blocked_path = blocked;
        o.revoke(.unsupported_path);
    }
}
pub fn deinit(self: *Self) void {
    wlr_aqueous_set_color_guard(null, null, null, null);
    self.gamma_changed.link.remove();
    while (self.leases.first()) |l| l.resource.destroy();
    while (self.observers.first()) |v| v.resource.destroy();
    while (self.bindings.first()) |b| b.resource.destroy();
    while (self.outputs.first()) |o| self.remove(o.wlr);
    self.timer.remove();
    self.global.destroy();
    self.allocator.destroy(self);
}

// Private headless fixture: real protocol events and wlroots commits, with only
// renderer qualification mocked. The testing allocator checks our lifetimes.
const Fixture = struct {
    extern fn wlr_pixman_renderer_create() ?*wlr.Renderer;
    extern fn wlr_aqueous_gamma_allowed(*wlr.Output) bool;
    extern fn wl_display_add_protocol_logger(*wl.Server, *const fn (?*anyopaque, wl.ProtocolLogger.Type, *const wl.ProtocolLogger.LogMessage) callconv(.c) void, ?*anyopaque) ?*wl.ProtocolLogger;
    extern fn wlr_color_transform_eval(*wlr.ColorTransform, *[3]f32, *const [3]f32) void;
    const Events = struct {
        results: [5]usize = @splat(0),
        denials: usize = 0,
        revoked: usize = 0,
        fn count(events: Events, status: Result) usize {
            return events.results[@intCast(@intFromEnum(status))];
        }
    };
    fn logger(data: ?*anyopaque, direction: wl.ProtocolLogger.Type, message: *const wl.ProtocolLogger.LogMessage) callconv(.c) void {
        if (direction != .event or !std.mem.eql(u8, std.mem.span(message.resource.getClass()), "aqueous_output_warming_lease_v1")) return;
        const events: *Events = @ptrCast(@alignCast(data.?));
        const name = std.mem.span(message.message.name);
        if (std.mem.eql(u8, name, "result")) events.results[message.arguments.?[1].u] += 1;
        if (std.mem.eql(u8, name, "denied")) events.denials += 1;
        if (std.mem.eql(u8, name, "revoked")) events.revoked += 1;
    }
    fn destroyBuffer(buffer: *wlr.Buffer) callconv(.c) void {
        std.testing.allocator.destroy(buffer);
    }
    const buffer_impl: wlr.Buffer.Impl = .{
        .destroy = destroyBuffer,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = null,
        .end_data_ptr_access = null,
    };
    fn newBuffer() !*wlr.Buffer {
        const buffer = try std.testing.allocator.create(wlr.Buffer);
        buffer.init(&buffer_impl, 64, 64);
        return buffer;
    }
    fn submit(manager: *Self, o: *Output, scene: *wlr.SceneOutput, group: bool) !void {
        var state = wlr.Output.State.init();
        defer state.finish();
        var options: c.struct_wlr_scene_output_state_options = std.mem.zeroes(c.struct_wlr_scene_output_state_options);
        try std.testing.expect(manager.prepare(o.wlr, scene, &state, &options));
        const buffer = try newBuffer();
        state.setBuffer(buffer);
        buffer.drop();
        manager.built(o.wlr, &state, true);
        try std.testing.expect(if (group) o.wlr.backend.commit(&.{.{ .output = o.wlr, .base = state }}) else o.wlr.commitState(&state));
    }
    fn set(l: *Lease, generation: u64, id: u32, kelvin: u32) void {
        leaseRequest(l.resource, .{ .set = .{ .generation_hi = hi(generation), .generation_lo = lo(generation), .request_id = id, .kelvin = kelvin } }, l);
    }
    fn acquireLease(v: *Observer, generation: u64) void {
        observerRequest(v.resource, .{ .acquire = .{ .id = 0, .generation_hi = hi(generation), .generation_lo = lo(generation) } }, v);
    }
};

test "warming protocol ownership, real commit guards, restoration and lifetimes" {
    const expect = std.testing.expect;
    const display = try wl.Server.create();
    defer display.destroy();
    var events: Fixture.Events = .{};
    const logger = Fixture.wl_display_add_protocol_logger(display, Fixture.logger, &events) orelse return error.OutOfMemory;
    defer logger.destroy();
    var sockets: [2]c_int = undefined;
    try expect(std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) == 0);
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse {
        _ = std.c.close(sockets[0]);
        return error.ClientCreateFailed;
    };
    var client_alive = true;
    defer if (client_alive) client.destroy();
    const gamma = try wlr.GammaControlManagerV1.create(display);
    const backend = try wlr.Backend.createHeadless(display.getEventLoop());
    defer backend.destroy();
    const output = try backend.headlessAddOutput(64, 64);
    const renderer = Fixture.wlr_pixman_renderer_create() orelse return error.RendererCreateFailed;
    defer renderer.destroy();
    output.renderer = renderer;
    defer output.renderer = null;
    output.enabled = true;
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    const scene_output = try scene.createSceneOutput(output);
    const manager = try init(std.testing.allocator, display, gamma);
    defer manager.deinit();
    try manager.add(output, 1);
    const o = manager.find(output).?;
    const v = try manager.observe(client, 0, o);
    Fixture.acquireLease(v, 1);
    try expect(events.denials == 1 and o.lease == null);
    try expect(!Fixture.wlr_aqueous_gamma_allowed(output));
    renderer.features.output_color_transform = true;
    Fixture.acquireLease(v, 0);
    try expect(events.denials == 2 and o.lease == null);
    Fixture.acquireLease(v, 1);
    var l = o.lease.?;
    bind(client, manager, 1, 0);
    const binding = manager.bindings.first().?;
    bindingRequest(binding.resource, .destroy, binding);
    try expect(o.lease == l and manager.bindings.empty());
    Fixture.acquireLease(v, 1);
    try expect(events.denials == 3 and o.lease == l);
    try expect(!Fixture.wlr_aqueous_gamma_allowed(output));
    Fixture.set(l, 0, 1, 4500);
    try expect(events.count(.rejected) == 1);
    Fixture.set(l, 1, 2, 2499);
    try expect(events.count(.rejected) == 2);
    Fixture.set(l, 1, 3, 4500);
    Fixture.set(l, 1, 4, 3500);
    try expect(events.count(.superseded) == 1);
    try expect(o.pending_id == 4 and o.locks and events.count(.committed) == 0);
    try Fixture.submit(manager, o, scene_output, false);
    try expect(o.committed_kelvin == 3500 and events.count(.committed) == 1);
    // Neither single nor grouped commits may bypass scene preparation. A test
    // of output state is read-only and cannot revoke the lease.
    var rogue = wlr.Output.State.init();
    defer rogue.finish();
    const buffer = try Fixture.newBuffer();
    rogue.setBuffer(buffer);
    buffer.drop();
    try expect(output.testState(&rogue));
    try expect(o.lease == l and o.generation == 1);
    try expect(!backend.commit(&.{.{ .output = output, .base = rogue }}));
    try expect(!output.commitState(&rogue));
    leaseRequest(l.resource, .{ .release = .{ .request_id = 5 } }, l);
    try expect(o.restoring and o.lease == l);
    Fixture.acquireLease(v, 1);
    try expect(events.denials == 4);
    try Fixture.submit(manager, o, scene_output, true);
    try expect(o.committed_kelvin == 6500 and !o.locks and o.lease == null and events.count(.committed) == 2);
    Fixture.acquireLease(v, o.generation);
    l = o.lease.?;
    Fixture.set(l, o.generation, 1, 4500);
    const old_generation = o.generation;
    manager.invalidate(output);
    try expect(o.generation > old_generation and o.lease == null and o.restoring and events.revoked == 1 and events.count(.revoked) == 1);
    try Fixture.submit(manager, o, scene_output, false);
    Fixture.acquireLease(v, o.generation);
    l = o.lease.?;
    Fixture.set(l, o.generation, 1, 4500);
    try Fixture.submit(manager, o, scene_output, false);
    leaseRequest(l.resource, .destroy, l);
    try expect(o.restoring and o.lease == null and o.locks);
    try Fixture.submit(manager, o, scene_output, false);
    try expect(!o.restoring and !o.locks and o.committed_kelvin == 6500);
    Fixture.acquireLease(v, o.generation);
    l = o.lease.?;
    Fixture.set(l, o.generation, 1, 4500);
    o.deadline = 1;
    _ = tick(manager);
    try expect(events.count(.failed) == 1 and o.restoring and o.lease == null);
    _ = tick(manager);
    try expect(events.count(.failed) == 1);
    try Fixture.submit(manager, o, scene_output, false);
    // Losing renderer support while a request is pending revokes it at scene
    // preparation, and the real baseline commit still releases the path locks.
    Fixture.acquireLease(v, o.generation);
    l = o.lease.?;
    Fixture.set(l, o.generation, 1, 4500);
    renderer.features.output_color_transform = false;
    try Fixture.submit(manager, o, scene_output, false);
    try expect(o.lease == null and !o.locks and o.committed_kelvin == 6500);
    try expect(reason(o) == .unqualified and !Fixture.wlr_aqueous_gamma_allowed(output));
    renderer.features.output_color_transform = true;
    var hdr: wlr.Output.ImageDescription = undefined;
    hdr.transfer_function = .st2084_pq;
    output.image_description = &hdr;
    try expect(reason(o) == .hdr);
    Fixture.acquireLease(v, o.generation);
    try expect(o.lease == null);
    output.image_description = null;
    scene_output.destroy();
    try expect(o.scene == null);
    o.generation = std.math.maxInt(u64);
    manager.invalidate(output);
    try expect(reason(o) == .retired);
    manager.remove(output);
    try expect(v.output == null and v.instance == 1 and v.generation == std.math.maxInt(u64));
    // Connection loss destroys all children through their real handlers.
    // Manager teardown also exercises live-resource cleanup on failing tests.
    client.destroy();
    client_alive = false;
    try expect(manager.resources == 0);
}

test "warming transform evaluates the full range and neutral baseline" {
    var kelvin: u32 = 2500;
    var previous: [3]f32 = @splat(0);
    while (kelvin <= 6500) : (kelvin += 100) {
        const transform = makeTransform(kelvin) orelse return error.OutOfMemory;
        defer wlr_color_transform_unref(transform);
        var rgb: [3]f32 = undefined;
        Fixture.wlr_color_transform_eval(transform, &rgb, &.{ 1, 1, 1 });
        try std.testing.expectApproxEqAbs(@as(f32, 1), rgb[0], 0.00001);
        try std.testing.expect(rgb[1] <= 1 and rgb[2] <= rgb[1] and rgb[1] >= previous[1] and rgb[2] >= previous[2]);
        if (kelvin == 6500) {
            try std.testing.expectApproxEqAbs(@as(f32, 1), rgb[1], 0.00001);
            try std.testing.expectApproxEqAbs(@as(f32, 1), rgb[2], 0.00001);
        }
        previous = rgb;
    }
}
