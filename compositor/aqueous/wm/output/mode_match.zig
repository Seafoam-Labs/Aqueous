// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

/// EDID timings commonly differ from their nominal refresh by a fraction of a
/// hertz (59.940 Hz vs. 60 Hz, for example). Keep accepting those nominal
/// values while rejecting a genuinely different advertised refresh rate.
pub const refresh_tolerance_mhz: u64 = 500;

pub const Candidate = struct {
    refresh_mhz: i32,
    preferred: bool,
};

/// Return whether `candidate` is a better advertised mode than `best` for the
/// requested refresh. This deliberately does not depend on backend enumeration
/// order: some DRM drivers expose near-nominal timings in a different order.
pub fn prefer(requested_refresh_mhz: ?i32, best: ?Candidate, candidate: Candidate) bool {
    const requested = requested_refresh_mhz orelse {
        return best == null or (candidate.preferred and !best.?.preferred);
    };

    const candidate_distance = refreshDistance(requested, candidate.refresh_mhz);
    if (candidate_distance >= refresh_tolerance_mhz) return false;
    const current = best orelse return true;
    const current_distance = refreshDistance(requested, current.refresh_mhz);
    return candidate_distance < current_distance or
        (candidate_distance == current_distance and candidate.preferred and !current.preferred);
}

fn refreshDistance(left: i32, right: i32) u64 {
    return @abs(@as(i64, left) - @as(i64, right));
}

test "closest near-nominal refresh wins regardless of enumeration order" {
    const modes = [_]Candidate{
        .{ .refresh_mhz = 59_940, .preferred = true },
        .{ .refresh_mhz = 60_000, .preferred = false },
    };
    var selected: ?Candidate = null;
    for (modes) |candidate| if (prefer(60_000, selected, candidate)) {
        selected = candidate;
    };
    try std.testing.expectEqual(@as(i32, 60_000), selected.?.refresh_mhz);
}

test "fractional EDID timing matches its nominal refresh" {
    const candidate: Candidate = .{ .refresh_mhz = 143_856, .preferred = false };
    try std.testing.expect(prefer(144_000, null, candidate));
}

test "refresh outside tolerance is rejected" {
    const candidate: Candidate = .{ .refresh_mhz = 143_500, .preferred = true };
    try std.testing.expect(!prefer(144_000, null, candidate));
}

test "geometry-only requests select the preferred timing" {
    const first: Candidate = .{ .refresh_mhz = 60_000, .preferred = false };
    const preferred: Candidate = .{ .refresh_mhz = 59_940, .preferred = true };
    try std.testing.expect(prefer(null, null, first));
    try std.testing.expect(prefer(null, first, preferred));
    try std.testing.expect(!prefer(null, preferred, first));
}
