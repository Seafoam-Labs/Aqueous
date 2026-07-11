// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const Direction = enum { left, right, up, down };

/// Return the index of the physically nearest output in `direction`.
///
/// Outputs with perpendicular overlap are preferred, then the edge-to-edge
/// distance in the requested direction, then perpendicular separation. The
/// output id provides a stable final tie-break independent of iterator order.
pub fn neighbor(outputs: anytype, current_id: u64, direction: Direction) ?usize {
    var current_index: ?usize = null;
    for (outputs, 0..) |output, index| {
        if (output.id == current_id) {
            current_index = index;
            break;
        }
    }
    const origin = outputs[current_index orelse return null].area;

    var best: ?usize = null;
    var best_score: Score = undefined;
    for (outputs, 0..) |output, index| {
        if (index == current_index.?) continue;
        const score = candidateScore(origin, output.area, output.id, direction) orelse continue;
        if (best == null or score.lessThan(best_score)) {
            best = index;
            best_score = score;
        }
    }
    return best;
}

const Score = struct {
    non_overlapping: u1,
    primary_gap: i64,
    perpendicular_gap: i64,
    primary_center_distance: u64,
    id: u64,

    fn lessThan(score: Score, other: Score) bool {
        if (score.non_overlapping != other.non_overlapping) return score.non_overlapping < other.non_overlapping;
        if (score.primary_gap != other.primary_gap) return score.primary_gap < other.primary_gap;
        if (score.perpendicular_gap != other.perpendicular_gap) return score.perpendicular_gap < other.perpendicular_gap;
        if (score.primary_center_distance != other.primary_center_distance) return score.primary_center_distance < other.primary_center_distance;
        return score.id < other.id;
    }
};

fn candidateScore(origin: anytype, candidate: @TypeOf(origin), id: u64, direction: Direction) ?Score {
    const origin_primary = if (direction == .left or direction == .right) center(origin.x, origin.width) else center(origin.y, origin.height);
    const candidate_primary = if (direction == .left or direction == .right) center(candidate.x, candidate.width) else center(candidate.y, candidate.height);
    if ((direction == .left or direction == .up) and candidate_primary >= origin_primary) return null;
    if ((direction == .right or direction == .down) and candidate_primary <= origin_primary) return null;

    const origin_perp_start: i64 = if (direction == .left or direction == .right) origin.y else origin.x;
    const origin_perp_end: i64 = origin_perp_start + if (direction == .left or direction == .right) origin.height else origin.width;
    const candidate_perp_start: i64 = if (direction == .left or direction == .right) candidate.y else candidate.x;
    const candidate_perp_end: i64 = candidate_perp_start + if (direction == .left or direction == .right) candidate.height else candidate.width;
    const perpendicular_gap = intervalGap(origin_perp_start, origin_perp_end, candidate_perp_start, candidate_perp_end);

    const primary_gap: i64 = switch (direction) {
        .left => @max(0, @as(i64, origin.x) - (@as(i64, candidate.x) + candidate.width)),
        .right => @max(0, @as(i64, candidate.x) - (@as(i64, origin.x) + origin.width)),
        .up => @max(0, @as(i64, origin.y) - (@as(i64, candidate.y) + candidate.height)),
        .down => @max(0, @as(i64, candidate.y) - (@as(i64, origin.y) + origin.height)),
    };
    return .{
        .non_overlapping = if (perpendicular_gap == 0) 0 else 1,
        .primary_gap = primary_gap,
        .perpendicular_gap = perpendicular_gap,
        .primary_center_distance = @abs(candidate_primary - origin_primary),
        .id = id,
    };
}

fn center(start: i32, length: i32) i64 {
    return @as(i64, start) * 2 + length;
}

fn intervalGap(a_start: i64, a_end: i64, b_start: i64, b_end: i64) i64 {
    if (a_end < b_start) return b_start - a_end;
    if (b_end < a_start) return a_start - b_end;
    return 0;
}

const TestRect = struct { x: i32, y: i32, width: i32, height: i32 };
const TestOutput = struct { id: u64, area: TestRect };

test "navigation uses physical position instead of slice order" {
    const outputs = [_]TestOutput{
        .{ .id = 2, .area = .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 } },
        .{ .id = 1, .area = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 } },
        .{ .id = 3, .area = .{ .x = -1280, .y = 200, .width = 1280, .height = 1024 } },
    };
    try std.testing.expectEqual(@as(?usize, 2), neighbor(&outputs, 1, .left));
    try std.testing.expectEqual(@as(?usize, 0), neighbor(&outputs, 1, .right));
}

test "navigation prefers perpendicular overlap on staggered layouts" {
    const outputs = [_]TestOutput{
        .{ .id = 1, .area = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .id = 2, .area = .{ .x = 110, .y = 300, .width = 100, .height = 100 } },
        .{ .id = 3, .area = .{ .x = 300, .y = 25, .width = 100, .height = 100 } },
    };
    try std.testing.expectEqual(@as(?usize, 2), neighbor(&outputs, 1, .right));
}

test "navigation does not wrap at a physical edge" {
    const outputs = [_]TestOutput{
        .{ .id = 1, .area = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .id = 2, .area = .{ .x = 100, .y = 0, .width = 100, .height = 100 } },
    };
    try std.testing.expectEqual(@as(?usize, null), neighbor(&outputs, 1, .left));
}
