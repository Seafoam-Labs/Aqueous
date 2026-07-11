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
    result.value_ptr.output = output;
    result.value_ptr.workspace = workspace;
    _ = fullscreen;
    return result.value_ptr;
}

pub fn remove(store: *Store, handle: types.Handle) void {
    if (store.entries.fetchRemove(handle)) |removed| {
        if (removed.value.kind == .fullscreen and store.fullscreen_by_output.get(removed.value.output) == handle) _ = store.fullscreen_by_output.remove(removed.value.output);
        if (removed.value.scratchpad != 0 and store.scratchpads.get(removed.value.scratchpad) == handle) _ = store.scratchpads.remove(removed.value.scratchpad);
    }
    removeFromList(&store.minimized_mru, handle);
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
