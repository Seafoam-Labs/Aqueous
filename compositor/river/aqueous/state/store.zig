// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Store = @This();
const std = @import("std");
const types = @import("../layout/types.zig");

pub const Kind = enum { tiled, floating, maximized, fullscreen, minimized, scratchpad };

pub const Entry = struct {
    kind: Kind = .tiled,
    previous: Kind = .tiled,
    output: u64 = 0,
    workspace: u32 = 0,
    floating_geometry: types.Rect = .empty,
    scratchpad: u64 = 0,
    scratchpad_visible: bool = false,
};

allocator: std.mem.Allocator,
entries: std.AutoHashMapUnmanaged(types.Handle, Entry) = .empty,
fullscreen_by_output: std.AutoHashMapUnmanaged(u64, types.Handle) = .empty,
minimized_mru: std.ArrayListUnmanaged(types.Handle) = .empty,
scratchpads: std.AutoHashMapUnmanaged(u64, types.Handle) = .empty,

pub fn init(allocator: std.mem.Allocator) Store {
    return .{ .allocator = allocator };
}

pub fn deinit(store: *Store) void {
    store.entries.deinit(store.allocator);
    store.fullscreen_by_output.deinit(store.allocator);
    store.minimized_mru.deinit(store.allocator);
    store.scratchpads.deinit(store.allocator);
}

pub fn observe(store: *Store, handle: types.Handle, output: u64, workspace: u32, fullscreen: bool) !*Entry {
    const result = try store.entries.getOrPut(store.allocator, handle);
    if (!result.found_existing) result.value_ptr.* = .{};
    const entry = result.value_ptr;
    const previous_output = entry.output;

    // Fullscreen can change outside the native keybinding path (for example via
    // an xdg_toplevel request or foreign-toplevel controller), so the compositor
    // snapshot is authoritative. Keep the ownership index and the entry kind in
    // sync in both directions.
    if (!fullscreen or previous_output != output) {
        if (store.fullscreen_by_output.get(previous_output) == handle) {
            _ = store.fullscreen_by_output.remove(previous_output);
        }
        if (entry.kind == .fullscreen) entry.kind = entry.previous;
    }

    entry.output = output;
    entry.workspace = workspace;

    if (fullscreen) {
        const ownership = try store.fullscreen_by_output.getOrPut(store.allocator, output);
        if (ownership.found_existing and ownership.value_ptr.* != handle) {
            if (store.entries.getPtr(ownership.value_ptr.*)) |prior| {
                if (prior.kind == .fullscreen) prior.kind = prior.previous;
            }
        }
        ownership.value_ptr.* = handle;
        if (entry.kind != .fullscreen) entry.previous = entry.kind;
        entry.kind = .fullscreen;
    }

    return entry;
}

pub fn remove(store: *Store, handle: types.Handle) void {
    if (store.entries.fetchRemove(handle)) |removed| {
        if (store.fullscreen_by_output.get(removed.value.output) == handle) _ = store.fullscreen_by_output.remove(removed.value.output);
        if (removed.value.scratchpad != 0 and store.scratchpads.get(removed.value.scratchpad) == handle) _ = store.scratchpads.remove(removed.value.scratchpad);
    }
    removeFromList(&store.minimized_mru, handle);
}

pub fn fullscreenOwner(store: *const Store, output: u64) ?types.Handle {
    return store.fullscreen_by_output.get(output);
}

/// Enter fullscreen and return the prior owner that must be restored by the
/// caller. The store itself enforces one fullscreen window per output.
pub fn enterFullscreen(store: *Store, handle: types.Handle, output: u64) !?types.Handle {
    const entry = (try store.entries.getOrPutValue(store.allocator, handle, .{})).value_ptr;
    const prior = store.fullscreen_by_output.get(output);
    if (prior) |owner| if (owner != handle) {
        if (store.entries.getPtr(owner)) |old| old.kind = old.previous;
    };
    if (entry.kind != .fullscreen) entry.previous = entry.kind;
    entry.kind = .fullscreen;
    entry.output = output;
    try store.fullscreen_by_output.put(store.allocator, output, handle);
    return if (prior != null and prior.? != handle) prior else null;
}

pub fn leaveFullscreen(store: *Store, handle: types.Handle) bool {
    const entry = store.entries.getPtr(handle) orelse return false;
    if (entry.kind != .fullscreen) return false;
    if (store.fullscreen_by_output.get(entry.output) == handle) _ = store.fullscreen_by_output.remove(entry.output);
    entry.kind = entry.previous;
    return true;
}

pub fn setFloating(store: *Store, handle: types.Handle, geometry: types.Rect) !void {
    const entry = (try store.entries.getOrPutValue(store.allocator, handle, .{})).value_ptr;
    if (entry.kind != .floating) entry.previous = entry.kind;
    entry.kind = .floating;
    if (geometry.width > 0 and geometry.height > 0) entry.floating_geometry = geometry;
}

pub fn toggleFloating(store: *Store, handle: types.Handle, geometry: types.Rect) !bool {
    const entry = (try store.entries.getOrPutValue(store.allocator, handle, .{})).value_ptr;
    if (entry.kind == .floating) {
        entry.kind = entry.previous;
        return false;
    }
    entry.previous = entry.kind;
    entry.kind = .floating;
    if (geometry.width > 0 and geometry.height > 0) entry.floating_geometry = geometry;
    return true;
}

pub fn toggleMaximized(store: *Store, handle: types.Handle) !bool {
    const entry = (try store.entries.getOrPutValue(store.allocator, handle, .{})).value_ptr;
    if (entry.kind == .maximized) {
        entry.kind = entry.previous;
        return false;
    }
    entry.previous = entry.kind;
    entry.kind = .maximized;
    return true;
}

pub fn restore(store: *Store, handle: types.Handle) bool {
    const entry = store.entries.getPtr(handle) orelse return false;
    if (entry.kind != .minimized) return false;
    entry.kind = entry.previous;
    removeFromList(&store.minimized_mru, handle);
    return true;
}

pub fn minimize(store: *Store, handle: types.Handle) !bool {
    const entry = store.entries.getPtr(handle) orelse return false;
    if (entry.kind == .minimized) return false;
    if (entry.kind == .fullscreen) _ = store.leaveFullscreen(handle);
    entry.previous = entry.kind;
    entry.kind = .minimized;
    removeFromList(&store.minimized_mru, handle);
    try store.minimized_mru.insert(store.allocator, 0, handle);
    return true;
}

pub fn restoreLastMinimized(store: *Store) types.Handle {
    while (store.minimized_mru.items.len > 0) {
        const handle = store.minimized_mru.orderedRemove(0);
        const entry = store.entries.getPtr(handle) orelse continue;
        if (entry.kind != .minimized) continue;
        entry.kind = entry.previous;
        return handle;
    }
    return 0;
}

pub fn sendToScratchpad(store: *Store, handle: types.Handle, name: []const u8) !void {
    const key = nameHash(name);
    if (store.scratchpads.get(key)) |prior| if (prior != handle) {
        if (store.entries.getPtr(prior)) |old| {
            old.kind = .tiled;
            old.scratchpad = 0;
            old.scratchpad_visible = false;
        }
    };
    const entry = (try store.entries.getOrPutValue(store.allocator, handle, .{})).value_ptr;
    entry.previous = entry.kind;
    entry.kind = .scratchpad;
    entry.scratchpad = key;
    entry.scratchpad_visible = false;
    try store.scratchpads.put(store.allocator, key, handle);
}

/// Toggle a named scratchpad and return its window, or zero when the pad is empty.
pub fn toggleScratchpad(store: *Store, name: []const u8) types.Handle {
    const handle = store.scratchpads.get(nameHash(name)) orelse return 0;
    const entry = store.entries.getPtr(handle) orelse return 0;
    entry.scratchpad_visible = !entry.scratchpad_visible;
    entry.kind = if (entry.scratchpad_visible) .floating else .scratchpad;
    return handle;
}

fn nameHash(name: []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(name);
    return hash.final();
}

fn removeFromList(list: *std.ArrayListUnmanaged(types.Handle), handle: types.Handle) void {
    if (std.mem.indexOfScalar(types.Handle, list.items, handle)) |index| _ = list.orderedRemove(index);
}

test "fullscreen ownership, minimize MRU, and scratchpads round-trip" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.observe(1, 10, 1, false);
    _ = try store.observe(2, 10, 1, false);
    try std.testing.expectEqual(@as(?types.Handle, null), try store.enterFullscreen(1, 10));
    try std.testing.expectEqual(@as(?types.Handle, 1), try store.enterFullscreen(2, 10));
    try std.testing.expectEqual(Kind.tiled, store.entries.get(1).?.kind);
    try std.testing.expect(try store.minimize(2));
    try std.testing.expectEqual(@as(types.Handle, 2), store.restoreLastMinimized());
    try store.sendToScratchpad(1, "term");
    try std.testing.expectEqual(@as(types.Handle, 1), store.toggleScratchpad("term"));
    try std.testing.expect(store.entries.get(1).?.scratchpad_visible);
}

test "observation synchronizes native fullscreen state in both directions" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.observe(1, 10, 1, false);
    try store.setFloating(1, .{ .x = 10, .y = 20, .width = 300, .height = 200 });

    const fullscreen = try store.observe(1, 10, 1, true);
    try std.testing.expectEqual(Kind.fullscreen, fullscreen.kind);
    try std.testing.expectEqual(@as(?types.Handle, 1), store.fullscreen_by_output.get(10));

    const restored = try store.observe(1, 10, 1, false);
    try std.testing.expectEqual(Kind.floating, restored.kind);
    try std.testing.expectEqual(@as(?types.Handle, null), store.fullscreen_by_output.get(10));
}

test "observed fullscreen ownership replaces and restores the prior owner" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.observe(1, 10, 1, true);
    _ = try store.observe(2, 10, 1, true);

    try std.testing.expectEqual(Kind.tiled, store.entries.get(1).?.kind);
    try std.testing.expectEqual(Kind.fullscreen, store.entries.get(2).?.kind);
    try std.testing.expectEqual(@as(?types.Handle, 2), store.fullscreen_by_output.get(10));
}

test "removing a window clears every state index" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.observe(1, 10, 1, true);
    try store.minimized_mru.append(store.allocator, 1);
    _ = try store.observe(2, 10, 1, false);
    try store.sendToScratchpad(2, "term");
    store.remove(1);
    store.remove(2);

    try std.testing.expect(!store.entries.contains(1));
    try std.testing.expect(!store.entries.contains(2));
    try std.testing.expectEqual(@as(?types.Handle, null), store.fullscreenOwner(10));
    try std.testing.expectEqual(@as(usize, 0), store.minimized_mru.items.len);
    try std.testing.expectEqual(@as(types.Handle, 0), store.toggleScratchpad("term"));
}
