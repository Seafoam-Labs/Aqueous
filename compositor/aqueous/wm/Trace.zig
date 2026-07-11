// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Trace = @This();

const std = @import("std");

const log = std.log.scoped(.aqueous);

pub const Phase = enum {
    manage_start,
    manage_finish,
    render_start,
    render_finish,
};

pub const Source = enum {
    internal,
    external,
};

pub const Snapshot = struct {
    windows: u32,
    rendering_order_hash: u64,
    geometry_hash: u64,
    workspace_hash: u64,
    focus_hash: u64,

    pub fn fingerprint(snapshot: Snapshot) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&snapshot.windows));
        hasher.update(std.mem.asBytes(&snapshot.rendering_order_hash));
        hasher.update(std.mem.asBytes(&snapshot.geometry_hash));
        hasher.update(std.mem.asBytes(&snapshot.workspace_hash));
        hasher.update(std.mem.asBytes(&snapshot.focus_hash));
        return hasher.final();
    }
};

sequence: u64 = 0,

pub fn emit(trace: *Trace, source: Source, phase: Phase, snapshot: Snapshot) void {
    trace.sequence +%= 1;
    log.info(
        "state-trace sequence={} source={s} phase={s} windows={} order=0x{x} geometry=0x{x} workspace=0x{x} focus=0x{x} fingerprint=0x{x}",
        .{
            trace.sequence,
            @tagName(source),
            @tagName(phase),
            snapshot.windows,
            snapshot.rendering_order_hash,
            snapshot.geometry_hash,
            snapshot.workspace_hash,
            snapshot.focus_hash,
            snapshot.fingerprint(),
        },
    );
}

test "snapshot fingerprint is stable and state-sensitive" {
    const baseline: Snapshot = .{
        .windows = 2,
        .rendering_order_hash = 17,
        .geometry_hash = 23,
        .workspace_hash = 29,
        .focus_hash = 31,
    };
    try std.testing.expectEqual(baseline.fingerprint(), baseline.fingerprint());
    try std.testing.expect(baseline.fingerprint() != (Snapshot{
        .windows = 3,
        .rendering_order_hash = 17,
        .geometry_hash = 23,
        .workspace_hash = 29,
        .focus_hash = 31,
    }).fingerprint());
    try std.testing.expect(baseline.fingerprint() != (Snapshot{
        .windows = 2,
        .rendering_order_hash = 18,
        .geometry_hash = 23,
        .workspace_hash = 29,
        .focus_hash = 31,
    }).fingerprint());
    try std.testing.expect(baseline.fingerprint() != (Snapshot{
        .windows = 2,
        .rendering_order_hash = 17,
        .geometry_hash = 24,
        .workspace_hash = 29,
        .focus_hash = 31,
    }).fingerprint());
}
