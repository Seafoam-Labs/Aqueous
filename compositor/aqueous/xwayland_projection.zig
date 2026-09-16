// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

/// Scaling policy for the embedded Xwayland server.
pub const Mode = enum {
    /// Logical-size Xwayland desktop, translated to a nonnegative origin.
    legacy,
    /// Give Xwayland a physical-pixel desktop and project its surfaces back
    /// into Aqueous' logical coordinate space.
    native,

    pub fn parse(value: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, value);
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn contains(rect: Rect, x: f64, y: f64) bool {
        return x >= @as(f64, @floatFromInt(rect.x)) and
            y >= @as(f64, @floatFromInt(rect.y)) and
            x < @as(f64, @floatFromInt(rect.x + rect.width)) and
            y < @as(f64, @floatFromInt(rect.y + rect.height));
    }
};

pub const Output = struct {
    logical: Rect,
    physical_width: i32,
    physical_height: i32,
    scale: f64,
};

pub const Projection = struct {
    logical: Rect,
    x11: Rect,
    scale: f64,

    pub fn logicalToX11Point(projection: Projection, x: f64, y: f64) struct { i32, i32 } {
        return .{
            projection.x11.x + roundI32((x - @as(f64, @floatFromInt(projection.logical.x))) * projection.scale),
            projection.x11.y + roundI32((y - @as(f64, @floatFromInt(projection.logical.y))) * projection.scale),
        };
    }

    pub fn x11ToLogicalPoint(projection: Projection, x: f64, y: f64) struct { f64, f64 } {
        return .{
            @as(f64, @floatFromInt(projection.logical.x)) +
                (x - @as(f64, @floatFromInt(projection.x11.x))) / projection.scale,
            @as(f64, @floatFromInt(projection.logical.y)) +
                (y - @as(f64, @floatFromInt(projection.x11.y))) / projection.scale,
        };
    }

    pub fn logicalToX11Size(projection: Projection, width: u31, height: u31) struct { u16, u16 } {
        return .{
            clampU16(@as(f64, @floatFromInt(width)) * projection.scale),
            clampU16(@as(f64, @floatFromInt(height)) * projection.scale),
        };
    }

    pub fn x11ToLogicalSize(projection: Projection, width: u16, height: u16) struct { u31, u31 } {
        return .{
            @intCast(@max(1, roundI32(@as(f64, @floatFromInt(width)) / projection.scale))),
            @intCast(@max(1, roundI32(@as(f64, @floatFromInt(height)) / projection.scale))),
        };
    }
};

/// Build the X11 box for one output. Legacy mode only translates negative
/// origins; native mode uses physical sizes and projects origins with the
/// largest active scale. This guarantees that independently physical-sized
/// output boxes cannot overlap, while retaining the compositor layout's
/// ordering. Lower-scale outputs can introduce inert gaps in the X11 root;
/// pointer delivery remains surface-local and is unaffected by those gaps.
pub fn project(outputs: []const Output, index: usize, mode: Mode) Projection {
    std.debug.assert(index < outputs.len);
    const target = outputs[index];

    var min_x = if (mode == .native) target.logical.x else @min(0, target.logical.x);
    var min_y = if (mode == .native) target.logical.y else @min(0, target.logical.y);
    var layout_scale: f64 = if (mode == .native) target.scale else 1;
    for (outputs) |output| {
        min_x = @min(min_x, output.logical.x);
        min_y = @min(min_y, output.logical.y);
        if (mode == .native) layout_scale = @max(layout_scale, output.scale);
    }

    return .{
        .logical = target.logical,
        .x11 = .{
            .x = roundI32(@as(f64, @floatFromInt(@as(i64, target.logical.x) - min_x)) * layout_scale),
            .y = roundI32(@as(f64, @floatFromInt(@as(i64, target.logical.y) - min_y)) * layout_scale),
            .width = if (mode == .native) target.physical_width else target.logical.width,
            .height = if (mode == .native) target.physical_height else target.logical.height,
        },
        .scale = if (mode == .native) target.scale else 1,
    };
}

/// X11 window positions are signed 16-bit coordinates. Validate the translated
/// desktop, including every head affected by a change in origin or scale.
pub fn layoutValid(outputs: []const Output, mode: Mode) bool {
    for (outputs, 0..) |_, index| {
        const box = project(outputs, index, mode).x11;
        if (box.x < 0 or box.y < 0 or box.width <= 0 or box.height <= 0 or
            @as(i64, box.x) + box.width > std.math.maxInt(i16) or
            @as(i64, box.y) + box.height > std.math.maxInt(i16)) return false;
    }
    return true;
}

fn roundI32(value: f64) i32 {
    return @intFromFloat(std.math.clamp(@round(value), @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

fn clampU16(value: f64) u16 {
    return @intFromFloat(std.math.clamp(@round(value), 1, std.math.maxInt(u16)));
}

test "native projection maps logical size to physical pixels" {
    const outputs = [_]Output{.{
        .logical = .{ .x = 0, .y = 0, .width = 2048, .height = 1152 },
        .physical_width = 2560,
        .physical_height = 1440,
        .scale = 1.25,
    }};
    const projection = project(&outputs, 0, .native);
    try std.testing.expectEqual(@as(i32, 2560), projection.x11.width);
    try std.testing.expectEqual(@as(u16, 1250), projection.logicalToX11Size(1000, 600)[0]);
    try std.testing.expectEqual(@as(u16, 750), projection.logicalToX11Size(1000, 600)[1]);
    try std.testing.expectEqual(@as(u31, 1000), projection.x11ToLogicalSize(1250, 750)[0]);
    try std.testing.expectEqual(@as(u31, 600), projection.x11ToLogicalSize(1250, 750)[1]);
}

test "mixed scale projection never overlaps horizontally adjacent outputs" {
    const outputs = [_]Output{
        .{
            .logical = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
            .physical_width = 1920,
            .physical_height = 1080,
            .scale = 1,
        },
        .{
            .logical = .{ .x = 1920, .y = 0, .width = 1707, .height = 960 },
            .physical_width = 2560,
            .physical_height = 1440,
            .scale = 1.5,
        },
    };
    const left = project(&outputs, 0, .native);
    const right = project(&outputs, 1, .native);
    try std.testing.expect(left.x11.x + left.x11.width <= right.x11.x);
    try std.testing.expectEqual(@as(i32, 2880), right.x11.x);
}

test "point conversion is output local and round trips" {
    const outputs = [_]Output{.{
        .logical = .{ .x = 100, .y = 40, .width = 800, .height = 600 },
        .physical_width = 1200,
        .physical_height = 900,
        .scale = 1.5,
    }};
    const projection = project(&outputs, 0, .native);
    const x, const y = projection.logicalToX11Point(300, 140);
    try std.testing.expectEqual(@as(i32, 300), x);
    try std.testing.expectEqual(@as(i32, 150), y);
    const lx, const ly = projection.x11ToLogicalPoint(x, y);
    try std.testing.expectApproxEqAbs(@as(f64, 300), lx, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 140), ly, 0.000001);
}

test "portrait output above the origin retains rotation geometry and X11 input coordinates" {
    const outputs = [_]Output{
        .{ .logical = .{ .x = 0, .y = 0, .width = 3840, .height = 1600 }, .physical_width = 3840, .physical_height = 1600, .scale = 1 },
        .{ .logical = .{ .x = 3880, .y = -920, .width = 1440, .height = 3440 }, .physical_width = 1440, .physical_height = 3440, .scale = 1 },
    };
    inline for (.{ Mode.legacy, Mode.native }) |mode| {
        try std.testing.expect(layoutValid(&outputs, mode));
        try std.testing.expectEqual(@as(i32, 920), project(&outputs, 0, mode).x11.y);
        const portrait = project(&outputs, 1, mode);
        try std.testing.expectEqual(Rect{ .x = 3880, .y = 0, .width = 1440, .height = 3440 }, portrait.x11);
        const x, const y = portrait.logicalToX11Point(3980, -820);
        try std.testing.expectEqual(@as(i32, 3980), x);
        try std.testing.expectEqual(@as(i32, 100), y);
        const lx, const ly = portrait.x11ToLogicalPoint(x, y);
        try std.testing.expectEqual(@as(f64, 3980), lx);
        try std.testing.expectEqual(@as(f64, -820), ly);
    }
}

test "legacy translation preserves logical sizes and positive origins at fractional scale" {
    var outputs = [_]Output{
        .{ .logical = .{ .x = 100, .y = 40, .width = 800, .height = 600 }, .physical_width = 1200, .physical_height = 900, .scale = 1.5 },
    };
    const positive = project(&outputs, 0, .legacy);
    try std.testing.expectEqual(outputs[0].logical, positive.x11);
    try std.testing.expectEqual(@as(f64, 1), positive.scale);
    outputs[0].logical.x = -800;
    outputs[0].logical.y = -600;
    const negative = project(&outputs, 0, .legacy);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 800, .height = 600 }, negative.x11);
    const x, const y = negative.logicalToX11Point(-700, -500);
    try std.testing.expectEqual(@as(i32, 100), x);
    try std.testing.expectEqual(@as(i32, 100), y);
}

test "coordinate limits apply to the whole translated and scaled desktop without overflow" {
    var outputs = [_]Output{
        .{ .logical = .{ .x = -16000, .y = 0, .width = 1000, .height = 600 }, .physical_width = 2000, .physical_height = 1200, .scale = 2 },
        .{ .logical = .{ .x = 15767, .y = 0, .width = 1000, .height = 600 }, .physical_width = 1000, .physical_height = 600, .scale = 1 },
    };
    try std.testing.expect(layoutValid(&outputs, .legacy));
    try std.testing.expect(!layoutValid(&outputs, .native));
    outputs[1].logical.x += 1;
    try std.testing.expect(!layoutValid(&outputs, .legacy));
    outputs[0].logical.x = std.math.minInt(i32);
    outputs[1].logical.x = std.math.maxInt(i32) - 1000;
    inline for (.{ Mode.legacy, Mode.native }) |mode| try std.testing.expect(!layoutValid(&outputs, mode));
}
