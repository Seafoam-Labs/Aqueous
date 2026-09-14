// SPDX-License-Identifier: GPL-3.0-only
//! Compositor-owned lease. Hardware groups remain gated pending acceptance.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const server = &@import("main.zig").server;
const util = @import("util.zig");
const Output = @import("Output.zig");
const Config = @import("wm/output/config.zig");
const Manager = @import("OutputManager.zig");
const Codec = @import("IpcProtocol.zig");
const Tx = @import("ConfigTransaction.zig");
const a = std.heap.c_allocator;
const Status = enum { applying, previewing, commit_authorized, kept, reverting, reverted, invalidated, failed };
const Item = struct { instance: u64, before: Output.State, after: Output.State };
const Lease = struct {
    token: [64]u8,
    candidate_digest: [64]u8,
    generation: [16]u8,
    display_digest: [64]u8,
    configs: *Configs,
    owner: usize,
    operation_id: [64]u8 = undefined,
    operation_len: usize = 0,
    after_generation: ?[16]u8 = null,
    rollback_partial: bool = false,
    fallback_used: bool = false,
    revision: u64,
    state: Status = .applying,
    reason: []const u8 = "applying",
    deadline_ms: i64,
    items: [Config.max_outputs]Item = undefined,
    len: usize = 0,
};
const Configs = struct { legacy: Config.Snapshot, preferred: Config.Snapshot };
var lease: ?Lease = null;
var timer: ?*wl.EventSource = null;
fn now() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}
pub fn active() bool {
    return if (lease) |l| l.state == .applying or l.state == .previewing or l.state == .commit_authorized or l.state == .reverting else false;
}
fn find(instance: u64) ?*Output {
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |o| if (o.display_instance == instance and o.wlr_output != null) return o;
    return null;
}
pub fn removed(instance: u64) void {
    const l = if (lease) |*v| v else return;
    if (!active()) return;
    for (l.items[0..l.len]) |item| if (item.instance == instance) {
        revert("hotplug", instance);
        return;
    };
}
pub fn disconnected(owner: usize) void {
    if (lease) |l| if (l.owner == owner and active() and l.state != .commit_authorized) revert("owner_disconnected", null);
}
pub fn failed() void {
    if (lease) |*l| {
        if (l.state == .reverting) {
            l.state = .failed;
            l.reason = "rollback_test_or_apply_failed";
        } else if (active()) revert("apply_failed", null);
    }
}
pub fn applied() void {
    const l = if (lease) |*v| v else return;
    if (!active() or l.state == .commit_authorized) return;
    if (l.state == .reverting) {
        for (l.items[0..l.len]) |item| {
            const o = find(item.instance) orelse {
                l.rollback_partial = true;
                continue;
            };
            if (!std.meta.eql(o.current, item.before)) l.rollback_partial = true;
        }
        if (l.rollback_partial) {
            l.state = .invalidated;
            return;
        }
        l.state = if (std.mem.eql(u8, l.reason, "explicit_revert") or std.mem.eql(u8, l.reason, "timeout") or std.mem.eql(u8, l.reason, "owner_disconnected")) .reverted else .invalidated;
        return;
    }
    for (l.items[0..l.len]) |item| {
        const o = find(item.instance) orelse {
            revert("hotplug", null);
            return;
        };
        if (!std.meta.eql(o.current, item.after)) {
            if (l.state == .previewing) revert("competing_change", null);
            return;
        }
    }
    if (l.state == .applying) {
        l.state = .previewing;
        l.deadline_ms = now() + 15000;
        l.reason = "confirmation_required";
        l.revision = server.om.display_revision;
    }
}
fn tick(_: *u8) c_int {
    if (active() and now() >= lease.?.deadline_ms) {
        if (lease.?.state == .reverting) {
            lease.?.state = .failed;
            lease.?.reason = "rollback_completion_timeout";
        } else if (lease.?.state == .commit_authorized) {
            reconcileCommit() catch revert("commit_deadline", null);
        } else revert("timeout", null);
    }
    if (timer) |t| t.timerUpdate(100) catch {};
    return 0;
}
var timer_data: u8 = 0;
fn testStates(states: []const Manager.Pending) !void {
    var backend_states: std.ArrayList(wlr.Backend.OutputState) = .empty;
    defer backend_states.deinit(util.gpa);
    defer for (backend_states.items) |*s| s.base.finish();
    var usable: usize = 0;
    for (states) |entry| {
        const output = entry.output.wlr_output orelse return error.StaleRevision;
        if (entry.state.state == .enabled and entry.state.mirror_of.empty()) usable += 1;
        const state = try backend_states.addOne(util.gpa);
        state.* = .{ .output = output, .base = wlr.Output.State.init() };
        if (!entry.state.applyModeset(output, &state.base)) return error.Unsupported;
    }
    if (usable == 0) return error.NoUsableOutput;
    var swapchains: wlr.OutputSwapchainManager = undefined;
    swapchains.init(server.backend);
    defer swapchains.finish();
    if (!swapchains.prepare(backend_states.items)) return error.TestFailed;
}
fn revert(reason: []const u8, removed_instance: ?u64) void {
    const l = if (lease) |*v| v else return;
    if (!active() or l.state == .reverting) return;
    l.reason = reason;
    server.aqueous.output_service.preview_config = null;
    server.aqueous.output_service.preview_persisted = null;
    var pending: [Config.max_outputs]Manager.Pending = undefined;
    var len: usize = 0;
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (removed_instance == o.display_instance or o.wlr_output == null) continue;
        if (len == pending.len) {
            l.state = .failed;
            return;
        }
        var target = o.scheduled;
        for (l.items[0..l.len]) |item| if (item.instance == o.display_instance) {
            // Restore only state still owned by this lease; a newer scheduled
            // value wins. Identity is never a connector or pointer address.
            if (std.meta.eql(o.scheduled, item.after)) target = item.before;
        };
        pending[len] = .{ .output = o, .state = target };
        len += 1;
    }
    Manager.layoutPlan(pending[0..len]);
    testStates(pending[0..len]) catch {
        // Test a conservative usable-head fallback when the baseline cannot
        // be restored (for example, its only enabled monitor disappeared).
        var usable_fallback = false;
        for (pending[0..len]) |*item| {
            if (item.state.mode == .none) continue;
            item.state.state = .enabled;
            item.state.mirror_of = .{};
            item.state.hdr_enabled = false;
            item.state.adaptive_sync = false;
            testStates(pending[0..len]) catch continue;
            usable_fallback = true;
            break;
        }
        if (!usable_fallback) {
            l.state = .failed;
            l.reason = "rollback_unusable_or_test_failed";
            return;
        }
        l.fallback_used = true;
        l.rollback_partial = true;
        l.reason = "tested_usable_output_fallback";
    };
    l.state = .reverting;
    l.deadline_ms = now() + 5000;
    for (pending[0..len]) |item| item.output.scheduled = item.state;
    server.om.display_revision += 1;
    server.wm.dirtyWindowing();
}

pub fn begin(owner: usize, params: std.json.ObjectMap) !void {
    if (active()) return error.Busy;
    if (server.wm.state != .idle or server.wm.scheduled.dirty) return error.Busy;
    const revision = try std.fmt.parseInt(u64, try Codec.string(params, "display_revision"), 10);
    if (revision != server.om.display_revision) return error.StaleRevision;
    const digest = try Codec.string(params, "candidate_digest");
    const generation = try Codec.string(params, "expected_generation");
    if (digest.len != 64 or generation.len != 16) return error.Invalid;
    const wm_source = try source(params, "wm_source");
    const outputs_source = try source(params, "outputs_source");
    const lock = try Tx.Lock.acquire(a, std.Io.Threaded.global_single_threaded.io(), false);
    defer lock.release();
    _ = try Tx.recover(a, std.Io.Threaded.global_single_threaded.io());
    const Document = @import("ConfigDocument.zig");
    var files = try Document.ConfigFiles.init(a);
    defer files.deinit();
    if (!std.mem.eql(u8, generation, &Document.generation(&files))) return error.StaleGeneration;
    const legacy = Config.parse(wm_source);
    const preferred = Config.parse(outputs_source);
    if (legacy.unknown_fields != 0 or preferred.unknown_fields != 0 or legacy.rejected_declarations != 0 or preferred.rejected_declarations != 0) return error.UnclassifiedDisplayProperty;
    var specs: [Config.max_outputs * 2]Config.Spec = undefined;
    const plan = try server.om.prepareSpecs(if (Config.effectiveApplyOnReload(&legacy, &preferred)) Config.configuredSpecs(&legacy, &preferred, &specs) else &.{});
    for (plan.report.rejections[0..plan.report.rejection_count]) |rejection| if (rejection.reason != .unknown_output) return error.RejectedDisplayDeclaration;
    var pending: [Config.max_outputs]Manager.Pending = undefined;
    var count: usize = 0;
    const configs = try a.create(Configs);
    errdefer a.destroy(configs);
    configs.* = .{ .legacy = legacy, .preferred = preferred };
    var l: Lease = .{ .configs = configs, .token = undefined, .candidate_digest = digest[0..64].*, .generation = generation[0..16].*, .display_digest = try displayDigest(wm_source, outputs_source), .owner = owner, .revision = revision, .deadline_ms = now() + 5000 };
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |o| {
        const w = o.wlr_output orelse continue;
        if (count == pending.len or !std.meta.eql(o.current, o.scheduled)) return error.Busy;
        // Only the simulated backend is enabled until physical acceptance.
        if (!w.isHeadless()) return error.HardwareAcceptanceRequired;
        var target = o.current;
        for (plan.items[0..plan.len]) |entry| if (entry.output == o) {
            target = entry.state;
        };
        if (target.hdr_enabled != o.current.hdr_enabled or target.adaptive_sync != o.current.adaptive_sync or
            target.hdr_level != o.current.hdr_level or target.sdr_white_level != o.current.sdr_white_level or
            target.auto_hdr != o.current.auto_hdr or target.auto_hdr_boost != o.current.auto_hdr_boost) return error.HardwareAcceptanceRequired;
        pending[count] = .{ .output = o, .state = target };
        l.items[count] = .{ .instance = o.display_instance, .before = o.current, .after = target };
        count += 1;
    }
    Manager.layoutPlan(pending[0..count]);
    for (pending[0..count], 0..) |entry, index| l.items[index].after = entry.state;
    for (pending[0..count]) |entry| {
        if (entry.state.mirror_of.empty()) continue;
        const source_present = for (pending[0..count]) |candidate| {
            if (std.mem.eql(u8, candidate.output.policyName(), entry.state.mirror_of.slice()) and candidate.state.state == .enabled and candidate.state.mirror_of.empty()) break true;
        } else false;
        if (!source_present) return error.MirrorSourceUnavailable;
    }
    try testStates(pending[0..count]);
    var random: [32]u8 = undefined;
    std.Io.random(std.Io.Threaded.global_single_threaded.io(), &random);
    l.token = std.fmt.bytesToHex(random, .lower);
    l.len = count;
    if (timer == null) timer = try server.wl_server.getEventLoop().addTimer(*u8, tick, &timer_data);
    try timer.?.timerUpdate(100);
    if (lease) |old| a.destroy(old.configs);
    lease = l;
    server.aqueous.output_service.preview_config = &configs.legacy;
    server.aqueous.output_service.preview_persisted = &configs.preferred;
    for (pending[0..count]) |entry| entry.output.scheduled = entry.state;
    server.wm.dirtyWindowing();
}
pub fn requestRevert(token: []const u8) !void {
    try checkToken(token);
    if (commitActive()) return error.CommitInProgress;
    revert("explicit_revert", null);
}
fn checkToken(token: []const u8) !void {
    const l = lease orelse return error.UnknownLease;
    if (!std.mem.eql(u8, token, &l.token)) return error.UnknownLease;
}
pub fn writeStatus(json: *std.json.Stringify, token: ?[]const u8) !void {
    if (token) |t| try checkToken(t);
    const l = lease orelse return error.UnknownLease;
    var names: [Config.max_outputs][20]u8 = undefined;
    const Affected = struct { instance: []const u8, connected: bool, restored: bool, still_owned: bool, reason: ?[]const u8 };
    var affected: [Config.max_outputs]Affected = undefined;
    for (l.items[0..l.len], 0..) |item, index| {
        const o = find(item.instance);
        const restored = if (o) |v| std.meta.eql(v.current, item.before) else false;
        const owned = if (o) |v| std.meta.eql(v.scheduled, item.after) else false;
        affected[index] = .{
            .instance = try std.fmt.bufPrint(&names[index], "{d}", .{item.instance}),
            .connected = o != null,
            .restored = restored,
            .still_owned = owned,
            .reason = if (o == null) "output_removed" else if (!restored and !owned) "newer_state_preserved" else null,
        };
    }
    var revision: [20]u8 = undefined;
    try json.write(.{ .session = server.shell_manager.session[0..32], .token = l.token, .state = @tagName(l.state), .reason = l.reason, .remaining_ms = if (active()) @max(0, l.deadline_ms - now()) else 0, .display_revision = try std.fmt.bufPrint(&revision, "{d}", .{server.om.display_revision}), .candidate_digest = l.candidate_digest, .expected_generation = l.generation, .after_generation = l.after_generation, .rollback_partial = l.rollback_partial, .fallback_used = l.fallback_used, .affected_outputs = affected[0..l.len], .affected_output_count = l.len, .supported_actions = .{ .revert = active() and !commitActive(), .commit = l.state == .previewing and now() < l.deadline_ms } });
}

pub fn source(params: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = params.get(key) orelse return error.Invalid;
    if (value != .string or value.string.len > 1024 * 1024 or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.Invalid;
    return value.string;
}
fn displayDigest(wm: []const u8, outputs: []const u8) ![64]u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, .{ wm, outputs }, .{});
    defer a.free(bytes);
    return Tx.digest(bytes);
}

pub fn commitActive() bool {
    return if (lease) |l| l.state == .commit_authorized else false;
}
pub fn authorize(params: std.json.ObjectMap) !void {
    try checkToken(try Codec.string(params, "token"));
    const l = &lease.?;
    const id = try Codec.string(params, "operation_id");
    if (!Tx.validOperationId(id)) return error.Invalid;
    if (l.state != .previewing or now() >= l.deadline_ms) return error.LeaseExpired;
    if (l.revision != server.om.display_revision) return error.StaleRevision;
    if (!std.mem.eql(u8, &l.candidate_digest, try Codec.string(params, "candidate_digest")) or
        !std.mem.eql(u8, &l.generation, try Codec.string(params, "expected_generation")) or
        !std.mem.eql(u8, &l.display_digest, &try displayDigest(try source(params, "wm_source"), try source(params, "outputs_source")))) return error.CandidateMismatch;
    const intent_path = try Tx.receiptPath(a, id, "intent");
    defer a.free(intent_path);
    const intent = try Tx.readOptional(a, std.Io.Threaded.global_single_threaded.io(), intent_path, 4096) orelse return error.OperationRecordRequired;
    defer a.free(intent);
    @memcpy(l.operation_id[0..id.len], id);
    l.operation_len = id.len;
    l.state = .commit_authorized;
    l.deadline_ms = now() + 10000;
    l.reason = "canonical_commit_authorized";
}
pub fn finalize(params: std.json.ObjectMap) !void {
    try checkToken(try Codec.string(params, "token"));
    const l = &lease.?;
    if (!std.mem.eql(u8, l.operation_id[0..l.operation_len], try Codec.string(params, "operation_id"))) return error.CandidateMismatch;
    if (l.state == .kept) return;
    if (l.state != .commit_authorized) return error.LeaseExpired;
    try readDecision();
}
fn readDecision() !void {
    const l = &lease.?;
    const path = try Tx.receiptPath(a, l.operation_id[0..l.operation_len], "decision");
    defer a.free(path);
    const bytes = try Tx.readOptional(a, std.Io.Threaded.global_single_threaded.io(), path, 65536) orelse return error.CommitNotDurable;
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (!std.mem.eql(u8, try Codec.string(obj, "save"), "saved") or
        !std.mem.eql(u8, try Codec.string(obj, "candidate_digest"), &l.candidate_digest)) return error.CommitNotDurable;
    const generation = try Codec.string(obj, "after_generation");
    if (generation.len != 16) return error.Invalid;
    l.after_generation = generation[0..16].*;
    l.state = .kept;
    l.revision = server.om.display_revision;
    l.reason = "canonical_commit_durable";
}
fn reconcileCommit() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const lock = try Tx.Lock.acquire(a, io, false);
    defer lock.release();
    _ = try Tx.recover(a, io);
    try readDecision();
}
// Watcher and explicit reload acknowledgements may observe the same adopted
// generation. Skip its output apply while this lease still owns the revision.
pub fn consumeAdoptedGeneration(generation: [16]u8) bool {
    const l = if (lease) |*v| v else return false;
    if (l.state != .kept or l.revision != server.om.display_revision) return false;
    const adopted = l.after_generation orelse return false;
    if (!std.mem.eql(u8, &adopted, &generation)) return false;
    l.revision += 1;
    return true;
}

pub fn hotplug() void {
    if (active()) revert("hotplug", null);
}

pub fn competingChange() void {
    if (active()) revert("competing_change", null);
    server.om.display_revision += 1;
}

pub fn deinit() void {
    if (timer) |t| t.remove();
    timer = null;
    if (lease) |l| a.destroy(l.configs);
    lease = null;
    server.aqueous.output_service.preview_config = null;
    server.aqueous.output_service.preview_persisted = null;
}
