// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const Icon = @This();
const std = @import("std");
const c = @import("c");
const wlr = @import("wlroots");
const selection = @import("icon_selection.zig");
pub const Native = c.struct_wlr_xdg_toplevel_icon_v1;

synced: c.struct_wlr_surface_synced = undefined,
initialized: bool = false,
pending: State = .{},
committed: State = .{},
current: ?*Native = null,
revision: u64 = 0,

const State = extern struct {
    set: bool = false,
    icon: ?*Native = null,
};
const synced_impl: c.struct_wlr_surface_synced_impl = .{
    .state_size = @sizeOf(State),
    .init_state = null,
    .finish_state = finishState,
    .move_state = moveState,
    .commit = null,
};

pub fn init(icon: *Icon, surface: *wlr.Surface) !void {
    if (!c.wlr_surface_synced_init(&icon.synced, @ptrCast(surface), &synced_impl, &icon.pending, &icon.committed)) return error.OutOfMemory;
    icon.initialized = true;
}

fn finishState(data: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    c.wlr_xdg_toplevel_icon_v1_unref(state.icon);
    state.* = .{};
}

fn moveState(dst_data: ?*anyopaque, src_data: ?*anyopaque) callconv(.c) void {
    const dst: *State = @ptrCast(@alignCast(dst_data));
    const src: *State = @ptrCast(@alignCast(src_data));
    if (!src.set) return;
    finishState(dst);
    dst.* = src.*;
    src.* = .{};
}

pub fn assign(icon: *Icon, value: ?*Native) void {
    const referenced = if (value) |v| c.wlr_xdg_toplevel_icon_v1_ref(v) else null;
    finishState(&icon.pending);
    icon.pending = .{ .set = true, .icon = referenced };
}

pub fn commit(icon: *Icon) bool {
    if (!icon.committed.set) return false;
    const changed = icon.current != icon.committed.icon;
    c.wlr_xdg_toplevel_icon_v1_unref(icon.current);
    icon.current = icon.committed.icon;
    icon.committed = .{};
    if (changed) icon.revision += 1;
    return changed;
}

pub fn deinit(icon: *Icon) void {
    if (icon.initialized) {
        c.wlr_surface_synced_finish(&icon.synced);
    } else {
        finishState(&icon.pending);
        finishState(&icon.committed);
    }
    c.wlr_xdg_toplevel_icon_v1_unref(icon.current);
    icon.* = .{};
}

pub const Metadata = struct { revision: []const u8, name: ?[]const u8, has_pixels: bool };
pub fn metadata(icon: *const Icon, a: std.mem.Allocator) !?Metadata {
    const current = icon.current orelse return null;
    return .{
        .revision = try std.fmt.allocPrint(a, "{d}", .{icon.revision}),
        .name = if (current.name != null) std.mem.span(current.name) else null,
        .has_pixels = select(current, 32, 1) != null,
    };
}

pub fn select(icon: *Native, size: u32, scale: f64) ?*wlr.Buffer {
    var link = icon.buffers.next;
    var best: ?*wlr.Buffer = null;
    var score: u64 = std.math.maxInt(u64);
    while (link != &icon.buffers) : (link = link.*.next) {
        const entry: *c.struct_wlr_xdg_toplevel_icon_v1_buffer = @fieldParentPtr("link", @as(*c.struct_wl_list, @ptrCast(link)));
        const candidate = selection.rank(entry.buffer.*.width, entry.scale, size, scale);
        if (candidate < score) {
            best = @ptrCast(@alignCast(entry.buffer));
            score = candidate;
        }
    }
    return best;
}

test "queued icon commit preserves its assignment ahead of newer uncommitted requests" {
    var first: Native = std.mem.zeroes(Native);
    var second: Native = std.mem.zeroes(Native);
    first.WLR_PRIVATE.n_refs = 1;
    second.WLR_PRIVATE.n_refs = 1;
    var icon: Icon = .{};
    var cached: State = .{};
    icon.assign(&first);
    moveState(&cached, &icon.pending);
    icon.assign(&second);
    moveState(&icon.committed, &cached);
    try std.testing.expect(icon.commit());
    try std.testing.expectEqual(&first, icon.current.?);
    try std.testing.expectEqual(&second, icon.pending.icon.?);
    try std.testing.expectEqual(@as(u64, 1), icon.revision);
    moveState(&icon.committed, &icon.pending);
    try std.testing.expect(icon.commit());
    try std.testing.expectEqual(&second, icon.current.?);
    icon.assign(null);
    try std.testing.expect(!icon.commit());
    moveState(&icon.committed, &icon.pending);
    try std.testing.expect(icon.commit());
    try std.testing.expectEqual(@as(?*Native, null), icon.current);
    icon.deinit();
    try std.testing.expectEqual(@as(c_int, 1), first.WLR_PRIVATE.n_refs);
    try std.testing.expectEqual(@as(c_int, 1), second.WLR_PRIVATE.n_refs);
}

test "cached destruction and request replacement release every icon reference" {
    var native: Native = std.mem.zeroes(Native);
    native.WLR_PRIVATE.n_refs = 1;
    var icon: Icon = .{};
    var cached: State = .{};
    icon.assign(&native);
    icon.assign(&native);
    try std.testing.expectEqual(@as(c_int, 2), native.WLR_PRIVATE.n_refs);
    moveState(&cached, &icon.pending);
    icon.assign(&native);
    try std.testing.expectEqual(@as(c_int, 3), native.WLR_PRIVATE.n_refs);
    finishState(&cached);
    icon.deinit();
    try std.testing.expectEqual(@as(c_int, 1), native.WLR_PRIVATE.n_refs);
}
