// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const wm = @import("../config/wm.zig");

pub const max_outputs = 64;
pub const max_profiles = 16;
pub const max_profile_outputs = 32;
pub const Text = wm.Text;
pub const Transform = enum { normal, rotate_90, rotate_180, rotate_270, flipped, flipped_90, flipped_180, flipped_270 };
pub const Mode = struct { width: i32, height: i32, refresh_mhz: ?i32 = null };

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
    primary: bool = false,

    pub fn hasDisplayField(spec: *const Spec) bool {
        return spec.enabled != null or spec.mode != null or spec.scale != null or spec.transform != null or spec.x != null or spec.adaptive_sync != null;
    }
};

pub const Profile = struct {
    name: Text = .{},
    outputs: [max_profile_outputs]Spec = undefined,
    output_count: u8 = 0,
};

pub const Snapshot = struct {
    apply_on_start: bool = true,
    apply_on_reload: bool = true,
    fallback_profile: Text = .{},
    identify_by: Text = defaultIdentifyBy(),
    rollback_seconds: u16 = 0,
    outputs: [max_outputs]Spec = undefined,
    output_count: u8 = 0,
    profiles: [max_profiles]Profile = undefined,
    profile_count: u8 = 0,

    pub fn profile(snapshot: *const Snapshot, name: []const u8) ?*const Profile {
        for (snapshot.profiles[0..snapshot.profile_count]) |*entry| if (std.mem.eql(u8, entry.name.slice(), name)) return entry;
        return null;
    }
};

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
    if (std.mem.eql(u8, key, "apply_on_start")) snapshot.apply_on_start = parseBool(value) orelse snapshot.apply_on_start;
    if (std.mem.eql(u8, key, "apply_on_reload")) snapshot.apply_on_reload = parseBool(value) orelse snapshot.apply_on_reload;
    if (std.mem.eql(u8, key, "fallback_profile")) _ = snapshot.fallback_profile.set(value);
    if (std.mem.eql(u8, key, "identify_by")) _ = snapshot.identify_by.set(value);
    if (std.mem.eql(u8, key, "rollback_seconds")) snapshot.rollback_seconds = std.fmt.parseInt(u16, value, 10) catch snapshot.rollback_seconds;
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
    return if (std.math.isFinite(scale) and scale >= 0.5 and scale <= 3.0) scale else null;
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
        \\[[display.profile]]
        \\name = "safe"
        \\[[display.profile.output]]
        \\name = "eDP-1"
        \\position = [0, 0]
    );
    try std.testing.expectEqual(@as(u8, 1), snapshot.output_count);
    try std.testing.expectEqual(@as(i32, 143999), snapshot.outputs[0].mode.?.refresh_mhz.?);
    try std.testing.expectEqual(Transform.flipped_90, snapshot.outputs[0].transform.?);
    try std.testing.expectEqual(@as(u8, 1), snapshot.profile_count);
    try std.testing.expectEqual(@as(u8, 1), snapshot.profiles[0].output_count);
    try std.testing.expectEqual(@as(i32, 0), snapshot.profiles[0].outputs[0].x.?);
}

test "mode scale and transform validation matches outputd contract" {
    try std.testing.expect(parseMode("1920x1080@60") != null);
    try std.testing.expect(parseMode("1920-by-1080") == null);
    try std.testing.expect(parseScale("0.49") == null);
    try std.testing.expect(parseScale("3.0") != null);
    try std.testing.expect(parseTransform("45") == null);
}
