// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub fn matches(pattern: ?[]const u8, value: ?[]const u8) bool {
    const actual_pattern = pattern orelse return false;
    const actual_value = value orelse "";
    if (std.mem.indexOfAny(u8, actual_pattern, "*?") == null) {
        return std.mem.eql(u8, actual_pattern, actual_value);
    }
    return matchAt(actual_pattern, 0, actual_value, 0);
}

fn matchAt(pattern: []const u8, start_pattern: usize, value: []const u8, start_value: usize) bool {
    var pi = start_pattern;
    var vi = start_value;
    while (pi < pattern.len) {
        const token = pattern[pi];
        if (token == '*') {
            while (pi < pattern.len and pattern[pi] == '*') pi += 1;
            if (pi == pattern.len) return true;
            var split = vi;
            while (split <= value.len) : (split += 1) {
                if (matchAt(pattern, pi, value, split)) return true;
            }
            return false;
        }
        if (vi >= value.len) return false;
        if (token != '?' and token != value[vi]) return false;
        pi += 1;
        vi += 1;
    }
    return vi == value.len;
}

test "glob is anchored, case-sensitive, and handles empty values" {
    try std.testing.expect(!matches(null, "app"));
    try std.testing.expect(matches("*", null));
    try std.testing.expect(matches("", null));
    try std.testing.expect(matches("org.*.Editor", "org.foo.Editor"));
    try std.testing.expect(matches("term?nal", "terminal"));
    try std.testing.expect(!matches("term", "terminal"));
    try std.testing.expect(!matches("APP", "app"));
    try std.testing.expect(matches("a**b", "ab"));
}
