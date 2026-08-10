// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Aqueous integration for the color-management-v1 Windows HDR extensions
//! carried by the downstream wlroots patch.

const std = @import("std");
const wayland = @import("wayland");
const wp = wayland.server.wp;
const wlr = @import("wlroots");

pub const windows_scrgb_bit: u32 = 1 << 0;
pub const windows_bt2100_bit: u32 = 1 << 1;

extern fn wlr_color_manager_v1_set_windows_hdr_features(
    manager: *wlr.ColorManagerV1,
    features: u32,
) void;

extern fn wlr_surface_has_windows_hdr_image_description(surface: *wlr.Surface) bool;

/// Return only the predefined Windows HDR descriptions which the renderer can
/// actually transform. Advertising is deliberately derived from the same
/// transfer-function and primaries lists passed to wlroots.
pub fn windowsHdrFeatureMask(
    transfer_functions: []const wp.ColorManagerV1.TransferFunction,
    primaries: []const wp.ColorManagerV1.Primaries,
) u32 {
    var has_ext_linear = false;
    var has_pq = false;
    for (transfer_functions) |transfer_function| switch (transfer_function) {
        .ext_linear => has_ext_linear = true,
        .st2084_pq => has_pq = true,
        else => {},
    };

    var has_srgb = false;
    var has_bt2020 = false;
    for (primaries) |primary| switch (primary) {
        .srgb => has_srgb = true,
        .bt2020 => has_bt2020 = true,
        else => {},
    };

    var mask: u32 = 0;
    if (has_ext_linear and has_srgb) mask |= windows_scrgb_bit;
    if (has_pq and has_bt2020) mask |= windows_bt2100_bit;
    return mask;
}

/// Enable the wlroots extensions immediately after creating the manager,
/// before the Wayland display starts accepting client connections.
pub fn enableWindowsHdr(manager: *wlr.ColorManagerV1, features: u32) void {
    wlr_color_manager_v1_set_windows_hdr_features(manager, features);
}

/// Native Windows scRGB and BT.2100 descriptions are already HDR-managed by
/// Wine/Proton and must never enter Aqueous's SDR Auto HDR expansion path.
pub fn surfaceHasWindowsHdrDescription(surface: *wlr.Surface) bool {
    return wlr_surface_has_windows_hdr_image_description(surface);
}

test "Windows HDR features require their complete color encoding" {
    const tfs = [_]wp.ColorManagerV1.TransferFunction{ .ext_linear, .st2084_pq };
    const primaries = [_]wp.ColorManagerV1.Primaries{ .srgb, .bt2020 };
    try std.testing.expectEqual(
        windows_scrgb_bit | windows_bt2100_bit,
        windowsHdrFeatureMask(&tfs, &primaries),
    );

    try std.testing.expectEqual(
        windows_scrgb_bit,
        windowsHdrFeatureMask(&.{.ext_linear}, &.{ .srgb, .bt2020 }),
    );
    try std.testing.expectEqual(
        windows_bt2100_bit,
        windowsHdrFeatureMask(&.{.st2084_pq}, &.{ .srgb, .bt2020 }),
    );
}

test "partial encodings are never advertised" {
    try std.testing.expectEqual(@as(u32, 0), windowsHdrFeatureMask(&.{.ext_linear}, &.{.bt2020}));
    try std.testing.expectEqual(@as(u32, 0), windowsHdrFeatureMask(&.{.st2084_pq}, &.{.srgb}));
    try std.testing.expectEqual(@as(u32, 0), windowsHdrFeatureMask(&.{}, &.{}));
}
