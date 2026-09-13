// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const Policy = struct {
    active: bool = false,
    locked: bool = false,
    stopping: bool = false,

    pub fn permitsLease(policy: Policy) bool {
        return policy.active and !policy.locked and !policy.stopping;
    }
};

pub fn reserved(is_drm: bool, non_desktop: bool) bool {
    return is_drm and non_desktop;
}

test "headsets stay reserved across lease policy transitions" {
    var policy: Policy = .{ .active = true };
    try std.testing.expect(reserved(true, true));
    try std.testing.expect(!reserved(false, true));
    try std.testing.expect(!reserved(true, false));
    try std.testing.expect(policy.permitsLease());
    policy.locked = true;
    policy.active = false;
    policy.active = true; // VT return cannot unlock an abandoned session lock.
    try std.testing.expect(!policy.permitsLease());
    policy.locked = false;
    try std.testing.expect(policy.permitsLease());
    policy.stopping = true;
    try std.testing.expect(!policy.permitsLease());
    try std.testing.expect(reserved(true, true));
}
