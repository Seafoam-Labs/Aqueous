// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const OutputManager = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const DragIcon = @import("DragIcon.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");
const OutputConfig = @import("wm/output/config.zig");
const autolayout = @import("wm/output/autolayout.zig");
const mode_match = @import("wm/output/mode_match.zig");

const log = std.log.scoped(.output);

/// The very first modeset is different in that if it fails we exit river.
first_modeset: bool = true,

new_output: wl.Listener(*wlr.Output) = .init(handleNewOutput),

output_layout: *wlr.OutputLayout,

presentation: *wlr.Presentation,
xdg_output_manager: *wlr.XdgOutputManagerV1,

wlr_output_manager: *wlr.OutputManagerV1,
manager_apply: wl.Listener(*wlr.OutputConfigurationV1) = .init(handleManagerApply),
manager_test: wl.Listener(*wlr.OutputConfigurationV1) = .init(handleManagerTest),

power_manager: *wlr.OutputPowerManagerV1,
power_manager_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) = .init(handlePowerManagerSetMode),

gamma_control_manager: *wlr.GammaControlManagerV1,

/// All Outputs that have a corresponding wlr_output.
outputs: wl.list.Head(Output, .link),

pub fn init(om: *OutputManager) !void {
    const output_layout = try wlr.OutputLayout.create(server.wl_server);
    errdefer output_layout.destroy();

    const gamma_control_manager = try wlr.GammaControlManagerV1.create(server.wl_server);
    server.scene.wlr_scene.setGammaControlManagerV1(gamma_control_manager);

    om.* = .{
        .output_layout = output_layout,
        .outputs = undefined,

        .presentation = try wlr.Presentation.create(server.wl_server, server.backend, 2),
        .xdg_output_manager = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout),
        .wlr_output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .gamma_control_manager = gamma_control_manager,
    };

    om.outputs.init();

    server.backend.events.new_output.add(&om.new_output);
    om.wlr_output_manager.events.apply.add(&om.manager_apply);
    om.wlr_output_manager.events.@"test".add(&om.manager_test);
    om.power_manager.events.set_mode.add(&om.power_manager_set_mode);
}

pub fn deinit(om: *OutputManager) void {
    om.manager_apply.link.remove();
    om.manager_test.link.remove();
    om.power_manager_set_mode.link.remove();

    om.output_layout.destroy();
}

fn handleNewOutput(_: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    log.debug("new output {s}", .{wlr_output.name});

    Output.create(wlr_output) catch |err| {
        switch (err) {
            error.OutOfMemory => log.err("out of memory", .{}),
            error.InitRenderFailed => log.err("failed to initialize renderer for output {s}", .{wlr_output.name}),
        }
        wlr_output.destroy();
        return;
    };
    server.aqueous.output_service.outputsChanged(true);
}

/// Returns null if there are no outputs in the output layout
pub fn outputAt(om: *OutputManager, lx: f64, ly: f64) ?*wlr.Output {
    var output_lx: f64 = undefined;
    var output_ly: f64 = undefined;
    om.output_layout.closestPoint(null, lx, ly, &output_lx, &output_ly);
    return om.output_layout.outputAt(output_lx, output_ly);
}

pub const ApplyError = error{
    MissingMatcher,
    UnknownOutput,
    WildcardPosition,
    ModeNotAdvertised,
    InvalidCoordinates,
    TooManyOutputs,
};

pub const RejectionReason = enum {
    missing_matcher,
    unknown_output,
    wildcard_position,
    mode_not_advertised,
    invalid_coordinates,
};

pub const Rejection = struct {
    spec_index: usize,
    matcher_kind: enum { name, edid },
    matcher: OutputConfig.Text,
    output_name: ?[]const u8,
    reason: RejectionReason,
};

pub const max_rejections = OutputConfig.max_outputs * 2;

pub const ApplyReport = struct {
    applied: usize = 0,
    rejections: [max_rejections]Rejection = undefined,
    rejection_count: usize = 0,
    total_rejections: usize = 0,

    fn reject(
        report: *ApplyReport,
        spec_index: usize,
        matcher_kind: @FieldType(Rejection, "matcher_kind"),
        matcher: OutputConfig.Text,
        output_name: ?[]const u8,
        reason: RejectionReason,
    ) void {
        if (report.rejection_count < report.rejections.len) {
            report.rejections[report.rejection_count] = .{
                .spec_index = spec_index,
                .matcher_kind = matcher_kind,
                .matcher = matcher,
                .output_name = output_name,
                .reason = reason,
            };
            report.rejection_count += 1;
        }
        report.total_rejections += 1;
    }
};

pub fn rejectionMessage(reason: RejectionReason) []const u8 {
    return switch (reason) {
        .missing_matcher => "missing 'name' or 'edid'",
        .unknown_output => "no connected output matches the spec",
        .wildcard_position => "position is not allowed with a wildcard name",
        .mode_not_advertised => "mode is not advertised by the output",
        .invalid_coordinates => "coordinates are incompatible with Xwayland",
    };
}

/// Validate and stage a native output transaction. Later specs override fields
/// from earlier specs, which preserves outputd's wildcard-then-specific behavior.
/// A rejected spec/output pair is reported and skipped without preventing valid
/// settings for other outputs from being staged. The existing WindowManager
/// transaction performs the atomic backend commit and restores `current` if
/// wlroots rejects the modeset.
pub fn applySpecs(om: *OutputManager, specs: []const OutputConfig.Spec) ApplyError!ApplyReport {
    const Pending = struct { output: *Output, state: Output.State };
    var pending: [OutputConfig.max_outputs]Pending = undefined;
    var pending_count: usize = 0;
    var report: ApplyReport = .{};

    for (specs, 0..) |*spec, spec_index| {
        const matcher_kind: @FieldType(Rejection, "matcher_kind") = if (!spec.edid.empty()) .edid else .name;
        const matcher = if (matcher_kind == .edid) spec.edid else spec.name;
        if (spec.name.empty() and spec.edid.empty()) {
            report.reject(spec_index, matcher_kind, matcher, null, .missing_matcher);
            continue;
        }
        const wildcard = spec.edid.empty() and hasGlob(spec.name.slice());
        if (wildcard and spec.x != null) {
            report.reject(spec_index, matcher_kind, matcher, null, .wildcard_position);
            continue;
        }
        var matched: usize = 0;
        var it = om.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;
            if (!matchesSpec(spec, wlr_output)) continue;
            matched += 1;
            var index: ?usize = null;
            var created = false;
            for (pending[0..pending_count], 0..) |entry, i| if (entry.output == output) {
                index = i;
                break;
            };
            if (index == null) {
                if (pending_count == pending.len) return error.TooManyOutputs;
                pending[pending_count] = .{ .output = output, .state = output.scheduled };
                index = pending_count;
                pending_count += 1;
                created = true;
            }
            var proposed = pending[index.?].state;
            applySpecToState(spec, wlr_output, &proposed) catch |err| {
                if (created) pending_count -= 1;
                report.reject(spec_index, matcher_kind, matcher, std.mem.span(wlr_output.name), switch (err) {
                    error.ModeNotAdvertised => .mode_not_advertised,
                    else => unreachable,
                });
                continue;
            };
            if (!coordinatesValid(&proposed)) {
                if (created) pending_count -= 1;
                report.reject(spec_index, matcher_kind, matcher, std.mem.span(wlr_output.name), .invalid_coordinates);
                continue;
            }
            pending[index.?].state = proposed;
        }
        if (matched == 0) report.reject(spec_index, matcher_kind, matcher, null, .unknown_output);
    }

    for (pending[0..pending_count]) |entry| entry.output.scheduled = entry.state;
    if (pending_count != 0) server.wm.dirtyWindowing();
    report.applied = pending_count;
    return report;
}

fn coordinatesValid(state: *const Output.State) bool {
    if (!build_options.xwayland or server.xwayland == null or state.state != .enabled) return true;
    const width, const height = state.dimensions();
    return state.x >= 0 and state.y >= 0 and
        state.x + width <= math.maxInt(i16) and
        state.y + height <= math.maxInt(i16);
}

fn applySpecToState(spec: *const OutputConfig.Spec, wlr_output: *wlr.Output, state: *Output.State) ApplyError!void {
    if (spec.enabled) |enabled| state.state = if (enabled) .enabled else .disabled_hard;
    if (spec.mode) |requested| {
        var selected: ?*wlr.Output.Mode = null;
        var modes = wlr_output.modes.iterator(.forward);
        while (modes.next()) |mode| {
            if (mode.width != requested.width or mode.height != requested.height) continue;
            const candidate: mode_match.Candidate = .{
                .refresh_mhz = mode.refresh,
                .preferred = mode.preferred,
            };
            const best: ?mode_match.Candidate = if (selected) |current| .{
                .refresh_mhz = current.refresh,
                .preferred = current.preferred,
            } else null;
            if (mode_match.prefer(requested.refresh_mhz, best, candidate)) {
                selected = mode;
            }
        }
        if (selected) |mode| {
            state.mode = .{ .standard = mode };
            if (requested.refresh_mhz) |refresh| log.info(
                "output {s}: requested {d}x{d}@{d} mHz, selected {d} mHz",
                .{ wlr_output.name, requested.width, requested.height, refresh, mode.refresh },
            );
        } else if (wlr_output.modes.first() == null) {
            state.mode = .{ .custom = .{ .width = requested.width, .height = requested.height, .refresh = requested.refresh_mhz orelse 0 } };
        } else return error.ModeNotAdvertised;
    }
    if (spec.scale) |scale| state.scale = scale;
    if (spec.transform) |transform| state.transform = transformToWl(transform);
    if (spec.x) |x| {
        state.x = x;
        state.y = spec.y.?;
        state.position_source = .configuration;
    }
    if (spec.adaptive_sync) |adaptive_sync| state.adaptive_sync = adaptive_sync;
}

/// Shared with the in-process output service when resolving the configured
/// primary output. Keeping this matcher in one place ensures name globs and
/// EDID identities have identical semantics for modesetting and selection.
pub fn matchesSpec(spec: *const OutputConfig.Spec, output: *wlr.Output) bool {
    if (!spec.edid.empty()) {
        var buffer: [7 + 64]u8 = undefined;
        const hash = outputIdentityHash(output, &buffer) orelse return false;
        return std.ascii.eqlIgnoreCase(spec.edid.slice(), hash);
    }
    return globMatch(spec.name.slice(), std.mem.span(output.name));
}

fn outputIdentityHash(output: *wlr.Output, buffer: *[71]u8) ?[]const u8 {
    if (output.make == null and output.model == null and output.serial == null) return null;
    var identity: [768]u8 = undefined;
    const source = std.fmt.bufPrint(&identity, "{s}|{s}|{s}", .{
        if (output.make) |value| std.mem.span(value) else "",
        if (output.model) |value| std.mem.span(value) else "",
        if (output.serial) |value| std.mem.span(value) else "",
    }) catch return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buffer, "sha256:{s}", .{hex}) catch null;
}

fn hasGlob(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (v < value.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == value[v])) {
            p += 1;
            v += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = v;
        } else if (star) |index| {
            p = index + 1;
            retry += 1;
            v = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn transformToWl(transform: OutputConfig.Transform) wl.Output.Transform {
    return switch (transform) {
        .normal => .normal,
        .rotate_90 => .@"90",
        .rotate_180 => .@"180",
        .rotate_270 => .@"270",
        .flipped => .flipped,
        .flipped_90 => .flipped_90,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_270,
    };
}

pub fn transformName(transform: wl.Output.Transform) []const u8 {
    return switch (transform) {
        .normal => "normal",
        .@"90" => "90",
        .@"180" => "180",
        .@"270" => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped-90",
        .flipped_180 => "flipped-180",
        .flipped_270 => "flipped-270",
        else => "normal",
    };
}

fn handleManagerTest(_: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
    defer config.destroy();

    if (!validateConfigCoordinates(config)) {
        config.sendFailed();
        return;
    }

    const states = config.buildState() catch {
        log.err("out of memory", .{});
        config.sendFailed();
        return;
    };
    defer std.c.free(states.ptr);

    var swapchain_manager: wlr.OutputSwapchainManager = undefined;
    swapchain_manager.init(server.backend);
    defer swapchain_manager.finish();

    if (swapchain_manager.prepare(states)) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

fn handleManagerApply(_: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
    log.info("applying output configuration", .{});

    if (!validateConfigCoordinates(config)) {
        config.sendFailed();
        return;
    }

    const repair_initial_overlap = shouldRepairInitialOverlap(&server.om, config);
    if (repair_initial_overlap) {
        log.warn("initial output-management transaction overlaps unconfigured outputs; retaining automatic positions", .{});
    }

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const output: *Output = @ptrCast(@alignCast(head.state.output.data));
        if (head.state.enabled) {
            log.debug("head {s}: enabled scale={d} transform={d} adaptive_sync={}", .{
                head.state.output.name,
                head.state.scale,
                @intFromEnum(head.state.transform),
                head.state.adaptive_sync_enabled,
            });
            const previous = output.scheduled.state;
            var proposed: Output.State = .fromHeadState(&head.state);
            if (repair_initial_overlap) proposed.position_source = .automatic;
            output.scheduled = proposed;
            // Maintain power management state set with wlr-output-power-management-v1
            if (previous == .disabled_soft) {
                output.scheduled.state = .disabled_soft;
            } else {
                assert(output.scheduled.state == .enabled);
            }
        } else {
            // Avoid overwriting and losing all other output state on disable.
            output.scheduled.state = .disabled_hard;
        }
    }

    if (server.wm.scheduled.output_config) |old| {
        old.sendFailed();
        old.destroy();
    }
    server.wm.scheduled.output_config = config;

    server.wm.dirtyWindowing();
}

/// Repair the uninitialized transaction emitted by output-management clients
/// which advertise every new head at (0, 0). Once any enabled output has an
/// explicitly owned position, overlap is treated as an intentional layout.
fn shouldRepairInitialOverlap(om: *OutputManager, config: *wlr.OutputConfigurationV1) bool {
    var outputs = om.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (output.scheduled.state == .enabled and output.scheduled.position_source != .automatic) return false;
    }

    var boxes: [OutputConfig.max_outputs]autolayout.Rect = undefined;
    var count: usize = 0;
    var heads = config.heads.iterator(.forward);
    while (heads.next()) |head| {
        if (!head.state.enabled) continue;
        if (count == boxes.len) return false;
        const proposed: Output.State = .fromHeadState(&head.state);
        const width, const height = proposed.dimensions();
        boxes[count] = .{
            .x = proposed.x,
            .y = proposed.y,
            .width = @intCast(width),
            .height = @intCast(height),
        };
        count += 1;
    }
    return autolayout.hasOverlap(boxes[0..count]);
}

fn validateConfigCoordinates(config: *wlr.OutputConfigurationV1) bool {
    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        if (!head.state.enabled) continue;

        const proposed: Output.State = .fromHeadState(&head.state);
        if (build_options.xwayland and server.xwayland != null) {
            // Negative output coordinates currently cause Xwayland clients to not receive click events.
            // See: https://gitlab.freedesktop.org/xorg/xserver/-/issues/899
            if (proposed.x < 0 or proposed.y < 0) {
                log.err(
                    \\Attempted to set negative coordinates for output {s}.
                    \\Negative output coordinates are disallowed if Xwayland is enabled due to a limitation of Xwayland.
                , .{head.state.output.name});
                return false;
            }
            const width, const height = proposed.dimensions();
            if (proposed.x + width > math.maxInt(i16) or
                proposed.y + height > math.maxInt(i16))
            {
                log.err(
                    \\Attempted to set too-large coordinates for output {s}.
                    \\Coordinates greater than {d} are disallowed if Xwayland is enabled due to a limitation of X11.
                , .{ head.state.output.name, math.maxInt(i16) });
                return false;
            }
        }
    }
    return true;
}

fn handlePowerManagerSetMode(
    _: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
    event: *wlr.OutputPowerManagerV1.event.SetMode,
) void {
    // The output may have been destroyed, in which case there is nothing to do
    const output = @as(?*Output, @ptrCast(@alignCast(event.output.data))) orelse return;

    log.debug("client requested dpms {s} for output {s}", .{
        @tagName(event.mode),
        event.output.name,
    });

    switch (output.scheduled.state) {
        .enabled => {
            if (event.mode == .off) output.scheduled.state = .disabled_soft else return;
        },
        .disabled_soft => {
            if (event.mode == .on) output.scheduled.state = .enabled else return;
        },
        .disabled_hard, .destroying => unreachable,
    }

    server.wm.dirtyWindowing();
}

pub fn autoLayout(om: *OutputManager) void {
    // Find the right most edge of any non-autolayout output.
    var rightmost_edge: i32 = 0;
    var row_y: i32 = 0;
    {
        var it = om.outputs.iterator(.forward);
        while (it.next()) |output| {
            if (output.scheduled.state != .enabled or output.scheduled.position_source == .automatic) continue;

            const x = output.scheduled.x + output.scheduled.dimensions()[0];
            if (x > rightmost_edge) {
                rightmost_edge = x;
                row_y = output.scheduled.y;
            }
        }
    }
    // Place autolayout outputs in a row starting at the rightmost edge.
    {
        var it = om.outputs.iterator(.forward);
        while (it.next()) |output| {
            if (output.scheduled.state != .enabled or output.scheduled.position_source != .automatic) continue;

            output.scheduled.x = rightmost_edge;
            output.scheduled.y = row_y;
            rightmost_edge += output.scheduled.dimensions()[0];
        }
    }
}

pub fn commitOutputState(om: *OutputManager) void {
    const wm = &server.wm;
    {
        var it = wm.sent.outputs.iterator(.forward);
        while (it.next()) |output| {
            assert(output.sent.state != .destroying);
            output.rendering_current = output.rendering_requested;
            // This may be null even when the state is not .destroying if the
            // output is destroyed between manage start and render finish.
            const wlr_output = output.wlr_output orelse continue;
            switch (output.sent.state) {
                .enabled, .disabled_soft => {
                    output.scene_output.?.setPosition(output.sent.x, output.sent.y);
                    _ = om.output_layout.add(wlr_output, output.sent.x, output.sent.y) catch {
                        log.err("out of memory", .{});
                        continue; // Try again next time
                    };
                    if (server.lock_manager.lockSurfaceFromOutput(output)) |lock_surface| {
                        lock_surface.tree.node.setPosition(output.sent.x, output.sent.y);
                    }
                },
                .disabled_hard => {
                    om.output_layout.remove(wlr_output);
                },
                .destroying => unreachable,
            }
        }
    }

    const need_modeset = blk: {
        var it = wm.sent.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;
            switch (output.sent.state) {
                .enabled => if (!wlr_output.enabled) break :blk true,
                .disabled_soft, .disabled_hard => if (wlr_output.enabled) break :blk true,
                .destroying => unreachable,
            }
            switch (output.sent.mode) {
                .standard => |mode| {
                    if (mode != wlr_output.current_mode) break :blk true;
                },
                .custom => |mode| {
                    if (mode.width != wlr_output.width) break :blk true;
                    if (mode.height != wlr_output.height) break :blk true;
                    if (mode.refresh != wlr_output.refresh) break :blk true;
                },
                // This branch is reachable if we fail to enable an output.
                .none => assert(output.sent.state == .disabled_hard),
            }
            // If an output newly exposed to river is already enabled, we
            // must modeset since the mode is otherwise undefined.
            if (output.current.mode == .none and output.sent.state == .enabled) {
                break :blk true;
            }
            if (output.sent.adaptive_sync != (wlr_output.adaptive_sync_status == .enabled)) {
                break :blk true;
            }
            if (output.sent.state == .enabled) {
                if (output.sent.scale != wlr_output.scale) break :blk true;
                if (output.sent.transform != wlr_output.transform) break :blk true;
            }
        }
        break :blk false;
    };

    if (need_modeset) {
        log.debug("committing output state requires modeset", .{});

        var states: std.ArrayList(wlr.Backend.OutputState) = .empty;
        defer states.deinit(util.gpa);
        defer for (states.items) |*s| s.base.finish();

        {
            var it = wm.sent.outputs.iterator(.forward);
            while (it.next()) |output| {
                const wlr_output = output.wlr_output orelse continue;
                const state = states.addOne(util.gpa) catch {
                    log.err("out of memory", .{});
                    return;
                };

                state.output = wlr_output;
                state.base = wlr.Output.State.init();

                output.sent.applyModeset(&state.base);
            }
        }

        var swapchain_manager: wlr.OutputSwapchainManager = undefined;
        swapchain_manager.init(server.backend);
        defer swapchain_manager.finish();

        if (!swapchain_manager.prepare(states.items)) {
            log.err("failed to prepare new output configuration", .{});
            om.modesetFailed();
            return;
        }

        for (states.items) |*state| {
            const output: *Output = @ptrCast(@alignCast(state.output.data));
            output.effects_swapchain_path = true;
            const uncached_blur_damage =
                output.prepareUncachedBlurDamage();
            const built = output.scene_output.?.buildState(&state.base, &.{
                .swapchain = swapchain_manager.getSwapchain(state.output),
            });
            if (built and uncached_blur_damage) {
                output.setUncachedBlurDamage(&state.base);
            }
            output.effects_swapchain_path = false;
            if (!built) {
                log.err("failed to render scene for {s}", .{state.output.name});
            }
        }

        if (!server.backend.commit(states.items)) {
            log.err("failed to commit new output configuration", .{});
            om.modesetFailed();
            return;
        }
        om.first_modeset = false;

        swapchain_manager.apply();
    }

    if (wm.sent.output_config) |config| {
        config.sendSucceeded();
        config.destroy();
        wm.sent.output_config = null;
    }

    {
        var it = wm.sent.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;

            // The wl_output global is created by wlroots when the output is
            // added to the wlr_output_layout and a mode is committed.
            // Wlroots does not directly notify us when the wl_output global is created.
            // However, we want send the river_output_v1.wl_output event as soon as
            // possible and therefore need to check after committing a mode.
            // This is idempotent and retried until it succeeds (also from
            // Output.handleBind and Output.manageStart) so the DRM backend's
            // lazily-created global is eventually announced to the wm client.
            output.trySendWlOutput();
            output.current = output.sent;
            output.syncBlur(false);
            switch (output.sent.state) {
                .enabled => {
                    assert(wlr_output.enabled);
                    wlr_output.scheduleFrame();
                },
                .disabled_soft, .disabled_hard => {
                    assert(!wlr_output.enabled);
                    output.lock_render_state = .blanked;
                    if (output.sent.state == .disabled_hard) {
                        output.link_sent.remove();
                        output.link_sent.init();
                    }
                },
                .destroying => unreachable,
            }
        }
    }

    om.sendConfig() catch {
        log.err("out of memory", .{});
    };
    server.aqueous.output_service.outputsChanged(false);
}

fn modesetFailed(om: *OutputManager) void {
    const wm = &server.wm;

    // If the very first modeset fails, the user's hardware/drivers are
    // probably not compatible with river. In this case, exit rather
    // than running forever without rendering anything.
    if (om.first_modeset) {
        log.err("initial modeset failed, exiting river", .{});
        server.wl_server.terminate();
        return;
    }

    if (wm.sent.output_config) |config| {
        config.sendFailed();
        config.destroy();
        wm.sent.output_config = null;
    }

    {
        // Revert to last working state on failure
        var it = wm.sent.outputs.iterator(.forward);
        while (it.next()) |output| {
            output.scheduled = output.current;
            output.sent = output.current;
        }
        wm.dirtyWindowing();
    }
}

/// Send the current output state to all wlr-output-manager clients.
fn sendConfig(om: *OutputManager) !void {
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = om.outputs.iterator(.forward);
    while (it.next()) |output| {
        const wlr_output = output.wlr_output orelse continue;
        const head = try wlr.OutputConfigurationV1.Head.create(config, wlr_output);

        // It's only necessary to overwrite the state that does not require a modeset.
        // All state that requires a modeset will have already been committed to the wlr_output.
        head.state.enabled = switch (output.current.state) {
            .enabled, .disabled_soft => true,
            .disabled_hard => false,
            .destroying => unreachable,
        };
        head.state.scale = output.current.scale;
        head.state.transform = output.current.transform;
        head.state.x = output.current.x;
        head.state.y = output.current.y;
    }

    // wlroots won't send events to clients unless something has changed
    // compared to the last config set.
    om.wlr_output_manager.setConfiguration(config);
}

// Returning a wlr.Output rather than Output is more convenient at the callsites.
pub fn maxOverlapOutput(om: *OutputManager, box: *const wlr.Box) ?*wlr.Output {
    var max_overlap_area: i32 = 0;
    var max_overlap_output: ?*wlr.Output = null;
    var it = om.outputs.iterator(.forward);
    while (it.next()) |output| {
        const wlr_output = output.wlr_output orelse continue;
        var overlap: wlr.Box = undefined;
        om.output_layout.getBox(wlr_output, &overlap);
        if (overlap.empty()) continue; // output not in layout
        _ = overlap.intersection(&overlap, box);
        const overlap_area = overlap.width * overlap.height;
        if (overlap_area > max_overlap_area) {
            max_overlap_area = overlap_area;
            max_overlap_output = wlr_output;
        }
    }
    return max_overlap_output;
}
