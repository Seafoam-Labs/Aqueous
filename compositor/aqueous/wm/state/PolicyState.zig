// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const types = @import("../layout/types.zig");
const PolicyState = @This();

pub const Kind = enum { tiled, floating, maximized, minimized };
pub const ClientMaximizeOrigin = enum {
    none,
    floating_overlay,
    workspace_floating,
};

kind: Kind = .tiled,
previous: Kind = .tiled,
/// Records only maximizes accepted from a client request. This distinguishes a
/// workspace-floating presentation (whose policy kind remains tiled) from a
/// persistent floating overlay and prevents client unmaximize from undoing a
/// compositor/keybinding-owned maximize.
client_maximize_origin: ClientMaximizeOrigin = .none,
floating_geometry: types.Rect = .empty,
/// Monotonic focus/creation order used to stack overlapping non-tiled windows.
stack_order: u64 = 0,
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
rule_workspace_requested: u32 = 0,
rule_fullscreen_requested: bool = false,
rule_floating_requested: bool = false,
rule_floating_signature: u64 = 0,
rule_fullscreen_previous: bool = false,
rule_floating_previous: Kind = .tiled,

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
    state.rule_workspace_overridden = false;
    state.rule_fullscreen_overridden = false;
    state.rule_floating_overridden = false;
    state.rule_workspace_requested = 0;
    state.rule_fullscreen_requested = false;
    state.rule_floating_requested = false;
    state.rule_floating_signature = 0;
    state.rule_initialized = true;
    state.rule_match = match;
}

test "manual overrides release only their corresponding rule property" {
    const std = @import("std");
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
    const std = @import("std");
    var state: PolicyState = .{};

    try std.testing.expect(state.toggleScrollingFullWidth());
    try std.testing.expectEqual(Kind.tiled, state.kind);
    try std.testing.expect(!state.toggleScrollingFullWidth());
    try std.testing.expectEqual(Kind.tiled, state.kind);
}
