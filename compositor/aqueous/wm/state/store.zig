// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Global indexes for policy-only window state.
//!
//! Per-window data is embedded in Window.PolicyState. This object only owns
//! the minimized-window MRU order, whose meaning spans multiple windows.

const Store = @This();
const std = @import("std");
const types = @import("../layout/types.zig");
const PolicyState = @import("PolicyState.zig");

pub const Kind = PolicyState.Kind;
pub const Presentation = PolicyState.Presentation;
pub const Visibility = PolicyState.Visibility;
pub const GeometryState = PolicyState.GeometryState;
pub const StackLayer = PolicyState.StackLayer;
pub const ClientMaximizeOrigin = PolicyState.ClientMaximizeOrigin;
pub const Entry = PolicyState;
pub const Resolver = *const fn (types.Handle) ?*Entry;

allocator: std.mem.Allocator,
resolver: Resolver,
minimized_mru: std.ArrayListUnmanaged(types.Handle) = .empty,

pub fn init(allocator: std.mem.Allocator, resolver: Resolver) Store {
    return .{ .allocator = allocator, .resolver = resolver };
}

pub fn deinit(store: *Store) void {
    store.minimized_mru.deinit(store.allocator);
}

pub fn get(store: *Store, handle: types.Handle) ?*Entry {
    return store.resolver(handle);
}

pub fn remove(store: *Store, handle: types.Handle) void {
    removeFromList(&store.minimized_mru, handle);
}

pub fn setFloating(store: *Store, handle: types.Handle, geometry: types.Rect) bool {
    const entry = store.resolver(handle) orelse return false;
    entry.overrideFloating();
    entry.client_maximize_origin = .none;
    setFloatingEntry(entry, geometry);
    return true;
}

/// Float a newly-parented transient without recording a manual override.
/// Overlay states retain precedence, matching the state controller's normal
/// transition guards.
pub fn setAutomaticFloating(store: *Store, handle: types.Handle, geometry: types.Rect) bool {
    const entry = store.resolver(handle) orelse return false;
    if (entry.kind() != .tiled) return false;
    setFloatingEntry(entry, geometry);
    return true;
}

/// Apply floating as a rule-owned transition. Unlike setFloating(), this does
/// not mark the action as a user override.
pub fn setRuleFloating(store: *Store, handle: types.Handle, geometry: types.Rect) bool {
    const entry = store.resolver(handle) orelse return false;
    if (!entry.rule_floating_owned) entry.rule_floating_previous = entry.presentation;
    setFloatingEntry(entry, geometry);
    entry.rule_floating_owned = true;
    return true;
}

pub fn restoreRuleFloating(store: *Store, handle: types.Handle) bool {
    const entry = store.resolver(handle) orelse return false;
    if (!entry.rule_floating_owned) return false;
    if (entry.presentation == .floating) entry.presentation = entry.rule_floating_previous;
    entry.rule_floating_owned = false;
    return true;
}

pub fn toggleFloating(store: *Store, handle: types.Handle, geometry: types.Rect) ?bool {
    const entry = store.resolver(handle) orelse return null;
    entry.overrideFloating();
    entry.client_maximize_origin = .none;
    if (entry.presentation == .floating) {
        entry.presentation = .tiled;
        return false;
    }
    setFloatingEntry(entry, geometry);
    return true;
}

pub fn toggleMaximized(store: *Store, handle: types.Handle) ?bool {
    const entry = store.resolver(handle) orelse return null;
    entry.overrideFloating();
    entry.client_maximize_origin = .none;
    if (entry.geometry_state == .maximized) {
        entry.geometry_state = .normal;
        return false;
    }
    entry.geometry_state = .maximized;
    return true;
}

/// Restore a maximized window as part of a user-initiated titlebar move.
/// Persistent floats can always return to their own geometry; tiled policy
/// windows may do so only while their active layout presents them as floating.
pub fn maximizedMoveRestoreKind(
    store: *Store,
    handle: types.Handle,
    layout_floating: bool,
) ?Kind {
    const entry = store.resolver(handle) orelse return null;
    if (entry.geometry_state != .maximized or entry.visibility != .visible) return null;
    return switch (entry.client_maximize_origin) {
        .floating_overlay => .floating,
        .workspace_floating => if (layout_floating) .tiled else null,
        .none => switch (entry.presentation) {
            .floating => .floating,
            .tiled => if (layout_floating) .tiled else null,
        },
    };
}

pub fn restoreMaximizedForMove(
    store: *Store,
    handle: types.Handle,
    layout_floating: bool,
) ?Kind {
    const entry = store.resolver(handle) orelse return null;
    const restored = store.maximizedMoveRestoreKind(handle, layout_floating) orelse return null;
    entry.overrideFloating();
    entry.client_maximize_origin = .none;
    entry.geometry_state = .normal;
    return restored;
}

/// Honor client maximize for either a persistent floating overlay or an
/// ordinary layout-owned window currently presented by the workspace floating
/// layout. Explicit provenance lets unmaximize restore the correct owner even
/// if the workspace changes layout in the meantime, without allowing a client
/// request to undo a compositor/keybinding-owned maximize.
pub fn setClientMaximized(
    store: *Store,
    handle: types.Handle,
    maximized: bool,
    layout_floating: bool,
) bool {
    const entry = store.resolver(handle) orelse return false;
    if (maximized) {
        const origin: ClientMaximizeOrigin = if (entry.presentation == .floating)
            .floating_overlay
        else if (entry.presentation == .tiled and layout_floating)
            .workspace_floating
        else
            return false;
        entry.overrideFloating();
        entry.client_maximize_origin = origin;
        entry.geometry_state = .maximized;
        return true;
    }
    if (entry.geometry_state != .maximized) return false;
    _ = switch (entry.client_maximize_origin) {
        .none => return false,
        .floating_overlay, .workspace_floating => {},
    };
    entry.overrideFloating();
    entry.client_maximize_origin = .none;
    entry.geometry_state = .normal;
    return true;
}

pub fn restore(store: *Store, handle: types.Handle) bool {
    const entry = store.resolver(handle) orelse return false;
    if (entry.visibility != .minimized) return false;
    entry.visibility = .visible;
    removeFromList(&store.minimized_mru, handle);
    return true;
}

/// Honor client minimize/unminimize only when the window is explicitly
/// floating or is an ordinary tiled-state window presented by the workspace
/// floating layout.
pub fn setClientMinimized(
    store: *Store,
    handle: types.Handle,
    minimized: bool,
    layout_floating: bool,
) !bool {
    if (!store.clientMinimizeAllowed(handle, minimized, layout_floating)) return false;
    return if (minimized) store.minimize(handle) else store.restore(handle);
}

pub fn clientMinimizeAllowed(
    store: *Store,
    handle: types.Handle,
    minimized: bool,
    layout_floating: bool,
) bool {
    const entry = store.resolver(handle) orelse return false;
    if (minimized) {
        return canMinimizeFrom(entry, layout_floating);
    }
    return entry.visibility == .minimized and canMinimizeFrom(entry, layout_floating);
}

fn canMinimizeFrom(entry: *const Entry, layout_floating: bool) bool {
    return entry.presentation == .floating or layout_floating;
}

pub fn minimize(store: *Store, handle: types.Handle) !bool {
    const entry = store.resolver(handle) orelse return false;
    if (entry.visibility == .minimized) return false;
    entry.overrideFloating();
    entry.visibility = .minimized;
    removeFromList(&store.minimized_mru, handle);
    try store.minimized_mru.insert(store.allocator, 0, handle);
    return true;
}

pub fn restoreLastMinimized(store: *Store) types.Handle {
    while (store.minimized_mru.items.len > 0) {
        const handle = store.minimized_mru.orderedRemove(0);
        const entry = store.resolver(handle) orelse continue;
        if (entry.visibility != .minimized) continue;
        entry.visibility = .visible;
        return handle;
    }
    return 0;
}

fn setFloatingEntry(entry: *Entry, geometry: types.Rect) void {
    entry.presentation = .floating;
    if (geometry.width > 0 and geometry.height > 0) entry.floating_geometry = geometry;
}

fn removeFromList(list: *std.ArrayListUnmanaged(types.Handle), handle: types.Handle) void {
    if (std.mem.indexOfScalar(types.Handle, list.items, handle)) |index| _ = list.orderedRemove(index);
}

test "floating presentation composes with visibility geometry and stack layer" {
    var entry: Entry = .{
        .geometry_state = .maximized,
        .stack_layer = .above,
    };
    setFloatingEntry(&entry, .{ .x = 10, .y = 20, .width = 300, .height = 200 });
    try std.testing.expectEqual(Kind.maximized, entry.kind());
    try std.testing.expectEqual(Presentation.floating, entry.presentation);
    try std.testing.expectEqual(StackLayer.above, entry.stack_layer);
    try std.testing.expectEqual(types.Rect{ .x = 10, .y = 20, .width = 300, .height = 200 }, entry.floating_geometry);
}

test "automatic floating only promotes ordinary tiled windows" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    const geometry: types.Rect = .{ .x = 20, .y = 30, .width = 580, .height = 360 };
    try std.testing.expect(store.setAutomaticFloating(1, geometry));
    try std.testing.expectEqual(Kind.floating, TestResolver.entries[0].kind());
    try std.testing.expectEqual(false, store.toggleFloating(1, .empty).?);
    try std.testing.expectEqual(Kind.tiled, TestResolver.entries[0].kind());

    TestResolver.entries[1].geometry_state = .maximized;
    try std.testing.expect(!store.setAutomaticFloating(2, geometry));
}

test "rule floating restores presentation without erasing geometry state" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    TestResolver.entries[0].geometry_state = .maximized;
    try std.testing.expect(store.setRuleFloating(1, .{ .x = 0, .y = 0, .width = 300, .height = 200 }));
    try std.testing.expectEqual(Presentation.floating, TestResolver.entries[0].presentation);
    try std.testing.expectEqual(GeometryState.maximized, TestResolver.entries[0].geometry_state);
    try std.testing.expect(store.restoreRuleFloating(1));
    try std.testing.expectEqual(Presentation.tiled, TestResolver.entries[0].presentation);

    try std.testing.expect(store.setRuleFloating(1, .{ .x = 0, .y = 0, .width = 300, .height = 200 }));
    _ = store.toggleFloating(1, .empty) orelse unreachable;
    try std.testing.expect(!store.restoreRuleFloating(1));
    try std.testing.expectEqual(Presentation.tiled, TestResolver.entries[0].presentation);
}

test "maximize and minimize preserve presentation independently" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    TestResolver.entries[0].presentation = .floating;
    try std.testing.expect(store.setClientMaximized(1, true, false));
    try std.testing.expectEqual(Kind.maximized, TestResolver.entries[0].kind());
    try std.testing.expectEqual(Presentation.floating, TestResolver.entries[0].presentation);

    try std.testing.expect(try store.setClientMinimized(1, true, false));
    try std.testing.expectEqual(Kind.minimized, TestResolver.entries[0].kind());
    try std.testing.expectEqual(GeometryState.maximized, TestResolver.entries[0].geometry_state);
    try std.testing.expectEqual(Presentation.floating, TestResolver.entries[0].presentation);

    try std.testing.expect(try store.setClientMinimized(1, false, false));
    try std.testing.expectEqual(Kind.maximized, TestResolver.entries[0].kind());
    try std.testing.expect(store.setClientMaximized(1, false, false));
    try std.testing.expectEqual(Kind.floating, TestResolver.entries[0].kind());
}

test "client state requests remain confined to freeform presentations" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    try std.testing.expect(!store.setClientMaximized(1, true, false));
    try std.testing.expect(!(try store.setClientMinimized(1, true, false)));
    try std.testing.expect(store.setClientMaximized(1, true, true));
    try std.testing.expectEqual(ClientMaximizeOrigin.workspace_floating, TestResolver.entries[0].client_maximize_origin);
    try std.testing.expect(store.setClientMaximized(1, false, false));
    try std.testing.expectEqual(Kind.tiled, TestResolver.entries[0].kind());
}

test "manual maximize supersedes client provenance" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    try std.testing.expect(store.setClientMaximized(1, true, true));
    try std.testing.expectEqual(false, store.toggleMaximized(1).?);
    try std.testing.expectEqual(ClientMaximizeOrigin.none, TestResolver.entries[0].client_maximize_origin);
    try std.testing.expectEqual(true, store.toggleMaximized(1).?);
    try std.testing.expect(!store.setClientMaximized(1, false, true));
}

test "titlebar move restores the correct freeform owner" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    TestResolver.entries[0] = .{
        .geometry_state = .maximized,
        .client_maximize_origin = .workspace_floating,
    };
    try std.testing.expectEqual(Kind.tiled, store.restoreMaximizedForMove(1, true).?);
    try std.testing.expectEqual(GeometryState.normal, TestResolver.entries[0].geometry_state);

    TestResolver.entries[1] = .{
        .presentation = .floating,
        .geometry_state = .maximized,
    };
    try std.testing.expectEqual(Kind.floating, store.restoreMaximizedForMove(2, false).?);
    try std.testing.expectEqual(Kind.floating, TestResolver.entries[1].kind());
}

const TestResolver = struct {
    var entries: [2]Entry = .{ .{}, .{} };

    fn reset() void {
        entries = .{ .{}, .{} };
    }

    fn resolve(handle: types.Handle) ?*Entry {
        if (handle == 0 or handle > entries.len) return null;
        return &entries[handle - 1];
    }
};

test "minimized index follows embedded state and prunes destroyed handles" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    try std.testing.expect(try store.minimize(1));
    try std.testing.expectEqual(Kind.minimized, TestResolver.entries[0].kind());
    try std.testing.expectEqual(@as(types.Handle, 1), store.restoreLastMinimized());
    try std.testing.expectEqual(Kind.tiled, TestResolver.entries[0].kind());

    try std.testing.expect(try store.minimize(2));
    store.remove(2);
    try std.testing.expectEqual(@as(types.Handle, 0), store.restoreLastMinimized());
}
