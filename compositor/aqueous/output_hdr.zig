// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Fixed HDR10 output profile used by Aqueous.
//!
//! wlroots performs the scene conversion from its linear working space to
//! BT.2020/PQ when the output image description is committed. The DRM backend
//! then programs the connector Colorspace, HDR_OUTPUT_METADATA, and max-bpc
//! properties. A 10-bit primary buffer is required for the latter.

const std = @import("std");
const wlr = @import("wlroots");

fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) |
        (@as(u32, b) << 8) |
        (@as(u32, c) << 16) |
        (@as(u32, d) << 24);
}

pub const sdr_render_format = fourcc('X', 'R', '2', '4'); // DRM_FORMAT_XRGB8888
pub const hdr_render_formats = [_]u32{
    fourcc('X', 'B', '3', '0'), // DRM_FORMAT_XBGR2101010
    fourcc('X', 'R', '3', '0'), // DRM_FORMAT_XRGB2101010
};

/// A conservative fixed mastering profile for the first HDR10 implementation.
/// Per-surface metadata and display-specific tone mapping can replace this once
/// the color-management protocol exposes all required metadata end-to-end.
pub const hdr10_image_description: wlr.Output.ImageDescription = .{
    .primaries = .bt2020,
    .transfer_function = .st2084_pq,
    .mastering_display_primaries = .{
        .red = .{ .x = 0.708, .y = 0.292 },
        .green = .{ .x = 0.170, .y = 0.797 },
        .blue = .{ .x = 0.131, .y = 0.046 },
        .white = .{ .x = 0.3127, .y = 0.3290 },
    },
    .mastering_luminance = .{ .min = 0.005, .max = 1000.0 },
    .max_cll = 1000.0,
    .max_fall = 400.0,
};

extern fn wlr_output_get_primary_formats(
    output: *wlr.Output,
    buffer_caps: u32,
) ?*const wlr.DrmFormatSet;

extern fn wlr_output_state_set_image_description(
    state: *wlr.Output.State,
    image_description: ?*const wlr.Output.ImageDescription,
) bool;

fn hasFlag(mask: u32, flag: c_int) bool {
    return mask & @as(u32, @intCast(flag)) != 0;
}

pub fn supportsHdrColors(supported_primaries: u32, supported_transfer_functions: u32) bool {
    return hasFlag(supported_primaries, @intFromEnum(wlr.color.NamedPrimaries.bt2020)) and
        hasFlag(supported_transfer_functions, @intFromEnum(wlr.color.TransferFunction.st2084_pq));
}

pub fn selectFormatFromSet(formats: ?*const wlr.DrmFormatSet) ?u32 {
    // A null set means that the backend imposes no primary-format constraint.
    const set = formats orelse return hdr_render_formats[0];
    for (hdr_render_formats) |candidate| {
        for (set.formats[0..set.len]) |format| {
            if (format.format == candidate) return candidate;
        }
    }
    return null;
}

pub fn selectRenderFormat(output: *wlr.Output) ?u32 {
    if (!output.isDrm()) return null;
    const renderer = output.renderer orelse return null;
    if (!renderer.features.output_color_transform) return null;
    if (!supportsHdrColors(output.supported_primaries, output.supported_transfer_functions)) return null;
    const allocator = output.allocator orelse return null;
    return selectFormatFromSet(wlr_output_get_primary_formats(output, allocator.buffer_caps));
}

pub fn capable(output: *wlr.Output) bool {
    return selectRenderFormat(output) != null;
}

pub fn active(output: *const wlr.Output) bool {
    if (!output.enabled) return false;
    const description = output.image_description orelse return false;
    if (description.primaries != .bt2020 or description.transfer_function != .st2084_pq) return false;
    for (hdr_render_formats) |format| if (output.render_format == format) return true;
    return false;
}

pub fn stateMatches(output: *wlr.Output, requested: bool) bool {
    if (requested) {
        const format = selectRenderFormat(output) orelse return false;
        return active(output) and output.render_format == format;
    }
    return output.image_description == null and output.render_format == sdr_render_format;
}

/// Add all color and pixel-format state needed for one atomic output commit.
/// The image description setter allocates a copy and can fail.
pub fn apply(output: *wlr.Output, enabled: bool, state: *wlr.Output.State) bool {
    if (enabled) {
        const format = selectRenderFormat(output) orelse return false;
        state.setRenderFormat(format);
        return wlr_output_state_set_image_description(state, &hdr10_image_description);
    }
    // Preserve the backend's untouched SDR state on initial modesets. Some
    // nested backends don't accept an explicit color-description commit even
    // when it merely restates their default.
    if (stateMatches(output, false)) return true;
    state.setRenderFormat(sdr_render_format);
    return wlr_output_state_set_image_description(state, null);
}

pub fn formatName(format: u32, buffer: *[4]u8) []const u8 {
    for (buffer, 0..) |*byte, shift| byte.* = @truncate(format >> @intCast(shift * 8));
    return buffer;
}

test "HDR color capability requires BT.2020 and PQ" {
    const srgb: u32 = @intCast(@intFromEnum(wlr.color.NamedPrimaries.srgb));
    const bt2020: u32 = @intCast(@intFromEnum(wlr.color.NamedPrimaries.bt2020));
    const pq: u32 = @intCast(@intFromEnum(wlr.color.TransferFunction.st2084_pq));
    try std.testing.expect(!supportsHdrColors(srgb, pq));
    try std.testing.expect(!supportsHdrColors(bt2020, 0));
    try std.testing.expect(supportsHdrColors(bt2020, pq));
}

test "HDR format selection prefers XBGR2101010 and rejects 8-bit-only sets" {
    var supported = [_]wlr.DrmFormat{
        .{ .format = sdr_render_format, .len = 0, .capacity = 0, .modifiers = undefined },
        .{ .format = hdr_render_formats[1], .len = 0, .capacity = 0, .modifiers = undefined },
        .{ .format = hdr_render_formats[0], .len = 0, .capacity = 0, .modifiers = undefined },
    };
    const set: wlr.DrmFormatSet = .{
        .len = supported.len,
        .capacity = supported.len,
        .formats = &supported,
    };
    try std.testing.expectEqual(hdr_render_formats[0], selectFormatFromSet(&set).?);

    const eight_bit_only: wlr.DrmFormatSet = .{
        .len = 1,
        .capacity = 1,
        .formats = &supported,
    };
    try std.testing.expect(selectFormatFromSet(&eight_bit_only) == null);
    try std.testing.expectEqual(hdr_render_formats[0], selectFormatFromSet(null).?);
}

test "DRM format names are exposed as fourcc strings" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("XR24", formatName(sdr_render_format, &buffer));
    try std.testing.expectEqualStrings("XB30", formatName(hdr_render_formats[0], &buffer));
}
