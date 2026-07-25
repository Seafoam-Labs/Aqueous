// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const Box = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Extent = struct {
    width: u32,
    height: u32,
};

pub const UpdatePlan = struct {
    final: Box,
    downsample: Box,
    horizontal: [16]Box,
    vertical: [16]Box,
    passes: u32,
    pixels_processed: u64,
};

pub fn fullBox(extent: Extent) Box {
    return .{
        .x = 0,
        .y = 0,
        .width = @intCast(extent.width),
        .height = @intCast(extent.height),
    };
}

pub fn intersection(a: Box, b: Box) ?Box {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    };
}

pub fn clipped(box: Box, extent: Extent) Box {
    return intersection(box, fullBox(extent)) orelse
        .{ .x = 0, .y = 0, .width = 0, .height = 0 };
}

pub fn expanded(box: Box, reach: u32) Box {
    const amount: i32 = @intCast(@min(reach, std.math.maxInt(i32)));
    return .{
        .x = box.x -| amount,
        .y = box.y -| amount,
        .width = box.width +| amount *| 2,
        .height = box.height +| amount *| 2,
    };
}

pub fn halfResolution(box: Box, extent: Extent) Box {
    const left = @divFloor(box.x, 2);
    const top = @divFloor(box.y, 2);
    const right = @divFloor(box.x + box.width + 1, 2);
    const bottom = @divFloor(box.y + box.height + 1, 2);
    return clipped(.{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    }, extent);
}

pub fn planUpdate(
    update: Box,
    half_extent: Extent,
    passes: u32,
    tap_reach: u32,
) UpdatePlan {
    std.debug.assert(passes > 0 and passes <= 16);
    std.debug.assert(tap_reach > 0);
    const final = halfResolution(update, half_extent);
    var plan: UpdatePlan = .{
        .final = final,
        .downsample = undefined,
        .horizontal = undefined,
        .vertical = undefined,
        .passes = passes,
        .pixels_processed = 0,
    };
    var needed = final;
    var reverse = passes;
    while (reverse > 0) {
        reverse -= 1;
        plan.vertical[reverse] = needed;
        needed = clipped(
            expandDirectional(needed, tap_reach, false),
            half_extent,
        );
        plan.horizontal[reverse] = needed;
        needed = clipped(
            expandDirectional(needed, tap_reach, true),
            half_extent,
        );
    }
    plan.downsample = needed;
    plan.pixels_processed = area(plan.downsample) + area(plan.final);
    for (0..passes) |index| {
        plan.pixels_processed += area(plan.horizontal[index]);
        plan.pixels_processed += area(plan.vertical[index]);
    }
    return plan;
}

pub fn area(box: Box) u64 {
    if (box.width <= 0 or box.height <= 0) return 0;
    return @as(u64, @intCast(box.width)) *
        @as(u64, @intCast(box.height));
}

fn expandDirectional(box: Box, reach: u32, horizontal: bool) Box {
    const amount: i32 = @intCast(@min(reach, std.math.maxInt(i32)));
    if (horizontal) {
        return .{
            .x = box.x -| amount,
            .y = box.y,
            .width = box.width +| amount *| 2,
            .height = box.height,
        };
    }
    return .{
        .x = box.x,
        .y = box.y -| amount,
        .width = box.width,
        .height = box.height +| amount *| 2,
    };
}

test "damage expansion and clipping are conservative" {
    const expanded_damage = expanded(
        .{ .x = 95, .y = 45, .width = 10, .height = 10 },
        20,
    );
    try std.testing.expectEqualDeep(
        Box{ .x = 75, .y = 25, .width = 50, .height = 50 },
        expanded_damage,
    );
    try std.testing.expectEqualDeep(
        Box{ .x = 0, .y = 0, .width = 30, .height = 30 },
        clipped(
            .{ .x = -10, .y = -20, .width = 40, .height = 50 },
            .{ .width = 100, .height = 80 },
        ),
    );
}

test "partial update walks kernel dependencies backwards" {
    const plan = planUpdate(
        .{ .x = 400, .y = 200, .width = 80, .height = 40 },
        .{ .width = 960, .height = 540 },
        4,
        6,
    );
    try std.testing.expectEqualDeep(
        Box{ .x = 200, .y = 100, .width = 40, .height = 20 },
        plan.final,
    );
    try std.testing.expect(plan.downsample.x < plan.final.x);
    try std.testing.expect(plan.downsample.y < plan.final.y);
    try std.testing.expect(
        plan.downsample.width > plan.final.width and
            plan.downsample.height > plan.final.height,
    );
    try std.testing.expect(plan.pixels_processed > area(plan.final));
}

test "odd pixel bounds cover every half-resolution texel" {
    try std.testing.expectEqualDeep(
        Box{ .x = 1, .y = 2, .width = 3, .height = 4 },
        halfResolution(
            .{ .x = 3, .y = 5, .width = 5, .height = 7 },
            .{ .width = 20, .height = 20 },
        ),
    );
}
