// SPDX-License-Identifier: GPL-3.0-only
//! Shared admission and observation policy. Physical production qualification
//! stays closed; selected feature groups can run in isolated acceptance builds.
const std = @import("std");
pub const Backend = enum { headless, drm, unsupported };
pub const Feature = enum { sdr, hdr, vrr, hdr_vrr, auto_hdr, mirroring, custom_mode };
pub const Features = std.EnumSet(Feature);
pub const State = struct {
    hdr: bool = false,
    vrr: bool = false,
    auto_hdr: bool = false,
    hdr_level: u16 = 1000,
    sdr_white_level: f64 = 200,
    auto_hdr_boost: f64 = 0.5,
};
pub const Requirements = struct {
    preserve: Features = .initEmpty(),
    transition: Features = .initEmpty(),

    pub fn include(self: *Requirements, before: State, after: State) void {
        self.preserve.insert(.sdr);
        if (before.hdr or after.hdr) self.preserve.insert(.hdr);
        if (before.vrr or after.vrr) self.preserve.insert(.vrr);
        if (before.auto_hdr or after.auto_hdr) {
            self.preserve.insert(.auto_hdr);
            self.preserve.insert(.hdr);
        }
        if (before.hdr != after.hdr or before.hdr_level != after.hdr_level or before.sdr_white_level != after.sdr_white_level) self.transition.insert(.hdr);
        if (before.vrr != after.vrr) self.transition.insert(.vrr);
        if (before.auto_hdr != after.auto_hdr or before.auto_hdr_boost != after.auto_hdr_boost) {
            self.transition.insert(.auto_hdr);
            self.preserve.insert(.hdr);
        }
        self.close();
    }
    pub fn merge(self: *Requirements, other: Requirements) void {
        self.preserve.setUnion(other.preserve);
        self.transition.setUnion(other.transition);
        self.close();
    }
    fn close(self: *Requirements) void {
        var all = self.preserve;
        all.setUnion(self.transition);
        if (all.contains(.hdr) and all.contains(.vrr)) {
            self.preserve.insert(.hdr_vrr);
            if (self.transition.contains(.hdr) or self.transition.contains(.vrr)) self.transition.insert(.hdr_vrr);
        }
    }
    pub fn contains(self: Requirements, feature: Feature) bool {
        return self.preserve.contains(feature) or self.transition.contains(feature);
    }
};
pub const Selection = struct {
    features: Features = .initOne(.sdr),
    valid: bool = true,
    pub fn parse(list: ?[]const u8) Selection {
        const text = list orelse return .{};
        var result: Selection = .{};
        var names = std.mem.splitScalar(u8, text, ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            const feature = std.meta.stringToEnum(Feature, name) orelse return .{ .valid = false };
            if (feature == .mirroring or feature == .custom_mode) return .{ .valid = false };
            result.features.insert(feature);
            if (feature == .hdr_vrr) {
                result.features.insert(.hdr);
                result.features.insert(.vrr);
            }
            if (feature == .auto_hdr) result.features.insert(.hdr);
        }
        return result;
    }
};
pub const Reason = enum {
    mode_not_advertised,
    preview_backend_unsupported,
    hdr_unsupported,
    vrr_unsupported,
    hardware_acceptance_pending,
    hdr_hardware_acceptance_pending,
    vrr_hardware_acceptance_pending,
    hdr_vrr_hardware_acceptance_pending,
    auto_hdr_hardware_acceptance_pending,
    mirroring_hardware_acceptance_pending,
    custom_mode_hardware_acceptance_pending,
    mirroring_renderer_unsupported,
    acceptance_output_not_selected,
    acceptance_features_invalid,
    hdr_acceptance_not_selected,
    vrr_acceptance_not_selected,
    hdr_vrr_acceptance_not_selected,
    auto_hdr_acceptance_not_selected,
};
pub const Support = struct {
    status: enum { available, acceptance_only, pending_qualification, unsupported },
    reason: ?Reason = null,
    pub fn allowed(self: Support) bool {
        return self.status == .available or self.status == .acceptance_only;
    }
};
pub const Context = struct {
    backend: Backend,
    acceptance_build: bool = false,
    acceptance_output: bool = false,
    selection: Selection = .{},
    hdr_capable: bool = false,
    vrr_capable: bool = false,
    renderer_mirroring: bool = false,
};
pub fn support(ctx: Context, feature: Feature) Support {
    if (ctx.backend == .unsupported) return .{ .status = .unsupported, .reason = .preview_backend_unsupported };
    if ((feature == .hdr or feature == .hdr_vrr or feature == .auto_hdr) and !ctx.hdr_capable) return .{ .status = .unsupported, .reason = .hdr_unsupported };
    if ((feature == .vrr or feature == .hdr_vrr) and !ctx.vrr_capable) return .{ .status = .unsupported, .reason = .vrr_unsupported };
    if (ctx.backend == .headless) {
        if (feature == .mirroring and !ctx.renderer_mirroring) return .{ .status = .unsupported, .reason = .mirroring_renderer_unsupported };
        // Headless hardware flags cannot qualify HDR or adaptive sync.
        if (feature == .hdr or feature == .auto_hdr or feature == .hdr_vrr) return .{ .status = .unsupported, .reason = .hdr_unsupported };
        if (feature == .vrr) return .{ .status = .unsupported, .reason = .vrr_unsupported };
        return .{ .status = .available };
    }
    const pending: Reason = switch (feature) {
        .sdr => .hardware_acceptance_pending,
        .hdr => .hdr_hardware_acceptance_pending,
        .vrr => .vrr_hardware_acceptance_pending,
        .hdr_vrr => .hdr_vrr_hardware_acceptance_pending,
        .auto_hdr => .auto_hdr_hardware_acceptance_pending,
        .mirroring => .mirroring_hardware_acceptance_pending,
        .custom_mode => .custom_mode_hardware_acceptance_pending,
    };
    if (!ctx.acceptance_build or feature == .mirroring or feature == .custom_mode) return .{ .status = .pending_qualification, .reason = pending };
    if (!ctx.acceptance_output) return .{ .status = .pending_qualification, .reason = .acceptance_output_not_selected };
    if (!ctx.selection.valid) return .{ .status = .unsupported, .reason = .acceptance_features_invalid };
    if (!ctx.selection.features.contains(feature)) return .{ .status = .pending_qualification, .reason = switch (feature) {
        .hdr => .hdr_acceptance_not_selected,
        .vrr => .vrr_acceptance_not_selected,
        .hdr_vrr => .hdr_vrr_acceptance_not_selected,
        .auto_hdr => .auto_hdr_acceptance_not_selected,
        else => pending,
    } };
    return .{ .status = .acceptance_only };
}
pub fn rejection(ctx: Context, requirements: Requirements) ?Reason {
    // Capability errors are actionable even when production qualification is
    // closed. Do not hide them behind the general SDR acceptance gate.
    inline for (std.meta.tags(Feature)) |feature| {
        if (requirements.contains(feature)) {
            const result = support(ctx, feature);
            if (result.status == .unsupported) return result.reason;
        }
    }
    inline for (std.meta.tags(Feature)) |feature| {
        if (requirements.contains(feature)) if (support(ctx, feature).reason) |why| return why;
    }
    return null;
}
pub fn failure(why: Reason) anyerror {
    inline for (std.meta.fields(Reason)) |field| {
        if (why == @field(Reason, field.name)) return @field(anyerror, field.name);
    }
    unreachable;
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
test "acceptance selection is explicit and combination groups have dependencies" {
    try std.testing.expect(Selection.parse(null).features.eql(Features.initOne(.sdr)));
    for ([_][]const u8{ "", "hdr,", "*", "mirroring", "custom_mode", "bogus" }) |text| try std.testing.expect(!Selection.parse(text).valid);
    const combined = Selection.parse("hdr_vrr,auto_hdr");
    inline for (.{ Feature.sdr, Feature.hdr, Feature.vrr, Feature.hdr_vrr, Feature.auto_hdr }) |feature| try std.testing.expect(combined.features.contains(feature));
    try std.testing.expect(!Selection.parse("hdr,vrr").features.contains(.hdr_vrr));
    try std.testing.expect(selected("DP-1,HDMI-A-1", "DP-1"));
    try std.testing.expect(!selected("DP-10,*", "DP-1"));
}
test "preservation transitions and mixed outputs require combined qualification" {
    var req: Requirements = .{};
    req.include(.{ .hdr = true }, .{ .hdr = true });
    try std.testing.expect(req.preserve.contains(.hdr));
    try std.testing.expect(!req.transition.contains(.hdr));
    req.include(.{}, .{ .vrr = true });
    try std.testing.expect(req.preserve.contains(.hdr_vrr));
    try std.testing.expect(req.transition.contains(.hdr_vrr));
    var metadata: Requirements = .{};
    metadata.include(.{}, .{ .hdr_level = 400, .auto_hdr_boost = 0.7 });
    try std.testing.expect(metadata.transition.contains(.hdr));
    try std.testing.expect(metadata.transition.contains(.auto_hdr));
    req.merge(metadata);
    try std.testing.expect(req.contains(.auto_hdr));
}
test "hardware support is separate from acceptance and production stays gated" {
    var ctx: Context = .{ .backend = .drm, .hdr_capable = true, .vrr_capable = true, .acceptance_output = true, .selection = Selection.parse("hdr_vrr,auto_hdr") };
    inline for (std.meta.tags(Feature)) |feature| try std.testing.expect(!support(ctx, feature).allowed());
    ctx.acceptance_build = true;
    inline for (.{ Feature.sdr, Feature.hdr, Feature.vrr, Feature.hdr_vrr, Feature.auto_hdr }) |feature| try std.testing.expect(support(ctx, feature).allowed());
    try std.testing.expect(!support(ctx, .mirroring).allowed());
    ctx.selection = Selection.parse("hdr,vrr");
    try std.testing.expectEqual(Reason.hdr_vrr_acceptance_not_selected, support(ctx, .hdr_vrr).reason.?);
    ctx.vrr_capable = false;
    try std.testing.expectEqual(Reason.vrr_unsupported, support(ctx, .vrr).reason.?);
    ctx.hdr_capable = false;
    try std.testing.expectEqual(Reason.hdr_unsupported, support(ctx, .hdr).reason.?);
    ctx.backend = .headless;
    try std.testing.expect(support(ctx, .sdr).allowed());
    try std.testing.expect(!support(ctx, .hdr).allowed());
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

test "both directions require feature selection and every participating connector" {
    const enabled: State = .{ .hdr = true, .vrr = true, .auto_hdr = true };
    for ([_][2]State{ .{ .{}, enabled }, .{ enabled, .{} }, .{ enabled, enabled } }) |pair| {
        var req: Requirements = .{};
        req.include(pair[0], pair[1]);
        var ctx: Context = .{ .backend = .drm, .acceptance_build = true, .acceptance_output = true, .hdr_capable = true, .vrr_capable = true };
        try std.testing.expectEqual(Reason.hdr_acceptance_not_selected, rejection(ctx, req).?);
        ctx.selection = Selection.parse("hdr,vrr,auto_hdr");
        try std.testing.expectEqual(Reason.hdr_vrr_acceptance_not_selected, rejection(ctx, req).?);
        ctx.selection = Selection.parse("hdr_vrr,auto_hdr");
        try std.testing.expectEqual(null, rejection(ctx, req));
        ctx.acceptance_output = false;
        try std.testing.expectEqual(Reason.acceptance_output_not_selected, rejection(ctx, req).?);
        ctx.acceptance_output = true;
        ctx.selection = Selection.parse("hdr,typo");
        try std.testing.expectEqual(Reason.acceptance_features_invalid, rejection(ctx, req).?);
    }
}

test "an SDR companion does not need HDR capability but shares group qualification" {
    var sdr: Requirements = .{};
    sdr.include(.{}, .{});
    const ctx: Context = .{ .backend = .drm, .acceptance_build = true, .acceptance_output = true, .selection = Selection.parse("hdr") };
    try std.testing.expectEqual(null, rejection(ctx, sdr));
    var hdr: Requirements = .{};
    hdr.include(.{ .hdr = true }, .{ .hdr = true, .sdr_white_level = 400 });
    try std.testing.expectEqual(Reason.hdr_unsupported, rejection(ctx, hdr).?);
    var capable = ctx;
    capable.hdr_capable = true;
    try std.testing.expectEqual(null, rejection(capable, hdr));
    capable.acceptance_build = false;
    capable.hdr_capable = false;
    try std.testing.expectEqual(Reason.hdr_unsupported, rejection(capable, hdr).?);
}
