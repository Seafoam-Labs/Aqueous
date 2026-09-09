// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const Visibility = struct {
    mapped: bool,
    capture: bool,
    desktop: bool,
    output: bool,
    preview: bool,
    workspace: bool,
    hidden: bool,
    clipped: bool,
};

pub fn suspended(v: Visibility) bool {
    if (!v.mapped or v.capture) return false;
    if (!v.desktop or !v.output) return true;
    return !v.preview and (!v.workspace or v.hidden or v.clipped);
}

test "suspension follows consumers, not focus or damage" {
    var v: Visibility = .{ .mapped = true, .capture = false, .desktop = true, .output = true, .preview = false, .workspace = true, .hidden = false, .clipped = false };
    try std.testing.expect(!suspended(v));
    v.workspace = false;
    try std.testing.expect(suspended(v));
    v.preview = true;
    try std.testing.expect(!suspended(v));
    v.desktop = false;
    try std.testing.expect(suspended(v));
    v.capture = true;
    try std.testing.expect(!suspended(v));
    v.capture = false;
    v.mapped = false;
    try std.testing.expect(!suspended(v));
    v.mapped = true;
    v.desktop = true;
    v.output = false;
    try std.testing.expect(suspended(v));
    v.output = true;
    v.workspace = true;
    v.preview = false;
    v.clipped = true;
    try std.testing.expect(suspended(v));
    v.clipped = false;
    v.hidden = true;
    try std.testing.expect(suspended(v));
}
