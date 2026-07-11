// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const Mode = enum {
    external,
    internal,
    compare,

    pub fn parse(value: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, value);
    }

    pub fn runsInternal(mode: Mode) bool {
        return mode != .external;
    }

    pub fn allowsExternal(mode: Mode) bool {
        return mode != .internal;
    }
};

test "policy mode parsing and capabilities" {
    try std.testing.expectEqual(Mode.external, Mode.parse("external").?);
    try std.testing.expectEqual(Mode.internal, Mode.parse("internal").?);
    try std.testing.expectEqual(Mode.compare, Mode.parse("compare").?);
    try std.testing.expect(Mode.parse("invalid") == null);

    try std.testing.expect(!Mode.external.runsInternal());
    try std.testing.expect(Mode.external.allowsExternal());
    try std.testing.expect(Mode.internal.runsInternal());
    try std.testing.expect(!Mode.internal.allowsExternal());
    try std.testing.expect(Mode.compare.runsInternal());
    try std.testing.expect(Mode.compare.allowsExternal());
}
