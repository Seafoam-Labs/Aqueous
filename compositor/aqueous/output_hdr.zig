// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! HDR10 output profiles used by Aqueous.
//!
//! wlroots performs the scene conversion from its linear working space to
//! BT.2020/PQ when the output image description is committed. The DRM backend
//! then programs the connector Colorspace, HDR_OUTPUT_METADATA, and max-bpc
//! properties. A 10-bit primary buffer is required for the latter.
//!
//! The static mastering metadata is parameterized by an HDR level (the target
//! peak luminance in cd/m²) so the InfoFrame matches the connected display.
//! The Aqueous wlroots patch additionally carries an SDR white level used by
//! scene composition to place SDR diffuse white on HDR outputs, and exposes
//! the EDID CTA-861 desired-content luminances for automatic level selection.

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

/// Target peak luminance presets for the HDR10 output profile. The values
/// follow the VESA DisplayHDR tiers that matter in practice; 100 cd/m² is a
/// conservative preset for displays without meaningful HDR headroom.
pub const HdrLevel = enum(u16) {
    l100 = 100,
    l400 = 400,
    l1000 = 1000,

    pub fn parse(value: []const u8) ?HdrLevel {
        if (std.mem.eql(u8, value, "100")) return .l100;
        if (std.mem.eql(u8, value, "400")) return .l400;
        if (std.mem.eql(u8, value, "1000")) return .l1000;
        return null;
    }

    pub fn nits(level: HdrLevel) u16 {
        return @intFromEnum(level);
    }

    pub fn name(level: HdrLevel) []const u8 {
        return switch (level) {
            .l100 => "100",
            .l400 => "400",
            .l1000 => "1000",
        };
    }
};

/// SDR diffuse white on an HDR output, in cd/m². 200 is close to the 203
/// cd/m² reference white wlroots uses internally and to common SDR-on-HDR
/// defaults elsewhere. The patched wlroots scene scales relative-luminance
/// content to this level; absolute-luminance PQ content is unaffected.
pub const default_sdr_white_level: f64 = 200.0;
pub const min_sdr_white_level: f64 = 80.0;
pub const max_sdr_white_level: f64 = 1000.0;

/// Mirror of the patched `struct wlr_output_image_description` including the
/// Aqueous-added trailing `sdr_white_level` field. wlroots copies the struct
/// when it is committed, so passing this extended layout is required.
pub const ImageDescription = extern struct {
    primaries: wlr.color.NamedPrimaries,
    transfer_function: wlr.color.TransferFunction,
    mastering_display_primaries: wlr.color.Primaries,
    mastering_luminance: extern struct {
        min: f64,
        max: f64,
    },
    max_cll: f64,
    max_fall: f64,
    sdr_white_level: f64,
};

/// Aqueous patch addition to wlroots: desired-content luminances parsed from
/// the connector EDID CTA-861 HDR static metadata block, in cd/m².
pub const EdidHdrStaticMetadata = extern struct {
    max_luminance: f64,
    max_frame_avg_luminance: f64,
    min_luminance: f64,
};

extern fn wlr_output_get_primary_formats(
    output: *wlr.Output,
    buffer_caps: u32,
) ?*const wlr.DrmFormatSet;

extern fn wlr_output_state_set_image_description(
    state: *wlr.Output.State,
    image_description: ?*const ImageDescription,
) bool;

extern fn wlr_output_get_edid_hdr_static_metadata(
    output: *wlr.Output,
) *const EdidHdrStaticMetadata;

/// Static mastering metadata for one HDR level. Mastering primaries stay
/// BT.2020; only the luminance envelope follows the level. Max FALL remains
/// at or below the peak so the InfoFrame is internally consistent.
pub fn imageDescription(level: HdrLevel, sdr_white_level: f64) ImageDescription {
    const peak: f64 = @floatFromInt(level.nits());
    const max_fall: f64 = switch (level) {
        .l100 => 50.0,
        .l400 => 200.0,
        .l1000 => 400.0,
    };
    return .{
        .primaries = .bt2020,
        .transfer_function = .st2084_pq,
        .mastering_display_primaries = .{
            .red = .{ .x = 0.708, .y = 0.292 },
            .green = .{ .x = 0.170, .y = 0.797 },
            .blue = .{ .x = 0.131, .y = 0.046 },
            .white = .{ .x = 0.3127, .y = 0.3290 },
        },
        .mastering_luminance = .{ .min = 0.005, .max = peak },
        .max_cll = peak,
        .max_fall = max_fall,
        .sdr_white_level = sdr_white_level,
    };
}

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

/// Pick the level nearest the display's desired-content peak luminance.
/// Returns null when the display advertised no usable luminance. Ties round
/// toward the lower level so metadata never overstates the panel.
pub fn pickAutoLevel(desired_max_luminance: f64, desired_max_frame_avg_luminance: f64) ?HdrLevel {
    const peak = if (desired_max_luminance > 0) desired_max_luminance else desired_max_frame_avg_luminance;
    if (peak <= 0) return null;
    if (peak <= 250.0) return .l100;
    if (peak <= 700.0) return .l400;
    return .l1000;
}

/// Resolve `hdr_level = "auto"` from the EDID CTA-861 HDR static metadata.
/// Non-DRM outputs and displays without metadata return null.
pub fn autoLevel(output: *wlr.Output) ?HdrLevel {
    if (!output.isDrm()) return null;
    const metadata = wlr_output_get_edid_hdr_static_metadata(output);
    return pickAutoLevel(metadata.max_luminance, metadata.max_frame_avg_luminance);
}

/// The EDID desired-content max luminance in cd/m², or null when unknown.
pub fn edidDesiredMaxLuminance(output: *wlr.Output) ?f64 {
    if (!output.isDrm()) return null;
    const metadata = wlr_output_get_edid_hdr_static_metadata(output);
    if (metadata.max_luminance <= 0) return null;
    return metadata.max_luminance;
}

pub fn stateMatches(output: *wlr.Output, requested: bool, level: HdrLevel, sdr_white_level: f64) bool {
    if (requested) {
        const format = selectRenderFormat(output) orelse return false;
        if (output.render_format != format) return false;
        const description = output.image_description orelse return false;
        if (description.primaries != .bt2020 or description.transfer_function != .st2084_pq) return false;
        // The committed description is the patched C struct; reinterpret it
        // to reach the Aqueous-added fields for the comparison.
        const committed: *const ImageDescription = @ptrCast(@alignCast(description));
        const expected = imageDescription(level, sdr_white_level);
        return committed.mastering_luminance.max == expected.mastering_luminance.max and
            committed.max_cll == expected.max_cll and
            committed.max_fall == expected.max_fall and
            committed.sdr_white_level == expected.sdr_white_level;
    }
    return output.image_description == null and output.render_format == sdr_render_format;
}

/// Add all color and pixel-format state needed for one atomic output commit.
/// The image description setter allocates a copy and can fail.
pub fn apply(output: *wlr.Output, enabled: bool, level: HdrLevel, sdr_white_level: f64, state: *wlr.Output.State) bool {
    if (enabled) {
        const format = selectRenderFormat(output) orelse return false;
        state.setRenderFormat(format);
        var description = imageDescription(level, sdr_white_level);
        return wlr_output_state_set_image_description(state, &description);
    }
    // Preserve the backend's untouched SDR state on initial modesets. Some
    // nested backends don't accept an explicit color-description commit even
    // when it merely restates their default.
    if (stateMatches(output, false, level, sdr_white_level)) return true;
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

test "HDR levels parse from their nit names" {
    try std.testing.expectEqual(HdrLevel.l100, HdrLevel.parse("100").?);
    try std.testing.expectEqual(HdrLevel.l400, HdrLevel.parse("400").?);
    try std.testing.expectEqual(HdrLevel.l1000, HdrLevel.parse("1000").?);
    try std.testing.expect(HdrLevel.parse("600") == null);
    try std.testing.expect(HdrLevel.parse("auto") == null);
    try std.testing.expectEqualStrings("400", HdrLevel.l400.name());
    try std.testing.expectEqual(@as(u16, 1000), HdrLevel.l1000.nits());
}

test "image descriptions follow the level envelope" {
    const l100 = imageDescription(.l100, 200.0);
    try std.testing.expectEqual(@as(f64, 100.0), l100.mastering_luminance.max);
    try std.testing.expectEqual(@as(f64, 100.0), l100.max_cll);
    try std.testing.expectEqual(@as(f64, 50.0), l100.max_fall);
    try std.testing.expectEqual(@as(f64, 0.005), l100.mastering_luminance.min);
    try std.testing.expectEqual(@as(f64, 200.0), l100.sdr_white_level);

    const l400 = imageDescription(.l400, 150.0);
    try std.testing.expectEqual(@as(f64, 400.0), l400.mastering_luminance.max);
    try std.testing.expectEqual(@as(f64, 200.0), l400.max_fall);
    try std.testing.expectEqual(@as(f64, 150.0), l400.sdr_white_level);

    const l1000 = imageDescription(.l1000, default_sdr_white_level);
    try std.testing.expectEqual(@as(f64, 1000.0), l1000.mastering_luminance.max);
    try std.testing.expectEqual(@as(f64, 1000.0), l1000.max_cll);
    try std.testing.expectEqual(@as(f64, 400.0), l1000.max_fall);

    for ([_]ImageDescription{ l100, l400, l1000 }) |description| {
        try std.testing.expectEqual(wlr.color.NamedPrimaries.bt2020, description.primaries);
        try std.testing.expectEqual(wlr.color.TransferFunction.st2084_pq, description.transfer_function);
        try std.testing.expect(description.max_fall <= description.max_cll);
    }
}

test "auto level picks the nearest preset to the EDID peak" {
    try std.testing.expect(pickAutoLevel(0, 0) == null);
    try std.testing.expectEqual(HdrLevel.l100, pickAutoLevel(150.0, 0).?);
    try std.testing.expectEqual(HdrLevel.l100, pickAutoLevel(250.0, 0).?);
    try std.testing.expectEqual(HdrLevel.l400, pickAutoLevel(251.0, 0).?);
    try std.testing.expectEqual(HdrLevel.l400, pickAutoLevel(400.0, 0).?);
    try std.testing.expectEqual(HdrLevel.l400, pickAutoLevel(600.0, 0).?);
    try std.testing.expectEqual(HdrLevel.l400, pickAutoLevel(700.0, 0).?);
    try std.testing.expectEqual(HdrLevel.l1000, pickAutoLevel(701.0, 0).?);
    try std.testing.expectEqual(HdrLevel.l1000, pickAutoLevel(1500.0, 0).?);
    // The frame-average value is a fallback when no peak is advertised.
    try std.testing.expectEqual(HdrLevel.l400, pickAutoLevel(0, 400.0).?);
}
