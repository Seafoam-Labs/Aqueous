// SPDX-License-Identifier: GPL-3.0-only
//! One event-loop observation, distinct from the canonical file generation.
const std = @import("std");
const server = &@import("main.zig").server;
const Output = @import("Output.zig");
const Manager = @import("OutputManager.zig");
const Service = @import("wm/output/Service.zig");
const Config = @import("wm/output/config.zig");
const Projection = @import("DisplayConfig.zig");
const field = Projection.field;

pub fn write(json: *std.json.Stringify) !void {
    var buffer: [20]u8 = undefined;
    try json.beginObject();
    try field(json, "version", 1);
    try field(json, "config_generation", server.aqueous.config.canonical_generation);
    try field(json, "session", server.shell_manager.session[0..32]);
    try field(json, "display_revision", try std.fmt.bufPrint(&buffer, "{d}", .{server.om.display_revision}));
    try field(json, "observation", if (server.wm.state == .idle and !server.wm.scheduled.dirty) "current" else "transitioning");
    try field(json, "active_profile", server.aqueous.output_service.active_profile.slice());
    try field(json, "preview_active", @import("DisplayPreview.zig").active());
    const service = &server.aqueous.output_service;
    try json.objectField("effective_profile");
    if (Config.effectiveProfile(&service.config, &service.persisted, service.active_profile.slice())) |profile| {
        try json.beginObject();
        try field(json, "name", profile.name.slice());
        try field(json, "declaration", profile.declaration);
        try field(json, "source", if (service.persisted.declarative and service.persisted.profile(profile.name.slice()) != null) "outputs" else if (service.config.profile(profile.name.slice()) != null) "wm" else "outputs");
        try json.objectField("outputs");
        try json.beginArray();
        for (profile.outputs[0..profile.output_count]) |spec| try Projection.writeSpec(json, spec);
        try json.endArray();
        try json.endObject();
    } else try json.write(null);
    try field(json, "fallback_profile", Config.effectiveFallbackProfile(&server.aqueous.output_service.config, &server.aqueous.output_service.persisted));
    try json.objectField("loaded_configuration");
    try json.beginObject();
    try json.objectField("wm");
    try Projection.writeSource(json, &server.aqueous.output_service.config);
    try json.objectField("outputs");
    try Projection.writeSource(json, &server.aqueous.output_service.persisted);
    try json.endObject();
    try json.objectField("outputs");
    try json.beginArray();
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |o| {
        const w = o.wlr_output orelse continue;
        try json.beginObject();
        try field(json, "instance", try std.fmt.bufPrint(&buffer, "{d}", .{o.display_instance}));
        try field(json, "connector", std.mem.span(w.name));
        try field(json, "connected", true);
        try field(json, "enabled", w.enabled);
        try field(json, "make", if (w.make) |s| @as(?[]const u8, std.mem.span(s)) else null);
        try field(json, "model", if (w.model) |s| @as(?[]const u8, std.mem.span(s)) else null);
        try field(json, "serial", if (w.serial) |s| @as(?[]const u8, std.mem.span(s)) else null);
        var edid_buf: [71]u8 = undefined;
        const edid = Service.identityHash(w, &edid_buf);
        var matches: usize = 0;
        if (edid) |value| {
            var others = server.om.outputs.iterator(.forward);
            while (others.next()) |other| {
                var other_buf: [71]u8 = undefined;
                const other_w = other.wlr_output orelse continue;
                if (Service.identityHash(other_w, &other_buf)) |other_id| if (std.mem.eql(u8, value, other_id)) {
                    matches += 1;
                };
            }
        }
        try field(json, "monitor_identity", .{ .value = edid, .kind = "make_model_serial_hash", .raw_edid_available = false, .ambiguous = matches > 1, .match_count = matches });
        try json.objectField("actual");
        var actual = o.current;
        actual.mode = if (w.width > 0 and w.height > 0) .{ .custom = .{ .width = w.width, .height = w.height, .refresh = w.refresh } } else .none;
        actual.scale = w.scale;
        actual.transform = w.transform;
        actual.hdr_enabled = Output.hdr.active(w);
        actual.adaptive_sync = w.adaptive_sync_status == .enabled;
        try writeState(json, actual);
        try field(json, "actual_hdr", Output.hdr.active(w));
        try field(json, "actual_vrr", w.adaptive_sync_status == .enabled);
        try field(json, "primary", server.aqueous.output_service.primaryOutput() == o);
        try json.objectField("configured");
        try writeEffective(json, o);
        try json.objectField("modes");
        try json.beginArray();
        var modes = w.modes.iterator(.forward);
        while (modes.next()) |mode| try json.write(.{ .width = mode.width, .height = mode.height, .refresh_mhz = mode.refresh, .preferred = mode.preferred });
        try json.endArray();
        try field(json, "support", .{
            .placement = support(w.isHeadless(), "hardware_acceptance_pending"),
            .mode = support(w.isHeadless(), "hardware_acceptance_pending"),
            .enable = support(w.isHeadless(), "hardware_acceptance_pending"),
            .hdr = support(false, if (Output.hdr.capable(w)) "hardware_acceptance_pending" else "hdr_unsupported"),
            .vrr = support(false, "hardware_test_required"),
            .mirroring = support(w.isHeadless() and @import("OutputMirror.zig").supported(), "hardware_or_renderer_acceptance_required"),
            .profiles = support(w.isHeadless(), "hardware_acceptance_pending"),
            .policies = support(w.isHeadless(), "hardware_acceptance_pending"),
            .primary = support(w.isHeadless(), "hardware_acceptance_pending"),
            .custom_mode = support(false, "custom_mode_test_required"),
        });
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}
fn support(preview: bool, reason: []const u8) struct { store: bool, @"test": bool, preview: bool, reason: ?[]const u8 } {
    return .{ .store = true, .@"test" = preview, .preview = preview, .reason = if (preview) null else reason };
}
pub fn writeState(json: *std.json.Stringify, state: Output.State) !void {
    const Mode = struct { width: i32, height: i32, refresh_mhz: i32 };
    const mode: ?Mode = switch (state.mode) {
        .standard => |m| .{ .width = m.width, .height = m.height, .refresh_mhz = m.refresh },
        .custom => |m| .{ .width = m.width, .height = m.height, .refresh_mhz = m.refresh },
        .none => null,
    };
    try json.write(.{
        .enabled = state.state == .enabled,
        .mode = mode,
        .scale = state.scale,
        .transform = Manager.transformName(state.transform),
        .x = state.x,
        .y = state.y,
        .mirror_of = state.mirror_of.slice(),
        .adaptive_sync = state.adaptive_sync,
        .hdr = state.hdr_enabled,
        .hdr_level = @intFromEnum(state.hdr_level),
        .sdr_white_level = state.sdr_white_level,
        .auto_hdr = state.auto_hdr,
        .auto_hdr_boost = state.auto_hdr_boost,
    });
}
fn writeEffective(json: *std.json.Stringify, output: *Output) !void {
    const service = &server.aqueous.output_service;
    var selected: [Config.max_outputs * 2]Config.Spec = undefined;
    const specs = Config.configuredSpecs(&service.config, &service.persisted, &selected);
    try json.beginObject();
    // Omitted values inherit runtime state. This is the actual resolver input,
    // not fabricated defaults for a head which has not yet been connected.
    inline for (.{ "enabled", "mode", "scale", "transform", "x", "y", "adaptive_sync", "hdr", "hdr_level", "sdr_white_level", "auto_hdr", "auto_hdr_boost", "primary" }) |key| {
        var value: @FieldType(Config.Spec, key) = null;
        var declaration: ?usize = null;
        var fold_order: ?usize = null;
        var legacy_count: usize = 0;
        for (service.config.outputs[0..service.config.output_count]) |spec| if (spec.hasDisplayField()) {
            legacy_count += 1;
        };
        for (specs, 0..) |spec, index| if (Manager.matchesSpec(&spec, output.wlr_output.?)) {
            if (@field(spec, key)) |v| {
                value = v;
                declaration = spec.declaration;
                fold_order = index;
            }
        };
        try field(json, key, .{ .value = value, .declaration = declaration, .source = if (fold_order) |order| @as(?[]const u8, if (order < legacy_count) "wm" else "outputs") else null, .fold_order = fold_order, .inherit_runtime = value == null });
    }
    var mirror: ?Config.Text = null;
    for (specs) |spec| if (Manager.matchesSpec(&spec, output.wlr_output.?)) {
        if (spec.mirror_of) |v| {
            mirror = v;
        }
    };
    try field(json, "mirror_of", if (mirror) |v| @as(?[]const u8, v.slice()) else null);
    try json.endObject();
}

pub fn candidate(json: *std.json.Stringify, params: std.json.ObjectMap) !void {
    const Codec = @import("IpcProtocol.zig");
    const Preview = @import("DisplayPreview.zig");
    if (!std.mem.eql(u8, try Codec.string(params, "expected_generation"), &server.aqueous.config.canonical_generation)) return error.StaleGeneration;
    if (server.wm.state != .idle or server.wm.scheduled.dirty) return error.Busy;
    const legacy = Config.parse(try Preview.source(params, "wm_source"));
    const preferred = Config.parse(try Preview.source(params, "outputs_source"));
    const service = &server.aqueous.output_service;
    var specs: [Config.max_outputs * 2]Config.Spec = undefined;
    const plan = server.om.prepareSpecs(Config.configuredSpecs(&legacy, &preferred, &specs)) catch return json.write(.{ .complete = false, .reason = "resolver_rejected_candidate" });
    var offline_only_rejections = true;
    for (plan.report.rejections[0..plan.report.rejection_count]) |rejection| if (rejection.reason != .unknown_output) {
        offline_only_rejections = false;
    };
    var live = false;
    for (plan.items[0..plan.len]) |item| if (!std.meta.eql(item.state, item.output.current)) {
        live = true;
    };
    const reload = Config.effectiveApplyOnReload(&legacy, &preferred);
    const ambiguous = legacy.unknown_fields != 0 or preferred.unknown_fields != 0 or legacy.rejected_declarations != 0 or preferred.rejected_declarations != 0;
    // No save-only assertion about inactive profiles is made without checking
    // their activation/fallback dependencies in the same observation.
    const profile_uncertain = false;
    const primary_specs = Service.resolvePrimarySpecs(&legacy, &preferred, service.active_profile);
    var next_primary: ?*Output = null;
    var outputs = server.om.outputs.iterator(.forward);
    while (outputs.next()) |o| {
        const w = o.wlr_output orelse continue;
        if (o.current.state != .enabled or !o.current.mirror_of.empty()) continue;
        var primary = false;
        for (primary_specs.base) |spec| if (Manager.matchesSpec(&spec, w)) {
            if (spec.primary) |v| {
                primary = v;
            }
        };
        for (primary_specs.preferred) |spec| if (Manager.matchesSpec(&spec, w)) {
            if (spec.primary) |v| {
                primary = v;
            }
        };
        if (primary and next_primary == null) next_primary = o;
    }
    if (next_primary != service.primaryOutput()) live = true;
    var resolved: [Config.max_outputs]Manager.Pending = undefined;
    var resolved_count: usize = 0;
    var heads = server.om.outputs.iterator(.forward);
    while (heads.next()) |o| {
        if (o.wlr_output == null) continue;
        if (resolved_count == resolved.len) return error.TooManyOutputs;
        var state = o.current;
        if (reload) for (plan.items[0..plan.len]) |item| {
            if (item.output == o) {
                state = item.state;
            }
        };
        resolved[resolved_count] = .{ .output = o, .state = state };
        resolved_count += 1;
    }
    Manager.layoutPlan(resolved[0..resolved_count]);
    var encoded: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer encoded.deinit();
    var ej: std.json.Stringify = .{ .writer = &encoded.writer };
    try ej.beginArray();
    for (resolved[0..resolved_count]) |item| {
        var id: [20]u8 = undefined;
        try ej.beginObject();
        try field(&ej, "instance", try std.fmt.bufPrint(&id, "{d}", .{item.output.display_instance}));
        try ej.objectField("resolved");
        try writeState(&ej, item.state);
        try ej.endObject();
    }
    try ej.endArray();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, encoded.written(), .{});
    defer parsed.deinit();
    var revision: [20]u8 = undefined;
    try json.write(.{
        .effective_outputs = parsed.value,
        .complete = !ambiguous and !profile_uncertain and offline_only_rejections,
        .session = server.shell_manager.session[0..32],
        .display_revision = try std.fmt.bufPrint(&revision, "{d}", .{server.om.display_revision}),
        .effects = if (live and reload) &[_][]const u8{ "display_live", "display_deferred" } else &[_][]const u8{"display_deferred"},
        .required_action = "preview",
        .deferred_save_requires_lease = true,
        .now = "unchanged_until_reload",
        .on_reload = if (reload and live) "output_plan_changes" else "no_output_modeset",
        .at_startup = if (Config.effectiveApplyOnStart(&legacy, &preferred)) "configured_plan" else "backend_defaults",
        .on_hotplug = "configured_plan_and_fallback_validation",
        .policies = .{
            .apply_on_start = .{ .value = Config.effectiveApplyOnStart(&legacy, &preferred), .phase = "startup" },
            .apply_on_reload = .{ .value = reload, .phase = "reload" },
            .fallback_profile = .{ .value = Config.effectiveFallbackProfile(&legacy, &preferred), .phase = "failed_configured_plan" },
            .identify_by = .{ .runtime_effect = false, .reason = "compatibility_only" },
            .rollback_seconds = .{ .runtime_effect = false, .crash_safe_lease = false },
        },
        .reason = if (ambiguous) @as(?[]const u8, "unknown_or_rejected_declaration") else if (profile_uncertain) @as(?[]const u8, "profile_activation_requires_protection") else if (!offline_only_rejections) @as(?[]const u8, "rejected_declaration") else null,
    });
}
