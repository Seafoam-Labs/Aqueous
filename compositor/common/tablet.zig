// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
//! Shared tablet configuration, matching and TOML serialization.
const std = @import("std");
pub const limit = 32;
pub const Text = struct {
    bytes: [256]u8 = @splat(0),
    len: u16 = 0,
    pub fn init(s: []const u8) !Text {
        if (s.len > 256 or !std.unicode.utf8ValidateSlice(s) or std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidText;
        var t: Text = .{};
        @memcpy(t.bytes[0..s.len], s);
        t.len = @intCast(s.len);
        return t;
    }
    pub fn slice(t: *const Text) []const u8 {
        return t.bytes[0..t.len];
    }
    pub fn empty(t: *const Text) bool {
        return t.len == 0;
    }
};
pub const Identity = struct { name: []const u8, vendor: ?u16 = null, product: ?u16 = null, path: []const u8 = "", virtual: bool = false, tablet: bool = true };
pub const Rule = struct {
    id: Text = .{},
    match_name: Text = .{},
    match_vendor: ?u16 = null,
    match_product: ?u16 = null,
    match_path: Text = .{},
    enabled: bool = true,
    mapping: enum { output, desktop } = .output,
    output: Text = .{},
    output_edid: Text = .{},
    pub fn matches(r: *const Rule, d: Identity) bool {
        return d.tablet and !d.virtual and
            (r.match_name.empty() or std.mem.eql(u8, r.match_name.slice(), d.name)) and
            (r.match_vendor == null or r.match_vendor == d.vendor) and
            (r.match_product == null or r.match_product == d.product) and
            (r.match_path.empty() or std.mem.eql(u8, r.match_path.slice(), d.path));
    }
    pub fn validate(r: *const Rule) !void {
        if (r.id.empty() or (r.match_name.empty() and r.match_path.empty() and (r.match_vendor == null or r.match_product == null))) return error.MissingSelector;
        if (!r.enabled) {
            if (!r.output.empty() or !r.output_edid.empty() or r.mapping != .output) return error.InvalidMapping;
        } else if (r.mapping == .desktop) {
            if (!r.output.empty() or !r.output_edid.empty()) return error.InvalidMapping;
        } else if (r.output.empty() == r.output_edid.empty()) return error.InvalidMapping;
        if (!r.output_edid.empty()) {
            const s = r.output_edid.slice();
            if (s.len != 71 or !std.mem.startsWith(u8, s, "sha256:")) return error.InvalidOutputIdentity;
            for (s[7..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidOutputIdentity;
        }
    }
};
pub const Policy = struct {
    rules: [limit]Rule = @splat(.{}),
    count: u8 = 0,
    valid: bool = true,
    error_line: usize = 0,
    error_id: Text = .{},
    reason: []const u8 = "",
    pub fn select(p: *const Policy, d: Identity) ?*const Rule {
        var i: usize = p.count;
        while (i > 0) {
            i -= 1;
            if (p.rules[i].matches(d)) return &p.rules[i];
        }
        return null;
    }
    pub fn overlay(p: *Policy, other: *const Policy) void {
        if (!p.valid) return;
        if (!other.valid) {
            p.valid = false;
            p.error_line = other.error_line;
            p.error_id = other.error_id;
            p.reason = other.reason;
            return;
        }
        var result = p.*;
        for (other.rules[0..other.count]) |r| {
            for (result.rules[0..result.count], 0..) |old, i| {
                if (std.mem.eql(u8, old.id.slice(), r.id.slice())) {
                    std.mem.copyForwards(Rule, result.rules[i .. result.count - 1], result.rules[i + 1 .. result.count]);
                    result.count -= 1;
                    break;
                }
            }
            if (result.count == limit) {
                p.valid = false;
                p.reason = "TooManyTabletRules";
                return;
            }
            result.rules[result.count] = r;
            result.count += 1;
        }
        p.* = result;
    }
};

pub const Statement = struct { start: usize, end: usize, line: usize, text: []const u8 };
/// Split complete TOML statements, including multiline strings/arrays. Table
/// headers inside strings or comments are never interpreted as table boundaries.
pub const Scanner = struct {
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    pub fn next(s: *Scanner) !?Statement {
        while (s.pos < s.source.len) {
            const start = s.pos;
            const line = s.line;
            var quote: u8 = 0;
            var triple = false;
            var escaped = false;
            var depth: usize = 0;
            var comment = false;
            var cut: ?usize = null;
            while (s.pos < s.source.len) {
                const i = s.pos;
                const ch = s.source[i];
                s.pos += 1;
                if (ch == '\n') s.line += 1;
                if (comment) {
                    if (ch == '\n') {
                        comment = false;
                        if (depth == 0) break;
                    }
                    continue;
                }
                if (quote != 0) {
                    if (escaped) {
                        escaped = false;
                        continue;
                    }
                    if (quote == '"' and ch == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (ch == quote) {
                        if (!triple) quote = 0 else if (i + 2 < s.source.len and s.source[i + 1] == quote and s.source[i + 2] == quote) {
                            s.pos += 2;
                            quote = 0;
                            triple = false;
                        }
                    } else if (ch == '\n' and !triple) return error.UnterminatedString;
                    continue;
                }
                if (ch == '"' or ch == '\'') {
                    quote = ch;
                    if (i + 2 < s.source.len and s.source[i + 1] == ch and s.source[i + 2] == ch) {
                        triple = true;
                        s.pos += 2;
                    }
                } else if (ch == '#') {
                    comment = true;
                    if (depth == 0) cut = i;
                } else if (ch == '[' or ch == '{') depth += 1 else if (ch == ']' or ch == '}') {
                    if (depth == 0) return error.UnbalancedValue;
                    depth -= 1;
                } else if (ch == '\n' and depth == 0) break;
            }
            if (quote != 0 or depth != 0) return error.UnterminatedValue;
            const value = std.mem.trim(u8, s.source[start .. cut orelse s.pos], " \t\r\n");
            if (value.len == 0) continue;
            return .{ .start = start, .end = s.pos, .line = line, .text = value };
        }
        return null;
    }
};

pub fn string(raw: []const u8) !Text {
    if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'') or raw[raw.len - 1] != raw[0]) return error.ExpectedString;
    if (raw[0] == '\'') {
        if (std.mem.indexOfScalar(u8, raw[1 .. raw.len - 1], '\'') != null) return error.InvalidString;
        for (raw[1 .. raw.len - 1]) |ch| if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return error.InvalidString;
        return Text.init(raw[1 .. raw.len - 1]);
    }
    // Decode TOML basic strings without allocating in configuration reloads.
    var out: [256]u8 = undefined;
    var n: usize = 0;
    var i: usize = 1;
    while (i < raw.len - 1) {
        var ch = raw[i];
        i += 1;
        if (ch == '"' or (ch < 0x20 and ch != '\t') or ch == 0x7f) return error.InvalidString;
        if (ch == '\\') {
            if (i >= raw.len - 1) return error.InvalidString;
            ch = raw[i];
            i += 1;
            ch = switch (ch) {
                '"', '\\' => ch,
                'b' => 8,
                't' => 9,
                'n' => 10,
                'f' => 12,
                'r' => 13,
                'u', 'U' => blk: {
                    const len: usize = if (ch == 'u') 4 else 8;
                    if (i + len > raw.len - 1) return error.InvalidString;
                    const cp = std.fmt.parseInt(u21, raw[i..][0..len], 16) catch return error.InvalidString;
                    var buf: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidString;
                    if (n + count > out.len) return error.InvalidText;
                    @memcpy(out[n..][0..count], buf[0..count]);
                    n += count;
                    i += len;
                    break :blk 0;
                },
                else => return error.InvalidString,
            };
            if (ch == 0) continue;
        }
        if (n == out.len) return error.InvalidText;
        out[n] = ch;
        n += 1;
    }
    return Text.init(out[0..n]);
}
fn boolean(v: []const u8) !bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return error.ExpectedBoolean;
}
fn deviceId(value: []const u8) !u16 {
    var v = value;
    const hex = std.mem.startsWith(u8, v, "0x");
    if (hex) v = v[2..] else if (std.mem.startsWith(u8, v, "+")) v = v[1..];
    if (v.len == 0 or (!hex and v.len > 1 and v[0] == '0')) return error.InvalidDeviceId;
    for (v, 0..) |ch, i| {
        if (ch == '_') {
            if (i == 0 or i + 1 == v.len or v[i - 1] == '_') return error.InvalidDeviceId;
        } else if (if (hex) !std.ascii.isHex(ch) else !std.ascii.isDigit(ch)) return error.InvalidDeviceId;
    }
    return std.fmt.parseInt(u16, v, if (hex) 16 else 10) catch error.InvalidDeviceId;
}
fn field(r: *Rule, key: []const u8, value: []const u8) !void {
    inline for (.{ "id", "match_name", "match_path", "output", "output_edid" }) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(r, name) = try string(value);
            return;
        }
    }
    inline for (.{ "match_vendor", "match_product" }) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(r, name) = try deviceId(value);
            return;
        }
    }
    if (std.mem.eql(u8, key, "enabled")) {
        r.enabled = try boolean(value);
        return;
    }
    if (std.mem.eql(u8, key, "mapping")) {
        const v = try string(value);
        r.mapping = std.meta.stringToEnum(@TypeOf(r.mapping), v.slice()) orelse return error.InvalidMapping;
        return;
    }
    return error.UnknownTabletKey;
}
fn append(p: *Policy, r: Rule) !void {
    try r.validate();
    for (p.rules[0..p.count]) |old| if (std.mem.eql(u8, old.id.slice(), r.id.slice())) return error.DuplicateTabletId;
    if (p.count == limit) return error.TooManyTabletRules;
    p.rules[p.count] = r;
    p.count += 1;
}
fn validatePresence(r: Rule, keys: u16) !void {
    const mapping = @as(u16, 1) << 6;
    const output = @as(u16, 1) << 7;
    const edid = @as(u16, 1) << 8;
    if ((!r.enabled and keys & (mapping | output | edid) != 0) or
        (r.mapping == .desktop and keys & (output | edid) != 0) or
        (keys & (output | edid) == (output | edid))) return error.InvalidMapping;
}
pub fn parse(source: []const u8) Policy {
    var p: Policy = .{};
    parseInto(&p, source) catch |err| {
        p.valid = false;
        p.reason = @errorName(err);
    };
    return p;
}
fn parseInto(p: *Policy, source: []const u8) !void {
    var scan: Scanner = .{ .source = source };
    var rule: ?Rule = null;
    var keys: u16 = 0;
    while (try scan.next()) |st| {
        p.error_line = st.line;
        if (st.text[0] == '[') {
            if (rule) |r| {
                try validatePresence(r, keys);
                try append(p, r);
                rule = null;
            }
            keys = 0;
            p.error_id = .{};
            if (std.mem.eql(u8, st.text, "[[input.tablet]]")) rule = .{} else if (std.mem.startsWith(u8, st.text, "[input.tablet") or std.mem.startsWith(u8, st.text, "[[input.tablet")) return error.InvalidTabletTable;
        } else if (rule) |*r| {
            const eq = std.mem.indexOfScalar(u8, st.text, '=') orelse return error.InvalidAssignment;
            const key = std.mem.trim(u8, st.text[0..eq], " \t");
            const value = std.mem.trim(u8, st.text[eq + 1 ..], " \t");
            const names = [_][]const u8{ "id", "match_name", "match_vendor", "match_product", "match_path", "enabled", "mapping", "output", "output_edid" };
            const index = for (names, 0..) |name, i| {
                if (std.mem.eql(u8, key, name)) break i;
            } else return error.UnknownTabletKey;
            const bit = @as(u16, 1) << @as(u4, @intCast(index));
            if (keys & bit != 0) return error.DuplicateTabletKey;
            keys |= bit;
            try field(r, key, value);
            p.error_id = r.id;
        }
    }
    if (rule) |r| {
        try validatePresence(r, keys);
        try append(p, r);
    }
    p.error_line = 0;
    p.error_id = .{};
}

fn writeString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |ch| switch (ch) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(ch);
        },
        0...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{@as(u16, ch)}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}
pub fn writeRule(w: *std.Io.Writer, r: *const Rule) !void {
    try r.validate();
    try w.writeAll("[[input.tablet]]\n");
    inline for (.{ "id", "match_name", "match_path" }) |name| if (!@field(r, name).empty()) {
        try w.print("{s} = ", .{name});
        try writeString(w, @field(r, name).slice());
        try w.writeByte('\n');
    };
    inline for (.{ "match_vendor", "match_product" }) |name| if (@field(r, name)) |v| {
        try w.print("{s} = 0x{x:0>4}\n", .{ name, v });
    };
    if (!r.enabled) return w.writeAll("enabled = false\n");
    if (r.mapping == .desktop) return w.writeAll("mapping = \"desktop\"\n");
    const key: []const u8 = if (!r.output_edid.empty()) "output_edid" else "output";
    try w.print("{s} = ", .{key});
    try writeString(w, if (!r.output_edid.empty()) r.output_edid.slice() else r.output.slice());
    try w.writeByte('\n');
}

pub const Box = struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };
pub const Point = struct { x: f64, y: f64 };
/// Invert wl_output's logical-to-physical buffer transform for tablet input.
pub fn position(box: Box, transform: u3, x: f64, y: f64) Point {
    var u = std.math.clamp(x, 0, 1);
    var v = std.math.clamp(y, 0, 1);
    const old = u;
    switch (transform % 4) {
        0 => {},
        1 => {
            u = 1 - v;
            v = old;
        },
        2 => {
            u = 1 - u;
            v = 1 - v;
        },
        3 => {
            u = v;
            v = 1 - old;
        },
        else => unreachable,
    }
    if (transform >= 4) u = 1 - u;
    return .{ .x = box.x + @min(u * box.width, @max(0, box.width - 0.000001)), .y = box.y + @min(v * box.height, @max(0, box.height - 0.000001)) };
}

test "tablet rules validate, overlay and round trip escaped identities" {
    var p = parse("[[input.tablet]]\nid = \"a\"\nmatch_vendor = 0x056a\nmatch_product = 0x033b\noutput = \"DP-1\"\n");
    try std.testing.expect(p.valid);
    try std.testing.expect(p.select(.{ .name = "Pen", .vendor = 0x056a, .product = 0x033b }) != null);
    const other = parse("[[input.tablet]]\nid='a'\nmatch_name='Pen'\nenabled=false\n");
    p.overlay(&other);
    try std.testing.expect(p.valid and p.count == 1 and !p.rules[0].enabled);
    var r = p.rules[0];
    r.match_name = try Text.init("Pen \"\\ #[]\n\tß\x7f");
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writeRule(&writer.writer, &r);
    const round = parse(writer.written());
    try std.testing.expect(round.valid);
    try std.testing.expectEqualStrings(r.match_name.slice(), round.rules[0].match_name.slice());
    for ([_][]const u8{ "match_vendor=65536", "enabled=1", "unknown=true", "output='DP-2'", "mapping='invalid'" }) |bad| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "[[input.tablet]]\nid='a'\nmatch_name='Pen'\noutput='DP-1'\n{s}\n", .{bad});
        defer std.testing.allocator.free(text);
        try std.testing.expect(!parse(text).valid);
    }
}
test "scanner ignores fake tablet tables in multiline strings" {
    const p = parse("[other]\ntext = '''\n[[input.tablet]]\nid='fake'\n'''\n[[input.tablet]]\nid='real'\nmatch_name='Pen'\noutput='DP-1'\n");
    try std.testing.expect(p.valid and p.count == 1);
    try std.testing.expectEqualStrings("real", p.rules[0].id.slice());
}
test "absolute coordinates stay inside negative-origin scaled outputs for every transform" {
    const box: Box = .{ .x = -1706.6666667, .y = -200, .width = 1706.6666667, .height = 960 };
    for (0..8) |t| for ([_]f64{ -1, 0, 0.5, 1, 2 }) |x| for ([_]f64{ 0, 0.5, 1 }) |y| {
        const p = position(box, @intCast(t), x, y);
        try std.testing.expect(p.x >= box.x and p.x < box.x + box.width and p.y >= box.y and p.y < box.y + box.height);
    };
}

test "tablet orientation inverts the output buffer transform" {
    const expected = [_]Point{
        .{ .x = 20, .y = 30 }, .{ .x = 70, .y = 20 },
        .{ .x = 80, .y = 70 }, .{ .x = 30, .y = 80 },
        .{ .x = 80, .y = 30 }, .{ .x = 30, .y = 20 },
        .{ .x = 20, .y = 70 }, .{ .x = 70, .y = 80 },
    };
    for (expected, 0..) |p, t| {
        const actual = position(.{ .width = 100, .height = 100 }, @intCast(t), 0.2, 0.3);
        try std.testing.expectApproxEqAbs(p.x, actual.x, 0.00001);
        try std.testing.expectApproxEqAbs(p.y, actual.y, 0.00001);
    }
}

test "tablet policy rejects invalid identities and fails closed at the collection limit" {
    for ([_][]const u8{ "", "-1", "01", "0x", "0x_12", "12_", "1__2", "65536", "1.0", "0b10" }) |v| try std.testing.expectError(error.InvalidDeviceId, deviceId(v));
    try std.testing.expectEqual(@as(u16, 65535), try deviceId("0xff_ff"));
    for ([_][]const u8{
        "id='a'\nmatch_vendor=1\noutput='DP-1'",
        "id='a'\nmatch_name='Pen'\noutput='DP-1'\noutput_edid='bad'",
        "id='a'\nmatch_name='Pen'\nmapping='desktop'\noutput='DP-1'",
        "id='a'\nmatch_name='Pen'\nenabled=false\nmapping='output'",
        "id='a'\nid='b'\nmatch_name='Pen'\nenabled=false",
    }) |v| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "[[input.tablet]]\n{s}\n", .{v});
        defer std.testing.allocator.free(source);
        try std.testing.expect(!parse(source).valid);
    }
    var p: Policy = .{};
    for (0..limit) |i| {
        var buf: [20]u8 = undefined;
        try append(&p, .{ .id = try Text.init(try std.fmt.bufPrint(&buf, "{d}", .{i})), .match_name = try Text.init("Pen"), .enabled = false });
    }
    try std.testing.expect(p.select(.{ .name = "Pen", .virtual = true }) == null);
    try std.testing.expect(p.select(.{ .name = "Pen", .tablet = false }) == null);
    const more = parse("[[input.tablet]]\nid='extra'\nmatch_name='Pen'\nenabled=false\n");
    p.overlay(&more);
    try std.testing.expect(!p.valid and p.count == limit);
}
