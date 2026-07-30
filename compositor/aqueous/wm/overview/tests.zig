// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const model = @import("model.zig");
const layout = @import("../layout/types.zig");

fn cards(sources: []const layout.Rect, storage: []model.Card) []model.Card {
    for (sources, storage, 0..) |source, *card, index| {
        card.* = .{ .handle = index + 1, .source = source };
    }
    return storage[0..sources.len];
}

fn expectContained(area: layout.Rect, arranged: []const model.Card) !void {
    for (arranged) |card| {
        try std.testing.expect(card.target.width > 0);
        try std.testing.expect(card.target.height > 0);
        try std.testing.expect(card.target.x >= area.x);
        try std.testing.expect(card.target.y >= area.y);
        try std.testing.expect(card.target.right() <= area.right());
        try std.testing.expect(card.target.bottom() <= area.bottom());
    }
}

fn overlaps(a: layout.Rect, b: layout.Rect) bool {
    return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
}

test "empty and single-window arrangements" {
    var empty: [0]model.Card = .{};
    model.arrange(&empty, .{ .x = 0, .y = 0, .width = 1920, .height = 1080 });

    var storage: [1]model.Card = undefined;
    const arranged = cards(&.{.{ .x = 30, .y = 40, .width = 1600, .height = 900 }}, &storage);
    const usable: layout.Rect = .{ .x = 100, .y = 80, .width = 1200, .height = 800 };
    model.arrange(arranged, usable);
    try expectContained(usable, arranged);
    try std.testing.expectEqual(@as(i32, 1136), arranged[0].target.width);
    try std.testing.expectEqual(@as(i32, 639), arranged[0].target.height);
}

test "mixed aspect ratios are stable, contained, and non-overlapping" {
    const sources = [_]layout.Rect{
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .{ .x = 0, .y = 0, .width = 900, .height = 1600 },
        .{ .x = 0, .y = 0, .width = 3440, .height = 1440 },
        .{ .x = 0, .y = 0, .width = 1000, .height = 1000 },
        .{ .x = 0, .y = 0, .width = 1280, .height = 720 },
        .{ .x = 0, .y = 0, .width = 720, .height = 1280 },
    };
    var first_storage: [sources.len]model.Card = undefined;
    var second_storage: [sources.len]model.Card = undefined;
    const usable: layout.Rect = .{ .x = -1440, .y = 120, .width = 1400, .height = 860 };
    const first = cards(&sources, &first_storage);
    const second = cards(&sources, &second_storage);
    model.arrange(first, usable);
    model.arrange(second, usable);
    try std.testing.expectEqualSlices(model.Card, first, second);
    try expectContained(usable, first);
    for (first, 0..) |card, index| {
        for (first[index + 1 ..]) |other| try std.testing.expect(!overlaps(card.target, other.target));
    }
}

test "large card counts remain inside the usable area" {
    var storage: [30]model.Card = undefined;
    var sources: [30]layout.Rect = undefined;
    for (&sources, 0..) |*source, index| {
        source.* = .{
            .x = 0,
            .y = 0,
            .width = 500 + @as(i32, @intCast(index % 5)) * 200,
            .height = 400 + @as(i32, @intCast(index % 3)) * 300,
        };
    }
    const usable: layout.Rect = .{ .x = 3840, .y = -200, .width = 2560, .height = 1440 };
    const arranged = cards(&sources, &storage);
    model.arrange(arranged, usable);
    try expectContained(usable, arranged);
    for (arranged, 0..) |card, index| {
        for (arranged[index + 1 ..]) |other| try std.testing.expect(!overlaps(card.target, other.target));
    }
}

test "directional navigation follows card centers" {
    const arranged = [_]model.Card{
        .{ .handle = 1, .source = .empty, .target = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .handle = 2, .source = .empty, .target = .{ .x = 200, .y = 10, .width = 100, .height = 100 } },
        .{ .handle = 3, .source = .empty, .target = .{ .x = 10, .y = 220, .width = 100, .height = 100 } },
        .{ .handle = 4, .source = .empty, .target = .{ .x = 210, .y = 230, .width = 100, .height = 100 } },
    };
    try std.testing.expectEqual(@as(?layout.Handle, 2), model.neighbor(&arranged, 1, .right));
    try std.testing.expectEqual(@as(?layout.Handle, 3), model.neighbor(&arranged, 1, .down));
    try std.testing.expectEqual(@as(?layout.Handle, 1), model.neighbor(&arranged, 2, .left));
    try std.testing.expectEqual(@as(?layout.Handle, 2), model.neighbor(&arranged, 4, .up));
    try std.testing.expect(model.neighbor(&arranged, 1, .left) == null);
}

test "cycling wraps and hit testing honors half-open card bounds" {
    const arranged = [_]model.Card{
        .{ .handle = 10, .source = .empty, .target = .{ .x = 100, .y = 100, .width = 200, .height = 100 } },
        .{ .handle = 20, .source = .empty, .target = .{ .x = 400, .y = 100, .width = 200, .height = 100 } },
        .{ .handle = 30, .source = .empty, .target = .{ .x = 700, .y = 100, .width = 200, .height = 100 } },
    };
    try std.testing.expectEqual(@as(?layout.Handle, 10), model.cycle(&arranged, 30, 1));
    try std.testing.expectEqual(@as(?layout.Handle, 30), model.cycle(&arranged, 10, -1));
    try std.testing.expectEqual(@as(?layout.Handle, 20), model.hitTest(&arranged, 450, 150));
    try std.testing.expect(model.hitTest(&arranged, 600, 150) == null);
    try std.testing.expect(model.hitTest(&arranged, std.math.nan(f64), 150) == null);
}

test "removing selection chooses the nearest replacement" {
    var state: model.State = .{
        .output_id = 1,
        .workspace_number = 2,
        .original_focus = 20,
        .selected = 20,
    };
    defer state.cards.deinit(std.testing.allocator);
    try state.cards.appendSlice(std.testing.allocator, &.{
        .{ .handle = 10, .source = .empty, .target = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .handle = 20, .source = .empty, .target = .{ .x = 200, .y = 0, .width = 100, .height = 100 } },
        .{ .handle = 30, .source = .empty, .target = .{ .x = 700, .y = 0, .width = 100, .height = 100 } },
    });
    try std.testing.expect(model.remove(&state, 20));
    try std.testing.expectEqual(@as(layout.Handle, 10), state.selected);
    try std.testing.expect(!model.contains(state.cards.items, 20));
    try std.testing.expect(model.remove(&state, 10));
    try std.testing.expectEqual(@as(layout.Handle, 30), state.selected);
    try std.testing.expect(model.remove(&state, 30));
    try std.testing.expectEqual(@as(layout.Handle, 0), state.selected);
}
