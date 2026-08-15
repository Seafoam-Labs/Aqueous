// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const wm = @import("../config/wm.zig");
const scaling = @import("scaling");

pub const max_outputs = 64;
pub const max_profiles = 16;
pub const max_profile_outputs = 32;
pub const Text = wm.Text;
pub const Transform = enum { normal, rotate_90, rotate_180, rotate_270, flipped, flipped_90, flipped_180, flipped_270 };
pub const Mode = struct { width: i32, height: i32, refresh_mhz: ?i32 = null };

/// Requested HDR peak-luminance preset. `auto` resolves against the EDID
/// CTA-861 desired-content luminances when the output applies.
pub const HdrLevelChoice = enum { auto, l100, l400, l1000 };

pub const Spec = struct {
    valid: bool = true,
    name: Text = .{},
    edid: Text = .{},
    enabled: ?bool = null,
    mode: ?Mode = null,
    scale: ?f32 = null,
    transform: ?Transform = null,
    x: ?i32 = null,
    y: ?i32 = null,
    adaptive_sync: ?bool = null,
    hdr: ?bool = null,
    hdr_level: ?HdrLevelChoice = null,
    /// SDR diffuse white luminance on the HDR output, in cd/m². Mirrors the
    /// 80–1000 range enforced by the compositor's output_hdr module.
    sdr_white_level: ?f64 = null,
    auto_hdr: ?bool = null,
    auto_hdr_boost: ?f64 = null,
    /// Preferred output for compositor actions which do not yet have an
    /// explicitly selected output. Optional so later matching specs can clear
    /// a wildcard/default declaration with `primary = false`.
    primary: ?bool = null,

    pub fn hasDisplayField(spec: *const Spec) bool {
        return spec.enabled != null or spec.mode != null or spec.scale != null or spec.transform != null or spec.x != null or spec.adaptive_sync != null or spec.hdr != null or spec.hdr_level != null or spec.sdr_white_level != null or spec.auto_hdr != null or spec.auto_hdr_boost != null;
    }
};

pub const Profile = struct {
    name: Text = .{},
    outputs: [max_profile_outputs]Spec = undefined,
    output_count: u8 = 0,
};

pub const Snapshot = struct {
    apply_on_start: bool = true,
    apply_on_start_set: bool = false,
    apply_on_reload: bool = true,
    apply_on_reload_set: bool = false,
    fallback_profile: Text = .{},
    fallback_profile_set: bool = false,
    identify_by: Text = defaultIdentifyBy(),
    identify_by_set: bool = false,
    rollback_seconds: u16 = 0,
    rollback_seconds_set: bool = false,
    /// True only when this source contains explicit top-level declarative
    /// output policy. Profiles alone are persisted state and intentionally do
    /// not opt a legacy wm.toml configuration into outputs.toml precedence.
    declarative: bool = false,
    outputs: [max_outputs]Spec = undefined,
    output_count: u8 = 0,
    profiles: [max_profiles]Profile = undefined,
    profile_count: u8 = 0,

    pub fn profile(snapshot: *const Snapshot, name: []const u8) ?*const Profile {
        for (snapshot.profiles[0..snapshot.profile_count]) |*entry| if (std.mem.eql(u8, entry.name.slice(), name)) return entry;
        return null;
    }
};

pub fn effectiveApplyOnStart(legacy: *const Snapshot, preferred: *const Snapshot) bool {
    if (preferred.declarative and preferred.apply_on_start_set) return preferred.apply_on_start;
    return legacy.apply_on_start;
}

pub fn effectiveApplyOnReload(legacy: *const Snapshot, preferred: *const Snapshot) bool {
    if (preferred.declarative and preferred.apply_on_reload_set) return preferred.apply_on_reload;
    return legacy.apply_on_reload;
}

pub fn effectiveFallbackProfile(legacy: *const Snapshot, preferred: *const Snapshot) []const u8 {
    if (preferred.declarative and preferred.fallback_profile_set) return preferred.fallback_profile.slice();
    return legacy.fallback_profile.slice();
}

pub fn effectiveProfile(legacy: *const Snapshot, preferred: *const Snapshot, name: []const u8) ?*const Profile {
    if (preferred.declarative) return preferred.profile(name) orelse legacy.profile(name);
    return legacy.profile(name) orelse preferred.profile(name);
}

/// Populate the specs in their fold order. In legacy mode this exactly retains
/// the previous all-or-nothing wm.toml fallback. After outputs.toml opts in,
/// wm.toml is the base and outputs.toml entries are later overrides.
pub fn configuredSpecs(legacy: *const Snapshot, preferred: *const Snapshot, destination: []Spec) []const Spec {
    var count: usize = 0;
    for (legacy.outputs[0..legacy.output_count]) |entry| if (entry.hasDisplayField()) {
        if (count == destination.len) return destination[0..count];
        destination[count] = entry;
        count += 1;
    };
    if (preferred.declarative) {
        for (preferred.outputs[0..preferred.output_count]) |entry| if (entry.hasDisplayField()) {
            if (count == destination.len) return destination[0..count];
            destination[count] = entry;
            count += 1;
        };
    } else if (count == 0) {
        for (preferred.outputs[0..preferred.output_count]) |entry| {
            if (count == destination.len) return destination[0..count];
            destination[count] = entry;
            count += 1;
        }
    }
    return destination[0..count];
}

fn defaultIdentifyBy() Text {
    var value: Text = .{};
    _ = value.set("edid");
    return value;
}

const Section = enum { none, display, output, profile, profile_output };

pub fn parse(source: []const u8) Snapshot {
    var snapshot: Snapshot = .{};
    var section: Section = .none;
    var output: ?Spec = null;
    var profile: ?Profile = null;
    var profile_output: ?Spec = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = wm.cleanLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            flushOutput(&snapshot, &output);
            flushProfileOutput(&profile, &profile_output);
            if (!std.mem.eql(u8, line, "[[display.profile.output]]")) flushProfile(&snapshot, &profile);
            if (std.mem.eql(u8, line, "[display]")) section = .display else if (std.mem.eql(u8, line, "[[output]]")) {
                section = .output;
                output = .{};
            } else if (std.mem.eql(u8, line, "[[display.profile]]")) {
                section = .profile;
                profile = .{};
            } else if (std.mem.eql(u8, line, "[[display.profile.output]]")) {
                section = .profile_output;
                profile_output = .{};
            } else section = .none;
            continue;
        }
        const equal = wm.indexUnquoted(line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const raw_value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        const value = wm.unquote(raw_value);
        switch (section) {
            .display => applyDisplay(&snapshot, key, value),
            .output => if (output) |*entry| applySpec(entry, key, raw_value),
            .profile => if (profile) |*entry| {
                if (std.mem.eql(u8, key, "name")) _ = entry.name.set(value);
            },
            .profile_output => if (profile_output) |*entry| applySpec(entry, key, raw_value),
            .none => {},
        }
    }
    flushOutput(&snapshot, &output);
    flushProfileOutput(&profile, &profile_output);
    flushProfile(&snapshot, &profile);
    return snapshot;
}

fn applyDisplay(snapshot: *Snapshot, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "apply_on_start")) if (parseBool(value)) |parsed| {
        snapshot.apply_on_start = parsed;
        snapshot.apply_on_start_set = true;
        snapshot.declarative = true;
    };
    if (std.mem.eql(u8, key, "apply_on_reload")) if (parseBool(value)) |parsed| {
        snapshot.apply_on_reload = parsed;
        snapshot.apply_on_reload_set = true;
        snapshot.declarative = true;
    };
    if (std.mem.eql(u8, key, "fallback_profile")) if (snapshot.fallback_profile.set(value)) {
        snapshot.fallback_profile_set = true;
        snapshot.declarative = true;
    };
    if (std.mem.eql(u8, key, "identify_by")) if (snapshot.identify_by.set(value)) {
        snapshot.identify_by_set = true;
    };
    if (std.mem.eql(u8, key, "rollback_seconds")) if (std.fmt.parseInt(u16, value, 10)) |parsed| {
        snapshot.rollback_seconds = parsed;
        snapshot.rollback_seconds_set = true;
    } else |_| {};
}

fn applySpec(spec: *Spec, key: []const u8, raw_value: []const u8) void {
    const value = wm.unquote(raw_value);
    if (std.mem.eql(u8, key, "name")) _ = spec.name.set(value);
    if (std.mem.eql(u8, key, "edid")) _ = spec.edid.set(value);
    if (std.mem.eql(u8, key, "enabled")) spec.enabled = parseBool(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "mode")) spec.mode = parseMode(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "scale")) spec.scale = parseScale(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "transform")) spec.transform = parseTransform(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "position")) {
        const position = parsePosition(raw_value) orelse {
            spec.valid = false;
            return;
        };
        spec.x = position[0];
        spec.y = position[1];
    }
    if (std.mem.eql(u8, key, "adaptive_sync")) spec.adaptive_sync = parseBool(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "hdr")) spec.hdr = parseBool(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "hdr_level")) spec.hdr_level = parseHdrLevelChoice(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "sdr_white_level")) spec.sdr_white_level = parseSdrWhiteLevel(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "auto_hdr")) spec.auto_hdr = parseBool(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "auto_hdr_boost")) spec.auto_hdr_boost = parseAutoHdrBoost(value) orelse {
        spec.valid = false;
        return;
    };
    if (std.mem.eql(u8, key, "primary")) spec.primary = parseBool(value) orelse {
        spec.valid = false;
        return;
    };
}

pub fn parseMode(value: []const u8) ?Mode {
    const x = std.mem.indexOfScalar(u8, value, 'x') orelse return null;
    const at = std.mem.indexOfScalarPos(u8, value, x + 1, '@');
    const width = std.fmt.parseInt(i32, value[0..x], 10) catch return null;
    const height = std.fmt.parseInt(i32, value[x + 1 .. at orelse value.len], 10) catch return null;
    if (width <= 0 or height <= 0) return null;
    var mode: Mode = .{ .width = width, .height = height };
    if (at) |index| {
        const hz = std.fmt.parseFloat(f64, value[index + 1 ..]) catch return null;
        if (!std.math.isFinite(hz) or hz <= 0) return null;
        mode.refresh_mhz = @intFromFloat(@round(hz * 1000.0));
    }
    return mode;
}

fn parseScale(value: []const u8) ?f32 {
    const scale = std.fmt.parseFloat(f32, value) catch return null;
    if (!std.math.isFinite(scale)) return null;
    if (scaling.clampScale(scale) != scale) return null;
    return scaling.normalizeScale(scale);
}

pub fn parseHdrLevelChoice(value: []const u8) ?HdrLevelChoice {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "100")) return .l100;
    if (std.mem.eql(u8, value, "400")) return .l400;
    if (std.mem.eql(u8, value, "1000")) return .l1000;
    return null;
}

pub fn hdrLevelChoiceName(choice: HdrLevelChoice) []const u8 {
    return switch (choice) {
        .auto => "auto",
        .l100 => "100",
        .l400 => "400",
        .l1000 => "1000",
    };
}

fn parseSdrWhiteLevel(value: []const u8) ?f64 {
    const white = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(white) and white >= 80.0 and white <= 1000.0) white else null;
}

fn parseAutoHdrBoost(value: []const u8) ?f64 {
    const boost = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(boost) and boost >= 0.0 and boost <= 1.0) boost else null;
}

pub fn parseTransform(value: []const u8) ?Transform {
    if (std.mem.eql(u8, value, "normal")) return .normal;
    if (std.mem.eql(u8, value, "90")) return .rotate_90;
    if (std.mem.eql(u8, value, "180")) return .rotate_180;
    if (std.mem.eql(u8, value, "270")) return .rotate_270;
    if (std.mem.eql(u8, value, "flipped")) return .flipped;
    if (std.mem.eql(u8, value, "flipped-90")) return .flipped_90;
    if (std.mem.eql(u8, value, "flipped-180")) return .flipped_180;
    if (std.mem.eql(u8, value, "flipped-270")) return .flipped_270;
    return null;
}

fn parsePosition(value: []const u8) ?[2]i32 {
    if (value.len < 5 or value[0] != '[' or value[value.len - 1] != ']') return null;
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return null;
    return .{
        std.fmt.parseInt(i32, std.mem.trim(u8, value[1..comma], " \t"), 10) catch return null,
        std.fmt.parseInt(i32, std.mem.trim(u8, value[comma + 1 .. value.len - 1], " \t"), 10) catch return null,
    };
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn flushOutput(snapshot: *Snapshot, pending: *?Spec) void {
    if (pending.*) |entry| if (entry.valid and (!entry.name.empty() or !entry.edid.empty()) and snapshot.output_count < max_outputs) {
        snapshot.outputs[snapshot.output_count] = entry;
        snapshot.output_count += 1;
        if (entry.hasDisplayField() or entry.primary != null) snapshot.declarative = true;
    };
    pending.* = null;
}

fn flushProfileOutput(profile: *?Profile, pending: *?Spec) void {
    if (pending.*) |entry| if (profile.*) |*target| if (entry.valid and (!entry.name.empty() or !entry.edid.empty()) and target.output_count < max_profile_outputs) {
        target.outputs[target.output_count] = entry;
        target.output_count += 1;
    };
    pending.* = null;
}

fn flushProfile(snapshot: *Snapshot, pending: *?Profile) void {
    if (pending.*) |entry| if (!entry.name.empty() and snapshot.profile_count < max_profiles) {
        snapshot.profiles[snapshot.profile_count] = entry;
        snapshot.profile_count += 1;
    };
    pending.* = null;
}

test "output config parses display specs and profiles" {
    const snapshot = parse(
        \\[display]
        \\fallback_profile = "safe"
        \\rollback_seconds = 12
        \\[[output]]
        \\name = "DP-*"
        \\mode = "2560x1440@143.999"
        \\scale = 1.25
        \\transform = "flipped-90"
        \\adaptive_sync = true
        \\hdr = true
        \\hdr_level = 400
        \\sdr_white_level = 180
        \\auto_hdr = true
        \\auto_hdr_boost = 0.7
        \\primary = true
        \\[[display.profile]]
        \\name = "safe"
        \\[[display.profile.output]]
        \\name = "eDP-1"
        \\position = [0, 0]
    );
    try std.testing.expectEqual(@as(u8, 1), snapshot.output_count);
    try std.testing.expectEqual(@as(i32, 143999), snapshot.outputs[0].mode.?.refresh_mhz.?);
    try std.testing.expectEqual(Transform.flipped_90, snapshot.outputs[0].transform.?);
    try std.testing.expectEqual(true, snapshot.outputs[0].hdr.?);
    try std.testing.expectEqual(HdrLevelChoice.l400, snapshot.outputs[0].hdr_level.?);
    try std.testing.expectEqual(@as(f64, 180.0), snapshot.outputs[0].sdr_white_level.?);
    try std.testing.expectEqual(true, snapshot.outputs[0].auto_hdr.?);
    try std.testing.expectEqual(@as(f64, 0.7), snapshot.outputs[0].auto_hdr_boost.?);
    try std.testing.expectEqual(true, snapshot.outputs[0].primary.?);
    try std.testing.expectEqual(@as(u8, 1), snapshot.profile_count);
    try std.testing.expectEqual(@as(u8, 1), snapshot.profiles[0].output_count);
    try std.testing.expectEqual(@as(i32, 0), snapshot.profiles[0].outputs[0].x.?);
}

test "primary preserves an explicit false override" {
    const snapshot = parse(
        \\[[output]]
        \\name = "*"
        \\primary = true
        \\[[output]]
        \\name = "HDMI-A-1"
        \\primary = false
    );
    try std.testing.expectEqual(@as(u8, 2), snapshot.output_count);
    try std.testing.expectEqual(true, snapshot.outputs[0].primary.?);
    try std.testing.expectEqual(false, snapshot.outputs[1].primary.?);
}

test "mode scale and transform validation matches outputd contract" {
    try std.testing.expect(parseMode("1920x1080@60") != null);
    try std.testing.expect(parseMode("1920-by-1080") == null);
    try std.testing.expect(parseScale("0.49") == null);
    try std.testing.expect(parseScale("3.0") != null);
    try std.testing.expect(parseTransform("45") == null);
}

test "hdr level and sdr white level reject unsupported values" {
    try std.testing.expectEqual(HdrLevelChoice.auto, parseHdrLevelChoice("auto").?);
    try std.testing.expectEqual(HdrLevelChoice.l1000, parseHdrLevelChoice("1000").?);
    try std.testing.expect(parseHdrLevelChoice("600") == null);
    try std.testing.expect(parseSdrWhiteLevel("79") == null);
    try std.testing.expect(parseSdrWhiteLevel("1000") != null);
    try std.testing.expect(parseSdrWhiteLevel("1000.5") == null);
    const snapshot = parse(
        \\[[output]]
        \\name = "DP-1"
        \\hdr_level = 600
    );
    try std.testing.expectEqual(@as(u8, 0), snapshot.output_count);
    const out_of_range = parse(
        \\[[output]]
        \\name = "DP-1"
        \\auto_hdr_boost = 1.5
    );
    try std.testing.expectEqual(@as(u8, 0), out_of_range.output_count);
}

test "declarative presence distinguishes policy from persisted profiles" {
    const persisted_only = parse(
        \\[[display.profile]]
        \\name = "dock"
        \\[[display.profile.output]]
        \\name = "DP-1"
        \\scale = 1.25
    );
    try std.testing.expect(!persisted_only.declarative);

    const compatibility_only = parse(
        \\[display]
        \\identify_by = "name"
        \\rollback_seconds = 10
    );
    try std.testing.expect(!compatibility_only.declarative);
    try std.testing.expect(compatibility_only.identify_by_set);
    try std.testing.expect(compatibility_only.rollback_seconds_set);

    const policy = parse(
        \\[display]
        \\apply_on_reload = false
        \\fallback_profile = ""
        \\[[output]]
        \\name = "DP-1"
        \\primary = true
    );
    try std.testing.expect(policy.declarative);
    try std.testing.expect(policy.apply_on_reload_set);
    try std.testing.expect(policy.fallback_profile_set);
    try std.testing.expect(!policy.apply_on_reload);
}

test "outputs policy overlays wm while persisted profiles preserve legacy behavior" {
    const legacy = parse(
        \\[display]
        \\apply_on_start = false
        \\apply_on_reload = true
        \\fallback_profile = "legacy-safe"
        \\[[output]]
        \\name = "DP-1"
        \\mode = "2560x1440@144"
        \\scale = 1.0
        \\[[display.profile]]
        \\name = "dock"
        \\[[display.profile.output]]
        \\name = "DP-1"
        \\scale = 1.0
    );
    const persisted_only = parse(
        \\[[display.profile]]
        \\name = "dock"
        \\[[display.profile.output]]
        \\name = "DP-1"
        \\scale = 1.25
    );
    var specs: [max_outputs * 2]Spec = undefined;
    const unchanged = configuredSpecs(&legacy, &persisted_only, &specs);
    try std.testing.expectEqual(@as(usize, 1), unchanged.len);
    try std.testing.expectEqual(@as(f32, 1.0), unchanged[0].scale.?);
    try std.testing.expectEqual(@as(f32, 1.0), effectiveProfile(&legacy, &persisted_only, "dock").?.outputs[0].scale.?);

    const preferred = parse(
        \\[display]
        \\apply_on_reload = false
        \\fallback_profile = ""
        \\[[output]]
        \\name = "DP-1"
        \\scale = 1.5
        \\[[display.profile]]
        \\name = "dock"
        \\[[display.profile.output]]
        \\name = "DP-1"
        \\scale = 1.25
    );
    const overlaid = configuredSpecs(&legacy, &preferred, &specs);
    try std.testing.expectEqual(@as(usize, 2), overlaid.len);
    try std.testing.expect(overlaid[0].mode != null);
    try std.testing.expectEqual(@as(f32, 1.0), overlaid[0].scale.?);
    try std.testing.expectEqual(@as(f32, 1.5), overlaid[1].scale.?);
    try std.testing.expect(!effectiveApplyOnStart(&legacy, &preferred));
    try std.testing.expect(!effectiveApplyOnReload(&legacy, &preferred));
    try std.testing.expectEqualStrings("", effectiveFallbackProfile(&legacy, &preferred));
    try std.testing.expectEqual(@as(f32, 1.25), effectiveProfile(&legacy, &preferred, "dock").?.outputs[0].scale.?);
}
