// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
pub const Config = @import("wm/config/bell.zig").Config;
pub const visual_ms = 150;
pub const cooldown_ms = 500;
pub const playback_ms = 2000;
pub const kill_grace_ms = 100;

pub const Policy = struct {
    last_request: ?u64 = null,

    pub fn accept(policy: *Policy, now: u64, config: *const Config, eligible: bool, locked: bool) bool {
        if (!eligible or locked or config.mode == .off) return false;
        if (policy.last_request) |last| if (now -| last < cooldown_ms) return false;
        policy.last_request = now;
        return true;
    }
};

test "shared cooldown is not extended by floods, invalid targets or locks" {
    var policy: Policy = .{};
    var config: Config = .{};
    try std.testing.expect(!policy.accept(0, &config, false, false));
    try std.testing.expect(policy.accept(0, &config, true, false));
    for (1..500) |now| try std.testing.expect(!policy.accept(now, &config, true, false));
    try std.testing.expect(!policy.accept(500, &config, true, true));
    try std.testing.expect(policy.accept(500, &config, true, false));
    config.mode = .off;
    try std.testing.expect(!policy.accept(1000, &config, true, false));
    config.mode = .sound;
    try std.testing.expect(policy.accept(1000, &config, true, false));
    config.mode = .both;
    try std.testing.expect(!policy.accept(1001, &config, true, false));
    try std.testing.expect(policy.accept(1500, &config, true, false));
}

test {
    _ = @import("wm/config/bell.zig");
}
