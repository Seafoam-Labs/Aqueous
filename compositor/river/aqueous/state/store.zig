// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Global indexes for policy-only window state.
//!
//! Per-window data is embedded in Window.PolicyState. This object only owns
//! collections whose meaning spans multiple windows: minimized MRU order and
//! named scratchpad lookup.

const Store = @This();
const std = @import("std");
const types = @import("../layout/types.zig");
const PolicyState = @import("PolicyState.zig");

pub const Kind = PolicyState.Kind;
pub const Entry = PolicyState;
pub const Resolver = *const fn (types.Handle) ?*Entry;

allocator: std.mem.Allocator,
resolver: Resolver,
minimized_mru: std.ArrayListUnmanaged(types.Handle) = .empty,
scratchpads: std.AutoHashMapUnmanaged(u64, types.Handle) = .empty,

pub fn init(allocator: std.mem.Allocator, resolver: Resolver) Store {
    return .{ .allocator = allocator, .resolver = resolver };
}

pub fn deinit(store: *Store) void {
    store.minimized_mru.deinit(store.allocator);
    store.scratchpads.deinit(store.allocator);
}

pub fn get(store: *Store, handle: types.Handle) ?*Entry {
    return store.resolver(handle);
}

pub fn remove(store: *Store, handle: types.Handle) void {
    if (store.resolver(handle)) |entry| {
        if (entry.scratchpad != 0 and store.scratchpads.get(entry.scratchpad) == handle) {
            _ = store.scratchpads.remove(entry.scratchpad);
        }
    }
    removeFromList(&store.minimized_mru, handle);
}

pub fn setFloating(store: *Store, handle: types.Handle, geometry: types.Rect) bool {
    const entry = store.resolver(handle) orelse return false;
    entry.overrideFloating();
    setFloatingEntry(entry, geometry);
    return true;
}

/// Apply floating as a rule-owned transition. Unlike setFloating(), this does
/// not mark the action as a user override.
pub fn setRuleFloating(store: *Store, handle: types.Handle, geometry: types.Rect) bool {
    const entry = store.resolver(handle) orelse return false;
    if (!entry.rule_floating_owned) entry.rule_floating_previous = entry.kind;
    setFloatingEntry(entry, geometry);
    entry.rule_floating_owned = true;
    return true;
}

pub fn restoreRuleFloating(store: *Store, handle: types.Handle) bool {
    const entry = store.resolver(handle) orelse return false;
    if (!entry.rule_floating_owned) return false;
    if (entry.kind == .floating) entry.kind = entry.rule_floating_previous;
    entry.rule_floating_owned = false;
    return true;
}

pub fn toggleFloating(store: *Store, handle: types.Handle, geometry: types.Rect) ?bool {
    const entry = store.resolver(handle) orelse return null;
    entry.overrideFloating();
    if (entry.kind == .floating) {
        entry.kind = entry.previous;
        return false;
    }
    setFloatingEntry(entry, geometry);
    return true;
}

pub fn toggleMaximized(store: *Store, handle: types.Handle) ?bool {
    const entry = store.resolver(handle) orelse return null;
    entry.overrideFloating();
    if (entry.kind == .maximized) {
        entry.kind = entry.previous;
        return false;
    }
    entry.previous = entry.kind;
    entry.kind = .maximized;
    return true;
}

pub fn restore(store: *Store, handle: types.Handle) bool {
    const entry = store.resolver(handle) orelse return false;
    if (entry.kind != .minimized) return false;
    entry.kind = entry.previous;
    removeFromList(&store.minimized_mru, handle);
    return true;
}

pub fn minimize(store: *Store, handle: types.Handle) !bool {
    const entry = store.resolver(handle) orelse return false;
    if (entry.kind == .minimized) return false;
    entry.overrideFloating();
    entry.previous = entry.kind;
    entry.kind = .minimized;
    removeFromList(&store.minimized_mru, handle);
    try store.minimized_mru.insert(store.allocator, 0, handle);
    return true;
}

pub fn restoreLastMinimized(store: *Store) types.Handle {
    while (store.minimized_mru.items.len > 0) {
        const handle = store.minimized_mru.orderedRemove(0);
        const entry = store.resolver(handle) orelse continue;
        if (entry.kind != .minimized) continue;
        entry.kind = entry.previous;
        return handle;
    }
    return 0;
}

pub fn sendToScratchpad(store: *Store, handle: types.Handle, name: []const u8) !bool {
    const entry = store.resolver(handle) orelse return false;
    entry.overrideFloating();
    const key = nameHash(name);
    if (entry.scratchpad != 0 and entry.scratchpad != key and store.scratchpads.get(entry.scratchpad) == handle) {
        _ = store.scratchpads.remove(entry.scratchpad);
    }
    if (store.scratchpads.get(key)) |prior| if (prior != handle) {
        if (store.resolver(prior)) |old| {
            old.kind = old.previous;
            old.scratchpad = 0;
            old.scratchpad_visible = false;
        }
    };
    entry.previous = entry.kind;
    entry.kind = .scratchpad;
    entry.scratchpad = key;
    entry.scratchpad_visible = false;
    try store.scratchpads.put(store.allocator, key, handle);
    return true;
}

/// Toggle a named scratchpad and return its window, or zero when the pad is empty.
pub fn toggleScratchpad(store: *Store, name: []const u8) types.Handle {
    const key = nameHash(name);
    const handle = store.scratchpads.get(key) orelse return 0;
    const entry = store.resolver(handle) orelse {
        _ = store.scratchpads.remove(key);
        return 0;
    };
    entry.scratchpad_visible = !entry.scratchpad_visible;
    entry.kind = if (entry.scratchpad_visible) .floating else .scratchpad;
    return handle;
}

fn setFloatingEntry(entry: *Entry, geometry: types.Rect) void {
    if (entry.kind != .floating) entry.previous = entry.kind;
    entry.kind = .floating;
    if (geometry.width > 0 and geometry.height > 0) entry.floating_geometry = geometry;
}

fn nameHash(name: []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(name);
    return hash.final();
}

fn removeFromList(list: *std.ArrayListUnmanaged(types.Handle), handle: types.Handle) void {
    if (std.mem.indexOfScalar(types.Handle, list.items, handle)) |index| _ = list.orderedRemove(index);
}

test "embedded policy state preserves the prior mode around floating" {
    var entry: Entry = .{ .kind = .maximized };
    setFloatingEntry(&entry, .{ .x = 10, .y = 20, .width = 300, .height = 200 });
    try std.testing.expectEqual(Kind.floating, entry.kind);
    try std.testing.expectEqual(Kind.maximized, entry.previous);
    try std.testing.expectEqual(types.Rect{ .x = 10, .y = 20, .width = 300, .height = 200 }, entry.floating_geometry);
}

test "rule floating rolls back unless manually overridden" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    TestResolver.entries[0].kind = .maximized;
    try std.testing.expect(store.setRuleFloating(1, .{ .x = 0, .y = 0, .width = 300, .height = 200 }));
    try std.testing.expectEqual(Kind.floating, TestResolver.entries[0].kind);
    try std.testing.expect(store.restoreRuleFloating(1));
    try std.testing.expectEqual(Kind.maximized, TestResolver.entries[0].kind);

    try std.testing.expect(store.setRuleFloating(1, .{ .x = 0, .y = 0, .width = 300, .height = 200 }));
    _ = store.toggleFloating(1, .empty) orelse unreachable;
    try std.testing.expect(!store.restoreRuleFloating(1));
    try std.testing.expectEqual(Kind.maximized, TestResolver.entries[0].kind);
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

test "global indexes follow embedded state and prune destroyed handles" {
    TestResolver.reset();
    var store = Store.init(std.testing.allocator, TestResolver.resolve);
    defer store.deinit();

    try std.testing.expect(try store.minimize(1));
    try std.testing.expectEqual(Kind.minimized, TestResolver.entries[0].kind);
    try std.testing.expectEqual(@as(types.Handle, 1), store.restoreLastMinimized());
    try std.testing.expectEqual(Kind.tiled, TestResolver.entries[0].kind);

    try std.testing.expect(try store.sendToScratchpad(2, "term"));
    try std.testing.expectEqual(@as(types.Handle, 2), store.toggleScratchpad("term"));
    try std.testing.expect(TestResolver.entries[1].scratchpad_visible);

    store.remove(2);
    try std.testing.expectEqual(@as(types.Handle, 0), store.toggleScratchpad("term"));
}
