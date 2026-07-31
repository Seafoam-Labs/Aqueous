// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Aqueous = @This();

const build_options = @import("build_options");
const std = @import("std");
const wl = @import("wayland").server.wl;

const server = &@import("../main.zig").server;

const CompositorApi = @import("CompositorApi.zig");
const Mode = @import("Mode.zig").Mode;
const Trace = @import("Trace.zig");
const layout_config = @import("config/layout.zig");
const config_loader = @import("config/loader.zig");
const action_config = @import("config/actions.zig");
const layout_engine = @import("layout/engine.zig");
const game_mode = @import("layout/game_mode.zig");
const stacking = @import("layout/stacking.zig");
const layout_types = @import("layout/types.zig");
const FocusHistory = @import("focus/history.zig");
const PendingFocus = @import("focus/pending.zig");
const pointer_drag = @import("input/drag.zig");
const gesture_input = @import("input/gestures.zig");
const output_transfer = @import("input/output_transfer.zig");
const StateStore = @import("state/store.zig");
const transient = @import("state/transient.zig");
const OutputService = @import("output/Service.zig");
const output_navigation = @import("output/navigation.zig");
const overview_model = @import("overview/model.zig");
const rules_config = @import("rules/config.zig");
const Rules = @import("rules/engine.zig");
const util = @import("../util.zig");
const process = @import("../process.zig");
const posix = std.posix;

const log = std.log.scoped(.aqueous);

const LayoutStateKey = struct { output: u64, workspace: u32 };

mode: Mode,
api: CompositorApi = .{},
trace: Trace = .{},
config: config_loader.Snapshot = .{},
rules: Rules,
layout_states: std.AutoHashMapUnmanaged(LayoutStateKey, layout_engine.State) = .empty,
layout_overrides: std.AutoHashMapUnmanaged(LayoutStateKey, layout_config.LayoutId) = .empty,
previous_workspaces: std.AutoHashMapUnmanaged(u64, u32) = .empty,
fired_exec: std.AutoHashMapUnmanaged(u64, void) = .empty,
reload_timer: ?*wl.EventSource = null,
globals_applied: bool = false,
focus_history: FocusHistory,
pending_focus: PendingFocus,
/// Most recently admitted toplevel waiting for the opt-in new-window focus
/// policy. A single handle is sufficient: coalesced admissions focus the
/// newest window, matching the compositor's creation-event order.
pending_new_focus: layout_types.Handle = 0,
window_states: StateStore,
output_service: OutputService,
started: bool = false,
drag: ?Drag = null,
untrap_keysym: ?u32 = null,
next_stack_order: u64 = 1,
requested_stack_focus: ?layout_types.Handle = null,
overview: ?overview_model.State = null,

const Drag = struct {
    handle: layout_types.Handle,
    start: layout_types.Rect,
    pointer_x: f64,
    pointer_y: f64,
    last_pointer_x: f64,
    last_pointer_y: f64,
    action: pointer_drag.Action,
    layout_key: LayoutStateKey = .{ .output = 0, .workspace = 0 },
    awaiting_layout: ?layout_types.Handle = null,
    resize_edges: pointer_drag.ResizeEdges = .{ .bottom = true, .right = true },
    client_seat: ?usize = null,
    /// Geometry belongs to the workspace floating layout, not PolicyState.
    layout_floating: bool = false,
};

pub fn init(aqueous: *Aqueous, mode: Mode) void {
    aqueous.* = .{
        .mode = mode,
        .config = config_loader.load(util.gpa),
        .rules = Rules.init(util.gpa),
        .focus_history = FocusHistory.init(util.gpa),
        .pending_focus = PendingFocus.init(util.gpa),
        .window_states = StateStore.init(util.gpa, CompositorApi.policyState),
        .output_service = undefined,
    };
    aqueous.output_service.init();
    rules_config.reloadDiscovered(util.gpa, &aqueous.rules, aqueous.config.wm.rules_path.slice());
    const event_loop = @import("../main.zig").server.wl_server.getEventLoop();
    aqueous.reload_timer = event_loop.addTimer(*Aqueous, handleReloadTimer, aqueous) catch |err| blk: {
        log.warn("unable to start configuration monitor: {}", .{err});
        break :blk null;
    };
    if (aqueous.reload_timer) |timer| timer.timerUpdate(1000) catch log.warn("unable to arm configuration monitor", .{});
    log.info("policy mode={s} layout={s}", .{ @tagName(mode), @tagName(aqueous.config.layout.default) });
}

pub fn deinit(aqueous: *Aqueous) void {
    aqueous.started = false;
    aqueous.cancelOverview();
    aqueous.output_service.deinit();
    if (aqueous.reload_timer) |timer| timer.remove();
    var states = aqueous.layout_states.valueIterator();
    while (states.next()) |state| state.deinit(util.gpa);
    aqueous.layout_states.deinit(util.gpa);
    aqueous.layout_overrides.deinit(util.gpa);
    aqueous.previous_workspaces.deinit(util.gpa);
    aqueous.fired_exec.deinit(util.gpa);
    aqueous.focus_history.deinit();
    aqueous.pending_focus.deinit();
    aqueous.window_states.deinit();
    aqueous.rules.deinit();
    log.debug("policy stopped after {} trace event(s)", .{aqueous.trace.sequence});
}

/// Called once the compositor globals, input manager and configuration objects exist.
pub fn start(aqueous: *Aqueous) void {
    if (aqueous.started) return;
    aqueous.started = true;
    aqueous.output_service.start();
    if (!aqueous.mode.runsInternal()) return;
    aqueous.applyLayerRules();
    aqueous.applyInputConfig();
    aqueous.runExec(.startup);
}

pub fn allowsExternal(aqueous: *const Aqueous) bool {
    return build_options.external_policy and aqueous.mode.allowsExternal();
}

pub fn reloadConfig(aqueous: *Aqueous) void {
    aqueous.cancelOverview();
    aqueous.config = config_loader.load(util.gpa);
    if (!aqueous.config.wm.input.focus_new_windows) aqueous.pending_new_focus = 0;
    rules_config.reloadDiscovered(util.gpa, &aqueous.rules, aqueous.config.wm.rules_path.slice());
    aqueous.applyLayerRules();
    aqueous.globals_applied = false;
    aqueous.api.requestManageCycle();
    aqueous.applyInputConfig();
    _ = aqueous.output_service.reload(true);
    aqueous.runExec(.reload);
    aqueous.notify("Aqueous configuration reloaded", null, false);
    log.info("configuration reloaded layout={s}", .{@tagName(aqueous.config.layout.default)});
}

pub fn traceCycle(aqueous: *Aqueous, phase: Trace.Phase, external_active: bool) void {
    const snapshot = aqueous.api.snapshot();
    if (aqueous.mode.runsInternal()) {
        aqueous.trace.emit(.internal, phase, snapshot);
    }
    if (external_active) {
        aqueous.trace.emit(.external, phase, snapshot);
    }
}

pub fn applyManageCycle(aqueous: *Aqueous) !void {
    if (!aqueous.mode.runsInternal()) return;
    defer aqueous.requested_stack_focus = null;

    if (!aqueous.globals_applied) {
        aqueous.applyGlobalConfig();
        aqueous.globals_applied = true;
    }

    var snapshot = try aqueous.api.policySnapshot(util.gpa);
    defer snapshot.deinit(util.gpa);
    const fullscreen_requests = try aqueous.api.takeClientFullscreenRequests(util.gpa);
    defer util.gpa.free(fullscreen_requests);
    if (fullscreen_requests.len > 0) {
        aqueous.applyClientFullscreenRequests(&snapshot, fullscreen_requests);

        // A usable output hint can move a window between outputs. Rebuild the
        // policy view so this same cycle lays it out under its new owner rather
        // than using the stale output grouping captured above.
        const refreshed = try aqueous.api.policySnapshot(util.gpa);
        snapshot.deinit(util.gpa);
        snapshot = refreshed;
    }
    const client_requests = try aqueous.api.takeClientWindowRequests(util.gpa);
    defer util.gpa.free(client_requests);
    if (aqueous.applyClientWindowRequests(&snapshot, client_requests)) {
        // Activation may select another workspace/output. Continue this
        // transaction using the newly active workspace so visibility, layout,
        // and focus are all committed together.
        const refreshed = try aqueous.api.policySnapshot(util.gpa);
        snapshot.deinit(util.gpa);
        snapshot = refreshed;
    }
    if (aqueous.finishInvalidInteractiveDrag(&snapshot)) {
        const refreshed = try aqueous.api.policySnapshot(util.gpa);
        snapshot.deinit(util.gpa);
        snapshot = refreshed;
    }
    aqueous.validateOverviewSnapshot(&snapshot);
    const focused = aqueous.api.focusedWindow();
    const non_window_keyboard_focus = aqueous.api.hasNonWindowKeyboardFocus();
    // A direct focus request is committed by Seat.manageFinish() after policy
    // resolves this transaction. Use that newer target now so placement order
    // and focus-sensitive visuals do not render one management cycle behind.
    var cycle_focus = transactionFocus(aqueous.requested_stack_focus, focused);
    var cycle_selected_output_id = aqueous.api.selectedOutputId();
    // Direct pointer, keybinding, or client activation requests are newer and
    // more intentional than admission focus. Never overwrite one which was
    // coalesced into this management transaction.
    if (!aqueous.config.wm.input.focus_new_windows or aqueous.requested_stack_focus != null) {
        aqueous.pending_new_focus = 0;
    }
    const pending_new_focus = aqueous.pending_new_focus;
    var pending_new_focus_seen = false;
    var focused_is_focusable = focused == null;
    var replacement_focus_requested = false;
    if ((focused != null and focused == aqueous.pending_focus.window) or
        (non_window_keyboard_focus and aqueous.pending_focus.window != 0))
    {
        aqueous.pending_focus.clear();
    }

    for (snapshot.outputs) |output| {
        var output_layout = aqueous.config.layout;
        if (aqueous.config.wm.resolveOutput(.{ .name = output.name, .make = output.make, .model = output.model, .serial = output.serial })) |configured| output_layout.default = configured;
        if (aqueous.config.wm.resolveWorkspace(output.name, output.workspace_number)) |configured| output_layout.default = configured;
        // Respect both dynamic layer-shell reservations (Noctalia, panels,
        // docks) and the user's static struts. Taking the intersection avoids
        // double-counting when both reserve the same edge.
        const usable_area = aqueous.effectiveUsableArea(output.area, output.usable_area);
        const workspace_key = workspaceKey(output.id, output.workspace_number);
        const layout_key: LayoutStateKey = .{ .output = output.id, .workspace = output.workspace_number };
        if (aqueous.layout_overrides.get(layout_key)) |override| output_layout.default = override;
        var managed: std.ArrayListUnmanaged(layout_types.Window) = .empty;
        defer managed.deinit(util.gpa);
        var requested: std.ArrayListUnmanaged(layout_types.Placement) = .empty;
        defer requested.deinit(util.gpa);
        var focusable: std.ArrayListUnmanaged(layout_types.Window) = .empty;
        defer focusable.deinit(util.gpa);
        try managed.ensureTotalCapacity(util.gpa, output.windows.len);
        try requested.ensureTotalCapacity(util.gpa, output.windows.len);
        try focusable.ensureTotalCapacity(util.gpa, output.windows.len);
        var game_anchor: ?struct { handle: layout_types.Handle, rule: Rules.Rule } = null;
        var fullscreen_owner: ?layout_types.Handle = null;
        for (output.windows) |window| {
            const state = aqueous.window_states.get(window.handle) orelse continue;
            const rule = aqueous.rules.resolve(.{
                .app_id = window.app_id,
                .class = window.app_id,
                .title = window.title,
            });
            aqueous.reconcileTransientParent(window, usable_area);
            aqueous.api.ensureWorkspace(window.handle, output.id);
            const effect = aqueous.reconcileWindowRule(
                window,
                output.id,
                output.workspace_number,
                output.area,
                usable_area,
                output_layout.layoutOptions(.floating).border,
                rule,
            );
            if (pending_new_focus != 0 and window.handle == pending_new_focus) {
                pending_new_focus_seen = true;
                if (!admissionFocusEligible(window.accepts_focus, state.kind, effect.workspace_visible)) {
                    aqueous.pending_new_focus = 0;
                } else if (!non_window_keyboard_focus) {
                    if (cycle_focus != window.handle) aqueous.requestFocus(window.handle);
                    cycle_focus = window.handle;
                    cycle_selected_output_id = output.id;
                    aqueous.pending_new_focus = 0;
                }
            }
            if (effect.fullscreen) {
                if (fullscreen_owner) |prior| if (prior != window.handle) {
                    if (aqueous.window_states.get(prior)) |prior_state| prior_state.overrideFullscreen();
                    aqueous.api.clearFullscreen(prior);
                };
                fullscreen_owner = window.handle;
            }
            if (state.kind == .minimized) {
                requested.appendAssumeCapacity(.{ .handle = window.handle, .geometry = .empty, .z_order = -1, .visible = false, .border = .none, .tiled = false });
                continue;
            }
            if (effect.fullscreen) {
                requested.appendAssumeCapacity(.{
                    .handle = window.handle,
                    .geometry = output.area,
                    .z_order = stacking.fullscreen_band,
                    .stack_order = aqueous.ensureStackOrder(state),
                    .visible = true,
                    .border = .none,
                    .tiled = false,
                });
                if (effect.workspace_visible and window.accepts_focus) focusable.appendAssumeCapacity(window);
                continue;
            }
            if (state.kind == .maximized) {
                const max_area = if (aqueous.config.wm.maximize_full_output) output.area else usable_area;
                requested.appendAssumeCapacity(.{
                    .handle = window.handle,
                    .geometry = max_area,
                    .z_order = stacking.maximized_band,
                    .stack_order = aqueous.ensureStackOrder(state),
                    .visible = true,
                    .border = output_layout.layoutOptions(.floating).border,
                    .tiled = false,
                    .maximized = true,
                });
                if (effect.workspace_visible and window.accepts_focus) focusable.appendAssumeCapacity(window);
                continue;
            }
            if (state.kind == .floating) {
                var geometry = state.floating_geometry;
                if (geometry.width <= 0 or geometry.height <= 0) geometry = floatingPlacement(usable_area, window.handle, .{}, output_layout.layoutOptions(.floating).border).geometry;
                if (state.needs_output_recovery) {
                    geometry = output_transfer.recoverGeometry(geometry, usable_area);
                    state.floating_geometry = geometry;
                    state.needs_output_recovery = false;
                }
                requested.appendAssumeCapacity(.{
                    .handle = window.handle,
                    .geometry = geometry,
                    .z_order = stacking.floatingZ(stacking.transientDepth(output.windows, window)),
                    .stack_order = aqueous.ensureStackOrder(state),
                    .visible = true,
                    .border = output_layout.layoutOptions(.floating).border,
                    .tiled = false,
                });
                if (effect.workspace_visible and window.accepts_focus) focusable.appendAssumeCapacity(window);
                continue;
            }
            if (rule) |matched| {
                if (matched.layout) |id| output_layout.default = ruleLayout(id);
                if (matched.layout == .game_mode and (game_anchor == null or cycle_focus == window.handle)) {
                    game_anchor = .{ .handle = window.handle, .rule = matched };
                }
            }
            managed.appendAssumeCapacity(window);
            if (effect.workspace_visible and window.accepts_focus) focusable.appendAssumeCapacity(window);
            if (rule != null and rule.?.layout == .game_mode and managed.items.len > 1) {
                std.mem.swap(layout_types.Window, &managed.items[0], &managed.items[managed.items.len - 1]);
            }
        }
        // Admission focus is resolved only after workspace/focusability rules,
        // so apply focus-sensitive visuals in a second pass using the focus
        // target which Seat.manageFinish() will commit this transaction.
        for (output.windows) |window| {
            const rule = aqueous.rules.resolve(.{
                .app_id = window.app_id,
                .class = window.app_id,
                .title = window.title,
            });
            const focus_opacity: ?f64 = if (aqueous.config.wm.opacity_enabled and aqueous.config.wm.opacity_focus_sensitive)
                (if (cycle_focus == window.handle) aqueous.config.wm.opacity_focused else aqueous.config.wm.opacity_unfocused)
            else
                null;
            aqueous.api.applyRuleVisual(
                window.handle,
                if (rule) |matched| matched.blur else null,
                if (rule) |matched| matched.opacity orelse focus_opacity else focus_opacity,
                aqueous.config.wm.force_ssd,
            );
        }
        const entry = try aqueous.layout_states.getOrPut(util.gpa, layout_key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (game_anchor != null) entry.value_ptr.game_mode.rule_layout_owned = true;
        if (entry.value_ptr.game_mode.rule_layout_owned) output_layout.default = .game_mode;
        entry.value_ptr.game_mode.rule_anchor = if (game_anchor) |anchor| anchor.handle else null;
        if (game_anchor) |anchor| entry.value_ptr.game_mode.rule_options = gameOptions(anchor.rule, aqueous.rules.game_mode, output.area, &output_layout);
        if (cycle_focus) |handle| {
            if (containsWindow(focusable.items, handle)) {
                focused_is_focusable = true;
                try aqueous.focus_history.record(workspace_key, handle);
            }
        }
        const focus_valid = if (cycle_focus) |handle| containsWindow(focusable.items, handle) else false;
        if (!focus_valid and !non_window_keyboard_focus and cycle_selected_output_id == output.id) {
            var target = aqueous.focus_history.pick(workspace_key, focusable.items, focusCandidateValid);
            if (target == 0 and focusable.items.len > 0) target = focusable.items[0].handle;
            if (target != 0 and target != aqueous.pending_focus.window) {
                aqueous.pending_focus.setWindow(target, 1);
                aqueous.requestFocus(target);
                cycle_focus = target;
                replacement_focus_requested = true;
            }
        }
        const placements = try layout_engine.arrange(
            util.gpa,
            entry.value_ptr,
            &output_layout,
            usable_area,
            managed.items,
            cycle_focus,
            gameConfigOptions(aqueous.rules.game_mode, &output_layout),
        );
        defer util.gpa.free(placements);
        for (placements) |*placement| {
            if (!placement.tiled) {
                placement.z_order = stacking.floating_band;
                if (aqueous.window_states.get(placement.handle)) |state| {
                    placement.stack_order = aqueous.ensureStackOrder(state);
                }
            }
        }
        try requested.appendSlice(util.gpa, placements);
        aqueous.ensureFocusedPlacementOnTop(requested.items, aqueous.requested_stack_focus orelse cycle_focus);
        std.mem.sort(layout_types.Placement, requested.items, {}, stacking.lessThan);
        for (requested.items) |placement| {
            aqueous.api.applyPlacement(
                placement,
                cycle_focus == placement.handle,
            );
        }
    }

    // A newly admitted window which cannot appear on any active output (for
    // example, a transient owned by an inactive workspace) must not steal
    // focus when that workspace is visited much later.
    if (pending_new_focus != 0 and !pending_new_focus_seen and snapshot.outputs.len > 0 and
        aqueous.pending_new_focus == pending_new_focus)
    {
        aqueous.pending_new_focus = 0;
    }

    // A closing, minimized, or workspace-removed window may still be the
    // wl_seat focus target. If no active output considers it focusable,
    // explicitly send keyboard leave before it is destroyed.
    if (!focused_is_focusable and !replacement_focus_requested) aqueous.api.clearFocus();

    var stale: std.ArrayListUnmanaged(LayoutStateKey) = .empty;
    defer stale.deinit(util.gpa);
    var keys = aqueous.layout_states.keyIterator();
    while (keys.next()) |id| {
        var found = false;
        for (snapshot.outputs) |output| {
            if (output.id == id.output) {
                found = true;
                break;
            }
        }
        if (!found) try stale.append(util.gpa, id.*);
    }
    for (stale.items) |id| {
        if (aqueous.layout_states.fetchRemove(id)) |removed| {
            var state = removed.value;
            state.deinit(util.gpa);
        }
    }
}

/// Apply client-originated fullscreen transitions before layout reconciliation
/// so this manage cycle configures and renders the requested state. Explicit
/// output objects are preferences under xdg-shell; honor usable hints and fall
/// back to the window's current output (then the first usable output).
fn applyClientFullscreenRequests(
    aqueous: *Aqueous,
    snapshot: *CompositorApi.PolicySnapshot,
    requests: []const CompositorApi.ClientFullscreenRequest,
) void {
    for (requests) |request| {
        const state = aqueous.window_states.get(request.handle) orelse continue;
        state.overrideFullscreen();

        switch (request.action) {
            .exit => {
                aqueous.api.clearFullscreen(request.handle);
            },
            .enter => |output_hint| {
                const target = findPolicyOutput(snapshot, output_hint) orelse
                    findPolicyOutput(snapshot, request.current_output_id) orelse
                    if (snapshot.outputs.len > 0) &snapshot.outputs[0] else null;
                const output = target orelse continue;

                // A fullscreen output hint may target a different display. Move
                // the window to that output's active workspace so ownership,
                // focus, and subsequent layout snapshots agree with rendering.
                if (request.current_output_id != output.id) {
                    _ = aqueous.api.moveWindowToWorkspace(
                        request.handle,
                        output.id,
                        output.workspace_number,
                    );
                }

                aqueous.api.clearOtherFullscreen(output.id, request.handle);
                _ = aqueous.api.setFullscreen(request.handle, output.id);
            },
        }
    }
}

fn findPolicyOutput(snapshot: *const CompositorApi.PolicySnapshot, id: ?u64) ?*const CompositorApi.PolicyOutput {
    const wanted = id orelse return null;
    for (snapshot.outputs) |*output| if (output.id == wanted) return output;
    return null;
}

/// Client-side decorations and foreign-toplevel controllers feed the same
/// one-shot request stream. Direct move/resize/maximize/minimize requests
/// remain constrained to floating policy, while activation can restore and
/// focus any managed window.
fn applyClientWindowRequests(
    aqueous: *Aqueous,
    snapshot: *const CompositorApi.PolicySnapshot,
    requests: []const CompositorApi.ClientWindowRequest,
) bool {
    var snapshot_dirty = false;
    for (requests) |request| switch (request.action) {
        .move => |pointer| aqueous.startClientPointerDrag(
            request.handle,
            pointer,
            .move_floating,
            .{},
        ),
        .resize => |resize| {
            const edges: pointer_drag.ResizeEdges = .{
                .top = resize.edges.top,
                .bottom = resize.edges.bottom,
                .left = resize.edges.left,
                .right = resize.edges.right,
            };
            if (edges.any()) aqueous.startClientPointerDrag(
                request.handle,
                resize.pointer,
                .resize_floating,
                edges,
            );
        },
        .maximize => {
            aqueous.finishInteractiveDragFor(request.handle);
            _ = aqueous.window_states.setClientMaximized(request.handle, true);
        },
        .unmaximize => {
            aqueous.finishInteractiveDragFor(request.handle);
            _ = aqueous.window_states.setClientMaximized(request.handle, false);
        },
        .minimize => {
            aqueous.finishInteractiveDragFor(request.handle);
            _ = aqueous.window_states.setClientMinimized(
                request.handle,
                true,
                aqueous.clientWindowUsesFloatingLayout(request.handle),
            ) catch {
                log.err("out of memory recording client minimize request", .{});
            };
        },
        .unminimize => {
            _ = aqueous.window_states.setClientMinimized(
                request.handle,
                false,
                aqueous.clientWindowUsesFloatingLayout(request.handle),
            ) catch unreachable;
        },
        .activate => {
            snapshot_dirty = aqueous.activateClientWindow(snapshot, request.handle) or snapshot_dirty;
        },
    };
    return snapshot_dirty;
}

/// A foreign-toplevel activation is the compositor-side equivalent of clicking
/// a dock/taskbar item: reveal its workspace, restore it if minimized, then
/// raise and focus it.
fn activateClientWindow(
    aqueous: *Aqueous,
    snapshot: *const CompositorApi.PolicySnapshot,
    handle: layout_types.Handle,
) bool {
    _ = aqueous.window_states.get(handle) orelse return false;
    const workspace = aqueous.api.windowWorkspace(handle) orelse return false;

    aqueous.finishInteractiveDragFor(handle);
    _ = aqueous.window_states.restore(handle);

    if (findPolicyOutput(snapshot, workspace.output_id)) |output| {
        if (output.workspace_number != workspace.workspace_number) {
            aqueous.previous_workspaces.put(
                util.gpa,
                workspace.output_id,
                output.workspace_number,
            ) catch log.err("out of memory recording previous workspace for dock activation", .{});
        }
    }

    _ = aqueous.api.selectOutput(workspace.output_id);
    if (!aqueous.api.activateWorkspace(workspace.output_id, workspace.workspace_number)) return false;
    aqueous.requestFocus(handle);
    return true;
}

fn startClientPointerDrag(
    aqueous: *Aqueous,
    handle: layout_types.Handle,
    pointer: CompositorApi.ClientPointer,
    action: pointer_drag.Action,
    edges: pointer_drag.ResizeEdges,
) void {
    if (aqueous.drag != null) return;
    const state = aqueous.window_states.get(handle) orelse return;
    const geometry = aqueous.api.windowGeometry(handle) orelse return;
    const workspace = aqueous.api.windowWorkspace(handle) orelse return;
    const layout_key: LayoutStateKey = .{
        .output = workspace.output_id,
        .workspace = workspace.workspace_number,
    };
    const layout_floating = state.kind == .tiled and aqueous.layoutIsFloating(layout_key);
    if (state.kind != .floating and !layout_floating) return;
    if (!aqueous.api.beginClientPointerOperation(pointer.seat)) return;

    aqueous.drag = .{
        .handle = handle,
        .start = geometry,
        .pointer_x = pointer.x,
        .pointer_y = pointer.y,
        .last_pointer_x = pointer.x,
        .last_pointer_y = pointer.y,
        .action = action,
        .layout_key = layout_key,
        .resize_edges = edges,
        .client_seat = pointer.seat,
        .layout_floating = layout_floating,
    };
    aqueous.api.beginInteractive(handle, action == .resize_floating);
    aqueous.requestFocus(handle);
}

fn finishInteractiveDragFor(aqueous: *Aqueous, handle: layout_types.Handle) void {
    if (aqueous.drag) |drag| if (drag.handle == handle) aqueous.finishInteractiveDrag();
}

fn finishInvalidInteractiveDrag(
    aqueous: *Aqueous,
    snapshot: *const CompositorApi.PolicySnapshot,
) bool {
    const drag = aqueous.drag orelse return false;
    if (findPolicyOutput(snapshot, drag.layout_key.output)) |source| {
        if (source.workspace_number == drag.layout_key.workspace) {
            for (source.windows) |window| {
                if (window.handle != drag.handle) continue;
                const state = aqueous.window_states.get(drag.handle) orelse break;
                const layout_floating = drag.layout_floating and
                    state.kind == .tiled and
                    aqueous.layoutIsFloating(drag.layout_key);
                if (drag.action == .swap_tiled or
                    ((state.kind == .floating or layout_floating) and !window.fullscreen))
                {
                    return false;
                }
                break;
            }
        }
        aqueous.finishInteractiveDrag();
        return false;
    }

    const recovered = if (drag.action == .move_floating or drag.action == .resize_floating)
        aqueous.recoverRemovedOutputDrag(drag)
    else
        false;
    aqueous.finishInteractiveDrag();
    return recovered;
}

fn recoverRemovedOutputDrag(aqueous: *Aqueous, drag: Drag) bool {
    const state = aqueous.window_states.get(drag.handle) orelse return false;
    if (state.kind != .floating) return false;
    const target = aqueous.api.outputTargetAt(drag.last_pointer_x, drag.last_pointer_y, true) orelse {
        state.needs_output_recovery = true;
        return false;
    };
    const usable_area = aqueous.effectiveUsableArea(target.area, target.usable_area);
    const geometry = output_transfer.recoverGeometry(state.floating_geometry, usable_area);
    if (!aqueous.api.moveWindowToWorkspace(drag.handle, target.id, target.workspace_number)) {
        state.needs_output_recovery = true;
        return false;
    }

    state.overrideWorkspace();
    state.floating_geometry = geometry;
    state.needs_output_recovery = false;
    _ = aqueous.api.selectOutput(target.id);
    aqueous.requestFocus(drag.handle);
    log.info("recovered floating drag on output {} workspace {}", .{ target.id, target.workspace_number });
    return true;
}

/// Apply the compositor's established parent-based popup heuristic on the
/// null -> parent edge. xdg_toplevel parents and X11 WM_TRANSIENT_FOR both
/// arrive through this field, covering native dialogs and Xwayland dialogs
/// without application-specific rules.
fn reconcileTransientParent(aqueous: *Aqueous, window: layout_types.Window, usable_area: layout_types.Rect) void {
    const state = aqueous.window_states.get(window.handle) orelse return;
    if (!transient.parentChanged(state, window.parent)) return;
    const parent = window.parent.?;

    aqueous.api.moveToParentWorkspace(window.handle);
    const parent_geometry = aqueous.api.windowGeometry(parent) orelse usable_area;
    const geometry = transient.geometry(usable_area, parent_geometry, window.min_width, window.min_height);
    _ = aqueous.window_states.setAutomaticFloating(window.handle, geometry);
}

/// Drop policy state before the compositor invalidates a stable window handle.
pub fn forgetWindow(aqueous: *Aqueous, handle: layout_types.Handle) void {
    if (!aqueous.started) return;
    var close_overview = false;
    if (aqueous.overview) |*overview| {
        if (overview_model.remove(overview, handle)) {
            aqueous.api.removeOverviewWindow(handle);
            if (overview.cards.items.len == 0) {
                close_overview = true;
            } else {
                aqueous.api.updateOverviewSelection(overview.selected);
            }
        }
    }
    if (close_overview) aqueous.cancelOverview();
    aqueous.finishInteractiveDragFor(handle);
    var layouts = aqueous.layout_states.valueIterator();
    while (layouts.next()) |state| layout_engine.forgetWindow(state, handle);
    aqueous.window_states.remove(handle);
    if (aqueous.pending_focus.window == handle) aqueous.pending_focus.clear();
    if (aqueous.pending_new_focus == handle) aqueous.pending_new_focus = 0;
}

/// Record a newly admitted normal toplevel for the integrated focus policy.
/// Native windows call this before their initial configure; XWayland calls it
/// once the associated surface and ICCCM focus hint are available.
pub fn noteWindowAdmission(aqueous: *Aqueous, handle: layout_types.Handle) void {
    aqueous.cancelOverview();
    if (!aqueous.mode.runsInternal() or !aqueous.config.wm.input.focus_new_windows) return;
    aqueous.pending_new_focus = handle;
}

/// Input events may be coalesced while an integrated-policy pointer operation
/// is active. Tiled swapping is intentionally excluded because every crossed
/// window is semantically meaningful there.
pub fn interactiveDragActive(aqueous: *const Aqueous) bool {
    const drag = aqueous.drag orelse return false;
    return drag.action != .swap_tiled;
}

fn finishInteractiveDrag(aqueous: *Aqueous) void {
    const drag = aqueous.drag orelse return;
    if (drag.action != .swap_tiled) aqueous.api.endInteractive(drag.handle);
    if (drag.client_seat) |seat| aqueous.api.endClientPointerOperation(seat);
    aqueous.drag = null;
}

fn keyBindingVerb(aqueous: *Aqueous, keysym: u32, modifiers: u32) ?[]const u8 {
    if (!aqueous.mode.runsInternal()) return null;
    const verb = aqueous.config.actions.find(keysym, modifiers & (1 | 4 | 8 | 64)) orelse return null;
    if (server.input_manager.defaultSeat().xwaylandKeyboardGrabActive() and
        !std.mem.eql(u8, verb, "builtin:untrap_pointer"))
    {
        return null;
    }
    return verb;
}

/// Report whether a press would be consumed by the direct compositor key path
/// without running its action. The keyboard group uses this to keep a bound
/// Caps Lock key from changing the XKB lock state before handleKey sees it.
pub fn hasKeyBinding(aqueous: *Aqueous, keysym: u32, modifiers: u32) bool {
    return aqueous.keyBindingVerb(keysym, modifiers) != null;
}

/// Direct compositor key path. Returning true eats the event before it reaches a client.
pub fn handleKey(aqueous: *Aqueous, keysym: u32, modifiers: u32, pressed: bool) bool {
    if (aqueous.overview != null) return aqueous.handleOverviewKey(keysym, modifiers, pressed);
    if (!pressed and aqueous.untrap_keysym == keysym) {
        aqueous.untrap_keysym = null;
        aqueous.api.suppressPointerConstraints(false);
        return true;
    }
    const verb = aqueous.keyBindingVerb(keysym, modifiers) orelse return false;
    if (std.mem.eql(u8, verb, "builtin:untrap_pointer")) {
        aqueous.untrap_keysym = if (pressed) keysym else null;
        aqueous.api.suppressPointerConstraints(pressed);
        return true;
    }
    if (pressed) aqueous.runVerb(verb);
    return true;
}

pub fn wantsGesture(aqueous: *const Aqueous, kind: action_config.GestureKind, fingers: u32) bool {
    if (!aqueous.mode.runsInternal() or fingers > std.math.maxInt(u8)) return false;
    return aqueous.config.actions.hasGesture(kind, @intCast(fingers));
}

pub fn handleGesture(aqueous: *Aqueous, gesture: gesture_input.Completed) void {
    if (!aqueous.mode.runsInternal()) return;
    const verb = aqueous.config.actions.findGesture(gesture.kind, gesture.direction, gesture.fingers) orelse return;
    aqueous.runVerb(verb);
}

pub fn handlePointerButton(aqueous: *Aqueous, button: u32, modifiers: u32, pressed: bool, x: f64, y: f64) bool {
    if (!aqueous.mode.runsInternal()) return false;
    if (aqueous.overview != null) {
        if (button == 0x110 and pressed) { // BTN_LEFT
            if (aqueous.updateOverviewHover(x, y)) aqueous.confirmOverview();
        }
        return true;
    }
    if (!pressed and aqueous.drag != null) {
        aqueous.finishInteractiveDrag();
        return true;
    }
    if (modifiers & (1 | 4 | 8 | 64) != aqueous.config.actions.primary_modifier) return false;
    if (button != 0x110 and button != 0x111) return false; // BTN_LEFT / BTN_RIGHT
    if (!pressed) {
        aqueous.drag = null;
        return true;
    }
    const target = aqueous.api.windowAt(x, y) orelse return false;
    const state = aqueous.window_states.get(target.handle) orelse return false;
    const workspace = aqueous.api.windowWorkspace(target.handle) orelse return false;
    const layout_key: LayoutStateKey = .{ .output = workspace.output_id, .workspace = workspace.workspace_number };
    const active_layout = if (aqueous.layout_states.get(layout_key)) |layout_state| layout_state.active_layout else aqueous.config.layout.default;
    const drag_action = pointer_drag.action(button, state.kind, active_layout);
    const layout_floating = state.kind == .tiled and active_layout == .floating;
    if (drag_action == .swap_tiled) {
        aqueous.drag = .{
            .handle = target.handle,
            .start = target.geometry,
            .pointer_x = x,
            .pointer_y = y,
            .last_pointer_x = x,
            .last_pointer_y = y,
            .action = drag_action,
            .layout_key = layout_key,
            .layout_floating = false,
        };
    } else {
        aqueous.drag = .{
            .handle = target.handle,
            .start = target.geometry,
            .pointer_x = x,
            .pointer_y = y,
            .last_pointer_x = x,
            .last_pointer_y = y,
            .action = drag_action,
            .layout_key = layout_key,
            .layout_floating = layout_floating,
        };
        if (!layout_floating) _ = aqueous.window_states.setFloating(target.handle, target.geometry);
        aqueous.api.beginInteractive(target.handle, drag_action == .resize_floating);
    }
    aqueous.requestFocus(target.handle);
    return true;
}

pub fn handleHover(aqueous: *Aqueous, handle: ?layout_types.Handle) void {
    if (!aqueous.mode.runsInternal() or !aqueous.config.wm.input.focus_follows_mouse) return;
    if (handle) |target| if (aqueous.api.focusedWindow() != target) aqueous.requestFocus(target);
}

/// Focus a window after an explicit, unmodified pointer interaction. The
/// compositor historically forwarded this only through river_seat_v1, so the
/// integrated policy silently discarded click-to-focus when focus-follows-mouse
/// was disabled. Xwayland games can then receive pointer input while keyboard
/// events continue going to the previously focused client.
pub fn handleWindowInteraction(aqueous: *Aqueous, handle: layout_types.Handle) void {
    if (!aqueous.mode.runsInternal()) return;
    const state = aqueous.window_states.get(handle) orelse return;
    if (state.kind == .minimized) return;
    if (aqueous.api.focusedWindow() != handle) aqueous.requestFocus(handle);
}

pub fn handlePointerMotion(aqueous: *Aqueous, x: f64, y: f64) void {
    if (aqueous.overview != null) {
        _ = aqueous.updateOverviewHover(x, y);
        return;
    }
    const drag = &(aqueous.drag orelse return);
    drag.last_pointer_x = x;
    drag.last_pointer_y = y;
    if (drag.action == .swap_tiled) {
        const target = aqueous.api.windowAt(x, y) orelse return;
        if (drag.awaiting_layout != null) {
            // Do not swap back while the scene still exposes the old geometry.
            // Re-arm once a manage cycle has moved the dragged window beneath
            // the pointer.
            if (target.handle == drag.handle) drag.awaiting_layout = null;
            return;
        }
        if (target.handle == drag.handle) return;
        const target_state = aqueous.window_states.get(target.handle) orelse return;
        if (target_state.kind != .tiled) return;
        if (!aqueous.api.windowOnWorkspace(target.handle, drag.layout_key.output, drag.layout_key.workspace)) return;
        const layout_state = aqueous.layout_states.getPtr(drag.layout_key) orelse return;
        const zone = pointer_drag.dropZone(target.geometry, x, y);
        if (!(layout_engine.drop(util.gpa, layout_state, drag.handle, target.handle, zone) catch {
            log.err("out of memory updating pointer drop target", .{});
            return;
        })) return;
        drag.awaiting_layout = target.handle;
        aqueous.api.requestManageCycle();
        return;
    }
    const dx: i32 = @intFromFloat(x - drag.pointer_x);
    const dy: i32 = @intFromFloat(y - drag.pointer_y);
    const geometry: layout_types.Rect = if (drag.action == .resize_floating)
        pointer_drag.resize(drag.start, dx, dy, drag.resize_edges)
    else
        .{
            .x = drag.start.x + dx,
            .y = drag.start.y + dy,
            .width = drag.start.width,
            .height = drag.start.height,
        };
    if (drag.action == .move_floating) aqueous.transferFloatingDrag(drag, geometry, x, y);
    if (drag.layout_floating) {
        const layout_state = aqueous.layout_states.getPtr(drag.layout_key) orelse return;
        layout_engine.setFloatingGeometry(util.gpa, layout_state, drag.handle, geometry) catch {
            log.err("out of memory remembering floating-layout geometry", .{});
            return;
        };
    } else if (!aqueous.window_states.setFloating(drag.handle, geometry)) return;
    aqueous.api.requestManageCycle();
}

fn transferFloatingDrag(aqueous: *Aqueous, drag: *Drag, geometry: layout_types.Rect, x: f64, y: f64) void {
    const target = aqueous.api.outputTargetAt(x, y, false) orelse return;
    if (target.id == drag.layout_key.output) return;
    const target_key: LayoutStateKey = .{ .output = target.id, .workspace = target.workspace_number };
    if (drag.layout_floating and !aqueous.layoutIsFloating(target_key)) return;
    if (!aqueous.api.moveWindowToWorkspace(drag.handle, target.id, target.workspace_number)) return;

    if (drag.layout_floating) {
        if (aqueous.layout_states.getPtr(drag.layout_key)) |source_state| {
            layout_engine.forgetWindow(source_state, drag.handle);
        }
        if (aqueous.layout_states.getPtr(target_key)) |target_state| {
            layout_engine.setFloatingGeometry(util.gpa, target_state, drag.handle, geometry) catch
                log.err("out of memory transferring floating-layout geometry", .{});
        }
    } else if (aqueous.window_states.get(drag.handle)) |state| {
        state.overrideWorkspace();
        state.needs_output_recovery = false;
    }
    drag.layout_key = target_key;
    _ = aqueous.api.selectOutput(target.id);
    log.debug("floating drag entered output {} workspace {}", .{ target.id, target.workspace_number });
}

fn runVerb(aqueous: *Aqueous, verb: []const u8) void {
    const colon = std.mem.indexOfScalar(u8, verb, ':') orelse {
        log.warn("unknown action '{s}'", .{verb});
        return;
    };
    const head = verb[0..colon];
    const argument = std.mem.trim(u8, verb[colon + 1 ..], " \t");
    if (std.mem.eql(u8, head, "spawn")) return aqueous.spawn(argument);
    if (std.mem.eql(u8, head, "set_layout")) return aqueous.setLayout(argument);
    if (std.mem.eql(u8, head, "builtin")) return aqueous.runBuiltin(argument);
    log.warn("unknown action verb '{s}'", .{head});
}

fn runBuiltin(aqueous: *Aqueous, value: []const u8) void {
    const colon = std.mem.indexOfScalar(u8, value, ':');
    const action = if (colon) |index| value[0..index] else value;
    if (std.mem.eql(u8, action, "toggle_start_menu")) return aqueous.spawn(aqueous.config.actions.toggle_start_menu.slice());
    if (std.mem.eql(u8, action, "spawn_terminal")) return aqueous.spawn(aqueous.config.actions.spawn_terminal.slice());
    if (std.mem.eql(u8, action, "screenshot")) return aqueous.spawn(aqueous.config.actions.screenshot.slice());
    if (std.mem.eql(u8, action, "lock_screen")) return aqueous.spawn(aqueous.config.actions.lock_screen.slice());
    if (std.mem.eql(u8, action, "toggle_overview")) return aqueous.toggleOverview();
    if (std.mem.eql(u8, action, "close_focused")) {
        if (aqueous.api.focusedWindow()) |handle| aqueous.api.closeWindow(handle);
        return;
    }
    if (std.mem.eql(u8, action, "reload_config")) return aqueous.reloadConfig();
    if (std.mem.eql(u8, action, "reload_rules")) {
        rules_config.reloadDiscovered(util.gpa, &aqueous.rules, aqueous.config.wm.rules_path.slice());
        aqueous.applyLayerRules();
        aqueous.api.requestManageCycle();
        aqueous.notify("Aqueous rules reloaded", null, false);
        return;
    }
    if (std.mem.startsWith(u8, action, "set_layout_")) {
        const slot: usize = if (std.mem.eql(u8, action, "set_layout_primary")) 0 else if (std.mem.eql(u8, action, "set_layout_secondary")) 1 else if (std.mem.eql(u8, action, "set_layout_tertiary")) 2 else 3;
        return aqueous.setLayoutId(aqueous.config.layout.slots[slot]);
    }
    if (parseIndexed(action, "focus_workspace_")) |number| return aqueous.focusWorkspace(number);
    if (parseIndexed(action, "move_to_workspace_")) |number| return aqueous.moveToWorkspace(number);
    if (std.mem.eql(u8, action, "focus_workspace_up")) return aqueous.relativeWorkspace(-1, false);
    if (std.mem.eql(u8, action, "focus_workspace_down")) return aqueous.relativeWorkspace(1, false);
    if (std.mem.eql(u8, action, "move_to_workspace_up")) return aqueous.relativeWorkspace(-1, true);
    if (std.mem.eql(u8, action, "move_to_workspace_down")) return aqueous.relativeWorkspace(1, true);
    if (std.mem.eql(u8, action, "focus_previous_workspace")) return aqueous.focusPreviousWorkspace();
    if (std.mem.eql(u8, action, "focus_output_left")) return aqueous.focusOutput(-1, false);
    if (std.mem.eql(u8, action, "focus_output_right")) return aqueous.focusOutput(1, false);
    if (std.mem.eql(u8, action, "move_to_output_left")) return aqueous.focusOutput(-1, true);
    if (std.mem.eql(u8, action, "move_to_output_right")) return aqueous.focusOutput(1, true);
    if (std.mem.eql(u8, action, "cycle_focus")) return aqueous.cycleFocus(1);
    if (std.mem.eql(u8, action, "focus_left")) return aqueous.directionalFocus(-1, 0);
    if (std.mem.eql(u8, action, "focus_right")) return aqueous.directionalFocus(1, 0);
    if (std.mem.eql(u8, action, "focus_up")) return aqueous.directionalFocus(0, -1);
    if (std.mem.eql(u8, action, "focus_down")) return aqueous.directionalFocus(0, 1);
    if (std.mem.eql(u8, action, "move_window_left")) return aqueous.moveFocused(-1, 0);
    if (std.mem.eql(u8, action, "move_window_right")) return aqueous.moveFocused(1, 0);
    if (std.mem.eql(u8, action, "move_window_up")) return aqueous.moveFocused(0, -1);
    if (std.mem.eql(u8, action, "move_window_down")) return aqueous.moveFocused(0, 1);
    if (std.mem.eql(u8, action, "move_column_left")) return aqueous.moveFocusedColumn(-1);
    if (std.mem.eql(u8, action, "move_column_right")) return aqueous.moveFocusedColumn(1);
    if (std.mem.eql(u8, action, "consume_window_into_column")) return aqueous.consumeWindowIntoColumn();
    if (std.mem.eql(u8, action, "expel_window_from_column")) return aqueous.expelWindowFromColumn();
    if (std.mem.startsWith(u8, action, "scroll_viewport_left")) return aqueous.scrollViewport(-1, 0);
    if (std.mem.startsWith(u8, action, "scroll_viewport_right")) return aqueous.scrollViewport(1, 0);
    if (std.mem.eql(u8, action, "scroll_viewport_up")) return aqueous.scrollViewport(0, -1);
    if (std.mem.eql(u8, action, "scroll_viewport_down")) return aqueous.scrollViewport(0, 1);
    if (std.mem.eql(u8, action, "toggle_scrolling_full_width")) return aqueous.toggleScrollingFullWidth();
    if (std.mem.eql(u8, action, "toggle_fullscreen")) return aqueous.toggleFullscreen();
    if (std.mem.eql(u8, action, "toggle_maximize")) return aqueous.toggleMaximize();
    if (std.mem.eql(u8, action, "toggle_floating")) return aqueous.toggleFloating();
    if (std.mem.eql(u8, action, "toggle_minimize")) return aqueous.toggleMinimize();
    if (std.mem.eql(u8, action, "unminimize_last")) {
        const handle = aqueous.window_states.restoreLastMinimized();
        if (handle != 0) aqueous.requestFocus(handle);
        aqueous.api.requestManageCycle();
        return;
    }
    log.warn("unknown builtin action '{s}'", .{action});
}

fn parseIndexed(action: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, action, prefix)) return null;
    const number = std.fmt.parseInt(u32, action[prefix.len..], 10) catch return null;
    return if (number >= 1 and number <= 9) number else null;
}

pub fn toggleOverview(aqueous: *Aqueous) void {
    if (aqueous.overview != null) {
        aqueous.cancelOverview();
    } else {
        aqueous.openOverview();
    }
}

fn openOverview(aqueous: *Aqueous) void {
    if (!aqueous.mode.runsInternal() or !aqueous.api.sessionUnlocked()) return;
    if (aqueous.drag != null or aqueous.api.hasNonWindowKeyboardFocus()) return;

    var snapshot = aqueous.api.policySnapshot(util.gpa) catch |err| {
        log.err("unable to snapshot windows for overview: {}", .{err});
        return;
    };
    defer snapshot.deinit(util.gpa);

    const focused = aqueous.api.focusedWindow();
    var target: ?*const CompositorApi.PolicyOutput = null;
    if (focused) |handle| {
        for (snapshot.outputs) |*output| {
            if (containsWindow(output.windows, handle)) {
                target = output;
                break;
            }
        }
    }
    if (target == null) {
        const selected_output = aqueous.api.selectedOutputId() orelse return;
        for (snapshot.outputs) |*output| {
            if (output.id == selected_output) {
                target = output;
                break;
            }
        }
    }
    const output = target orelse return;
    const usable_area = aqueous.effectiveUsableArea(output.area, output.usable_area);

    var state: overview_model.State = .{
        .output_id = output.id,
        .workspace_number = output.workspace_number,
        .original_focus = focused,
        .selected = 0,
    };
    errdefer state.cards.deinit(util.gpa);
    state.cards.ensureTotalCapacity(util.gpa, output.windows.len) catch {
        log.err("out of memory building overview", .{});
        return;
    };
    for (output.windows) |window| {
        if (!window.accepts_focus) continue;
        const window_state = aqueous.window_states.get(window.handle) orelse continue;
        if (window_state.kind == .minimized) continue;
        const geometry = aqueous.api.windowGeometry(window.handle) orelse continue;
        if (geometry.width <= 0 or geometry.height <= 0) continue;
        state.cards.appendAssumeCapacity(.{
            .handle = window.handle,
            .source = geometry,
        });
    }
    if (state.cards.items.len == 0) return;
    overview_model.arrange(state.cards.items, usable_area);
    state.selected = if (focused) |handle|
        if (overview_model.contains(state.cards.items, handle)) handle else state.cards.items[0].handle
    else
        state.cards.items[0].handle;

    const accepted = aqueous.api.showOverview(
        state.output_id,
        state.cards.items,
        &state.selected,
    ) catch |err| {
        log.warn("unable to show overview: {}", .{err});
        return;
    };
    state.cards.items.len = accepted;
    aqueous.overview = state;
    aqueous.api.suppressPointerConstraints(true);
    aqueous.api.refreshPointerFocus();
}

pub fn cancelOverview(aqueous: *Aqueous) void {
    var state = aqueous.overview orelse return;
    aqueous.overview = null;
    aqueous.api.hideOverview();
    state.deinit(util.gpa);
    aqueous.api.suppressPointerConstraints(false);
    aqueous.api.refreshPointerFocus();
}

fn confirmOverview(aqueous: *Aqueous) void {
    const state = aqueous.overview orelse return;
    const selected = state.selected;
    const output_id = state.output_id;
    const workspace_number = state.workspace_number;
    aqueous.cancelOverview();
    if (!aqueous.api.windowOnWorkspace(selected, output_id, workspace_number)) return;
    const window_state = aqueous.window_states.get(selected) orelse return;
    if (window_state.kind == .minimized) return;
    aqueous.requestFocus(selected);
}

fn moveOverviewSelection(aqueous: *Aqueous, direction: overview_model.Direction) void {
    const state = &(aqueous.overview orelse return);
    const selected = overview_model.neighbor(state.cards.items, state.selected, direction) orelse return;
    if (selected == state.selected) return;
    state.selected = selected;
    aqueous.api.updateOverviewSelection(selected);
}

fn cycleOverviewSelection(aqueous: *Aqueous, delta: i32) void {
    const state = &(aqueous.overview orelse return);
    const selected = overview_model.cycle(state.cards.items, state.selected, delta) orelse return;
    if (selected == state.selected) return;
    state.selected = selected;
    aqueous.api.updateOverviewSelection(selected);
}

fn updateOverviewHover(aqueous: *Aqueous, x: f64, y: f64) bool {
    const state = &(aqueous.overview orelse return false);
    const selected = overview_model.hitTest(state.cards.items, x, y) orelse return false;
    if (selected != state.selected) {
        state.selected = selected;
        aqueous.api.updateOverviewSelection(selected);
    }
    return true;
}

fn handleOverviewKey(aqueous: *Aqueous, keysym: u32, modifiers: u32, pressed: bool) bool {
    const modifier_mask = modifiers & (1 | 4 | 8 | 64);
    const toggle = if (aqueous.mode.runsInternal())
        aqueous.config.actions.find(keysym, modifier_mask)
    else
        null;
    if (toggle) |verb| {
        if (std.mem.eql(u8, verb, "builtin:toggle_overview")) {
            if (pressed) aqueous.cancelOverview();
            return true;
        }
    }
    if (!pressed) return !isModifierKeysym(keysym);
    switch (keysym) {
        0xff51, 'h', 'H' => aqueous.moveOverviewSelection(.left),
        0xff53, 'l', 'L' => aqueous.moveOverviewSelection(.right),
        0xff52, 'k', 'K' => aqueous.moveOverviewSelection(.up),
        0xff54, 'j', 'J' => aqueous.moveOverviewSelection(.down),
        0xff09 => aqueous.cycleOverviewSelection(if (modifier_mask & 1 != 0) -1 else 1),
        0xff0d, 0x20 => aqueous.confirmOverview(),
        0xff1b => aqueous.cancelOverview(),
        else => return !isModifierKeysym(keysym),
    }
    return true;
}

fn isModifierKeysym(keysym: u32) bool {
    return switch (keysym) {
        0xffe1...0xffee => true, // Shift, Control, Meta, Alt, Super, Hyper
        else => false,
    };
}

fn validateOverviewSnapshot(aqueous: *Aqueous, snapshot: *const CompositorApi.PolicySnapshot) void {
    const state = if (aqueous.overview) |*value| value else return;
    var owner: ?*const CompositorApi.PolicyOutput = null;
    for (snapshot.outputs) |*output| {
        if (output.id == state.output_id) {
            owner = output;
            break;
        }
    }
    const output = owner orelse {
        aqueous.cancelOverview();
        return;
    };
    if (output.workspace_number != state.workspace_number) {
        aqueous.cancelOverview();
        return;
    }
    var index: usize = 0;
    while (index < state.cards.items.len) {
        const card = state.cards.items[index];
        const window_state = aqueous.window_states.get(card.handle);
        if (window_state == null or window_state.?.kind == .minimized) {
            aqueous.cancelOverview();
            return;
        }
        if (!containsWindow(output.windows, card.handle)) {
            if (!aqueous.api.overviewWindowDisappearing(card.handle)) {
                aqueous.cancelOverview();
                return;
            }
            _ = overview_model.remove(state, card.handle);
            aqueous.api.removeOverviewWindow(card.handle);
            if (state.cards.items.len == 0) {
                aqueous.cancelOverview();
                return;
            }
            aqueous.api.updateOverviewSelection(state.selected);
            continue;
        }
        if (!aqueous.api.windowOnWorkspace(card.handle, state.output_id, state.workspace_number)) {
            aqueous.cancelOverview();
            return;
        }
        index += 1;
    }
}

pub fn forgetOutput(aqueous: *Aqueous, output_id: u64) void {
    const state = aqueous.overview orelse return;
    if (state.output_id == output_id) aqueous.cancelOverview();
}

fn focusWorkspace(aqueous: *Aqueous, number: u32) void {
    const context = aqueous.api.workspaceContext() orelse return;
    if (number == context.workspace_number) return;
    aqueous.previous_workspaces.put(util.gpa, context.output.policyId(), context.workspace_number) catch return;
    _ = aqueous.api.activateWorkspace(context.output.policyId(), number);
}

fn moveToWorkspace(aqueous: *Aqueous, number: u32) void {
    const context = aqueous.api.focusedContext() orelse return;
    context.window.policy_state.overrideWorkspace();
    _ = aqueous.api.moveWindowToWorkspace(@bitCast(context.window.ref), context.output.policyId(), number);
    aqueous.api.requestManageCycle();
}

fn relativeWorkspace(aqueous: *Aqueous, delta: i32, move: bool) void {
    const context: CompositorApi.WorkspaceContext = if (move) blk: {
        const focused = aqueous.api.focusedContext() orelse return;
        break :blk .{ .output = focused.output, .workspace_number = focused.workspace_number };
    } else aqueous.api.workspaceContext() orelse return;
    const target_i = @as(i32, @intCast(context.workspace_number)) + delta;
    if (target_i < 1 or target_i > 9) return;
    if (move) aqueous.moveToWorkspace(@intCast(target_i)) else aqueous.focusWorkspace(@intCast(target_i));
}

fn focusPreviousWorkspace(aqueous: *Aqueous) void {
    const context = aqueous.api.workspaceContext() orelse return;
    const previous = aqueous.previous_workspaces.get(context.output.policyId()) orelse return;
    aqueous.focusWorkspace(previous);
}

fn focusOutput(aqueous: *Aqueous, delta: i32, move: bool) void {
    const context = aqueous.api.workspaceContext() orelse return;
    const moving_window = if (move) aqueous.api.focusedContext() orelse return else null;
    var snapshot = aqueous.api.policySnapshot(util.gpa) catch return;
    defer snapshot.deinit(util.gpa);
    const direction: output_navigation.Direction = if (delta < 0) .left else .right;
    const target_index = output_navigation.neighbor(snapshot.outputs, context.output.policyId(), direction) orelse return;
    const target = snapshot.outputs[target_index];
    if (!aqueous.api.selectOutput(target.id)) return;
    if (move) {
        moving_window.?.window.policy_state.overrideWorkspace();
        const handle: layout_types.Handle = @bitCast(moving_window.?.window.ref);
        if (aqueous.api.moveWindowToWorkspace(handle, target.id, target.workspace_number)) aqueous.requestFocus(handle);
    } else {
        const candidate_context: OutputFocusContext = .{
            .aqueous = aqueous,
            .windows = target.windows,
            .output_id = target.id,
            .workspace_number = target.workspace_number,
        };
        var target_handle = aqueous.focus_history.pick(
            workspaceKey(target.id, target.workspace_number),
            candidate_context,
            outputFocusCandidateValid,
        );
        if (target_handle == 0) {
            for (target.windows) |window| {
                if (outputFocusCandidateValid(candidate_context, window.handle)) {
                    target_handle = window.handle;
                    break;
                }
            }
        }
        if (target_handle != 0) {
            aqueous.requestFocus(target_handle);
        } else {
            // Surface focus and output selection are deliberately independent:
            // an empty output remains selected after keyboard focus is cleared.
            aqueous.api.clearFocus();
        }
    }
    aqueous.api.requestManageCycle();
}

fn cycleFocus(aqueous: *Aqueous, delta: i32) void {
    var snapshot = aqueous.api.policySnapshot(util.gpa) catch return;
    defer snapshot.deinit(util.gpa);
    const focused = aqueous.api.focusedWindow();
    for (snapshot.outputs) |output| {
        if (output.windows.len == 0) continue;
        const index = if (focused) |handle| blk: {
            for (output.windows, 0..) |window, i| if (window.handle == handle) break :blk i;
            continue;
        } else 0;
        const next = if (delta < 0) (index + output.windows.len - 1) % output.windows.len else (index + 1) % output.windows.len;
        aqueous.requestFocus(output.windows[next].handle);
        return;
    }
}

fn directionalFocus(aqueous: *Aqueous, dx: i32, dy: i32) void {
    const focused = aqueous.api.focusedWindow() orelse return;
    if (aqueous.api.directionalNeighbor(focused, dx, dy)) |target| aqueous.requestFocus(target);
}

fn moveFocused(aqueous: *Aqueous, dx: i32, dy: i32) void {
    const context = aqueous.api.focusedContext() orelse return;
    if (context.window.policy_state.kind != .tiled) return;
    const key: LayoutStateKey = .{ .output = context.output.policyId(), .workspace = context.workspace_number };
    const state = aqueous.layout_states.getPtr(key) orelse return;
    const handle: layout_types.Handle = @bitCast(context.window.ref);
    if (state.active_layout == .scrolling) {
        if (!(layout_engine.moveScrolling(util.gpa, state, handle, dx, dy) catch {
            log.err("out of memory moving scrolling column member", .{});
            return;
        })) return;
        aqueous.api.requestManageCycle();
        return;
    }
    const target = aqueous.api.directionalNeighbor(handle, dx, dy) orelse return;
    const target_state = aqueous.window_states.get(target) orelse return;
    if (target_state.kind != .tiled) return;
    if (layout_engine.swap(state, handle, target)) aqueous.api.requestManageCycle();
}

fn moveFocusedColumn(aqueous: *Aqueous, delta: i32) void {
    const context = aqueous.api.focusedContext() orelse return;
    if (context.window.policy_state.kind != .tiled) return;
    const key: LayoutStateKey = .{ .output = context.output.policyId(), .workspace = context.workspace_number };
    const state = aqueous.layout_states.getPtr(key) orelse return;
    const handle: layout_types.Handle = @bitCast(context.window.ref);
    if (!(layout_engine.moveScrollingColumn(util.gpa, state, handle, delta) catch {
        log.err("out of memory moving scrolling column", .{});
        return;
    })) return;
    aqueous.api.requestManageCycle();
}

fn scrollViewport(aqueous: *Aqueous, dx: i32, dy: i32) void {
    const context = aqueous.api.focusedContext() orelse return;
    const state = aqueous.layout_states.getPtr(.{ .output = context.output.policyId(), .workspace = context.workspace_number }) orelse return;
    if (layout_engine.scrollViewport(state, @bitCast(context.window.ref), dx, dy)) aqueous.api.requestManageCycle();
}

fn consumeWindowIntoColumn(aqueous: *Aqueous) void {
    const context = aqueous.api.focusedContext() orelse return;
    if (context.window.policy_state.kind != .tiled) return;
    const state = aqueous.layout_states.getPtr(.{ .output = context.output.policyId(), .workspace = context.workspace_number }) orelse return;
    if (!(layout_engine.consumeWindowIntoColumn(util.gpa, state, @bitCast(context.window.ref)) catch {
        log.err("out of memory consuming window into column", .{});
        return;
    })) return;
    aqueous.api.requestManageCycle();
}

fn expelWindowFromColumn(aqueous: *Aqueous) void {
    const context = aqueous.api.focusedContext() orelse return;
    if (context.window.policy_state.kind != .tiled) return;
    const state = aqueous.layout_states.getPtr(.{ .output = context.output.policyId(), .workspace = context.workspace_number }) orelse return;
    if (!(layout_engine.expelWindowFromColumn(util.gpa, state, @bitCast(context.window.ref)) catch {
        log.err("out of memory expelling window from column", .{});
        return;
    })) return;
    aqueous.api.requestManageCycle();
}

fn toggleFullscreen(aqueous: *Aqueous) void {
    const context = aqueous.api.focusedContext() orelse return;
    const handle: layout_types.Handle = @bitCast(context.window.ref);
    context.window.policy_state.overrideFullscreen();
    if (context.window.policySnapshot().fullscreen) {
        aqueous.api.clearFullscreen(handle);
    } else {
        aqueous.api.clearOtherFullscreen(context.output.policyId(), handle);
        _ = aqueous.api.setFullscreen(handle, context.output.policyId());
    }
    aqueous.api.requestManageCycle();
}

fn toggleMaximize(aqueous: *Aqueous) void {
    const handle = aqueous.api.focusedWindow() orelse return;
    _ = aqueous.window_states.toggleMaximized(handle) orelse return;
    aqueous.api.requestManageCycle();
}

fn toggleScrollingFullWidth(aqueous: *Aqueous) void {
    const context = aqueous.api.focusedContext() orelse return;
    if (context.window.policy_state.kind != .tiled) return;
    _ = context.window.policy_state.toggleScrollingFullWidth();
    aqueous.api.requestManageCycle();
}

fn toggleFloating(aqueous: *Aqueous) void {
    const context = aqueous.api.focusedContext() orelse return;
    const handle: layout_types.Handle = @bitCast(context.window.ref);
    const key: LayoutStateKey = .{ .output = context.output.policyId(), .workspace = context.workspace_number };
    const box = context.window.box;
    const geometry: layout_types.Rect = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };

    // In a floating workspace, toggling on creates a deliberate per-window
    // overlay which remains floating after a later layout switch. Toggling off
    // returns the window to workspace ownership at its latest rectangle.
    if (aqueous.layoutIsFloating(key)) {
        const layout_state = aqueous.layout_states.getPtr(key) orelse return;
        layout_engine.setFloatingGeometry(util.gpa, layout_state, handle, geometry) catch return;
    }
    _ = aqueous.window_states.toggleFloating(handle, geometry) orelse return;
    aqueous.api.requestManageCycle();
}

fn toggleMinimize(aqueous: *Aqueous) void {
    const handle = aqueous.api.focusedWindow() orelse return;
    if (!aqueous.window_states.restore(handle)) {
        if (aqueous.window_states.get(handle)) |state| state.overrideFullscreen();
        aqueous.api.clearFullscreen(handle);
        _ = aqueous.window_states.minimize(handle) catch return;
    }
    aqueous.api.requestManageCycle();
}

fn setLayout(aqueous: *Aqueous, name: []const u8) void {
    const id = parseLayoutName(name) orelse {
        if (std.mem.eql(u8, name, "primary")) return aqueous.setLayoutId(aqueous.config.layout.slots[0]);
        if (std.mem.eql(u8, name, "secondary")) return aqueous.setLayoutId(aqueous.config.layout.slots[1]);
        if (std.mem.eql(u8, name, "tertiary")) return aqueous.setLayoutId(aqueous.config.layout.slots[2]);
        if (std.mem.eql(u8, name, "quaternary")) return aqueous.setLayoutId(aqueous.config.layout.slots[3]);
        return;
    };
    aqueous.setLayoutId(id);
}

fn parseLayoutName(name: []const u8) ?layout_config.LayoutId {
    return std.meta.stringToEnum(
        layout_config.LayoutId,
        if (std.mem.eql(u8, name, "float")) "floating" else if (std.mem.eql(u8, name, "game-mode")) "game_mode" else name,
    );
}

pub fn layoutName(id: layout_config.LayoutId) [:0]const u8 {
    return switch (id) {
        .floating => "float",
        .game_mode => "game-mode",
        else => @tagName(id),
    };
}

pub const ActiveWorkspaceLayout = struct {
    workspace: u32,
    layout: layout_config.LayoutId,
};

fn outputByName(name: []const u8) ?*@import("../Output.zig") {
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (std.mem.eql(u8, output.policyName(), name)) return output;
    }
    return null;
}

pub fn activeWorkspaceLayout(aqueous: *Aqueous, output_name: []const u8) ?ActiveWorkspaceLayout {
    if (!aqueous.mode.runsInternal()) return null;
    const output = outputByName(output_name) orelse return null;
    const workspace = output.policyActiveWorkspaceNumber();
    if (workspace == 0) return null;
    const key: LayoutStateKey = .{ .output = output.policyId(), .workspace = workspace };
    if (aqueous.layout_overrides.get(key)) |id| return .{ .workspace = workspace, .layout = id };
    if (aqueous.layout_states.get(key)) |state| return .{ .workspace = workspace, .layout = state.active_layout };

    var id = aqueous.config.layout.default;
    const identity = output.policyIdentity();
    if (aqueous.config.wm.resolveOutput(.{
        .name = identity.name,
        .make = identity.make,
        .model = identity.model,
        .serial = identity.serial,
    })) |configured| id = configured;
    if (aqueous.config.wm.resolveWorkspace(output_name, workspace)) |configured| id = configured;
    return .{ .workspace = workspace, .layout = id };
}

pub const SetActiveWorkspaceLayoutStatus = enum {
    success,
    output_not_found,
    invalid_layout,
    unavailable,
};

pub fn setActiveWorkspaceLayout(
    aqueous: *Aqueous,
    output_name: []const u8,
    layout_name: []const u8,
) SetActiveWorkspaceLayoutStatus {
    if (!aqueous.mode.runsInternal()) return .unavailable;
    const id = parseLayoutName(layout_name) orelse return .invalid_layout;
    const output = outputByName(output_name) orelse return .output_not_found;
    const workspace = output.policyActiveWorkspaceNumber();
    if (workspace == 0) return .unavailable;
    const key: LayoutStateKey = .{ .output = output.policyId(), .workspace = workspace };
    if (aqueous.layout_states.getPtr(key)) |state| state.game_mode.rule_layout_owned = false;
    aqueous.layout_overrides.put(util.gpa, key, id) catch return .unavailable;
    aqueous.api.requestManageCycle();
    return .success;
}

fn setLayoutId(aqueous: *Aqueous, id: layout_config.LayoutId) void {
    const context = aqueous.api.focusedContext() orelse return;
    const key: LayoutStateKey = .{ .output = context.output.policyId(), .workspace = context.workspace_number };
    if (aqueous.layout_states.getPtr(key)) |state| state.game_mode.rule_layout_owned = false;
    aqueous.layout_overrides.put(util.gpa, key, id) catch return;
    aqueous.api.requestManageCycle();
}

fn layoutIsFloating(aqueous: *const Aqueous, key: LayoutStateKey) bool {
    if (aqueous.layout_overrides.get(key)) |id| return id == .floating;
    if (aqueous.layout_states.get(key)) |state| return state.active_layout == .floating;
    return aqueous.config.layout.default == .floating;
}

fn clientWindowUsesFloatingLayout(
    aqueous: *const Aqueous,
    handle: layout_types.Handle,
) bool {
    if (!aqueous.mode.runsInternal()) return false;
    const workspace = aqueous.api.windowWorkspace(handle) orelse return false;
    return aqueous.layoutIsFloating(.{
        .output = workspace.output_id,
        .workspace = workspace.workspace_number,
    });
}

pub fn clientMinimizeAllowed(
    aqueous: *Aqueous,
    handle: layout_types.Handle,
    minimized: bool,
) bool {
    return aqueous.window_states.clientMinimizeAllowed(
        handle,
        minimized,
        aqueous.clientWindowUsesFloatingLayout(handle),
    );
}

fn applyInputConfig(aqueous: *Aqueous) void {
    if (aqueous.started and aqueous.mode.runsInternal()) aqueous.api.applyInputConfig(aqueous.config.wm.input);
}

fn runExec(aqueous: *Aqueous, when: action_config.ExecWhen) void {
    if (!aqueous.started) return;
    for (aqueous.config.actions.exec[0..aqueous.config.actions.exec_count]) |*entry| {
        if (!(entry.when == .always or entry.when == when)) continue;
        var hash = std.hash.Wyhash.init(0);
        hash.update(entry.name.slice());
        const key = hash.final();
        if (entry.once and aqueous.fired_exec.contains(key)) continue;
        if (entry.once) aqueous.fired_exec.put(util.gpa, key, {}) catch continue;
        aqueous.spawnExec(entry);
    }
}

fn spawnExec(aqueous: *Aqueous, entry: *const action_config.Exec) void {
    var buffer: [2048]u8 = undefined;
    var out: usize = 0;
    if (!entry.env.empty()) {
        const raw = std.mem.trim(u8, entry.env.slice(), " {}\t");
        var pairs = std.mem.splitScalar(u8, raw, ',');
        while (pairs.next()) |pair| {
            const equal = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = std.mem.trim(u8, pair[0..equal], " \t");
            const value = wmUnquote(std.mem.trim(u8, pair[equal + 1 ..], " \t"));
            const rendered = std.fmt.bufPrint(buffer[out..], "export {s}='{s}'; ", .{ key, value }) catch return;
            out += rendered.len;
        }
    }
    if (entry.restart) {
        const rendered = std.fmt.bufPrint(buffer[out..], "delay=.25; while :; do {s}; code=$?; [ $code -eq 0 ] && break; sleep $delay; case $delay in .25) delay=.5;; .5) delay=1;; 1) delay=2;; 2) delay=4;; 4) delay=8;; *) delay=10;; esac; done", .{entry.command.slice()}) catch return;
        out += rendered.len;
    } else {
        const rendered = std.fmt.bufPrint(buffer[out..], "{s}", .{entry.command.slice()}) catch return;
        out += rendered.len;
    }
    if (!entry.log_path.empty()) {
        const rendered = std.fmt.bufPrint(buffer[out..], " >>'{s}' 2>&1", .{entry.log_path.slice()}) catch return;
        out += rendered.len;
    }
    aqueous.spawn(buffer[0..out]);
}

fn wmUnquote(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) return value[1 .. value.len - 1];
    return value;
}

fn spawn(_: *Aqueous, command: []const u8) void {
    if (command.len == 0) return;
    const owned = util.gpa.dupeZ(u8, command) catch return;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", owned.ptr, null };
    const rc = posix.system.fork();
    if (posix.errno(rc) != .SUCCESS) {
        util.gpa.free(owned);
        log.err("fork failed for command '{s}'", .{command});
        return;
    }
    if (rc == 0) {
        process.cleanupChild();
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        if (posix.errno(posix.system.execve("/bin/sh", &argv, envp)) != .SUCCESS) posix.system.exit(127);
    }
    util.gpa.free(owned);
}

fn notify(aqueous: *Aqueous, summary: []const u8, body: ?[]const u8, is_error: bool) void {
    _ = body;
    var buffer: [512]u8 = undefined;
    const command = std.fmt.bufPrint(&buffer, "notify-send --app-name=Aqueous --expire-time=3000 --urgency={s} '{s}'", .{ if (is_error) "critical" else "normal", summary }) catch return;
    aqueous.spawn(command);
}

fn focusCandidateValid(windows: []const layout_types.Window, handle: layout_types.Handle) bool {
    return containsWindow(windows, handle);
}

fn admissionFocusEligible(accepts_focus: bool, kind: StateStore.Kind, workspace_visible: bool) bool {
    return accepts_focus and kind != .minimized and workspace_visible;
}

const OutputFocusContext = struct {
    aqueous: *Aqueous,
    windows: []const layout_types.Window,
    output_id: u64,
    workspace_number: u32,
};

fn outputFocusCandidateValid(context: OutputFocusContext, handle: layout_types.Handle) bool {
    if (!containsWindow(context.windows, handle)) return false;
    if (!context.aqueous.api.windowOnWorkspace(handle, context.output_id, context.workspace_number)) return false;
    const state = context.aqueous.window_states.get(handle) orelse return false;
    return state.kind != .minimized;
}

fn workspaceKey(output_id: u64, workspace_number: u32) u64 {
    return output_id ^ (@as(u64, workspace_number) *% 0x9e3779b97f4a7c15);
}

fn containsWindow(windows: []const layout_types.Window, handle: layout_types.Handle) bool {
    for (windows) |window| if (window.handle == handle) return true;
    return false;
}

const RuleEffect = struct {
    fullscreen: bool,
    workspace_visible: bool = true,
};

/// Reconcile stateful rule properties only when the semantic match changes.
/// Visual properties are intentionally handled separately on every cycle.
fn reconcileWindowRule(
    aqueous: *Aqueous,
    window: layout_types.Window,
    output_id: u64,
    active_workspace: u32,
    output_area: layout_types.Rect,
    usable_area: layout_types.Rect,
    border: layout_types.Border,
    rule: ?Rules.Rule,
) RuleEffect {
    const state = aqueous.window_states.get(window.handle) orelse return .{ .fullscreen = window.fullscreen };
    const match = if (rule) |matched| matched.matcherFingerprint() else 0;
    var effect: RuleEffect = .{ .fullscreen = window.fullscreen };
    const match_changed = state.ruleChanged(match);

    if (match_changed) {
        // Undo only properties which are still owned by the old match. Manual
        // overrides survive until the matcher itself changes.
        if (state.rule_fullscreen_owned) {
            if (state.rule_fullscreen_previous) {
                if (!effect.fullscreen) {
                    aqueous.api.clearOtherFullscreen(output_id, window.handle);
                    effect.fullscreen = aqueous.api.setFullscreen(window.handle, output_id);
                }
            } else {
                aqueous.api.clearFullscreen(window.handle);
                effect.fullscreen = false;
            }
        }
        _ = aqueous.window_states.restoreRuleFloating(window.handle);
        state.acceptRuleMatch(match);
    }

    const matched = rule orelse return effect;
    const requested_workspace = matched.placement.workspace;
    if (requested_workspace != state.rule_workspace_requested) {
        if (requested_workspace == 0) {
            state.rule_workspace_owned = false;
            state.rule_workspace_overridden = false;
        } else if (!state.rule_workspace_overridden and aqueous.api.applyRuleWorkspace(window.handle, output_id, requested_workspace)) {
            state.rule_workspace_owned = true;
            effect.workspace_visible = requested_workspace == active_workspace;
        }
        state.rule_workspace_requested = requested_workspace;
    }

    if (matched.fullscreen != state.rule_fullscreen_requested) {
        if (matched.fullscreen) {
            if (!state.rule_fullscreen_overridden) {
                state.rule_fullscreen_previous = effect.fullscreen;
                aqueous.api.clearOtherFullscreen(output_id, window.handle);
                if (aqueous.api.setFullscreen(window.handle, output_id)) {
                    state.rule_fullscreen_owned = true;
                    effect.fullscreen = true;
                }
            }
        } else {
            if (state.rule_fullscreen_owned) {
                if (state.rule_fullscreen_previous) {
                    if (!effect.fullscreen) {
                        aqueous.api.clearOtherFullscreen(output_id, window.handle);
                        effect.fullscreen = aqueous.api.setFullscreen(window.handle, output_id);
                    }
                } else {
                    aqueous.api.clearFullscreen(window.handle);
                    effect.fullscreen = false;
                }
            }
            state.rule_fullscreen_owned = false;
            state.rule_fullscreen_overridden = false;
        }
        state.rule_fullscreen_requested = matched.fullscreen;
    }

    const floating_signature = matched.floatingFingerprint();
    if (matched.placement.floating != state.rule_floating_requested or
        (matched.placement.floating and floating_signature != state.rule_floating_signature))
    {
        if (matched.placement.floating) {
            if (!state.rule_floating_overridden) {
                const area = if (matched.ignore_struts) output_area else usable_area;
                const geometry = floatingRulePlacement(area, window, matched, border).geometry;
                _ = aqueous.window_states.setRuleFloating(window.handle, geometry);
            }
        } else {
            _ = aqueous.window_states.restoreRuleFloating(window.handle);
            state.rule_floating_overridden = false;
        }
        state.rule_floating_requested = matched.placement.floating;
        state.rule_floating_signature = floating_signature;
    }
    return effect;
}

fn handleReloadTimer(aqueous: *Aqueous) c_int {
    defer if (aqueous.reload_timer) |timer| timer.timerUpdate(1000) catch log.warn("unable to re-arm configuration monitor", .{});
    const replacement = config_loader.load(util.gpa);
    const config_changed = replacement.fingerprint != aqueous.config.fingerprint;
    const rules_fingerprint = rules_config.discoveredFingerprint(util.gpa, replacement.wm.rules_path.slice());
    const rules_changed = rules_fingerprint != aqueous.rules.source_fingerprint;
    const output_changed = aqueous.output_service.pollReload();
    if (!config_changed and !rules_changed and !output_changed) return 0;

    aqueous.cancelOverview();
    if (config_changed) {
        aqueous.config = replacement;
        if (!aqueous.config.wm.input.focus_new_windows) aqueous.pending_new_focus = 0;
    }
    if (config_changed or rules_changed) {
        rules_config.reloadDiscovered(util.gpa, &aqueous.rules, aqueous.config.wm.rules_path.slice());
        aqueous.applyLayerRules();
    }
    aqueous.globals_applied = false;
    aqueous.api.requestManageCycle();
    log.info("configuration hot-reloaded layout={s}", .{@tagName(aqueous.config.layout.default)});
    if (config_changed or rules_changed) {
        aqueous.applyInputConfig();
        aqueous.runExec(.reload);
        aqueous.notify("Aqueous configuration reloaded", null, false);
    }
    return 0;
}

pub fn layerBlurEnabled(aqueous: *const Aqueous, namespace: []const u8) bool {
    if (!aqueous.mode.runsInternal()) return false;
    const rule = aqueous.rules.resolveLayer(namespace) orelse return false;
    return rule.blur;
}

pub fn layerPopupBlurEnabled(
    aqueous: *const Aqueous,
    namespace: []const u8,
) bool {
    if (!aqueous.mode.runsInternal()) return false;
    const rule = aqueous.rules.resolveLayer(namespace) orelse return false;
    return rule.blur and rule.blur_popups;
}

pub fn hasLayerBlurRules(aqueous: *const Aqueous) bool {
    if (!aqueous.mode.runsInternal()) return false;
    for (aqueous.rules.layer_rules) |rule| {
        if (rule.blur) return true;
    }
    return false;
}

fn applyLayerRules(aqueous: *Aqueous) void {
    if (!aqueous.mode.runsInternal()) return;
    var surfaces = server.layer_shell.surfaces.iterator();
    while (surfaces.next()) |surface| {
        const namespace = std.mem.span(surface.wlr_layer_surface.namespace);
        surface.applyBlurRule(
            aqueous.layerBlurEnabled(namespace),
            aqueous.layerPopupBlurEnabled(namespace),
        );
    }
}

fn applyGlobalConfig(aqueous: *Aqueous) void {
    const config = aqueous.config.wm;
    const opacity = if (config.opacity_enabled) config.opacity else 1;
    aqueous.api.applyGlobals(
        config.blur_enabled,
        config.blur_radius,
        config.blur_passes,
        .{
            .noise = @floatCast(config.blur_noise),
            .contrast = @floatCast(config.blur_contrast),
            .brightness = @floatCast(config.blur_brightness),
            .vibrancy = @floatCast(config.blur_vibrancy),
            .vibrancy_darkness = @floatCast(config.blur_vibrancy_darkness),
        },
        opacity,
        config.workspace_transition_enabled,
        config.workspace_transition_rate,
    );
}

fn ensureFocusedPlacementOnTop(aqueous: *Aqueous, placements: []layout_types.Placement, focused: ?layout_types.Handle) void {
    const handle = focused orelse return;
    var target: ?*layout_types.Placement = null;
    for (placements) |*placement| {
        if (placement.handle == handle and !placement.tiled and placement.visible) {
            target = placement;
            break;
        }
    }
    const focused_placement = target orelse return;

    var greatest_order = focused_placement.stack_order;
    for (placements) |placement| {
        if (placement.z_order == focused_placement.z_order) {
            greatest_order = @max(greatest_order, placement.stack_order);
        }
    }
    if (focused_placement.stack_order >= greatest_order) return;

    const order = aqueous.takeStackOrder();
    focused_placement.stack_order = order;
    if (aqueous.window_states.get(handle)) |state| state.stack_order = order;
}

/// Raise at request time because the compositor applies keyboard focus in
/// manageFinish(), after policy has already resolved this transaction's scene
/// order. Waiting to observe the new focus would make click-to-raise lag by one
/// unrelated manage cycle.
fn requestFocus(aqueous: *Aqueous, handle: layout_types.Handle) void {
    if (aqueous.window_states.get(handle)) |state| state.stack_order = aqueous.takeStackOrder();
    aqueous.requested_stack_focus = handle;
    aqueous.api.requestFocus(handle);
}

fn transactionFocus(
    requested: ?layout_types.Handle,
    committed: ?layout_types.Handle,
) ?layout_types.Handle {
    return requested orelse committed;
}

fn ensureStackOrder(aqueous: *Aqueous, state: *StateStore.Entry) u64 {
    if (state.stack_order == 0) state.stack_order = aqueous.takeStackOrder();
    return state.stack_order;
}

fn takeStackOrder(aqueous: *Aqueous) u64 {
    const order = aqueous.next_stack_order;
    aqueous.next_stack_order += 1;
    return order;
}

fn intersectRects(a: layout_types.Rect, b: layout_types.Rect) layout_types.Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.right(), b.right());
    const bottom = @min(a.bottom(), b.bottom());
    return .{
        .x = left,
        .y = top,
        .width = @max(1, right - left),
        .height = @max(1, bottom - top),
    };
}

fn effectiveUsableArea(aqueous: *const Aqueous, area: layout_types.Rect, live_usable_area: layout_types.Rect) layout_types.Rect {
    return intersectRects(live_usable_area, aqueous.config.wm.struts.apply(area));
}

fn ruleLayout(id: Rules.Layout) layout_config.LayoutId {
    return switch (id) {
        .tile => .tile,
        .monocle => .monocle,
        .grid => .grid,
        .rows => .rows,
        .dwindle => .dwindle,
        .scrolling => .scrolling,
        .floating => .floating,
        .game_mode => .game_mode,
    };
}

fn floatingPlacement(area: layout_types.Rect, handle: layout_types.Handle, placement: Rules.Placement, border: layout_types.Border) layout_types.Placement {
    const width = @min(area.width, if (placement.width > 0) placement.width else @max(1, @divTrunc(area.width * 3, 5)));
    const height = @min(area.height, if (placement.height > 0) placement.height else @max(1, @divTrunc(area.height * 3, 5)));
    const x = if (placement.x != 0) area.x + placement.x else area.x + @divTrunc(area.width - width, 2);
    const y = if (placement.y != 0) area.y + placement.y else area.y + @divTrunc(area.height - height, 2);
    return .{
        .handle = handle,
        .geometry = .{ .x = x, .y = y, .width = width, .height = height },
        .z_order = stacking.floating_band,
        .visible = true,
        .border = border,
        .tiled = false,
    };
}

fn floatingRulePlacement(area: layout_types.Rect, window: layout_types.Window, rule: Rules.Rule, border: layout_types.Border) layout_types.Placement {
    var placement = rule.placement;
    switch (rule.size) {
        .native => {
            if (placement.width == 0) placement.width = window.min_width;
            if (placement.height == 0) placement.height = window.min_height;
        },
        .pixels => |size| {
            placement.width = size.width;
            placement.height = size.height;
        },
        .fraction => |size| {
            placement.width = @intFromFloat(@as(f64, @floatFromInt(area.width)) * size.width);
            placement.height = @intFromFloat(@as(f64, @floatFromInt(area.height)) * size.height);
        },
    }
    return floatingPlacement(area, window.handle, placement, border);
}

fn gameOptions(rule: Rules.Rule, config: Rules.GameMode, output_area: layout_types.Rect, layout_snapshot: *const layout_config.Snapshot) game_mode.Options {
    return .{
        .size = switch (rule.size) {
            .native => .native,
            .pixels => |size| .{ .pixels = .{ .width = size.width, .height = size.height } },
            .fraction => |size| .{ .fraction = .{ .width = size.width, .height = size.height } },
        },
        .anchor = switch (rule.anchor) {
            .center => .center,
            .top => .top,
            .bottom => .bottom,
            .left => .left,
            .right => .right,
        },
        .scale = rule.scale,
        .remainder = ruleRemainder(config.remainder_layout),
        .fallback = ruleRemainder(config.fallback_layout),
        .gaps_inner = config.gaps_inner,
        .anchor_area = if (rule.ignore_struts) output_area else null,
        .scrolling_options = game_mode.ScrollingOptions{
            .center_focused = layout_snapshot.scrolling_center_focused,
            .column_fraction = layout_snapshot.scrolling_column_fraction,
            .follow_new = layout_snapshot.scrolling_follow_new,
            .overscroll = layout_snapshot.scrolling_overscroll,
            .snap = layout_snapshot.scrolling_snap,
        },
    };
}

fn gameConfigOptions(config: Rules.GameMode, layout_snapshot: *const layout_config.Snapshot) game_mode.Options {
    return .{
        .remainder = ruleRemainder(config.remainder_layout),
        .fallback = ruleRemainder(config.fallback_layout),
        .gaps_inner = config.gaps_inner,
        .scrolling_options = game_mode.ScrollingOptions{
            .column_fraction = layout_snapshot.scrolling_column_fraction,
            .center_focused = layout_snapshot.scrolling_center_focused,
            .follow_new = layout_snapshot.scrolling_follow_new,
            .snap = layout_snapshot.scrolling_snap,
            .overscroll = layout_snapshot.scrolling_overscroll,
        },
    };
}

fn ruleRemainder(id: Rules.Layout) game_mode.Remainder {
    return switch (id) {
        .tile => .tile,
        .monocle => .monocle,
        .grid, .game_mode => .grid,
        .rows => .rows,
        .dwindle => .dwindle,
        .scrolling => .scrolling,
        .floating => .floating,
    };
}

test "usable area combines layer-shell zones and static struts without double counting" {
    const live: layout_types.Rect = .{ .x = 0, .y = 32, .width = 1920, .height = 1048 };
    const configured: layout_types.Rect = .{ .x = 0, .y = 32, .width = 1920, .height = 1048 };
    try std.testing.expectEqual(configured, intersectRects(live, configured));

    const dock: layout_types.Rect = .{ .x = 48, .y = 0, .width = 1872, .height = 1080 };
    try std.testing.expectEqual(
        layout_types.Rect{ .x = 48, .y = 32, .width = 1872, .height = 1048 },
        intersectRects(dock, configured),
    );
}

test "new-window focus eligibility rejects hidden, minimized, and input-inert windows" {
    try std.testing.expect(admissionFocusEligible(true, .tiled, true));
    try std.testing.expect(admissionFocusEligible(true, .floating, true));
    try std.testing.expect(!admissionFocusEligible(false, .tiled, true));
    try std.testing.expect(!admissionFocusEligible(true, .minimized, true));
    try std.testing.expect(!admissionFocusEligible(true, .tiled, false));
}

test "pending focus drives the transaction before seat focus commits" {
    try std.testing.expectEqual(
        @as(?layout_types.Handle, 22),
        transactionFocus(22, 11),
    );
    try std.testing.expectEqual(
        @as(?layout_types.Handle, 11),
        transactionFocus(null, 11),
    );
}
