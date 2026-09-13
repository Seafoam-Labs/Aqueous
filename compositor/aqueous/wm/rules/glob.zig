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

/// Tag patterns additionally allow backslash to quote the following byte.
/// Missing metadata never matches, even for the wildcard or empty pattern.
pub fn matchesTag(pattern: []const u8, value: ?[]const u8) bool {
    const actual = value orelse return false;
    var pi: usize = 0;
    var vi: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (vi < actual.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            pi += 1;
            star = pi;
            retry = vi;
            continue;
        }
        if (pi < pattern.len) {
            const escaped = pattern[pi] == '\\' and pi + 1 < pattern.len;
            const token = pattern[pi + @intFromBool(escaped)];
            if ((!escaped and token == '?') or token == actual[vi]) {
                pi += if (escaped) @as(usize, 2) else 1;
                vi += 1;
                continue;
            }
        }
        if (star) |start| {
            retry += 1;
            vi = retry;
            pi = start;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

test "tag globs distinguish absent values and support literal metacharacters" {
    try std.testing.expect(!matchesTag("*", null));
    try std.testing.expect(!matchesTag("", null));
    try std.testing.expect(matchesTag("", ""));
    try std.testing.expect(matchesTag("*", ""));
    try std.testing.expect(matchesTag("set*?gs", "settings"));
    try std.testing.expect(!matchesTag("Settings", "settings"));
    try std.testing.expect(matchesTag("a\\*\\?\\\\b", "a*?\\b"));
    try std.testing.expect(!matchesTag("a\\*", "anything"));
    try std.testing.expect(matchesTag("*\\**", "literal*tag"));
}
