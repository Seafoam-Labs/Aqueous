// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
//! Display-independent projection of the compositor's actual parser.
const std = @import("std");
pub const document = @import("ConfigDocument.zig");
pub const ipc = @import("ConfigIpcClient.zig");
pub const transaction = @import("ConfigTransaction.zig");
pub const config = @import("wm/output/config.zig");
// Pure configuration parsers shared with the helper's collection classifier.
pub const collection_actions = @import("wm/config/actions.zig");
pub const collection_layout = @import("wm/config/layout.zig");
pub const collection_toml = @import("wm/config/wm.zig");
pub const decodeBindingCommand = @import("wm/config/loader.zig").decodeBasic;
const scaling = @import("scaling");

pub fn field(json: *std.json.Stringify, key: []const u8, value: anytype) !void {
    try json.objectField(key);
    try json.write(value);
}

pub fn writeSpec(json: *std.json.Stringify, spec: config.Spec) !void {
    try json.beginObject();
    try field(json, "declaration", spec.declaration);
    try field(json, "name", spec.name.slice());
    try field(json, "edid", spec.edid.slice());
    try field(json, "mirror_of", if (spec.mirror_of) |v| @as(?[]const u8, v.slice()) else null);
    try field(json, "enabled", spec.enabled);
    try field(json, "mode", spec.mode);
    try field(json, "scale", spec.scale);
    try field(json, "transform", spec.transform);
    try field(json, "position", if (spec.x) |x| @as(?[2]i32, .{ x, spec.y.? }) else null);
    try field(json, "adaptive_sync", spec.adaptive_sync);
    try field(json, "fullscreen_only_adaptive_sync", spec.fullscreen_only_adaptive_sync);
    try field(json, "hdr", spec.hdr);
    try field(json, "hdr_level", spec.hdr_level);
    try field(json, "sdr_white_level", spec.sdr_white_level);
    try field(json, "auto_hdr", spec.auto_hdr);
    try field(json, "auto_hdr_boost", spec.auto_hdr_boost);
    try field(json, "primary", spec.primary);
    try json.endObject();
}

pub fn writeSource(json: *std.json.Stringify, source: *const config.Snapshot) !void {
    try json.beginObject();
    try field(json, "declarative", source.declarative);
    try field(json, "diagnostics", .{ .unknown_fields = source.unknown_fields, .rejected_declarations = source.rejected_declarations });
    try json.objectField("policy");
    try json.beginObject();
    inline for (.{ "apply_on_start", "apply_on_reload", "rollback_seconds" }) |key| {
        try field(json, key, if (@field(source, key ++ "_set")) @as(?@FieldType(config.Snapshot, key), @field(source, key)) else null);
    }
    inline for (.{ "fallback_profile", "identify_by" }) |key| {
        try field(json, key, if (@field(source, key ++ "_set")) @as(?[]const u8, @field(source, key).slice()) else null);
    }
    try json.endObject();
    try json.objectField("outputs");
    try json.beginArray();
    for (source.outputs[0..source.output_count]) |spec| try writeSpec(json, spec);
    try json.endArray();
    try json.objectField("profiles");
    try json.beginArray();
    for (source.profiles[0..source.profile_count]) |profile| {
        try json.beginObject();
        try field(json, "declaration", profile.declaration);
        try field(json, "name", profile.name.slice());
        try json.objectField("outputs");
        try json.beginArray();
        for (profile.outputs[0..profile.output_count]) |spec| try writeSpec(json, spec);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

pub fn write(json: *std.json.Stringify, wm_source: []const u8, outputs_source: []const u8) !void {
    const legacy = config.parse(wm_source);
    const preferred = config.parse(outputs_source);
    try json.beginObject();
    try field(json, "version", 1);
    try field(json, "identity_scope", "generation");
    try field(json, "live_resolution", "unavailable");
    try field(json, "reason", "revision_bound_compositor_projection_unavailable");
    try json.objectField("parsed_sources");
    try json.beginObject();
    try json.objectField("wm");
    try writeSource(json, &legacy);
    try json.objectField("outputs");
    try writeSource(json, &preferred);
    try json.endObject();
    try json.objectField("effective_policy");
    try json.beginObject();
    inline for (.{ "apply_on_start", "apply_on_reload", "fallback_profile" }) |key| {
        const use_preferred = preferred.declarative and @field(preferred, key ++ "_set");
        const source = if (use_preferred) &preferred else &legacy;
        try json.objectField(key);
        try json.beginObject();
        if (comptime std.mem.eql(u8, key, "fallback_profile")) {
            try field(json, "value", config.effectiveFallbackProfile(&legacy, &preferred));
        } else {
            try field(json, "value", @field(source, key));
        }
        try field(json, "source", if (use_preferred) "outputs" else if (@field(legacy, key ++ "_set")) "wm" else "default");
        try json.endObject();
    }
    try field(json, "identify_by", .{ .behavior = "compatibility_only", .runtime_effect = false });
    try field(json, "rollback_seconds", .{ .behavior = "compatibility_only", .crash_safe_lease = false });
    try json.endObject();
    try json.objectField("configured_fold");
    try json.beginArray();
    var specs: [config.max_outputs * 2]config.Spec = undefined;
    var legacy_count: usize = 0;
    for (legacy.outputs[0..legacy.output_count]) |spec| {
        if (spec.hasDisplayField()) legacy_count += 1;
    }
    for (config.configuredSpecs(&legacy, &preferred, &specs), 0..) |spec, index| {
        try json.beginObject();
        try field(json, "source", if (index < legacy_count) "wm" else "outputs");
        try field(json, "fold_order", index);
        try json.objectField("spec");
        try writeSpec(json, spec);
        try json.endObject();
    }
    try json.endArray();
    try field(json, "limits", .{
        .outputs_per_source = config.max_outputs,
        .profiles_per_source = config.max_profiles,
        .outputs_per_profile = config.max_profile_outputs,
        .scale = .{ .unit = "logical_to_physical_ratio", .min = scaling.min_scale, .max = scaling.max_scale, .denominator = 120 },
        .mode = .{ .dimensions = "physical_pixels", .refresh_mhz = "integer_millihertz", .custom = "requires_backend_test" },
        .luminance = .{ .unit = "cd/m2", .sdr_white_min = 80, .sdr_white_max = 1000 },
        .transforms = std.meta.fieldNames(config.Transform),
        .hdr_levels = std.meta.fieldNames(config.HdrLevelChoice),
        .auto_hdr_boost = .{ .min = 0, .max = 1 },
    });
    try field(json, "support", .{ .store = true, .@"test" = false, .preview = false, .reason = "native_display_transaction_unavailable" });
    try json.endObject();
}

test "projection preserves false, inherit, reset and canonical precedence" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer };
    try write(&json, "[[output]]\nname = \"DP-1\"\nhdr = true\nmirror_of = \"DP-2\"\n", "[[output]]\nname = \"DP-1\"\nhdr = false\nmirror_of = \"\"\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.written(), .{});
    defer parsed.deinit();
    const fold = parsed.value.object.get("configured_fold").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), fold.len);
    const spec = fold[1].object.get("spec").?.object;
    try std.testing.expect(!spec.get("hdr").?.bool);
    try std.testing.expectEqualStrings("", spec.get("mirror_of").?.string);
    try std.testing.expect(spec.get("enabled").? == .null);
}

test {
    _ = document;
    _ = transaction;
    _ = config;
}
