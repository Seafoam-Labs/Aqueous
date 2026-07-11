// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Aqueous = @This();

const std = @import("std");

const CompositorApi = @import("CompositorApi.zig");
const Mode = @import("Mode.zig").Mode;
const Trace = @import("Trace.zig");

const log = std.log.scoped(.aqueous);

mode: Mode,
api: CompositorApi = .{},
trace: Trace = .{},

pub fn init(aqueous: *Aqueous, mode: Mode) void {
    aqueous.* = .{ .mode = mode };
    log.info("policy mode={s}", .{@tagName(mode)});
}

pub fn deinit(aqueous: *Aqueous) void {
    log.debug("policy stopped after {} trace event(s)", .{aqueous.trace.sequence});
}

pub fn allowsExternal(aqueous: *const Aqueous) bool {
    return aqueous.mode.allowsExternal();
}

pub fn traceCycle(aqueous: *Aqueous, phase: Trace.Phase, external_active: bool) void {
    const snapshot = aqueous.api.snapshot();
    if (aqueous.mode.runsInternal()) {
        aqueous.trace.emit(.internal, phase, snapshot);
    }
    if (external_active) {
        aqueous.trace.emit(.external, phase, snapshot);
    }
}
