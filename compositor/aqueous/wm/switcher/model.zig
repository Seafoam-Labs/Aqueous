// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const layout = @import("../layout/types.zig");
pub const Ring = struct {
    ids: std.ArrayListUnmanaged(u64) = .empty,
    pub fn deinit(self: *Ring, a: std.mem.Allocator) void {
        self.ids.deinit(a);
    }
    /// Input sorted by stable identity; focus never changes ordering.
    pub fn reconcile(self: *Ring, a: std.mem.Allocator, eligible: []const u64) !void {
        try self.ids.ensureTotalCapacity(a, self.ids.items.len + eligible.len);
        var i: usize = 0;
        while (i < self.ids.items.len) {
            if (std.mem.indexOfScalar(u64, eligible, self.ids.items[i]) == null) _ = self.ids.orderedRemove(i) else i += 1;
        }
        for (eligible) |id| if (std.mem.indexOfScalar(u64, self.ids.items, id) == null) self.ids.appendAssumeCapacity(id);
    }
    pub fn next(self: Ring, focused: ?u64, reverse: bool) ?u64 {
        const n = self.ids.items.len;
        if (n == 0) return null;
        const i = if (focused) |id| std.mem.indexOfScalar(u64, self.ids.items, id) else null;
        return self.ids.items[if (i) |at| (at + (if (reverse) n - 1 else @as(usize, 1))) % n else if (reverse) n - 1 else 0];
    }
};
/// Aspect-fit each source into a bounded stack slot; only presentation changes.
pub fn cardRect(source: layout.Rect, area: layout.Rect, slot: usize) layout.Rect {
    const scale: f64 = if (slot == 0) 0.66 else 0.54;
    const width = @as(f64, @floatFromInt(@max(1, area.width))) * scale;
    const height = @as(f64, @floatFromInt(@max(1, area.height))) * (if (slot == 0) @as(f64, 0.62) else 0.51);
    const ratio = @min(width / @as(f64, @floatFromInt(@max(1, source.width))), height / @as(f64, @floatFromInt(@max(1, source.height))));
    const w: i32 = @max(1, @as(i32, @intFromFloat(@as(f64, @floatFromInt(@max(1, source.width))) * ratio)));
    const h: i32 = @max(1, @as(i32, @intFromFloat(@as(f64, @floatFromInt(@max(1, source.height))) * ratio)));
    const offset: i32 = if (slot == 0) 0 else @divTrunc(area.width, 6) * (if (slot == 1) @as(i32, 1) else -1);
    return .{ .x = area.x + @divTrunc(area.width - w, 2) + offset, .y = area.y + @divTrunc(area.height - h, 2) - @divTrunc(area.height, 16), .width = w, .height = h };
}
test "stable ring wraps through every window and survives idle external focus and churn" {
    const a = std.testing.allocator;
    var ring: Ring = .{};
    defer ring.deinit(a);
    try std.testing.expectEqual(null, ring.next(null, false));
    try ring.reconcile(a, &.{ 10, 20, 30 });
    var id: u64 = 10;
    for ([_]u64{ 20, 30, 10, 20, 30, 10 }) |expected| {
        id = ring.next(id, false).?;
        try std.testing.expectEqual(expected, id);
        try ring.reconcile(a, &.{ 10, 20, 30 });
    }
    try std.testing.expectEqual(@as(?u64, 30), ring.next(10, true));
    try std.testing.expectEqual(@as(?u64, 10), ring.next(null, false));
    try std.testing.expectEqual(@as(?u64, 30), ring.next(null, true));
    try ring.reconcile(a, &.{ 5, 10, 30 });
    try std.testing.expectEqualSlices(u64, &.{ 10, 30, 5 }, ring.ids.items);
    try ring.reconcile(a, &.{30});
    try std.testing.expectEqual(@as(?u64, 30), ring.next(30, false));
    try ring.reconcile(a, &.{});
    try std.testing.expectEqual(null, ring.next(30, true));
}
test "cards preserve aspect ratio inside portrait and landscape bounds" {
    for ([_]layout.Rect{ .{ .x = -800, .y = 0, .width = 800, .height = 1200 }, .{ .x = 0, .y = 40, .width = 1920, .height = 1040 } }) |area| {
        for (0..3) |slot| {
            const rect = cardRect(.{ .x = 0, .y = 0, .width = 1200, .height = 800 }, area, slot);
            try std.testing.expect(rect.x >= area.x and rect.y >= area.y and rect.right() <= area.right() and rect.bottom() <= area.bottom());
            try std.testing.expect(@abs(rect.width * 2 - rect.height * 3) <= 3);
        }
    }
}
