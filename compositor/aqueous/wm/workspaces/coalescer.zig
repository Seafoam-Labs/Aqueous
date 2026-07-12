// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Coalescer = @This();

pub const Decision = enum {
    commit,
    no_op,
    coalesced,
    invalid,
};

switched_this_iteration: bool = false,
last_committed: u64 = 0,
ever_committed: bool = false,

pub fn focus(coalescer: *Coalescer, workspace: u64, live: bool) Decision {
    if (workspace == 0 or !live) return .invalid;
    if (coalescer.switched_this_iteration) return .coalesced;
    coalescer.switched_this_iteration = true;
    if (coalescer.ever_committed and workspace == coalescer.last_committed) return .no_op;
    coalescer.last_committed = workspace;
    coalescer.ever_committed = true;
    return .commit;
}

pub fn move(coalescer: *Coalescer, workspace: u64, live: bool, moved: bool) Decision {
    if (workspace == 0 or !live) return .invalid;
    if (coalescer.switched_this_iteration) return .coalesced;
    if (!moved) return .invalid;
    coalescer.switched_this_iteration = true;
    return .commit;
}

pub fn flushPending(coalescer: *Coalescer) void {
    coalescer.switched_this_iteration = false;
}

test "workspace focus is first-wins per dispatch iteration" {
    const std = @import("std");
    var coalescer: Coalescer = .{};
    try std.testing.expectEqual(Decision.commit, coalescer.focus(1, true));
    try std.testing.expectEqual(Decision.coalesced, coalescer.focus(2, true));
    coalescer.flushPending();
    try std.testing.expectEqual(Decision.no_op, coalescer.focus(1, true));
    try std.testing.expectEqual(Decision.coalesced, coalescer.focus(2, true));
    coalescer.flushPending();
    try std.testing.expectEqual(Decision.invalid, coalescer.focus(0, false));
    try std.testing.expectEqual(Decision.commit, coalescer.focus(2, true));
}

test "failed move does not claim the iteration" {
    const std = @import("std");
    var coalescer: Coalescer = .{};
    try std.testing.expectEqual(Decision.invalid, coalescer.move(1, true, false));
    try std.testing.expectEqual(Decision.commit, coalescer.move(2, true, true));
    try std.testing.expectEqual(Decision.coalesced, coalescer.move(3, true, true));
}
