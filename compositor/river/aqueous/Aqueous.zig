// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Aqueous = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;

const CompositorApi = @import("CompositorApi.zig");
const Mode = @import("Mode.zig").Mode;
const Trace = @import("Trace.zig");
const layout_config = @import("config/layout.zig");
const config_loader = @import("config/loader.zig");
const layout_engine = @import("layout/engine.zig");
const game_mode = @import("layout/game_mode.zig");
const layout_types = @import("layout/types.zig");
const FocusHistory = @import("focus/history.zig");
const PendingFocus = @import("focus/pending.zig");
const StateStore = @import("state/store.zig");
const rules_config = @import("rules/config.zig");
const Rules = @import("rules/engine.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.aqueous);

const LayoutStateKey = struct { output: u64, workspace: u32 };

mode: Mode,
api: CompositorApi = .{},
trace: Trace = .{},
config: config_loader.Snapshot = .{},
rules: Rules,
layout_states: std.AutoHashMapUnmanaged(LayoutStateKey, layout_engine.State) = .empty,
reload_timer: ?*wl.EventSource = null,
globals_applied: bool = false,
focus_history: FocusHistory,
pending_focus: PendingFocus,
window_states: StateStore,

pub fn init(aqueous: *Aqueous, mode: Mode) void {
    aqueous.* = .{
        .mode = mode,
        .config = config_loader.load(util.gpa),
        .rules = Rules.init(util.gpa),
        .focus_history = FocusHistory.init(util.gpa),
        .pending_focus = PendingFocus.init(util.gpa),
        .window_states = StateStore.init(util.gpa),
    };
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
    if (aqueous.reload_timer) |timer| timer.remove();
    var states = aqueous.layout_states.valueIterator();
    while (states.next()) |state| state.deinit(util.gpa);
    aqueous.layout_states.deinit(util.gpa);
    aqueous.focus_history.deinit();
    aqueous.pending_focus.deinit();
    aqueous.window_states.deinit();
    aqueous.rules.deinit();
    log.debug("policy stopped after {} trace event(s)", .{aqueous.trace.sequence});
}

pub fn allowsExternal(aqueous: *const Aqueous) bool {
    return aqueous.mode.allowsExternal();
}

pub fn reloadConfig(aqueous: *Aqueous) void {
    aqueous.config = config_loader.load(util.gpa);
    rules_config.reloadDiscovered(util.gpa, &aqueous.rules, aqueous.config.wm.rules_path.slice());
    aqueous.globals_applied = false;
    aqueous.api.requestManageCycle();
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

    if (!aqueous.globals_applied) {
        aqueous.applyGlobalConfig();
        aqueous.globals_applied = true;
    }

    var snapshot = try aqueous.api.policySnapshot(util.gpa);
    defer snapshot.deinit(util.gpa);
    const focused = aqueous.api.focusedWindow();
    if (focused != null and focused == aqueous.pending_focus.window) aqueous.pending_focus.clear();

    for (snapshot.outputs) |output| {
        var output_layout = aqueous.config.layout;
        if (aqueous.config.wm.resolveOutput(.{ .name = output.name, .make = output.make, .model = output.model, .serial = output.serial })) |configured| output_layout.default = configured;
        if (aqueous.config.wm.resolveWorkspace(output.name, output.workspace_number)) |configured| output_layout.default = configured;
        const usable_area = aqueous.config.wm.struts.apply(output.area);
        const workspace_key = output.id ^ (@as(u64, output.workspace_number) *% 0x9e3779b97f4a7c15);
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
        for (output.windows) |window| {
            const state = try aqueous.window_states.observe(window.handle, output.id, output.workspace_number, window.fullscreen);
            if (window.fullscreen and state.kind != .fullscreen) {
                if (try aqueous.window_states.enterFullscreen(window.handle, output.id)) |prior| aqueous.api.clearFullscreen(prior);
            }
            if (state.kind == .minimized or (state.kind == .scratchpad and !state.scratchpad_visible)) {
                requested.appendAssumeCapacity(.{ .handle = window.handle, .geometry = .empty, .z_order = -1, .visible = false, .border = .none });
                continue;
            }
            const rule = aqueous.rules.resolve(.{
                .app_id = window.app_id,
                .class = window.app_id,
                .title = window.title,
            });
            const focus_opacity: ?f64 = if (aqueous.config.wm.opacity_enabled and aqueous.config.wm.opacity_focus_sensitive)
                (if (focused == window.handle) aqueous.config.wm.opacity_focused else aqueous.config.wm.opacity_unfocused)
            else
                null;
            if (rule) |matched| {
                aqueous.api.applyRule(window.handle, output.id, matched.placement.tag, matched.fullscreen, matched.blur, matched.opacity orelse focus_opacity, aqueous.config.wm.force_ssd);
            } else {
                aqueous.api.applyRule(window.handle, output.id, 0, false, null, focus_opacity, aqueous.config.wm.force_ssd);
            }
            if (window.fullscreen) {
                requested.appendAssumeCapacity(.{ .handle = window.handle, .geometry = output.area, .z_order = 2, .visible = true, .border = .none });
                focusable.appendAssumeCapacity(window);
                continue;
            }
            if (rule) |matched| {
                if (matched.layout) |id| output_layout.default = ruleLayout(id);
                if (matched.fullscreen) {
                    if (try aqueous.window_states.enterFullscreen(window.handle, output.id)) |prior| aqueous.api.clearFullscreen(prior);
                    requested.appendAssumeCapacity(.{
                        .handle = window.handle,
                        .geometry = output.area,
                        .z_order = 2,
                        .visible = true,
                        .border = .none,
                    });
                    if (matched.placement.tag == 0 or matched.placement.tag == output.workspace_number) focusable.appendAssumeCapacity(window);
                    continue;
                }
                if (matched.layout == .game_mode and (game_anchor == null or focused == window.handle)) {
                    game_anchor = .{ .handle = window.handle, .rule = matched };
                }
                if (matched.placement.floating) {
                    const float_area = if (matched.ignore_struts) output.area else usable_area;
                    const float_placement = floatingRulePlacement(float_area, window, matched, output_layout.layoutOptions(.floating).border);
                    try aqueous.window_states.setFloating(window.handle, float_placement.geometry);
                    requested.appendAssumeCapacity(float_placement);
                    if (matched.placement.tag == 0 or matched.placement.tag == output.workspace_number) focusable.appendAssumeCapacity(window);
                    continue;
                }
            }
            managed.appendAssumeCapacity(window);
            if (rule == null or rule.?.placement.tag == 0 or rule.?.placement.tag == output.workspace_number) focusable.appendAssumeCapacity(window);
            if (rule != null and rule.?.layout == .game_mode and managed.items.len > 1) {
                std.mem.swap(layout_types.Window, &managed.items[0], &managed.items[managed.items.len - 1]);
            }
        }
        if (output_layout.default == .game_mode and game_anchor == null) output_layout.default = ruleLayout(aqueous.rules.game_mode.fallback_layout);
        const entry = try aqueous.layout_states.getOrPut(util.gpa, .{ .output = output.id, .workspace = output.workspace_number });
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.game_mode.rule_anchor = if (game_anchor) |anchor| anchor.handle else null;
        if (game_anchor) |anchor| entry.value_ptr.game_mode.rule_options = gameOptions(anchor.rule, aqueous.rules.game_mode, output.area);
        if (focused) |handle| {
            if (containsWindow(focusable.items, handle)) try aqueous.focus_history.record(workspace_key, handle);
        }
        const focus_valid = if (focused) |handle| containsWindow(focusable.items, handle) else false;
        if (!focus_valid) {
            var target = aqueous.focus_history.pick(workspace_key, focusable.items, focusCandidateValid);
            if (target == 0 and managed.items.len > 0) target = managed.items[0].handle;
            if (target == 0 and focusable.items.len > 0) target = focusable.items[0].handle;
            if (target != 0 and target != aqueous.pending_focus.window) {
                aqueous.pending_focus.setWindow(target, 1);
                aqueous.api.requestFocus(target);
            }
        }
        const placements = try layout_engine.arrange(
            util.gpa,
            entry.value_ptr,
            &output_layout,
            usable_area,
            managed.items,
            focused,
        );
        defer util.gpa.free(placements);
        try requested.appendSlice(util.gpa, placements);
        std.mem.sort(layout_types.Placement, requested.items, {}, placementLessThan);
        for (requested.items) |placement| aqueous.api.applyPlacement(placement);
    }

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

fn focusCandidateValid(windows: []const layout_types.Window, handle: layout_types.Handle) bool {
    return containsWindow(windows, handle);
}

fn containsWindow(windows: []const layout_types.Window, handle: layout_types.Handle) bool {
    for (windows) |window| if (window.handle == handle) return true;
    return false;
}

fn handleReloadTimer(aqueous: *Aqueous) c_int {
    defer if (aqueous.reload_timer) |timer| timer.timerUpdate(1000) catch log.warn("unable to re-arm configuration monitor", .{});
    const replacement = config_loader.load(util.gpa);
    const config_changed = replacement.fingerprint != aqueous.config.fingerprint;
    const rules_fingerprint = rules_config.discoveredFingerprint(util.gpa, replacement.wm.rules_path.slice());
    const rules_changed = rules_fingerprint != aqueous.rules.source_fingerprint;
    if (!config_changed and !rules_changed) return 0;

    if (config_changed) aqueous.config = replacement;
    if (config_changed or rules_changed) rules_config.reloadDiscovered(util.gpa, &aqueous.rules, aqueous.config.wm.rules_path.slice());
    aqueous.globals_applied = false;
    aqueous.api.requestManageCycle();
    log.info("configuration hot-reloaded layout={s}", .{@tagName(aqueous.config.layout.default)});
    return 0;
}

fn applyGlobalConfig(aqueous: *Aqueous) void {
    const config = aqueous.config.wm;
    const opacity = if (config.opacity_enabled) config.opacity else 1;
    aqueous.api.applyGlobals(
        config.blur_enabled,
        config.blur_radius,
        config.blur_passes,
        opacity,
        config.workspace_transition_enabled,
        config.workspace_transition_rate,
    );
}

fn placementLessThan(_: void, left: layout_types.Placement, right: layout_types.Placement) bool {
    if (left.z_order != right.z_order) return left.z_order < right.z_order;
    return left.handle < right.handle;
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
        .z_order = 1,
        .visible = true,
        .border = border,
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

fn gameOptions(rule: Rules.Rule, config: Rules.GameMode, output_area: layout_types.Rect) game_mode.Options {
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
        .gaps_inner = config.gaps_inner,
        .anchor_area = if (rule.ignore_struts) output_area else null,
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
