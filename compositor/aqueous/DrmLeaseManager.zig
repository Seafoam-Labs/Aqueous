// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! wlroots owns lease resources and destroys outputs synchronously on grant.
//! Use translated C layouts: zig-wlroots 0.20.1 has stale lease list offsets.
const DrmLeaseManager = @This();
const std = @import("std");
const c = @import("c");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const util = @import("util.zig");
const policy = @import("drm_lease_policy.zig");
const log = std.log.scoped(.drm_lease);

const Native = c.struct_wlr_drm_lease_v1_manager;
const Request = c.struct_wlr_drm_lease_request_v1;
const Device = c.struct_wlr_drm_lease_device_v1;
const Lease = c.struct_wlr_drm_lease_v1;

native: ?*Native = null,
session: ?*wlr.Session = null,
state: policy.Policy = .{},
outputs: wl.list.Head(ReservedOutput, .link) = undefined,
request: wl.Listener(*Request) = .init(handleRequest),
destroy: wl.Listener(void) = .init(handleDestroy),
session_active: wl.Listener(void) = .init(handleSessionActive),
session_destroy: wl.Listener(*wlr.Session) = .init(handleSessionDestroy),

const ReservedOutput = struct {
    output: *wlr.Output,
    offered: bool = false,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(*wlr.Output) = .init(handleOutputDestroy),
};

pub fn init(manager: *DrmLeaseManager, display: *wl.Server, backend: *wlr.Backend, session: ?*wlr.Session) void {
    manager.outputs.init();
    manager.session = session;
    manager.state.active = if (session) |s| s.active else false;
    if (session) |s| {
        s.events.active.add(&manager.session_active);
        s.events.destroy.add(&manager.session_destroy);
    }
    manager.native = c.wlr_drm_lease_v1_manager_create(@ptrCast(display), @ptrCast(backend));
    if (manager.native) |native| {
        const request_signal: *wl.Signal(*Request) = @ptrCast(&native.events.request);
        const destroy_signal: *wl.Signal(void) = @ptrCast(&native.events.destroy);
        request_signal.add(&manager.request);
        destroy_signal.add(&manager.destroy);
        log.info("DRM leasing available for non-desktop outputs", .{});
    } else {
        log.info("DRM leasing unavailable (no usable lease device)", .{});
    }
}

/// Return true even when offering fails: a headset must never become a desktop.
pub fn reserve(manager: *DrmLeaseManager, output: *wlr.Output) bool {
    if (!policy.reserved(c.wlr_output_is_drm(@ptrCast(output)), output.non_desktop)) return false;
    // A newly discovered non-desktop connector may retain an old modeset.
    // Keep it dark until a lessee takes ownership, including during locking.
    manager.blank(output);
    const entry = util.gpa.create(ReservedOutput) catch {
        log.err("cannot track reserved output {s}: out of memory", .{output.name});
        return true;
    };
    entry.* = .{ .output = output };
    manager.outputs.append(entry);
    output.events.destroy.add(&entry.destroy);
    log.info("reserving non-desktop output {s}", .{output.name});
    manager.offer(entry);
    return true;
}

fn blank(manager: *DrmLeaseManager, output: *wlr.Output) void {
    // Backend resume listeners run before ours and may emit outputs while
    // the cached admission policy still says inactive. The real session can
    // already modeset; blank before allocating tracking (even on OOM).
    const active = if (manager.session) |session| session.active else manager.state.active;
    if (!active or !output.enabled) return;
    var state: c.struct_wlr_output_state = undefined;
    c.wlr_output_state_init(&state);
    defer c.wlr_output_state_finish(&state);
    c.wlr_output_state_set_enabled(&state, false);
    if (!c.wlr_output_commit_state(@ptrCast(output), &state)) {
        // Do not acknowledge a lock or advertise an output still scanning out
        // content left by another owner after a failed disabling modeset.
        log.err("cannot disable reserved output {s}", .{output.name});
        c.abort();
    }
}

fn offer(manager: *DrmLeaseManager, entry: *ReservedOutput) void {
    const native = manager.native orelse return;
    if (entry.offered or !manager.state.permitsLease()) return;
    entry.offered = c.wlr_drm_lease_v1_manager_offer_output(native, @ptrCast(entry.output));
    if (!entry.offered) log.warn("cannot offer reserved output {s}", .{entry.output.name});
}

pub fn setLocked(manager: *DrmLeaseManager, locked: bool) void {
    manager.state.locked = locked;
    manager.refresh();
}

fn fromLink(comptime T: type, link: *c.struct_wl_list) *T {
    return @ptrFromInt(@intFromPtr(link) - @offsetOf(T, "link"));
}

fn refresh(manager: *DrmLeaseManager) void {
    var reserved = manager.outputs.iterator(.forward);
    while (reserved.next()) |entry| manager.blank(entry.output);
    const native = manager.native orelse return;
    if (manager.state.permitsLease()) {
        var it = manager.outputs.iterator(.forward);
        while (it.next()) |entry| manager.offer(entry);
        return;
    }

    // Set denial state before this call: revocation can reissue outputs.
    var it = manager.outputs.iterator(.forward);
    while (it.next()) |entry| {
        if (entry.offered) {
            entry.offered = false;
            c.wlr_drm_lease_v1_manager_withdraw_output(native, @ptrCast(entry.output));
        }
    }
    var link = native.devices.next;
    while (link != &native.devices) {
        const device = fromLink(Device, link);
        link = device.link.next;
        while (device.leases.next != &device.leases) {
            // Revoke frees the lease and may change output lists synchronously.
            const lease = fromLink(Lease, device.leases.next);
            c.wlr_drm_lease_v1_revoke(lease);
        }
    }
}

fn accepts(manager: *DrmLeaseManager, request: *Request) bool {
    if (!manager.state.permitsLease() or request.invalid or
        request.n_connectors == 0 or request.connectors == null) return false;
    for (request.connectors[0..request.n_connectors]) |connector| {
        if (connector == null or connector.*.device != request.device or connector.*.output == null) return false;
        var found = false;
        var it = manager.outputs.iterator(.forward);
        while (it.next()) |entry| {
            if (@intFromPtr(entry.output) == @intFromPtr(connector.*.output)) {
                found = entry.offered and policy.reserved(
                    c.wlr_output_is_drm(connector.*.output),
                    entry.output.non_desktop,
                );
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn handleRequest(listener: *wl.Listener(*Request), request: *Request) void {
    const manager: *DrmLeaseManager = @fieldParentPtr("request", listener);
    if (!manager.accepts(request)) {
        c.wlr_drm_lease_request_v1_reject(request);
        log.debug("lease request rejected by session/connector policy", .{});
        return;
    }
    const count = request.n_connectors;
    // Grant destroys connector/output objects. The request belongs to submit.
    if (c.wlr_drm_lease_request_v1_grant(request) != null) {
        log.info("granted DRM lease for {d} connector(s)", .{count});
    } else {
        log.warn("DRM lease grant failed for {d} connector(s)", .{count});
    }
}

fn handleOutputDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const entry: *ReservedOutput = @fieldParentPtr("destroy", listener);
    // wlroots has its own output listener which withdraws the connector.
    entry.destroy.link.remove();
    entry.link.remove();
    util.gpa.destroy(entry);
}

fn handleSessionActive(listener: *wl.Listener(void)) void {
    const manager: *DrmLeaseManager = @fieldParentPtr("session_active", listener);
    manager.state.active = manager.session.?.active;
    manager.refresh();
}

fn detachSession(manager: *DrmLeaseManager) void {
    if (manager.session != null) {
        manager.session_active.link.remove();
        manager.session_destroy.link.remove();
        manager.session = null;
    }
}

fn handleSessionDestroy(listener: *wl.Listener(*wlr.Session), _: *wlr.Session) void {
    const manager: *DrmLeaseManager = @fieldParentPtr("session_destroy", listener);
    manager.state.active = false;
    manager.refresh();
    manager.detachSession();
}

/// Before client/backend teardown, while all native owners still exist.
pub fn stop(manager: *DrmLeaseManager) void {
    manager.state.stopping = true;
    manager.refresh();
    manager.detachSession();
}

/// After backend teardown, before the display destroys the native manager.
pub fn deinit(manager: *DrmLeaseManager) void {
    std.debug.assert(manager.outputs.length() == 0);
    manager.detachSession();
    if (manager.native != null) {
        manager.request.link.remove();
        manager.destroy.link.remove();
        manager.native = null;
    }
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const manager: *DrmLeaseManager = @fieldParentPtr("destroy", listener);
    manager.request.link.remove();
    manager.destroy.link.remove();
    manager.native = null;
    var it = manager.outputs.iterator(.forward);
    while (it.next()) |entry| entry.offered = false;
}
