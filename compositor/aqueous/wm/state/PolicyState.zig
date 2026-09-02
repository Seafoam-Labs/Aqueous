// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const layout_config = @import("../config/layout.zig");
const types = @import("../layout/types.zig");
const PolicyState = @This();

/// Compatibility view used at layout/input boundaries. Policy stores the
/// underlying axes independently so minimize/maximize never erase the window's
/// presentation or restore target.
pub const Kind = enum { tiled, floating, maximized, minimized };
pub const Presentation = enum { tiled, floating };
pub const Visibility = enum { visible, minimized };
pub const GeometryState = enum { normal, maximized };
pub const StackLayer = types.StackLayer;
pub const ClientMaximizeOrigin = enum {
    none,
    floating_overlay,
    workspace_floating,
};
pub const SnapState = enum {
    none,
    left,
    right,
    up,
    down,
    up_left,
    up_right,
    down_left,
    down_right,
    center,
    maximized_horizontal,
    maximized_vertical,
};

presentation: Presentation = .tiled,
visibility: Visibility = .visible,
geometry_state: GeometryState = .normal,
stack_layer: StackLayer = .normal,
snap_state: SnapState = .none,
snap_restore_geometry: types.Rect = .empty,
custom_snap_zone: u8 = std.math.maxInt(u8),
snap_layout_id: layout_config.SnapId = .{},
snap_zone_id: layout_config.SnapId = .{},
/// Records only maximizes accepted from a client request. This distinguishes a
/// workspace-floating presentation (whose policy kind remains tiled) from a
/// persistent floating overlay and prevents client unmaximize from undoing a
/// compositor/keybinding-owned maximize.
client_maximize_origin: ClientMaximizeOrigin = .none,
floating_geometry: types.Rect = .empty,
/// Set when the last output vanished without an available recovery target.
/// The next output which admits this window clamps it back into usable space.
needs_output_recovery: bool = false,
/// Scrolling-layout column width override. This is independent of `kind` so
/// the window remains part of the layout and viewport navigation keeps working.
scrolling_full_width: bool = false,

/// Last non-null toplevel parent for which automatic transient placement was
/// applied. Keeping this edge-triggered lets a user tile the dialog manually
/// without the next manage cycle immediately forcing it floating again.
auto_float_parent: types.Handle = 0,

/// Semantic identity of the rule last reconciled for this window. A zero hash
/// represents no match. `rule_initialized` distinguishes that from a window
/// which has not reached its first rule evaluation yet.
rule_initialized: bool = false,
rule_match: u64 = 0,

/// Placement properties are claimed independently. User actions release the
/// corresponding claim, preventing an unchanged rule from reasserting it on
/// the next manage cycle.
rule_workspace_owned: bool = false,
rule_fullscreen_owned: bool = false,
rule_floating_owned: bool = false,
rule_workspace_overridden: bool = false,
rule_fullscreen_overridden: bool = false,
rule_floating_overridden: bool = false,
rule_stack_layer_owned: bool = false,
rule_stack_layer_overridden: bool = false,
/// Fingerprint of the last composite output/workspace target reconciled for
/// the active matcher. Zero represents ordinary admission placement.
rule_workspace_requested: u64 = 0,
rule_fullscreen_requested: bool = false,
rule_floating_requested: bool = false,
rule_floating_signature: u64 = 0,
rule_fullscreen_previous: bool = false,
rule_floating_previous: Presentation = .tiled,
rule_stack_layer_previous: StackLayer = .normal,
rule_stack_layer_requested: ?StackLayer = null,
focus_allowed: bool = true,
fixed_position: bool = false,
skip_switcher: bool = false,
skip_taskbar: bool = false,

pub fn kind(state: *const PolicyState) Kind {
    if (state.visibility == .minimized) return .minimized;
    if (state.geometry_state == .maximized) return .maximized;
    return switch (state.presentation) {
        .tiled => .tiled,
        .floating => .floating,
    };
}

pub fn isTiled(state: *const PolicyState) bool {
    return state.presentation == .tiled;
}

pub fn isFloating(state: *const PolicyState) bool {
    return state.presentation == .floating;
}

pub fn isVisible(state: *const PolicyState) bool {
    return state.visibility == .visible;
}

pub fn isMaximized(state: *const PolicyState) bool {
    return state.geometry_state == .maximized;
}

pub fn overrideWorkspace(state: *PolicyState) void {
    state.rule_workspace_owned = false;
    state.rule_workspace_overridden = true;
}

pub fn overrideFullscreen(state: *PolicyState) void {
    state.rule_fullscreen_owned = false;
    state.rule_fullscreen_overridden = true;
}

pub fn overrideFloating(state: *PolicyState) void {
    state.rule_floating_owned = false;
    state.rule_floating_overridden = true;
}

pub fn overrideStackLayer(state: *PolicyState) void {
    state.rule_stack_layer_owned = false;
    state.rule_stack_layer_overridden = true;
}

pub fn toggleScrollingFullWidth(state: *PolicyState) bool {
    state.scrolling_full_width = !state.scrolling_full_width;
    return state.scrolling_full_width;
}

pub fn ruleChanged(state: *const PolicyState, match: u64) bool {
    return !state.rule_initialized or state.rule_match != match;
}

/// Start ownership tracking for a different semantic matcher after the caller
/// has rolled back properties still owned by the prior match.
pub fn acceptRuleMatch(state: *PolicyState, match: u64) void {
    state.rule_workspace_owned = false;
    state.rule_fullscreen_owned = false;
    state.rule_floating_owned = false;
    state.rule_stack_layer_owned = false;
    state.rule_workspace_overridden = false;
    state.rule_fullscreen_overridden = false;
    state.rule_floating_overridden = false;
    state.rule_stack_layer_overridden = false;
    state.rule_workspace_requested = 0;
    state.rule_fullscreen_requested = false;
    state.rule_floating_requested = false;
    state.rule_floating_signature = 0;
    state.rule_stack_layer_requested = null;
    state.rule_initialized = true;
    state.rule_match = match;
}

test "manual overrides release only their corresponding rule property" {
    var state: PolicyState = .{
        .rule_initialized = true,
        .rule_match = 42,
        .rule_workspace_owned = true,
        .rule_fullscreen_owned = true,
        .rule_floating_owned = true,
    };

    state.overrideFullscreen();
    try std.testing.expect(state.rule_workspace_owned);
    try std.testing.expect(!state.rule_fullscreen_owned);
    try std.testing.expect(state.rule_fullscreen_overridden);
    try std.testing.expect(state.rule_floating_owned);
    try std.testing.expect(!state.ruleChanged(42));
    try std.testing.expect(state.ruleChanged(7));

    // Re-evaluating the same matcher leaves the override intact. Only an
    // actual matcher transition opens a new rule-ownership lifecycle.
    try std.testing.expect(state.rule_fullscreen_overridden);
    state.acceptRuleMatch(7);
    try std.testing.expect(!state.rule_fullscreen_overridden);
    try std.testing.expect(!state.ruleChanged(7));
}

test "scrolling full width toggles independently of window kind" {
    var state: PolicyState = .{};

    try std.testing.expect(state.toggleScrollingFullWidth());
    try std.testing.expectEqual(Kind.tiled, state.kind());
    try std.testing.expect(!state.toggleScrollingFullWidth());
    try std.testing.expectEqual(Kind.tiled, state.kind());
}

test "presentation visibility geometry and stack layer compose" {
    var state: PolicyState = .{
        .presentation = .floating,
        .visibility = .minimized,
        .geometry_state = .maximized,
        .stack_layer = .above,
    };

    try std.testing.expectEqual(Kind.minimized, state.kind());
    state.visibility = .visible;
    try std.testing.expectEqual(Kind.maximized, state.kind());
    state.geometry_state = .normal;
    try std.testing.expectEqual(Kind.floating, state.kind());
    try std.testing.expectEqual(StackLayer.above, state.stack_layer);
}

test "snap state remains independent of presentation and visibility" {
    var state: PolicyState = .{ .presentation = .floating, .snap_state = .left, .snap_restore_geometry = .{ .x = 10, .y = 20, .width = 300, .height = 200 } };
    state.visibility = .minimized;
    try std.testing.expectEqual(SnapState.left, state.snap_state);
    state.visibility = .visible;
    try std.testing.expectEqual(Kind.floating, state.kind());
    try std.testing.expectEqual(@as(i32, 300), state.snap_restore_geometry.width);
}
