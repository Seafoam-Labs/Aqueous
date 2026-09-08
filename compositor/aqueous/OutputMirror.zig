// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! A physical output consumes copies of a source's composed image. No client
//! surface, frame callback or scene node is owned by the mirror. One copy may
//! be in flight; the wlroots swapchain bounds storage to four buffers.
const Mirror = @This();
const std = @import("std");
const c = @import("c");
const wlr = @import("wlroots");
const Output = @import("Output.zig");
const util = @import("util.zig");
const server = &@import("main.zig").server;
const geometry = @import("wm/output/mirror.zig");
// Also bound retired generations during repeated hotplug/mode changes.
var in_flight_copies: usize = 0;

swapchain: ?*wlr.Swapchain = null,
latest: ?*wlr.Buffer = null,
submitted: ?*wlr.Buffer = null,
blank_buffer: ?*wlr.Buffer = null,
blank_timeline: ?*c.struct_wlr_drm_syncobj_timeline = null,
commit_seq: u32 = 0,
job: ?*Copy = null,
requested: bool = true,
source_dirty: bool = true,
source_id: u64 = 0,
source_width: i32 = 0,
source_height: i32 = 0,
failure: ?[]const u8 = null,
copies: u64 = 0,
reported_status: []const u8 = "",

// A copy outlives its output if necessary. Its waiter only releases resources;
// it never dereferences a destroyed output or publishes a stale generation.
const Copy = struct {
    source: *wlr.Buffer,
    buffer: *wlr.Buffer,
    timeline: ?*c.struct_wlr_drm_syncobj_timeline = null,
    waiter: c.struct_wlr_drm_syncobj_timeline_waiter = undefined,
    complete: bool = false,
    orphaned: bool = false,

    fn ready(waiter: [*c]c.struct_wlr_drm_syncobj_timeline_waiter) callconv(.c) void {
        const copy: *Copy = @fieldParentPtr("waiter", @as(*c.struct_wlr_drm_syncobj_timeline_waiter, @ptrCast(waiter)));
        c.wlr_drm_syncobj_timeline_waiter_finish(&copy.waiter);
        copy.source.unlock();
        in_flight_copies -= 1;
        copy.complete = true;
        if (copy.orphaned) copy.destroy();
    }

    fn destroy(copy: *Copy) void {
        std.debug.assert(copy.complete);
        copy.buffer.unlock();
        if (copy.timeline) |timeline| c.wlr_drm_syncobj_timeline_unref(timeline);
        util.gpa.destroy(copy);
    }
};

pub fn supported() bool {
    // Pixman completes synchronously. GPU support requires explicit completion
    // so a slow copy cannot cause a CPU wait or premature source-buffer reuse.
    return server.renderer.isPixman() or server.renderer.features.timeline;
}

pub fn reset(mirror: *Mirror) void {
    if (mirror.job) |copy| {
        if (copy.complete) copy.destroy() else copy.orphaned = true;
    }
    if (mirror.latest) |buffer| buffer.unlock();
    if (mirror.submitted) |buffer| buffer.unlock();
    if (mirror.blank_buffer) |buffer| buffer.unlock();
    if (mirror.blank_timeline) |timeline| c.wlr_drm_syncobj_timeline_unref(timeline);
    if (mirror.swapchain) |swapchain| swapchain.destroy();
    mirror.* = .{};
}

fn source(output: *Output) ?*Output {
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |candidate| {
        if (candidate == output or candidate.wlr_output == null) continue;
        if (!candidate.current.mirror_of.empty() or candidate.current.state != .enabled or candidate.sent.state != .enabled) continue;
        if (candidate.current.hdr_enabled or candidate.current.transform != .normal) continue;
        if (std.mem.eql(u8, candidate.policyName(), output.sent.mirror_of.slice())) return candidate;
    }
    return null;
}

pub fn status(mirror: *const Mirror, output: *Output) []const u8 {
    if (output.scheduled.mirror_of.empty()) return "extended";
    if (mirror.failure != null) return "error";
    if (server.lock_manager.state != .unlocked or output.current.state != .enabled) return "suspended";
    if (source(output) == null) return "waiting_for_source";
    return if (mirror.latest != null) "active" else "starting";
}

pub fn notifyStatus(mirror: *Mirror, output: *Output) void {
    const current_status = mirror.status(output);
    if (std.mem.eql(u8, mirror.reported_status, current_status)) return;
    mirror.reported_status = current_status;
    server.aqueous.output_service.outputsChanged(false);
}

pub fn invalidateAll() void {
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (output.current.mirror_of.empty()) continue;
        output.mirror.reset();
        if (output.wlr_output) |physical| physical.scheduleFrame();
    }
}

pub fn reconcile() void {
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        const physical = output.wlr_output orelse continue;
        var needed = false;
        var destinations = server.om.outputs.iterator(.forward);
        while (destinations.next()) |dest| {
            if (dest.current.state != .enabled or dest.current.mirror_of.empty()) continue;
            if (source(dest) == output) {
                needed = true;
                break;
            }
        }
        if (needed != output.mirror_source_locked) {
            physical.lockAttachRender(needed);
            physical.lockSoftwareCursors(needed);
            output.mirror_source_locked = needed;
            if (output.scene_output) |scene| scene.damage_ring.addWhole();
            physical.scheduleFrame();
        }
        if (output.current.mirror_of.empty() or output.current.state != .enabled) {
            output.mirror.reset();
            continue;
        }
        const src = source(output);
        const id = if (src) |s| s.policyId() else 0;
        if (id != output.mirror.source_id) {
            output.mirror.reset();
            output.mirror.source_id = id;
            physical.scheduleFrame();
        }
    }
}

/// Called after successful source commits. GPU reads wait on the source's
/// render timeline; the copy waiter keeps both buffers locked until completion.
pub fn capture(output: *Output, state: *const wlr.Output.State) void {
    if (!output.sent.mirror_of.empty()) {
        if (state.buffer) |buffer| {
            if (output.mirror.submitted) |old| old.unlock();
            output.mirror.submitted = buffer.lock();
            output.mirror.commit_seq = output.wlr_output.?.commit_seq;
        }
        return;
    }
    if (!output.mirror_source_locked or server.lock_manager.state != .unlocked) return;
    const buffer = state.buffer orelse return;
    var destinations = server.om.outputs.iterator(.forward);
    while (destinations.next()) |dest| {
        if (source(dest) != output or dest.current.state != .enabled) continue;
        const mirror = &dest.mirror;
        mirror.source_dirty = true;
        if (!mirror.requested or mirror.job != null or in_flight_copies != 0) continue;
        const chain = mirror.swapchain orelse continue;
        const target = chain.acquire() catch continue;
        const texture = wlr.Texture.fromBuffer(server.renderer, buffer) orelse {
            target.unlock();
            mirror.failure = "cannot sample source output buffer";
            continue;
        };
        defer texture.destroy();
        const copy = util.gpa.create(Copy) catch {
            target.unlock();
            continue;
        };
        copy.* = .{ .source = buffer.lock(), .buffer = target };
        var options: c.struct_wlr_buffer_pass_options = std.mem.zeroes(c.struct_wlr_buffer_pass_options);
        if (!server.renderer.isPixman()) {
            copy.timeline = c.wlr_drm_syncobj_timeline_create(server.renderer.getDrmFd());
            if (copy.timeline == null or !c.wlr_drm_syncobj_timeline_waiter_init(&copy.waiter, copy.timeline, 1, 0, @ptrCast(server.wl_server.getEventLoop()), Copy.ready)) {
                buffer.unlock();
                copy.complete = true;
                copy.destroy();
                mirror.failure = "cannot create copy completion fence";
                continue;
            }
            options.signal_timeline = copy.timeline;
            options.signal_point = 1;
        }
        const pass = c.wlr_renderer_begin_buffer_pass(@ptrCast(server.renderer), @ptrCast(target), &options);
        if (pass == null) {
            if (copy.timeline != null) c.wlr_drm_syncobj_timeline_waiter_finish(&copy.waiter);
            buffer.unlock();
            copy.complete = true;
            copy.destroy();
            mirror.failure = "cannot begin mirror render pass";
            continue;
        }
        black(pass, target.width, target.height);
        var tex: c.struct_wlr_render_texture_options = std.mem.zeroes(c.struct_wlr_render_texture_options);
        tex.texture = @ptrCast(texture);
        const box = geometry.fit(buffer.width, buffer.height, target.width, target.height);
        tex.dst_box = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        tex.blend_mode = c.WLR_RENDER_BLEND_MODE_NONE;
        tex.transfer_function = c.WLR_COLOR_TRANSFER_FUNCTION_GAMMA22;
        tex.wait_timeline = @ptrCast(@alignCast(state.wait_timeline));
        tex.wait_point = state.wait_point;
        c.wlr_render_pass_add_texture(pass, &tex);
        if (!c.wlr_render_pass_submit(pass)) {
            if (copy.timeline != null) c.wlr_drm_syncobj_timeline_waiter_finish(&copy.waiter);
            buffer.unlock();
            copy.complete = true;
            copy.destroy();
            mirror.failure = "mirror render submission failed";
            continue;
        }
        if (copy.timeline == null) {
            buffer.unlock();
            copy.complete = true;
        }
        if (copy.timeline != null) in_flight_copies += 1;
        mirror.job = copy;
        mirror.requested = false;
        mirror.source_dirty = false;
        mirror.failure = null;
        mirror.copies += 1;
    }
}

fn black(pass: ?*c.struct_wlr_render_pass, width: i32, height: i32) void {
    var rect: c.struct_wlr_render_rect_options = std.mem.zeroes(c.struct_wlr_render_rect_options);
    rect.box = .{ .x = 0, .y = 0, .width = width, .height = height };
    rect.color.a = 1;
    rect.blend_mode = c.WLR_RENDER_BLEND_MODE_NONE;
    c.wlr_render_pass_add_rect(pass, &rect);
}

/// Build a physical destination state, never a scene-output state. This also
/// handles modesets using the swapchain selected by the backend transaction.
pub fn build(mirror: *Mirror, output: *Output, state: *wlr.Output.State, supplied: ?*wlr.Swapchain) bool {
    const physical = output.wlr_output orelse return false;
    if ((state.committed.enabled and !state.enabled) or output.sent.state != .enabled) return true;
    const width, const height = output.sent.physicalDimensions();
    if (width <= 0 or height <= 0) return false;
    const src = source(output);
    const sw = if (src) |s| s.wlr_output.?.width else 0;
    const sh = if (src) |s| s.wlr_output.?.height else 0;
    if (mirror.swapchain) |chain| {
        if (chain.width != width or chain.height != height or mirror.source_width != sw or mirror.source_height != sh) mirror.reset();
    }
    mirror.source_id = if (src) |v| v.policyId() else 0;
    mirror.source_width = sw;
    mirror.source_height = sh;
    if (server.lock_manager.state != .unlocked or src == null) {
        if (mirror.latest != null or mirror.job != null) mirror.reset();
    } else if (mirror.job) |copy| {
        if (copy.complete) {
            if (mirror.latest) |latest| latest.unlock();
            mirror.latest = copy.buffer.lock();
            copy.destroy();
            mirror.job = null;
        }
    }
    if (mirror.swapchain == null) {
        var chain = supplied orelse physical.swapchain;
        if (chain == null and !c.wlr_output_configure_primary_swapchain(@ptrCast(physical), @ptrCast(state), @ptrCast(&chain))) return false;
        const format = &(chain orelse return false).format;
        mirror.swapchain = wlr.Swapchain.create(server.allocator, width, height, format) catch {
            mirror.failure = "cannot allocate mirror swapchain";
            return false;
        };
    }
    mirror.requested = true;
    // A source may go idle after committing while the previous copy was busy.
    // Request one fresh composition so its final update cannot be lost.
    if (src) |s| if (server.lock_manager.state == .unlocked and mirror.job == null and mirror.source_dirty) {
        s.scene_output.?.damage_ring.addWhole();
        s.wlr_output.?.scheduleFrame();
    };
    if (mirror.latest) |latest| {
        state.setBuffer(latest);
    } else {
        if (mirror.blank_buffer) |buffer| {
            state.setBuffer(buffer);
            if (mirror.blank_timeline) |t| c.wlr_output_state_set_wait_timeline(@ptrCast(state), t, 1);
            if (src) |s| if (server.lock_manager.state == .unlocked and mirror.job == null) {
                s.scene_output.?.damage_ring.addWhole();
                s.wlr_output.?.scheduleFrame();
            };
            return true;
        }
        const buffer = mirror.swapchain.?.acquire() catch return false;
        defer buffer.unlock();
        var options: c.struct_wlr_buffer_pass_options = std.mem.zeroes(c.struct_wlr_buffer_pass_options);
        const explicit = !server.renderer.isPixman() and physical.isDrm() and physical.backend.features.timeline;
        const timeline = if (!explicit) null else c.wlr_drm_syncobj_timeline_create(server.renderer.getDrmFd());
        defer if (timeline) |t| c.wlr_drm_syncobj_timeline_unref(t);
        if (explicit and timeline == null) return false;
        options.signal_timeline = timeline;
        options.signal_point = 1;
        const pass = c.wlr_renderer_begin_buffer_pass(@ptrCast(server.renderer), @ptrCast(buffer), &options) orelse return false;
        black(pass, width, height);
        if (!c.wlr_render_pass_submit(pass)) return false;
        state.setBuffer(buffer);
        mirror.blank_buffer = buffer.lock();
        if (timeline) |t| {
            mirror.blank_timeline = c.wlr_drm_syncobj_timeline_ref(t);
            c.wlr_output_state_set_wait_timeline(@ptrCast(state), t, 1);
        }
        if (src) |s| if (server.lock_manager.state == .unlocked and mirror.job == null) {
            s.scene_output.?.damage_ring.addWhole();
            s.wlr_output.?.scheduleFrame();
        };
    }
    state.tearing_page_flip = false;
    return true;
}
