// SPDX-License-Identifier: GPL-3.0-only

//! Default transform for built-in panels that are mounted rotated relative to
//! the device chassis (handhelds and pocket laptops with tablet panels).
//!
//! The kernel's DRM "panel orientation" connector property is preferred. Some
//! devices are missing from the kernel quirk table, so a small DMI table below
//! covers them. Explicit output configuration always overrides this default.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;

const Quirk = struct {
    sys_vendor: []const u8,
    product_name: []const u8,
    transform: wl.Output.Transform,
};

/// Devices whose panels are mounted right-side-up (DRM_MODE_PANEL_ORIENTATION_RIGHT_UP)
/// but which the kernel does not report.
const quirks = [_]Quirk{
    .{ .sys_vendor = "GPD", .product_name = "G1621-02", .transform = .@"270" }, // GPD Pocket 3
    .{ .sys_vendor = "GPD", .product_name = "G1628-04", .transform = .@"270" }, // GPD Pocket 4
};

pub fn lookup(sys_vendor: []const u8, product_name: []const u8) ?wl.Output.Transform {
    for (quirks) |quirk| {
        if (std.mem.eql(u8, quirk.sys_vendor, sys_vendor) and
            std.mem.eql(u8, quirk.product_name, product_name)) return quirk.transform;
    }
    return null;
}

/// Connector names of panels built into the device.
pub fn isInternalConnector(name: []const u8) bool {
    for ([_][]const u8{ "eDP-", "DSI-", "LVDS-" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

var dmi_cache: ?(?wl.Output.Transform) = null;

/// Quirk transform for the running machine, read once from sysfs.
pub fn dmiTransform() ?wl.Output.Transform {
    if (dmi_cache) |cached| return cached;
    var vendor_buf: [64]u8 = undefined;
    var product_buf: [64]u8 = undefined;
    const vendor = readDmi("sys_vendor", &vendor_buf);
    const product = readDmi("product_name", &product_buf);
    const result = if (vendor != null and product != null) lookup(vendor.?, product.?) else null;
    dmi_cache = result;
    return result;
}

fn readDmi(comptime field: []const u8, buf: []u8) ?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFile(io, "/sys/class/dmi/id/" ++ field, buf) catch return null;
    return std.mem.trim(u8, data, " \t\r\n");
}

test "GPD Pocket 3 and 4 panels rotate to landscape" {
    try std.testing.expectEqual(wl.Output.Transform.@"270", lookup("GPD", "G1621-02").?);
    try std.testing.expectEqual(wl.Output.Transform.@"270", lookup("GPD", "G1628-04").?);
    try std.testing.expect(lookup("GPD", "G1619-01") == null);
    try std.testing.expect(lookup("Framework", "Laptop 13") == null);
}

test "only built-in connectors receive the quirk" {
    try std.testing.expect(isInternalConnector("eDP-1"));
    try std.testing.expect(isInternalConnector("DSI-1"));
    try std.testing.expect(!isInternalConnector("HDMI-A-1"));
    try std.testing.expect(!isInternalConnector("DP-1"));
}
