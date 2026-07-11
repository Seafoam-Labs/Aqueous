// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Aqueous = @This();

const std = @import("std");

const CompositorApi = @import("CompositorApi.zig");
const Mode = @import("Mode.zig").Mode;
const Trace = @import("Trace.zig");
const layout_config = @import("config/layout.zig");
const config_loader = @import("config/loader.zig");
const layout_engine = @import("layout/engine.zig");
const layout_types = @import("layout/types.zig");
const rules_config = @import("rules/config.zig");
const Rules = @import("rules/engine.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.aqueous);

mode: Mode,
api: CompositorApi = .{},
trace: Trace = .{},
layout: layout_config.Snapshot = .{},
rules: Rules,
layout_states: std.AutoHashMapUnmanaged(u64, layout_engine.State) = .empty,

pub fn init(aqueous: *Aqueous, mode: Mode) void {
    aqueous.* = .{
        .mode = mode,
        .layout = config_loader.load(util.gpa),
        .rules = Rules.init(util.gpa),
    };
    rules_config.reloadFromDefaultPath(util.gpa, &aqueous.rules);
    log.info("policy mode={s} layout={s}", .{ @tagName(mode), @tagName(aqueous.layout.default) });
}

pub fn deinit(aqueous: *Aqueous) void {
    var states = aqueous.layout_states.valueIterator();
    while (states.next()) |state| state.deinit(util.gpa);
    aqueous.layout_states.deinit(util.gpa);
    aqueous.rules.deinit();
    log.debug("policy stopped after {} trace event(s)", .{aqueous.trace.sequence});
}

pub fn allowsExternal(aqueous: *const Aqueous) bool {
    return aqueous.mode.allowsExternal();
}

pub fn reloadConfig(aqueous: *Aqueous) void {
    aqueous.layout = config_loader.load(util.gpa);
    rules_config.reloadFromDefaultPath(util.gpa, &aqueous.rules);
    aqueous.api.requestManageCycle();
    log.info("configuration reloaded layout={s}", .{@tagName(aqueous.layout.default)});
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

    var snapshot = try aqueous.api.policySnapshot(util.gpa);
    defer snapshot.deinit(util.gpa);
    const focused = aqueous.api.focusedWindow();

    for (snapshot.outputs) |output| {
        var output_layout = aqueous.layout;
        var managed: std.ArrayListUnmanaged(layout_types.Window) = .empty;
        defer managed.deinit(util.gpa);
        var requested: std.ArrayListUnmanaged(layout_types.Placement) = .empty;
        defer requested.deinit(util.gpa);
        try managed.ensureTotalCapacity(util.gpa, output.windows.len);
        try requested.ensureTotalCapacity(util.gpa, output.windows.len);
        for (output.windows) |window| {
            if (window.fullscreen) {
                requested.appendAssumeCapacity(.{
                    .handle = window.handle,
                    .geometry = output.area,
                    .z_order = 2,
                    .visible = true,
                    .border = .none,
                });
                continue;
            }
            const rule = aqueous.rules.resolve(.{
                .app_id = window.app_id,
                .class = window.app_id,
                .title = window.title,
            });
            if (rule) |matched| {
                if (matched.layout) |id| output_layout.default = ruleLayout(id);
                if (matched.placement.floating) {
                    requested.appendAssumeCapacity(floatingPlacement(output.area, window.handle, matched.placement, output_layout.layoutOptions(.floating).border));
                    continue;
                }
            }
            managed.appendAssumeCapacity(window);
            if (rule != null and rule.?.layout == .game_mode and managed.items.len > 1) {
                std.mem.swap(layout_types.Window, &managed.items[0], &managed.items[managed.items.len - 1]);
            }
        }
        const entry = try aqueous.layout_states.getOrPut(util.gpa, output.id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (focused == null and managed.items.len > 0) aqueous.api.requestFocus(managed.items[0].handle);
        const placements = try layout_engine.arrange(
            util.gpa,
            entry.value_ptr,
            &output_layout,
            output.area,
            managed.items,
            focused,
        );
        defer util.gpa.free(placements);
        try requested.appendSlice(util.gpa, placements);
        std.mem.sort(layout_types.Placement, requested.items, {}, placementLessThan);
        for (requested.items) |placement| aqueous.api.applyPlacement(placement);
    }

    var stale: std.ArrayListUnmanaged(u64) = .empty;
    defer stale.deinit(util.gpa);
    var keys = aqueous.layout_states.keyIterator();
    while (keys.next()) |id| {
        var found = false;
        for (snapshot.outputs) |output| {
            if (output.id == id.*) {
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
