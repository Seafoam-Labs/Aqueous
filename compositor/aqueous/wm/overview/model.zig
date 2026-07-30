// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const layout = @import("../layout/types.zig");

pub const outer_margin: i32 = 32;
pub const card_gap: i32 = 24;

pub const Card = struct {
    handle: layout.Handle,
    source: layout.Rect,
    target: layout.Rect = .empty,
};

pub const State = struct {
    output_id: u64,
    workspace_number: u32,
    original_focus: ?layout.Handle,
    selected: layout.Handle,
    cards: std.ArrayListUnmanaged(Card) = .empty,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.cards.deinit(allocator);
        state.* = undefined;
    }
};

pub const Direction = enum { left, right, up, down };

/// Arrange cards in the deterministic highest-scoring grid. Card order is
/// deliberately preserved: the policy snapshot order defines cell assignment.
pub fn arrange(cards: []Card, usable_area: layout.Rect) void {
    if (cards.len == 0) return;
    if (usable_area.width <= 0 or usable_area.height <= 0) {
        for (cards) |*card| card.target = .empty;
        return;
    }

    var best_columns: usize = 1;
    var best_score = -std.math.inf(f64);
    var columns: usize = 1;
    while (columns <= cards.len) : (columns += 1) {
        const rows = ceilDiv(cards.len, columns);
        const cell = gridCellSize(usable_area, columns, rows) orelse continue;
        var score: f64 = 0;
        for (cards) |card| {
            const fitted = aspectFit(card.source, .{
                .x = 0,
                .y = 0,
                .width = cell.width,
                .height = cell.height,
            });
            const area: f64 = @floatFromInt(@as(i64, fitted.width) * fitted.height);
            score += area;
            // Very narrow cards are hard to recognize and select, even when a
            // grid technically maximizes raw displayed area.
            if (fitted.width < 96) {
                const shortfall: f64 = @floatFromInt(96 - fitted.width);
                score -= shortfall * @as(f64, @floatFromInt(@max(1, fitted.height))) * 0.75;
            }
        }
        const empty_cells = columns * rows - cards.len;
        if (empty_cells > 0) {
            const cell_area: f64 = @floatFromInt(@as(i64, cell.width) * cell.height);
            score -= @as(f64, @floatFromInt(empty_cells)) * cell_area * 0.20;
        }

        // A strict comparison keeps the lower column count on exact ties.
        if (score > best_score) {
            best_score = score;
            best_columns = columns;
        }
    }

    const best_rows = ceilDiv(cards.len, best_columns);
    const cell = gridCellSize(usable_area, best_columns, best_rows) orelse {
        for (cards) |*card| card.target = aspectFit(card.source, usable_area);
        return;
    };
    for (cards, 0..) |*card, index| {
        const column: i32 = @intCast(index % best_columns);
        const row: i32 = @intCast(index / best_columns);
        const cell_rect: layout.Rect = .{
            .x = usable_area.x + outer_margin + column * (cell.width + card_gap),
            .y = usable_area.y + outer_margin + row * (cell.height + card_gap),
            .width = cell.width,
            .height = cell.height,
        };
        card.target = aspectFit(card.source, cell_rect);
    }
}

/// Return the nearest card whose center lies in the requested half-plane.
/// Primary-axis distance dominates, with perpendicular distance and original
/// card order providing deterministic tie-breaking.
pub fn neighbor(cards: []const Card, selected: layout.Handle, direction: Direction) ?layout.Handle {
    const origin = find(cards, selected) orelse return null;
    const ox = centerX(origin.target);
    const oy = centerY(origin.target);
    var best: ?layout.Handle = null;
    var best_score: i128 = std.math.maxInt(i128);
    var best_primary: i64 = std.math.maxInt(i64);

    for (cards) |card| {
        if (card.handle == selected) continue;
        const dx = centerX(card.target) - ox;
        const dy = centerY(card.target) - oy;
        const eligible = switch (direction) {
            .left => dx < 0,
            .right => dx > 0,
            .up => dy < 0,
            .down => dy > 0,
        };
        if (!eligible) continue;

        const primary: i64 = @intCast(@abs(if (direction == .left or direction == .right) dx else dy));
        const secondary: i64 = @intCast(@abs(if (direction == .left or direction == .right) dy else dx));
        // Perpendicular displacement is deliberately weighted so a card in
        // the next row is not selected as "right" merely because its center is
        // a few pixels farther right.
        const score = @as(i128, primary) * primary + @as(i128, secondary) * secondary * 5;
        if (score < best_score or (score == best_score and primary < best_primary)) {
            best = card.handle;
            best_score = score;
            best_primary = primary;
        }
    }
    return best;
}

pub fn cycle(cards: []const Card, selected: layout.Handle, delta: i32) ?layout.Handle {
    if (cards.len == 0) return null;
    var selected_index: usize = 0;
    for (cards, 0..) |card, index| {
        if (card.handle == selected) {
            selected_index = index;
            break;
        }
    }
    const len: i64 = @intCast(cards.len);
    const raw = @as(i64, @intCast(selected_index)) + delta;
    const wrapped = @mod(raw, len);
    return cards[@intCast(wrapped)].handle;
}

pub fn hitTest(cards: []const Card, x: f64, y: f64) ?layout.Handle {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    for (cards) |card| {
        const rect = card.target;
        if (rect.width <= 0 or rect.height <= 0) continue;
        if (x >= @as(f64, @floatFromInt(rect.x)) and
            y >= @as(f64, @floatFromInt(rect.y)) and
            x < @as(f64, @floatFromInt(rect.right())) and
            y < @as(f64, @floatFromInt(rect.bottom())))
        {
            return card.handle;
        }
    }
    return null;
}

/// Remove a card. If it owned selection, choose the geometrically nearest
/// remaining card. A zero selected handle represents the now-empty state.
pub fn remove(state: *State, handle: layout.Handle) bool {
    var index: ?usize = null;
    for (state.cards.items, 0..) |card, card_index| {
        if (card.handle == handle) {
            index = card_index;
            break;
        }
    }
    const removed_index = index orelse return false;
    const removed = state.cards.items[removed_index];
    _ = state.cards.orderedRemove(removed_index);
    if (state.selected != handle) return true;
    if (state.cards.items.len == 0) {
        state.selected = 0;
        return true;
    }

    const ox = centerX(removed.target);
    const oy = centerY(removed.target);
    var replacement = state.cards.items[0].handle;
    var best_distance: i128 = std.math.maxInt(i128);
    for (state.cards.items) |card| {
        const dx = centerX(card.target) - ox;
        const dy = centerY(card.target) - oy;
        const distance = @as(i128, dx) * dx + @as(i128, dy) * dy;
        if (distance < best_distance) {
            replacement = card.handle;
            best_distance = distance;
        }
    }
    state.selected = replacement;
    return true;
}

pub fn contains(cards: []const Card, handle: layout.Handle) bool {
    return find(cards, handle) != null;
}

fn find(cards: []const Card, handle: layout.Handle) ?Card {
    for (cards) |card| if (card.handle == handle) return card;
    return null;
}

fn ceilDiv(numerator: usize, denominator: usize) usize {
    return (numerator + denominator - 1) / denominator;
}

fn gridCellSize(area: layout.Rect, columns: usize, rows: usize) ?layout.Rect {
    const columns_i32: i32 = @intCast(columns);
    const rows_i32: i32 = @intCast(rows);
    const available_width = area.width - 2 * outer_margin - @max(0, columns_i32 - 1) * card_gap;
    const available_height = area.height - 2 * outer_margin - @max(0, rows_i32 - 1) * card_gap;
    if (available_width < columns_i32 or available_height < rows_i32) return null;
    return .{
        .x = 0,
        .y = 0,
        .width = @divFloor(available_width, columns_i32),
        .height = @divFloor(available_height, rows_i32),
    };
}

fn aspectFit(source: layout.Rect, bounds: layout.Rect) layout.Rect {
    if (source.width <= 0 or source.height <= 0 or bounds.width <= 0 or bounds.height <= 0) return .empty;
    const width_scale = @as(f64, @floatFromInt(bounds.width)) / @as(f64, @floatFromInt(source.width));
    const height_scale = @as(f64, @floatFromInt(bounds.height)) / @as(f64, @floatFromInt(source.height));
    const scale = @min(width_scale, height_scale);
    const width = @max(1, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(source.width)) * scale))));
    const height = @max(1, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(source.height)) * scale))));
    return .{
        .x = bounds.x + @divFloor(bounds.width - width, 2),
        .y = bounds.y + @divFloor(bounds.height - height, 2),
        .width = width,
        .height = height,
    };
}

fn centerX(rect: layout.Rect) i64 {
    return @as(i64, rect.x) * 2 + rect.width;
}

fn centerY(rect: layout.Rect) i64 {
    return @as(i64, rect.y) * 2 + rect.height;
}
