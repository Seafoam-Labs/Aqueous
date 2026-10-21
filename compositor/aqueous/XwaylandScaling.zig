// SPDX-License-Identifier: GPL-3.0-only
const Adapter = @This();
const std = @import("std");
const build_options = @import("build_options");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const server = &@import("main.zig").server;
const Output = @import("Output.zig");
const policy = @import("xwayland_dpi_policy.zig");
const log = std.log.scoped(.xwayland);

const dpi = @import("xwayland_dpi.zig");
const Status = dpi.Status;

worker: ?*dpi.Supervisor = null,
timer: ?*wl.EventSource = null,
ready: wl.Listener(void) = .init(handleReady),
listening: bool = false,
status: Status = .{},
target_dpi: u32 = policy.base_dpi,
source: [256]u8 = undefined,
source_len: usize = 0,

pub fn init(adapter: *Adapter, xwayland: *wlr.Xwayland) void {
    if (!build_options.xwayland or server.xwayland_scaling != .native) return;
    adapter.timer = server.wl_server.getEventLoop().addTimer(*Adapter, tick, adapter) catch {
        adapter.status.state = .failed;
        log.warn("unable to initialize Xwayland DPI adapter", .{});
        return;
    };
    xwayland.events.ready.add(&adapter.ready);
    adapter.listening = true;
    adapter.refresh();
}

fn handleReady(listener: *wl.Listener(void)) void {
    if (!build_options.xwayland) return;
    const adapter: *Adapter = @fieldParentPtr("ready", listener);
    // Retire the old child asynchronously on wlroots automatic restarts.
    if (adapter.worker) |worker| {
        worker.restart();
    } else {
        adapter.worker = dpi.Supervisor.create(server.xwayland.?.display_name) catch null;
    }
    adapter.status = .{ .state = if (adapter.worker == null) .failed else .starting, .dpi = 0, .pid = 0 };
    adapter.refresh();
    _ = tick(adapter);
}

fn usable(output: *Output) bool {
    if (output.wlr_output == null or !output.current.mirror_of.empty()) return false;
    return output.current.state == .enabled and !output.current.box().empty();
}

/// Called after output commits; only applied output state feeds application DPI.
/// Primary declarations can also change without a geometry transaction, so the
/// timer reconciles those against the same current output state.
pub fn refresh(adapter: *Adapter) void {
    if (!build_options.xwayland or server.xwayland_scaling != .native) return;
    // Preview policy is staged before hardware commits. Preserve the previous
    // DPI/source until the complete output transaction has settled, including
    // rollback after a failed commit.
    var pending = server.om.outputs.iterator(.forward);
    while (pending.next()) |output| {
        if (!std.meta.eql(output.current, output.scheduled)) return;
    }
    var selected = server.aqueous.output_service.primaryOutput();
    if (selected) |output| if (!usable(output)) {
        selected = null;
    };
    if (selected == null) {
        var outputs = server.om.outputs.iterator(.forward);
        while (outputs.next()) |output| {
            if (!usable(output)) continue;
            if (selected == null or std.mem.order(u8, std.mem.span(output.wlr_output.?.name), std.mem.span(selected.?.wlr_output.?.name)) == .lt)
                selected = output;
        }
    }
    const name = if (selected) |output| std.mem.span(output.wlr_output.?.name) else "";
    adapter.source_len = @min(adapter.source.len, name.len);
    @memcpy(adapter.source[0..adapter.source_len], name[0..adapter.source_len]);
    adapter.target_dpi = policy.fromScale(if (selected) |output| output.current.scale else 1);
}

fn tick(adapter: *Adapter) c_int {
    adapter.refresh();
    if (adapter.worker) |worker| {
        const previous = adapter.status;
        adapter.status = worker.tick(adapter.target_dpi);
        if (previous.state != adapter.status.state or previous.dpi != adapter.status.dpi) {
            switch (adapter.status.state) {
                .applied => log.info("Xwayland application DPI={d} source={s}", .{ @as(f64, @floatFromInt(adapter.status.dpi)) / 1024, adapter.source[0..adapter.source_len] }),
                .external => log.warn("Xwayland DPI is externally managed; retaining the existing XSettings owner", .{}),
                .failed => log.warn("Xwayland DPI publication failed; retrying independently of rendering", .{}),
                else => {},
            }
        }
    }
    if (adapter.timer) |timer| timer.timerUpdate(100) catch {};
    return 0;
}

pub fn startupPending(adapter: *const Adapter) bool {
    return adapter.listening and adapter.status.state == .starting;
}

pub fn writeStatus(adapter: *const Adapter, json: *std.json.Stringify) !void {
    const enabled = build_options.xwayland and server.xwayland_enabled;
    const native = enabled and server.xwayland_scaling == .native;
    try json.write(.{
        .mode = if (enabled) @tagName(server.xwayland_scaling) else "disabled",
        .dpi_status = if (!native) "unmanaged" else switch (adapter.status.state) {
            .starting => "starting",
            .applied => "applied",
            .external => "external",
            else => "failed",
        },
        .target_dpi = if (native) @as(?f64, @as(f64, @floatFromInt(adapter.target_dpi)) / 1024) else null,
        .published_dpi = if (native and adapter.status.state == .applied) @as(?f64, @as(f64, @floatFromInt(adapter.status.dpi)) / 1024) else null,
        .source_output = if (native and adapter.source_len > 0) @as(?[]const u8, adapter.source[0..adapter.source_len]) else null,
    });
}

pub fn deinit(adapter: *Adapter) void {
    if (!build_options.xwayland) return;
    if (adapter.listening) adapter.ready.link.remove();
    if (adapter.timer) |timer| timer.remove();
    if (adapter.worker) |worker| worker.destroy();
    adapter.* = .{};
}
