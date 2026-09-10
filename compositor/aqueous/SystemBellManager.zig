// SPDX-License-Identifier: GPL-3.0-only
const Manager = @This();
const std = @import("std");
const c = @import("c");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const server = &@import("main.zig").server;
const util = @import("util.zig");
const bell = @import("system_bell.zig");
const Overlay = @import("BellOverlay.zig");
const Audio = @import("BellAudio.zig");
const Output = @import("Output.zig");
const Window = @import("Window.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Event = c.struct_wlr_xdg_system_bell_v1_ring_event;

manager: ?*c.struct_wlr_xdg_system_bell_v1 = null,
ring: wl.Listener(*Event) = .init(handleRing),
overlay: ?Overlay = null,
audio: Audio = .{},
timer: ?*wl.EventSource = null,
config: bell.Config = .{},
policy: bell.Policy = .{},
visual_target: ?Target = null,
audio_target: ?Target = null,
visual_deadline: u64 = 0,

const Target = struct {
    id: u64,
    box: wlr.Box,
    scale: f32,
    transform: wl.Output.Transform,

    fn from(output: *Output) ?Target {
        const wlr_output = output.wlr_output orelse return null;
        if (!wlr_output.enabled or output.current.state != .enabled or !output.policyTransferTarget()) return null;
        const box = output.current.box();
        if (box.width <= 0 or box.height <= 0) return null;
        return .{ .id = output.policyId(), .box = box, .scale = output.current.scale, .transform = output.current.transform };
    }

    fn valid(target: Target) bool {
        var outputs = server.om.outputs.iterator(.forward);
        while (outputs.next()) |output| {
            if (output.policyId() != target.id) continue;
            const current = from(output) orelse return false;
            return std.meta.eql(current, target) and std.meta.eql(output.scheduled.box(), target.box) and
                output.scheduled.scale == target.scale and output.scheduled.transform == target.transform;
        }
        return false;
    }
};

pub fn init(manager: *Manager) !void {
    manager.overlay = try Overlay.init(&server.scene.wlr_scene.tree);
    errdefer {
        manager.overlay.?.deinit();
        manager.overlay = null;
    }
    // This tree is outside input picking; keep drag icons above it.
    server.scene.drag_icons.node.raiseToTop();
    manager.timer = try server.wl_server.getEventLoop().addTimer(*Manager, handleTimer, manager);
    errdefer {
        manager.timer.?.remove();
        manager.timer = null;
    }
    manager.manager = c.wlr_xdg_system_bell_v1_create(@ptrCast(server.wl_server), 1) orelse return error.OutOfMemory;
    const signal: *wl.Signal(*Event) = @ptrCast(&manager.manager.?.events.ring);
    signal.add(&manager.ring);
    manager.config = server.aqueous.config.wm.bell;
}

pub fn global(manager: Manager) *wl.Global {
    return @ptrCast(manager.manager.?.global);
}

pub fn configure(manager: *Manager, config: *const bell.Config) void {
    if (!manager.config.eql(config)) manager.cancel();
    manager.config = config.*;
}

pub fn cancel(manager: *Manager) void {
    if (manager.overlay) |*overlay| overlay.hide();
    manager.visual_target = null;
    manager.audio_target = null;
    manager.audio.cancel(nowMs());
    manager.arm();
}

pub fn outputRemoved(manager: *Manager, id: u64) void {
    if (manager.visual_target) |target| if (target.id == id) {
        manager.overlay.?.hide();
        manager.visual_target = null;
    };
    if (manager.audio_target) |target| if (target.id == id) {
        manager.audio.cancel(nowMs());
        manager.audio_target = null;
    };
}

pub fn validateTargets(manager: *Manager) void {
    if (manager.visual_target) |target| if (!target.valid()) {
        manager.overlay.?.hide();
        manager.visual_target = null;
    };
    if (manager.audio_target) |target| if (!target.valid()) {
        manager.audio.cancel(nowMs());
        manager.audio_target = null;
    };
}

pub fn deinit(manager: *Manager) void {
    if (manager.manager != null) manager.ring.link.remove();
    if (manager.timer) |timer| timer.remove();
    manager.timer = null;
    manager.audio.deinit();
    if (manager.overlay) |*overlay| overlay.deinit();
    manager.overlay = null;
    manager.visual_target = null;
    manager.audio_target = null;
}

fn windowTarget(window: *Window, surface: *wlr.Surface) ?Target {
    if (window.state != .mapped or window.rootSurface() != surface or !surface.mapped) return null;
    // Do not reveal hidden/minimized/occluded-by-policy scene trees.
    var node = &window.tree.node;
    while (true) {
        if (!node.enabled) return null;
        node = if (node.parent) |parent| &parent.node else break;
    }
    const workspace = window.workspace orelse return null;
    const output = workspace.output;
    if (!output.policyWorkspaceActive(workspace)) return null;
    return Target.from(output);
}

fn targetFor(event: *Event) ?Target {
    if (event.surface) |raw| {
        const surface: *wlr.Surface = @ptrCast(@alignCast(raw));
        const data = SceneNodeData.fromSurface(surface) orelse return null;
        return switch (data.data) {
            .window => |window| windowTarget(window, surface),
            else => null,
        };
    }
    // Seat creation order is stable. Pick the first eligible focused client window.
    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| {
        if (seat.focused != .window) continue;
        const window = seat.focused.window;
        const surface = window.rootSurface() orelse continue;
        if (@intFromPtr(surface.resource.getClient()) != @intFromPtr(event.client)) continue;
        if (windowTarget(window, surface)) |target| return target;
    }
    return null;
}

fn handleRing(listener: *wl.Listener(*Event), event: *Event) void {
    const manager: *Manager = @fieldParentPtr("ring", listener);
    if (server.lock_manager.state != .unlocked or manager.config.mode == .off) return;
    const target = targetFor(event) orelse return;
    const now = nowMs();
    if (!manager.policy.accept(now, &manager.config, true, false)) return;
    if (manager.config.visual()) {
        manager.overlay.?.show(target.box);
        manager.visual_target = target;
        manager.visual_deadline = now + bell.visual_ms;
    }
    if (manager.audio.pid == null and manager.config.sound()) {
        manager.audio.play(&manager.config, now);
        if (manager.audio.pid != null) manager.audio_target = target;
    }
    manager.arm();
}

fn handleTimer(manager: *Manager) c_int {
    const now = nowMs();
    manager.audio.poll(now);
    if (manager.audio.pid == null) manager.audio_target = null;
    if (server.lock_manager.state != .unlocked) manager.cancel();
    manager.validateTargets();
    if (manager.visual_target != null and now >= manager.visual_deadline) {
        manager.overlay.?.hide();
        manager.visual_target = null;
    }
    manager.arm();
    return 0;
}

fn arm(manager: *Manager) void {
    const timer = manager.timer orelse return;
    // Only poll while feedback or a child exists. No idle wakeups after expiry.
    timer.timerUpdate(if (manager.visual_target != null or manager.audio.pid != null) 10 else 0) catch {
        if (manager.overlay) |*overlay| overlay.hide();
        manager.visual_target = null;
        manager.audio.deinit();
        manager.audio_target = null;
    };
}

fn nowMs() u64 {
    const now = util.timestamp();
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / 1_000_000;
}
