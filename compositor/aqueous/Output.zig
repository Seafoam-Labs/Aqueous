// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Output = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const scaling = @import("scaling.zig");

const fx = @import("fx.zig");
const LayerShellOutput = @import("LayerShellOutput.zig");
const LockSurface = @import("LockSurface.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");

const log = std.log.scoped(.output);

pub const State = struct {
    pub const PositionSource = enum {
        automatic,
        configuration,
        output_management,
    };

    state: enum {
        /// Powered on and exposed to the window manager
        enabled,
        /// Powered off and exposed to the window manager
        disabled_soft,
        /// Powered off and hidden from the window manager
        disabled_hard,
        /// Corresponding hardware no longer present
        destroying,
    },
    /// Logical coordinate space
    x: i32,
    /// Logical coordinate space
    y: i32,
    /// The width/height of modes is in physical pixels, not in the
    /// compositors logical coordinate space.
    mode: union(enum) {
        standard: *wlr.Output.Mode,
        custom: struct {
            width: i32,
            height: i32,
            refresh: i32,
        },
        /// Used before the initial modeset and after the wlr_output is destroyed.
        none,
    },
    scale: f32,
    transform: wl.Output.Transform,
    adaptive_sync: bool,
    position_source: PositionSource,

    pub fn fromHeadState(state: *const wlr.OutputHeadV1.State) State {
        assert(state.enabled);
        const requested_scale: f32 = @floatCast(state.scale);
        const clamped_scale = scaling.clampScale(requested_scale);
        if (clamped_scale != requested_scale) {
            std.log.scoped(.output).info(
                "output {s}: scale {d} clamped to {d}",
                .{ state.output.name, requested_scale, clamped_scale },
            );
        }
        return .{
            .state = .enabled,
            .mode = blk: {
                if (state.mode) |mode| {
                    break :blk .{ .standard = mode };
                } else {
                    break :blk .{ .custom = .{
                        .width = state.custom_mode.width,
                        .height = state.custom_mode.height,
                        .refresh = state.custom_mode.refresh,
                    } };
                }
            },
            .x = state.x,
            .y = state.y,
            .scale = scaling.roundScale(clamped_scale),
            .transform = state.transform,
            .adaptive_sync = state.adaptive_sync_enabled,
            .position_source = .output_management,
        };
    }

    /// Width/height in the logical coordinate space
    pub fn dimensions(state: *const State) struct { u31, u31 } {
        var w: i32, var h: i32 = switch (state.mode) {
            .standard => |mode| .{ mode.width, mode.height },
            .custom => |mode| .{ mode.width, mode.height },
            .none => .{ 0, 0 },
        };
        if (@mod(@intFromEnum(state.transform), 2) != 0) {
            mem.swap(i32, &w, &h);
        }
        return .{
            @intFromFloat(@as(f32, @floatFromInt(w)) / state.scale),
            @intFromFloat(@as(f32, @floatFromInt(h)) / state.scale),
        };
    }

    pub fn box(state: *const State) wlr.Box {
        const w, const h = state.dimensions();
        return .{ .x = state.x, .y = state.y, .width = w, .height = h };
    }

    pub fn applyNoModeset(state: *const State, wlr_state: *wlr.Output.State) void {
        wlr_state.setScale(state.scale);
        wlr_state.setTransform(state.transform);
    }

    pub fn applyModeset(state: *const State, wlr_state: *wlr.Output.State) void {
        const enabled = state.state == .enabled;
        wlr_state.setEnabled(enabled);
        if (!enabled) return;
        state.applyNoModeset(wlr_state);
        switch (state.mode) {
            .standard => |mode| wlr_state.setMode(mode),
            .custom => |mode| wlr_state.setCustomMode(mode.width, mode.height, mode.refresh),
            .none => {},
        }
        wlr_state.setAdaptiveSyncEnabled(state.adaptive_sync);
    }
};

const RenderingState = struct {
    tearing: bool,
    const init: RenderingState = .{
        .tearing = false,
    };
};

/// Set to null when the wlr_output is destroyed.
wlr_output: ?*wlr.Output,
scene_output: ?*wlr.SceneOutput,

object: ?*river.OutputV1 = null,
layer_shell: LayerShellOutput = .{},

/// Tracks the currently presented frame on the output as it pertains to ext-session-lock.
/// The output is initially considered blanked:
/// If using the DRM backend it will be blanked with the initial modeset.
/// If using the Wayland or X11 backend nothing will be visible until the first frame is rendered.
lock_render_state: enum {
    /// Submitted an unlocked buffer but the buffer has not yet been presented.
    pending_unlock,
    /// Normal, "unlocked" content may be visible.
    unlocked,
    /// Submitted a blank buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_blank,
    /// A blank buffer has been presented.
    blanked,
    /// Submitted the lock surface buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_lock_surface,
    /// The lock surface buffer has been presented.
    lock_surface,
} = .blanked,

/// Root.outputs
link: wl.list.Link,

/// Ordered list of workspaces belonging to this output.
workspaces: wl.list.Head(Workspace, .link),
/// The single workspace currently visible on this output.
active_workspace: ?*Workspace = null,

/// Workspace currently sliding out during a switch (null when not
/// transitioning). A non-null value is the single source of truth that a
/// workspace-swap slide animation is in flight on this output.
prev_workspace: ?*Workspace = null,
/// Sign of the slide direction during a transition: +1 means the incoming
/// workspace enters from the right (outgoing exits left), -1 the reverse.
transition_dir: i32 = 0,
/// True once `renderFinish` has actually armed the current workspace-swap
/// slide. Guards `finalizeTransition` against running before the (async)
/// windowing transaction has seeded/armed the participating windows, which
/// would otherwise cancel the transition before it visibly begins.
transition_armed: bool = false,

/// State to be sent to the wm in the next manage sequence.
scheduled: State,
/// State sent to the wm in the latest manage sequence.
sent: State,
link_sent: wl.list.Link,
sent_wl_output: bool = false,
/// The wl_output global for which `river_output_v1.wl_output` was last sent.
/// Tracked so the event is re-sent if wlroots destroys and recreates the
/// global (e.g. on hotplug/modeset), which would otherwise leave the wm
/// client referencing a stale global name.
sent_wl_output_global: ?*wl.Global = null,
/// Rendering state requested by the window manager.
rendering_requested: RenderingState = .init,
/// State applied to the wlr_output and rendered.
current: State,
rendering_current: RenderingState = .init,

/// Monotonic timestamp (nanoseconds) of the previous frame, used to compute the
/// frame-rate-independent delta time for window position animations. 0 means no
/// previous frame has been recorded yet.
anim_last_ns: i64 = 0,

/// SceneFX optimized backdrop blur for this output. `blur_box` records the
/// geometry used to produce the cached texture so moves and modesets can
/// invalidate it without forcing regeneration on every frame.
blur_node: ?*anyopaque = null,
blur_box: ?wlr.Box = null,

destroy: wl.Listener(*wlr.Output) = .init(handleDestroy),
request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
frame: wl.Listener(*wlr.Output) = .init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = .init(handlePresent),
commit: wl.Listener(*wlr.Output.event.Commit) = .init(handleCommit),
bind: wl.Listener(*wlr.Output.event.Bind) = .init(handleBind),

/// Stable identity used by the in-process policy. This is deliberately derived from the
/// output object's address only for the lifetime of the output; policy state is discarded
/// when the output no longer appears in a manage-cycle snapshot.
pub fn policyId(output: *const Output) u64 {
    return @intFromPtr(output);
}

fn boxesEqual(a: wlr.Box, b: wlr.Box) bool {
    return a.x == b.x and a.y == b.y and
        a.width == b.width and a.height == b.height;
}

/// Synchronize the output-local optimized blur node with the current output
/// state. Scene graph coordinates are logical, matching State.box().
pub fn syncBlur(output: *Output, force_dirty: bool) void {
    if (comptime !fx.blur_available) return;

    const active = server.wm.blur.enabled and
        server.wm.blur.radius > 0 and
        server.wm.blur.passes > 0 and
        output.current.state == .enabled and
        output.current.mode != .none;
    if (!active) {
        if (output.blur_node) |node| fx.setOptimizedBlurEnabled(node, false);
        // Re-enabling must regenerate the cached backdrop even if the output
        // returns with identical geometry.
        output.blur_box = null;
        return;
    }

    const box = output.current.box();
    if (box.width == 0 or box.height == 0) return;

    var created = false;
    if (output.blur_node == null) {
        output.blur_node = fx.createOptimizedBlur(
            server.scene.layers.wm,
            box.width,
            box.height,
        );
        created = output.blur_node != null;
    }

    const node = output.blur_node orelse return;
    const geometry_changed = if (output.blur_box) |old| !boxesEqual(old, box) else true;
    fx.configureOptimizedBlur(node, box, true, force_dirty or created or geometry_changed);
    output.blur_box = box;

    if (created or geometry_changed) {
        const name = if (output.wlr_output) |wlr_output| std.mem.span(wlr_output.name) else "unknown";
        log.debug("blur node for {s}: {d}x{d} at {d},{d}", .{
            name,
            box.width,
            box.height,
            box.x,
            box.y,
        });
    }
}

/// Invalidate the cached backdrop after a background/bottom layer change.
pub fn markBlurDirty(output: *Output) void {
    if (comptime !fx.blur_available) return;
    if (!server.wm.blur.enabled or output.current.state != .enabled) return;
    if (output.blur_node) |node| fx.markOptimizedBlurDirty(node);
}

fn destroyBlur(output: *Output) void {
    if (comptime !fx.blur_available) return;
    if (output.blur_node) |node| fx.destroyOptimizedBlur(node);
    output.blur_node = null;
    output.blur_box = null;
}

/// Full output geometry exposed to the in-process policy.
pub fn policyFullBox(output: *const Output) wlr.Box {
    return output.scheduled.box();
}

/// Output geometry remaining after layer-shell exclusive zones are reserved.
pub fn policyUsableBox(output: *const Output) wlr.Box {
    const usable = output.layer_shell.scheduled.non_exclusive_area;
    if (usable.width > 0 and usable.height > 0) return usable;
    return output.policyFullBox();
}

pub fn policyName(output: *const Output) []const u8 {
    return if (output.wlr_output) |wlr_output| std.mem.span(wlr_output.name) else "";
}

pub const PolicyIdentity = struct {
    name: []const u8,
    make: ?[]const u8,
    model: ?[]const u8,
    serial: ?[]const u8,
};

pub fn policyIdentity(output: *const Output) PolicyIdentity {
    const wlr_output = output.wlr_output orelse return .{ .name = "", .make = null, .model = null, .serial = null };
    return .{
        .name = std.mem.span(wlr_output.name),
        .make = if (wlr_output.make) |value| std.mem.span(value) else null,
        .model = if (wlr_output.model) |value| std.mem.span(value) else null,
        .serial = if (wlr_output.serial) |value| std.mem.span(value) else null,
    };
}

pub fn policyActiveWorkspaceNumber(output: *Output) u32 {
    const active = output.active_workspace orelse return 0;
    var number: u32 = 1;
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| : (number += 1) if (workspace == active) return number;
    return 0;
}

pub fn policyWorkspaceAt(output: *Output, requested: u32) ?*Workspace {
    if (requested == 0) return null;
    var number: u32 = 1;
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| : (number += 1) if (number == requested) return workspace;
    return null;
}

pub fn policyWorkspaceActive(output: *const Output, workspace: ?*const Workspace) bool {
    return workspace == null or workspace == output.active_workspace;
}

pub fn policyTrace(output: *const Output, hasher: *std.hash.Wyhash) void {
    const name = if (output.wlr_output) |wlr_output| std.mem.span(wlr_output.name) else "";
    hasher.update(name);
    const workspace_id: u32 = if (output.active_workspace) |workspace| workspace.policyId() else 0;
    hasher.update(std.mem.asBytes(&workspace_id));
}

pub fn create(wlr_output: *wlr.Output) !void {
    const output = try util.gpa.create(Output);
    errdefer util.gpa.destroy(output);

    {
        const title = try fmt.allocPrintSentinel(util.gpa, "river - {s}", .{wlr_output.name}, 0);
        defer util.gpa.free(title);
        if (wlr_output.isWl()) {
            wlr_output.wlSetAppId("river");
            wlr_output.wlSetTitle(title);
        } else if (wlr.config.has_x11_backend and wlr_output.isX11()) {
            wlr_output.x11SetTitle(title);
        }
    }

    if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

    const scene_output = try server.scene.wlr_scene.createSceneOutput(wlr_output);
    errdefer comptime unreachable;

    const initial: State = .{
        .state = .disabled_hard,
        .x = 0,
        .y = 0,
        .mode = .none,
        .scale = 1,
        .transform = .normal,
        .adaptive_sync = wlr_output.adaptive_sync_status == .enabled,
        .position_source = .automatic,
    };
    output.* = .{
        .wlr_output = wlr_output,
        .scene_output = scene_output,
        .scheduled = initial,
        .sent = initial,
        .current = initial,
        .link = undefined,
        .link_sent = undefined,
        .workspaces = undefined,
    };
    wlr_output.data = output;

    server.om.outputs.append(output);
    output.link_sent.init();
    output.workspaces.init();
    output.ensureWorkspaces();

    wlr_output.events.destroy.add(&output.destroy);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);
    wlr_output.events.commit.add(&output.commit);
    wlr_output.events.bind.add(&output.bind);

    output.scheduled.state = .enabled;
    if (wlr_output.preferredMode()) |preferred_mode| {
        output.scheduled.mode = .{ .standard = preferred_mode };
    } else {
        // The output does not support modes (i.e. we are not using the DRM backend)
        // Currently, wlroots does not make it possible for us know the dimensions
        // requested by the host compositor in the first configure event. Therefore,
        // we can't do anything but guess until the second configure is sent and
        // wlroots emits the wlr_output request_state event.
        // TODO(wlroots): fix this API limitation, for context see
        // https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/4963
        output.scheduled.mode = .{ .custom = .{ .width = 1280, .height = 720, .refresh = 0 } };
    }

    server.wm.dirtyWindowing();
}

/// Ensure the output has at least one workspace and an active workspace.
pub fn ensureWorkspaces(output: *Output) void {
    if (output.workspaces.first() == null) {
        var i: u32 = 1;
        while (i <= 9) : (i += 1) {
            var buf: [16]u8 = undefined;
            const name = fmt.bufPrint(&buf, "{d}", .{i}) catch "workspace";
            const ws = Workspace.create(output, name) catch {
                log.err("out of memory creating static workspace", .{});
                break;
            };
            ws.pinned = true;
        }
    }
    if (output.active_workspace == null) {
        output.active_workspace = output.workspaces.first();
    }
}

/// Make the given workspace the single active workspace on this output.
pub fn activateWorkspace(output: *Output, workspace: *Workspace) void {
    assert(workspace.output == output);
    const prev = output.active_workspace;
    if (prev == workspace) return;

    if (comptime fx.anim_enabled) {
        if (server.wm.workspace_transition.enabled) {
            if (prev) |p| {
                // Begin a workspace-swap slide. `renderFinish` keeps both the
                // outgoing (`prev_workspace`) and incoming (`active_workspace`)
                // workspaces rendered and offset; the transition is finalized in
                // `stepAnimations` once every participating window has settled.
                // If a transition is already in flight, retarget it: the workspace
                // sliding out is whichever one we are leaving now.
                output.prev_workspace = p;
                output.transition_dir = output.slideDirection(p, workspace);
                output.transition_armed = false;
                // The incoming windows must seed their clones off-screen on the
                // first transition frame; clear any stale seed flags so they do.
                var it = p.windows.iterator(.forward);
                while (it.next()) |w| w.slide_seeded = false;
                var it2 = workspace.windows.iterator(.forward);
                while (it2.next()) |w| w.slide_seeded = false;
            }
        }
    }

    output.active_workspace = workspace;
    // Reaping is intentionally not performed here: it is deferred to the end of
    // the workspace transaction so an in-flight batch cannot free a workspace
    // it still references. Other call sites (window unmap/move) reap directly.
    server.wm.dirtyWindowing();
    server.workspace_manager.dirty();
    if (output.wlr_output) |o| o.scheduleFrame();
}

/// Return the slide direction sign for a transition from `prev` to `next`:
/// +1 when `next` is ordered after `prev` in `output.workspaces` (new content
/// enters from the right), -1 otherwise.
fn slideDirection(output: *Output, prev: *Workspace, next: *Workspace) i32 {
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |w| {
        if (w == prev) return 1;
        if (w == next) return -1;
    }
    return 1;
}

/// Abort any in-flight workspace-swap slide, tearing down the participating
/// windows' clones so they cannot outlive their workspace (e.g. when an output
/// is disconnected, migrated, or cleared mid-transition).
pub fn cancelTransition(output: *Output) void {
    if (comptime !fx.anim_enabled) return;
    if (output.prev_workspace) |prev| {
        var it = prev.windows.iterator(.forward);
        while (it.next()) |w| w.cancelSlide();
    }
    if (output.active_workspace) |active| {
        var it = active.windows.iterator(.forward);
        while (it.next()) |w| w.cancelSlide();
    }
    output.prev_workspace = null;
    output.transition_dir = 0;
    output.transition_armed = false;
}

/// If a workspace-swap slide is in flight and every participating window has
/// settled, commit the end state: clear the transition so the outgoing
/// workspace's windows hit the non-visible gate (disabling their live trees) on
/// the next `renderFinish`, then reap the now-hidden empty workspace.
fn finalizeTransition(output: *Output) void {
    if (comptime !fx.anim_enabled) return;
    const prev = output.prev_workspace orelse return;
    // Do not finalize before `renderFinish` has armed the slide: an early frame
    // (scheduled by `activateWorkspace`) can beat the async windowing
    // transaction, at which point no window is animating yet and finalizing
    // here would cancel the transition before it visibly begins.
    if (!output.transition_armed) return;
    if (output.hasActiveAnimations()) return;
    output.prev_workspace = null;
    output.transition_dir = 0;
    output.transition_armed = false;
    server.wm.dirtyWindowing();
    if (!prev.pinned and prev.empty()) output.reapEmpty();
}

/// Made a noop as static exists but this is safer than removing the functionality entirely
pub fn ensureTrailingEmpty(output: *Output) void {
    if (output.workspaces.first() != null) return;
    _ = output.createWorkspace();
}

/// Destroy empty workspaces that are neither active nor the trailing one.
pub fn reapEmpty(output: *Output) void {
    const last = output.workspaces.last();
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| {
        if (workspace.pinned) continue;
        if (workspace == output.active_workspace) continue;
        // Never reap a workspace that is still sliding out: its windows' clones
        // are mid-transition and `Workspace.destroy` asserts the workspace is
        // inactive and empty. The finalize block clears `prev_workspace` and
        // calls `reapEmpty` again once the slide completes.
        if (workspace == output.prev_workspace) continue;
        if (workspace == last) continue;
        if (workspace.empty()) workspace.destroy();
    }
}

/// Return another enabled output to which this output's workspaces may be
/// migrated, or null if this is the last remaining output.
fn fallbackOutput(output: *Output) ?*Output {
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |other| {
        if (other == output) continue;
        if (other.scheduled.state == .destroying) continue;
        if (other.wlr_output == null) continue;
        return other;
    }
    return null;
}

fn migrateWorkspacesTo(output: *Output, dest: *Output) void {
    output.cancelTransition();
    output.active_workspace = null;
    var it = output.workspaces.safeIterator(.forward);
    while (it.next()) |workspace| {
        if (workspace.pinned) {
            if (dest.pinnedByName(workspace.name)) |target| {
                var win_it = workspace.windows.safeIterator(.forward);
                while (win_it.next()) |window| window.setWorkspace(target);
            } else {
                workspace.link.remove();
                workspace.output = dest;
                dest.workspaces.append(workspace);
                continue;
            }
            workspace.destroy();
            continue;
        }

        workspace.link.remove();
        workspace.output = dest;
        dest.workspaces.append(workspace);
    }
    dest.ensureTrailingEmpty();
    dest.reapEmpty();
    server.wm.dirtyWindowing();
    server.workspace_manager.dirty();
}

/// Destroy all workspaces, detaching any remaining windows first. Detaching is
/// done without triggering reaping so it is safe to call while iterating the
/// workspace list.
fn clearWorkspaces(output: *Output) void {
    output.cancelTransition();
    output.active_workspace = null;
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| {
        var window_it = workspace.windows.iterator(.forward);
        while (window_it.next()) |window| window.detachWorkspace();
        workspace.destroy();
    }
}

fn createWorkspace(output: *Output) ?*Workspace {
    var buf: [16]u8 = undefined;
    const index = output.workspaces.length() + 1;
    const name = fmt.bufPrint(&buf, "{d}", .{index}) catch "workspace";
    return Workspace.create(output, name) catch {
        log.err("out of memory creating workspace", .{});
        return null;
    };
}

fn handleCommit(
    listener: *wl.Listener(*wlr.Output.event.Commit),
    event: *wlr.Output.event.Commit,
) void {
    const output: *Output = @fieldParentPtr("commit", listener);
    const committed = event.state.committed;
    if (!(committed.scale or committed.mode or committed.transform or committed.enabled)) return;
    const wlr_output = output.wlr_output orelse return;
    log.debug("output {s}: commit affects layout (scale={} mode={} transform={} enabled={})", .{
        wlr_output.name,
        committed.scale,
        committed.mode,
        committed.transform,
        committed.enabled,
    });
    server.wm.dirtyWindowing();

    if (committed.scale or committed.enabled) {
        var seat_it = server.input_manager.seats.iterator(.forward);
        while (seat_it.next()) |seat| {
            seat.cursor.reloadScales();
        }
    }
}

/// Attempts to send the river_output_v1.wl_output event if it has not yet been
/// sent and the underlying wl_output global now exists. Wlroots creates the
/// wl_output global lazily (notably on the DRM backend the global is only
/// created once the output is added to the layout and a mode is committed), so
/// this must be retried from every site that learns the global may now exist
/// (manageStart, post-modeset, and client bind) until it succeeds.
pub fn trySendWlOutput(output: *Output) void {
    const wlr_output = output.wlr_output orelse return;
    const global = wlr_output.global orelse return;
    const output_v1 = output.object orelse return;
    // Re-send if we have not sent yet or the global was recreated.
    if (output.sent_wl_output and output.sent_wl_output_global == global) return;
    output_v1.sendWlOutput(global.getName(output_v1.getClient()));
    output.sent_wl_output = true;
    output.sent_wl_output_global = global;
}

/// Handles a client binding to an output
fn handleBind(listener: *wl.Listener(*wlr.Output.event.Bind), _: *wlr.Output.event.Bind) void {
    const output: *Output = @fieldParentPtr("bind", listener);
    // The wl_output.bind event only fires after the wl_output global exists, so
    // this is a reliable point to (re)send river_output_v1.wl_output when the
    // global was still null at manageStart/modeset time (e.g. DRM backend).
    output.trySendWlOutput();
    server.workspace_manager.dirty();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);

    log.debug("wlr_output '{s}' destroyed", .{wlr_output.name});

    var seats = server.input_manager.seats.iterator(.forward);
    while (seats.next()) |seat| seat.policyForgetOutput(output);

    {
        var it = server.layer_shell.surfaces.iterator();
        while (it.next()) |surface| {
            if (surface.wlr_layer_surface.output == wlr_output) {
                surface.wlr_layer_surface.destroy();
            }
        }
    }
    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            if (device.config.map_to_output == wlr_output) {
                device.config.map_to_output = null;
                device.seat.cursor.wlr_cursor.mapInputToOutput(device.wlr_device, null);
            }
        }
    }

    output.destroy.link.remove();
    output.request_state.link.remove();
    output.frame.link.remove();
    output.present.link.remove();
    output.commit.link.remove();
    output.bind.link.remove();

    output.destroyBlur();

    wlr_output.data = null;

    output.wlr_output = null;
    output.scene_output = null;
    output.scheduled.mode = .none;
    output.sent.mode = .none;
    output.current.mode = .none;
    output.scheduled.state = .destroying;

    server.aqueous.output_service.outputsChanged(true);

    server.wm.dirtyWindowing();
}

pub fn manageStart(output: *Output) void {
    switch (output.scheduled.state) {
        .enabled, .disabled_soft => {
            // We cannot send 0 width/height to the window manager client.
            assert(output.scheduled.mode != .none);

            output.layer_shell.manageStart();

            if (server.wm.object) |wm_v1| {
                const new = output.object == null;
                const output_v1 = output.object orelse blk: {
                    const output_v1 = river.OutputV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                        log.err("out of memory", .{});
                        return; // try again next update
                    };
                    output.object = output_v1;

                    output_v1.setHandler(*Output, handleRequest, handleObjectDestroy, output);
                    wm_v1.sendOutput(output_v1);

                    break :blk output_v1;
                };
                errdefer comptime unreachable;

                // wl_output globals are created/destroyed by the wlroots output layout.
                // Retry until it succeeds; handleBind and the post-modeset pass also retry.
                output.trySendWlOutput();

                const scheduled = &output.scheduled;
                const sent = &output.sent;

                const scheduled_width, const scheduled_height = scheduled.dimensions();
                const sent_width, const sent_height = sent.dimensions();

                if (new or scheduled_width != sent_width or scheduled_height != sent_height) {
                    output_v1.sendDimensions(scheduled_width, scheduled_height);
                }
                if (new or scheduled.x != sent.x or scheduled.y != sent.y) {
                    output_v1.sendPosition(scheduled.x, scheduled.y);
                }
            }

            output.sent = output.scheduled;

            output.link_sent.remove();
            server.wm.sent.outputs.append(output);
        },
        .disabled_hard, .destroying => {
            output.makeInert();

            output.sent = output.scheduled;

            if (output.scheduled.state == .destroying) {
                assert(output.wlr_output == null);
                {
                    var it = server.wm.windows.iterator();
                    while (it.next()) |window| {
                        switch (window.wm_scheduled.fullscreen_requested) {
                            .fullscreen => |output_hint| {
                                if (output_hint == output) {
                                    window.wm_scheduled.fullscreen_requested = .{ .fullscreen = null };
                                }
                            },
                            .no_request, .exit => {},
                        }
                        if (window.wm_requested.fullscreen == output) {
                            window.wm_requested.fullscreen = null;
                        }
                    }
                }
                const dest = output.fallbackOutput();
                if (dest) |to| {
                    output.migrateWorkspacesTo(to);
                } else {
                    output.clearWorkspaces();
                }
                server.workspace_manager.handleOutputRemoved(output, dest);

                output.link.remove();
                output.link_sent.remove();

                util.gpa.destroy(output);
            }
        },
    }
}

pub fn makeInert(output: *Output) void {
    if (output.object) |output_v1| {
        output_v1.sendRemoved();
        output_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        output.layer_shell.makeInert();
        handleObjectDestroy(output_v1, output);
    }
}

fn handleRequestInert(
    output_v1: *river.OutputV1,
    request: river.OutputV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) output_v1.destroy();
}

fn handleObjectDestroy(_: *river.OutputV1, output: *Output) void {
    output.object = null;
    output.sent_wl_output = false;
    output.sent_wl_output_global = null;
}

fn handleRequest(
    output_v1: *river.OutputV1,
    request: river.OutputV1.Request,
    output: *Output,
) void {
    assert(output.object == output_v1);
    switch (request) {
        .destroy => output_v1.destroy(),
        .set_presentation_mode => |args| {
            if (!server.wm.ensureRendering()) return;
            output.rendering_requested.tearing = switch (args.mode) {
                .vsync => false,
                .async => true,
                _ => {
                    output_v1.postError(.invalid_presentation_mode, "invalid presentation mode enum value");
                    return;
                },
            };
        },
    }
}

fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    // The only state currently requested by a wlroots backend is a
    // custom mode as the Wayland/X11 backend window is resized.
    const committed: u32 = @bitCast(event.state.committed);
    const supported: u32 = @bitCast(wlr.Output.State.Fields{ .mode = true });

    if (committed != supported) {
        log.err("backend requested unsupported state {}", .{committed});
        return;
    }

    log.debug("backend requested new mode", .{});

    if (event.state.mode) |mode| {
        output.scheduled.mode = .{ .standard = mode };
    } else {
        output.scheduled.mode = .{ .custom = .{
            .width = event.state.custom_mode.width,
            .height = event.state.custom_mode.height,
            .refresh = event.state.custom_mode.refresh,
        } };
    }

    server.wm.dirtyWindowing();
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);

    const animation_changed_scene = output.stepAnimations();
    if (animation_changed_scene) output.scene_output.?.damage_ring.addWhole();

    // Commit the end of a workspace-swap slide once all windows have settled.
    output.finalizeTransition();

    // TODO this should probably be retried on failure
    output.renderAndCommit(animation_changed_scene) catch |err| switch (err) {
        error.CommitFailed => log.err("output commit failed for {s}", .{wlr_output.name}),
    };

    var now = util.timestamp();
    output.scene_output.?.sendFrameDone(&now);

    // renderAndCommit early-returns when the scene reports no pending changes, so
    // re-arm the frame loop ourselves while any window on this output is still
    // moving; otherwise the animation would stall after the first eased frame.
    if (output.hasActiveAnimations()) {
        wlr_output.scheduleFrame();
    } else {
        // The animation loop is going idle. Clear the delta accumulator so the
        // next slide's first frame starts fresh (dt == 0) instead of inheriting
        // the multi-second gap since this slide ended — which would otherwise
        // produce a single huge first step (clamped to 0.1s) and make every
        // switch after the first appear to snap most of the way instantly.
        output.anim_last_ns = 0;
    }
}

/// Advance the position animation of every window currently displayed on this
/// output by the time elapsed since the previous frame. Returns true when any
/// animation changed scene state. Compiles out (always returns false) when animations
/// are disabled.
fn stepAnimations(output: *Output) bool {
    if (comptime !fx.anim_enabled) return false;

    const now = util.timestamp();
    const now_ns: i64 = @as(i64, @intCast(now.sec)) * std.time.ns_per_s + @as(i64, @intCast(now.nsec));

    var dt_s: f64 = 0;
    if (output.anim_last_ns != 0) {
        const delta_ns = now_ns - output.anim_last_ns;
        dt_s = @as(f64, @floatFromInt(delta_ns)) / @as(f64, std.time.ns_per_s);
        // Clamp so a stall (e.g. after the output was idle) does not teleport the
        // window in a single huge step.
        if (dt_s < 0) dt_s = 0;
        if (dt_s > 0.1) dt_s = 0.1;
    }
    output.anim_last_ns = now_ns;

    if (dt_s <= 0) return false;

    var changed = false;
    var it = server.wm.windows.iterator();
    while (it.next()) |window| {
        const ws = window.workspace orelse continue;
        if (ws.output != output) continue;
        if (window.stepAnimation(dt_s)) changed = true;
    }
    return changed;
}

fn hasActiveAnimations(output: *Output) bool {
    if (comptime !fx.anim_enabled) return false;

    var it = server.wm.windows.iterator();
    while (it.next()) |window| {
        const ws = window.workspace orelse continue;
        if (ws.output != output) continue;
        if (window.anim_active) return true;
    }
    return false;
}

fn renderAndCommit(output: *Output, force: bool) !void {
    // Native clients such as Firefox/Zen use desynchronized GPU subsurfaces
    // which can replace their scene buffers without committing the XDG
    // top-level. Surface commits still schedule an output frame, so use the
    // frame boundary as the final visual-state barrier before SceneFX computes
    // damage, opaque-region occlusion, and blending.
    output.syncWindowVisualState();

    if (!force and !output.scene_output.?.needsFrame()) return;

    const wlr_output = output.wlr_output.?;

    var state = wlr.Output.State.init();
    defer state.finish();

    output.current.applyNoModeset(&state);

    if (!output.scene_output.?.buildState(&state, null)) return error.CommitFailed;

    if (output.rendering_current.tearing) {
        state.tearing_page_flip = true;
        // TODO don't try this every frame if it consistently fails. Stop trying if it fails
        // for 10 frames in a row or something.
        if (!wlr_output.testState(&state)) {
            log.info("tearing page flip test failed for {s}, retrying without tearing", .{wlr_output.name});
            state.tearing_page_flip = false;
        }
    }

    if (!wlr_output.commitState(&state)) return error.CommitFailed;

    switch (server.lock_manager.state) {
        .unlocked => {
            if (output.lock_render_state != .unlocked) {
                output.lock_render_state = .pending_unlock;
            }
        },
        .locked => {
            assert(!server.scene.normal_tree.node.enabled);
            switch (output.lock_render_state) {
                .pending_unlock, .unlocked, .pending_blank, .pending_lock_surface => unreachable,
                .blanked, .lock_surface => {},
            }
        },
        .waiting_for_blank => {
            assert(!server.scene.normal_tree.node.enabled);
            if (output.lock_render_state != .blanked) {
                output.lock_render_state = .pending_blank;
            }
        },
        .waiting_for_lock_surfaces => {
            const lock_surface_mapped = blk: {
                if (server.lock_manager.lockSurfaceFromOutput(output)) |lock_surface| {
                    break :blk lock_surface.wlr_lock_surface.surface.mapped;
                } else {
                    break :blk false;
                }
            };
            if (lock_surface_mapped) {
                if (output.lock_render_state != .lock_surface) {
                    output.lock_render_state = .pending_lock_surface;
                }
            } else {
                if (output.lock_render_state != .unlocked) {
                    output.lock_render_state = .pending_unlock;
                }
            }
        },
    }
}

fn syncWindowVisualState(output: *Output) void {
    var windows = server.wm.windows.iterator();
    while (windows.next()) |window| {
        const workspace = window.workspace orelse continue;
        if (workspace.output != output) continue;
        window.applyOpacity();
    }
}

fn handlePresent(
    listener: *wl.Listener(*wlr.Output.event.Present),
    event: *wlr.Output.event.Present,
) void {
    const output: *Output = @fieldParentPtr("present", listener);
    if (!event.presented) {
        return;
    }
    switch (output.lock_render_state) {
        .pending_unlock => {
            assert(server.lock_manager.state != .locked);
            output.lock_render_state = .unlocked;
        },
        .unlocked => assert(server.lock_manager.state != .locked),
        .pending_blank => {
            output.lock_render_state = .blanked;
            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .pending_lock_surface => {
            output.lock_render_state = .lock_surface;
            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .blanked, .lock_surface => {},
    }
}

fn pinnedByName(output: *Output, name: [:0]const u8) ?*Workspace {
    var it = output.workspaces.iterator(.forward);
    while (it.next()) |workspace| {
        if (workspace.pinned and std.mem.eql(u8, workspace.name, name)) {
            return workspace;
        }
    }
    return null;
}
