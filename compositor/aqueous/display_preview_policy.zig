// SPDX-License-Identifier: GPL-3.0-only
//! Production hardware acceptance is deliberately empty. The isolated test
//! build can exercise SDR DRM paths without advertising hardware acceptance.
const std = @import("std");
pub const Backend = enum { headless, drm, unsupported };
pub const Feature = enum { sdr, hdr, vrr, mirroring, custom_mode };
pub fn reason(backend: Backend, feature: Feature, acceptance_output: bool, renderer_mirroring: bool) ?[]const u8 {
    if (backend == .unsupported) return "preview_backend_unsupported";
    if (feature == .hdr) return "hdr_hardware_acceptance_pending";
    if (feature == .vrr) return "vrr_hardware_acceptance_pending";
    if (backend == .drm) {
        if (feature == .mirroring) return "mirroring_hardware_acceptance_pending";
        if (feature == .custom_mode) return "custom_mode_hardware_acceptance_pending";
        return if (acceptance_output) null else "hardware_acceptance_pending";
    }
    if (feature == .mirroring and !renderer_mirroring) return "mirroring_renderer_unsupported";
    return null;
}
pub fn selected(list: []const u8, connector: []const u8) bool {
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |name| if (name.len != 0 and std.mem.eql(u8, name, connector)) return true;
    return false;
}
pub const Completion = struct {
    baseline: u32,
    presented: bool = false,
    rejected: bool = false,
    pub fn observe(self: *Completion, sequence: u32, success: bool) void {
        const distance = sequence -% self.baseline;
        if (distance == 0 or distance >= 0x80000000) return;
        self.presented = self.presented or success;
        self.rejected = self.rejected or !success;
    }
};
test "hardware groups remain separately gated, acceptance selects exact outputs" {
    try std.testing.expect(reason(.drm, .sdr, false, true) != null);
    try std.testing.expect(reason(.drm, .sdr, true, true) == null);
    for ([_]Feature{ .hdr, .vrr, .mirroring, .custom_mode }) |feature|
        try std.testing.expect(reason(.drm, feature, true, true) != null);
    try std.testing.expect(reason(.unsupported, .sdr, true, true) != null);
    try std.testing.expect(reason(.headless, .mirroring, false, false) != null);
    try std.testing.expect(reason(.headless, .sdr, false, false) == null);
    try std.testing.expect(selected("DP-1,HDMI-A-1", "DP-1"));
    try std.testing.expect(!selected("DP-10,HDMI-A-1", "DP-1"));
    try std.testing.expect(!selected("*", "DP-1"));
}
test "completion excludes old and equal sequences, handles wrap and rejected presents" {
    var c: Completion = .{ .baseline = std.math.maxInt(u32) };
    c.observe(c.baseline, true);
    c.observe(c.baseline - 1, false);
    try std.testing.expect(!c.presented and !c.rejected);
    c.observe(0, true);
    try std.testing.expect(c.presented);
    c.observe(1, false);
    try std.testing.expect(c.rejected);
}
