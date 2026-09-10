// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const policy = @import("tablet");
const io = std.Io.Threaded.global_single_threaded.io();
const a = std.heap.c_allocator;
const max_file = 1024 * 1024;

pub fn run(args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    if (args.len < 3) return error.InvalidArguments;
    const list = std.mem.eql(u8, args[2], "devices");
    if (list and (args.len != 4 or !std.mem.eql(u8, args[3], "--json"))) return error.InvalidArguments;
    if (!list and !std.mem.eql(u8, args[2], "generate-config")) return error.InvalidArguments;
    var flags: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer flags.deinit(a);
    if (!list) {
        var i: usize = 3;
        while (i < args.len) {
            const key = args[i];
            if (flags.contains(key)) return error.InvalidArguments;
            if (std.mem.eql(u8, key, "--disabled")) {
                try flags.put(a, key, "true");
                i += 1;
                continue;
            }
            if (i + 1 >= args.len) return error.InvalidArguments;
            const allowed = [_][]const u8{ "--device", "--output", "--id", "--mapping", "--write" };
            for (allowed) |name| {
                if (std.mem.eql(u8, name, key)) break;
            } else return error.InvalidArguments;
            try flags.put(a, key, args[i + 1]);
            i += 2;
        }
        if (!flags.contains("--device") or !flags.contains("--id")) return error.InvalidArguments;
        const choices = @intFromBool(flags.contains("--output")) + @as(u8, @intFromBool(flags.contains("--mapping"))) + @intFromBool(flags.contains("--disabled"));
        if (choices != 1 or (flags.get("--mapping") != null and !std.mem.eql(u8, flags.get("--mapping").?, "desktop"))) return error.InvalidArguments;
    }
    var parsed = @import("OutputInfo.zig").readRequest(a, "{\"op\":\"input_devices\"}\n") orelse return error.InputDiscoveryUnavailable;
    defer parsed.deinit();
    const snapshot = parsed.value;
    if (!boolField(snapshot, "ok")) return error.InputDiscoveryUnavailable;
    if (list) {
        try std.json.Stringify.value(snapshot, .{}, out);
        try out.writeByte('\n');
        try out.flush();
        return;
    }
    if (!boolField(snapshot, "internal_policy")) return error.ExternalPolicyOwnsInput;
    const rule = try generate(snapshot, flags.get("--device").?, flags.get("--id").?, flags.get("--output"), flags.contains("--disabled"));
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    if (!rule.match_path.empty()) try writer.writer.writeAll("# Device identity includes its physical port (ID_PATH).\n");
    if (!rule.output.empty()) try writer.writer.writeAll("# Output is connector-bound; update this rule if the connector name changes.\n");
    try policy.writeRule(&writer.writer, &rule);
    if (flags.get("--write")) |path| {
        if (!boolField(snapshot, "base_tablets_valid")) return error.InvalidInheritedTabletPolicy;
        const baseline = policy.parse(str(snapshot, "base_tablets"));
        if (!baseline.valid) return error.InvalidInheritedTabletPolicy;
        try writeConfig(path, &rule, &baseline, snapshot);
        var refreshed = @import("OutputInfo.zig").readRequest(a, "{\"op\":\"input_devices\"}\n");
        defer if (refreshed) |*value| value.deinit();
        const active = try isActive(path, str(if (refreshed) |value| value.value else snapshot, "input_file"));
        try err.print("Wrote tablet rule '{s}' to {s}. {s}\n", .{ rule.id.slice(), path, if (active) "Active input sidecar; application follows the normal configuration watcher (check input devices --json)." else "This is not the currently active input sidecar; select it in Aqueous configuration if needed." });
        try err.flush();
    } else {
        try out.writeAll(writer.written());
        try out.flush();
    }
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const value = v.object.get(key) orelse return "";
    return if (value == .string) value.string else "";
}
fn boolField(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const value = v.object.get(key) orelse return false;
    return value == .bool and value.bool;
}
fn idField(v: std.json.Value, key: []const u8) ?u16 {
    if (v != .object) return null;
    const value = v.object.get(key) orelse return null;
    return if (value == .integer) std.math.cast(u16, value.integer) else null;
}
fn array(v: std.json.Value, key: []const u8) ![]std.json.Value {
    if (v != .object) return error.InvalidDiscovery;
    const value = v.object.get(key) orelse return error.InvalidDiscovery;
    if (value != .array) return error.InvalidDiscovery;
    return value.array.items;
}
fn identity(d: std.json.Value) policy.Identity {
    return .{ .name = str(d, "name"), .vendor = idField(d, "vendor"), .product = idField(d, "product"), .path = str(d, "path"), .virtual = boolField(d, "virtual"), .tablet = std.mem.eql(u8, str(d, "type"), "tablet") };
}

fn generate(snapshot: std.json.Value, device_id: []const u8, rule_id: []const u8, output_name: ?[]const u8, disabled: bool) !policy.Rule {
    const devices = try array(snapshot, "devices");
    const device = for (devices) |d| {
        if (std.mem.eql(u8, str(d, "id"), device_id)) break d;
    } else return error.DeviceNotFound;
    const d = identity(device);
    if (!d.tablet or d.virtual) return error.NotPhysicalTablet;
    var r: policy.Rule = .{ .id = try policy.Text.init(rule_id), .match_name = try policy.Text.init(d.name), .match_vendor = d.vendor, .match_product = d.product, .enabled = !disabled };
    var matches: usize = 0;
    for (devices) |other| if (r.matches(identity(other))) {
        matches += 1;
    };
    if (matches != 1) {
        if (d.path.len == 0) return error.AmbiguousDeviceIdentity;
        r.match_path = try policy.Text.init(d.path);
        matches = 0;
        for (devices) |other| if (r.matches(identity(other))) {
            matches += 1;
        };
        if (matches != 1) return error.AmbiguousDeviceIdentity;
    }
    if (output_name) |name| {
        const outputs = try array(snapshot, "outputs");
        const output = for (outputs) |o| {
            if (std.mem.eql(u8, str(o, "name"), name)) break o;
        } else return error.OutputNotFound;
        if (!boolField(output, "enabled") or boolField(output, "mirror")) return error.OutputUnavailable;
        const hash = str(output, "edid");
        var hashes: usize = 0;
        for (outputs) |o| if (std.mem.eql(u8, str(o, "edid"), hash)) {
            hashes += 1;
        };
        if (hash.len == 71 and hashes == 1) r.output_edid = try policy.Text.init(hash) else r.output = try policy.Text.init(name);
    } else if (!disabled) r.mapping = .desktop;
    try r.validate();
    return r;
}

/// Replace only statements in the selected tablet table. Standalone comments,
/// whitespace and every unrelated table are preserved byte-for-byte.
pub fn updateSource(allocator: std.mem.Allocator, source: []const u8, rule: *const policy.Rule) ![]u8 {
    try validateDocument(allocator, source);
    const before = policy.parse(source);
    if (!before.valid) return error.InvalidExistingTabletPolicy;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var scanner: policy.Scanner = .{ .source = source };
    var table_index: usize = 0;
    var removing = false;
    var copied: usize = 0;
    while (try scanner.next()) |st| {
        if (st.text[0] == '[') {
            removing = false;
            if (std.mem.eql(u8, st.text, "[[input.tablet]]")) {
                removing = std.mem.eql(u8, before.rules[table_index].id.slice(), rule.id.slice());
                table_index += 1;
            } else if (st.text[st.text.len - 1] != ']') return error.InvalidExistingToml;
        } else {
            // Fail closed on statements the line-oriented configuration format
            // cannot identify as assignments; never rewrite arbitrary text.
            const eq = std.mem.indexOfScalar(u8, st.text, '=') orelse return error.InvalidExistingToml;
            if (eq == 0 or std.mem.trim(u8, st.text[eq + 1 ..], " \t").len == 0) return error.InvalidExistingToml;
        }
        if (removing) {
            try writer.writer.writeAll(source[copied..st.start]);
            const leading = std.mem.indexOf(u8, source[st.start..st.end], st.text) orelse return error.InvalidExistingToml;
            const tail = source[st.start + leading + st.text.len .. st.end];
            if (std.mem.indexOfScalar(u8, tail, '#') != null) try writer.writer.writeAll(tail);
            copied = st.end;
        }
    }
    try writer.writer.writeAll(source[copied..]);
    if (writer.written().len > 0 and writer.written()[writer.written().len - 1] != '\n') try writer.writer.writeByte('\n');
    // No blank line accumulation when repeatedly updating the final rule.
    try policy.writeRule(&writer.writer, rule);
    const result = policy.parse(writer.written());
    if (!result.valid) return error.InvalidGeneratedTabletPolicy;
    return allocator.dupe(u8, writer.written());
}

// The writer accepts the TOML forms used by input.toml, including arrays,
// multiline strings and inline tables. Unsupported forms fail before mutation.
const ValueParser = struct {
    text: []const u8,
    pos: usize = 0,
    fn skip(p: *ValueParser) void {
        while (p.pos < p.text.len) {
            if (std.ascii.isWhitespace(p.text[p.pos])) {
                p.pos += 1;
                continue;
            }
            if (p.text[p.pos] != '#') return;
            while (p.pos < p.text.len and p.text[p.pos] != '\n') p.pos += 1;
        }
    }
    fn quoted(p: *ValueParser) !void {
        const q = p.text[p.pos];
        p.pos += 1;
        const triple = p.pos + 1 < p.text.len and p.text[p.pos] == q and p.text[p.pos + 1] == q;
        if (triple) p.pos += 2;
        while (p.pos < p.text.len) {
            const ch = p.text[p.pos];
            p.pos += 1;
            if (ch == q) {
                if (!triple) return;
                if (p.pos + 1 < p.text.len and p.text[p.pos] == q and p.text[p.pos + 1] == q) {
                    p.pos += 2;
                    return;
                }
            }
            if ((ch < 0x20 and ch != '\t' and !(triple and (ch == '\n' or ch == '\r'))) or ch == 0x7f) return error.InvalidExistingToml;
            if (ch == '\\' and q == '"') {
                if (p.pos == p.text.len) return error.InvalidExistingToml;
                const escape = p.text[p.pos];
                p.pos += 1;
                if (triple and std.ascii.isWhitespace(escape)) {
                    while (p.pos < p.text.len and std.ascii.isWhitespace(p.text[p.pos])) p.pos += 1;
                    continue;
                }
                if (escape == 'u' or escape == 'U') {
                    const n: usize = if (escape == 'u') 4 else 8;
                    if (p.pos + n > p.text.len) return error.InvalidExistingToml;
                    const cp = std.fmt.parseInt(u21, p.text[p.pos..][0..n], 16) catch return error.InvalidExistingToml;
                    var encoded: [4]u8 = undefined;
                    _ = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidExistingToml;
                    p.pos += n;
                } else if (std.mem.indexOfScalar(u8, "\"\\btnfr", escape) == null) return error.InvalidExistingToml;
            }
        }
        return error.InvalidExistingToml;
    }
    fn key(p: *ValueParser) !void {
        p.skip();
        if (p.pos == p.text.len) return error.InvalidExistingToml;
        if (p.text[p.pos] == '"' or p.text[p.pos] == '\'') {
            try p.quoted();
            return;
        }
        const start = p.pos;
        while (p.pos < p.text.len and (std.ascii.isAlphanumeric(p.text[p.pos]) or p.text[p.pos] == '_' or p.text[p.pos] == '-')) p.pos += 1;
        if (start == p.pos) return error.InvalidExistingToml;
    }
    fn path(p: *ValueParser) !void {
        try p.key();
        p.skip();
        while (p.pos < p.text.len and p.text[p.pos] == '.') {
            p.pos += 1;
            try p.key();
            p.skip();
        }
    }
    fn value(p: *ValueParser, depth: usize) anyerror!void {
        if (depth > 32) return error.InvalidExistingToml;
        p.skip();
        if (p.pos == p.text.len) return error.InvalidExistingToml;
        const ch = p.text[p.pos];
        if (ch == '"' or ch == '\'') return p.quoted();
        if (ch == '[' or ch == '{') {
            p.pos += 1;
            p.skip();
            const end: u8 = if (ch == '[') ']' else '}';
            while (p.pos < p.text.len and p.text[p.pos] != end) {
                if (ch == '{') {
                    try p.path();
                    if (p.pos == p.text.len or p.text[p.pos] != '=') return error.InvalidExistingToml;
                    p.pos += 1;
                }
                try p.value(depth + 1);
                p.skip();
                if (p.pos == p.text.len) return error.InvalidExistingToml;
                if (p.text[p.pos] == end) break;
                if (p.text[p.pos] != ',') return error.InvalidExistingToml;
                p.pos += 1;
                p.skip();
                if (ch == '{' and p.pos < p.text.len and p.text[p.pos] == end) return error.InvalidExistingToml;
            }
            if (p.pos == p.text.len) return error.InvalidExistingToml;
            p.pos += 1;
            return;
        }
        const start = p.pos;
        while (p.pos < p.text.len and std.mem.indexOfScalar(u8, " \t\r\n,]}#", p.text[p.pos]) == null) p.pos += 1;
        const token = p.text[start..p.pos];
        if (token.len == 0) return error.InvalidExistingToml;
        for ([_][]const u8{ "true", "false", "inf", "+inf", "-inf", "nan", "+nan", "-nan" }) |v| if (std.mem.eql(u8, token, v)) return;
        // Numeric validation is deliberately conservative: unknown bare values
        // (including timestamps, not used by input settings) are not rewritten.
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        for (token, 0..) |v, i| {
            if (v == '_') {
                if (i == 0 or i + 1 == token.len or !std.ascii.isHex(token[i - 1]) or !std.ascii.isHex(token[i + 1])) return error.InvalidExistingToml;
                continue;
            }
            if (n == buf.len) return error.InvalidExistingToml;
            buf[n] = v;
            n += 1;
        }
        const number = buf[0..n];
        if (std.fmt.parseInt(i64, number, 0)) |_| return else |_| {}
        if (std.mem.indexOfAny(u8, number, ".eE") == null) return error.InvalidExistingToml;
        _ = std.fmt.parseFloat(f64, number) catch return error.InvalidExistingToml;
        if (number[0] == '.' or number[number.len - 1] == '.') return error.InvalidExistingToml;
    }
};
fn validateDocument(allocator: std.mem.Allocator, source: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidExistingToml;
    var scanner: policy.Scanner = .{ .source = source };
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit(allocator);
    }
    var table: []const u8 = "";
    var array_index: usize = 0;
    while (try scanner.next()) |st| {
        var p: ValueParser = .{ .text = st.text };
        if (st.text[0] == '[') {
            const multiple = st.text.len > 1 and st.text[1] == '[';
            p.pos = if (multiple) 2 else 1;
            const start = p.pos;
            try p.path();
            const end = p.pos;
            const suffix: []const u8 = if (multiple) "]]" else "]";
            if (!std.mem.eql(u8, st.text[p.pos..], suffix)) return error.InvalidExistingToml;
            table = st.text[start..end];
            if (multiple) array_index += 1;
        } else {
            try p.path();
            const key_end = p.pos;
            if (p.pos == st.text.len or st.text[p.pos] != '=') return error.InvalidExistingToml;
            p.pos += 1;
            try p.value(0);
            p.skip();
            if (p.pos != st.text.len) return error.InvalidExistingToml;
            const key = try std.fmt.allocPrint(allocator, "{d}:{s}:{s}", .{ array_index, table, std.mem.trim(u8, st.text[0..key_end], " \t") });
            if (seen.contains(key)) {
                allocator.free(key);
                return error.InvalidExistingToml;
            }
            try seen.put(allocator, key, {});
        }
    }
}

fn canonical(path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch |e| switch (e) {
        error.FileNotFound => blk: {
            const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (st) |s| if (s.kind == .sym_link) return error.DanglingSymlink;
            // Resolve the parent even for a new file, preserving directory symlinks.
            const parent = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", a);
            defer a.free(parent);
            break :blk try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, std.fs.path.basename(path) }, 0);
        },
        else => return e,
    };
}
fn isActive(path: []const u8, configured: []const u8) !bool {
    if (configured.len == 0) return false;
    const dest = try canonical(path);
    defer a.free(dest);
    const active = canonical(configured) catch return false;
    defer a.free(active);
    return std.mem.eql(u8, dest, active);
}

fn writeConfig(path: []const u8, rule: *const policy.Rule, baseline: *const policy.Policy, snapshot: std.json.Value) !void {
    if (path.len == 0) return error.InvalidArguments;
    const dest = try canonical(path);
    defer a.free(dest);
    if (std.mem.eql(u8, std.fs.path.basename(dest), "wm.toml")) return error.InputSidecarRequired;
    if (try isActive(dest, str(snapshot, "wm_file"))) return error.InputSidecarRequired;
    const old_stat = std.Io.Dir.cwd().statFile(io, dest, .{}) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (old_stat) |st| if (st.kind != .file) return error.NotRegularFile;
    const old = if (old_stat != null) try std.Io.Dir.cwd().readFileAlloc(io, dest, a, .limited(max_file)) else null;
    defer if (old) |b| a.free(b);
    const candidate = try updateSource(a, old orelse "", rule);
    defer a.free(candidate);
    var merged = baseline.*;
    const overlay = policy.parse(candidate);
    merged.overlay(&overlay);
    if (!merged.valid) return error.InvalidMergedTabletPolicy;
    for (try array(snapshot, "devices")) |device| {
        if (rule.matches(identity(device))) {
            const winner = merged.select(identity(device)) orelse return error.GeneratedRuleOverridden;
            if (!std.mem.eql(u8, winner.id.slice(), rule.id.slice())) return error.GeneratedRuleOverridden;
        }
    }
    if (old) |bytes| if (std.mem.eql(u8, bytes, candidate)) return;
    var temp = try std.Io.Dir.cwd().createFileAtomic(io, dest, .{ .replace = old != null, .permissions = if (old_stat) |st| st.permissions else .fromMode(0o600) });
    defer temp.deinit(io);
    try temp.file.writeStreamingAll(io, candidate);
    if (old_stat) |st| try temp.file.setPermissions(io, st.permissions);
    try temp.file.sync(io);
    if (old) |bytes| {
        const st = try std.Io.Dir.cwd().statFile(io, dest, .{});
        if (st.kind != .file or st.inode != old_stat.?.inode) return error.ConcurrentModification;
        const check = try std.Io.Dir.cwd().readFileAlloc(io, dest, a, .limited(max_file));
        defer a.free(check);
        if (!std.mem.eql(u8, check, bytes) or st.inode != old_stat.?.inode or !std.meta.eql(st.mtime, old_stat.?.mtime) or !std.meta.eql(st.ctime, old_stat.?.ctime)) return error.ConcurrentModification;
        const resolved = try canonical(path);
        defer a.free(resolved);
        if (!std.mem.eql(u8, resolved, dest)) return error.ConcurrentModification;
        try temp.replace(io);
    } else try temp.link(io);
}

test "tablet rule update preserves other tables and comments and is idempotent" {
    const source = "# original\n[input.mouse]\naccel_speed = 0.25\n[[input.tablet]] # pen\nid='pen'\n# keep this\nmatch_name='Pen'\noutput='DP-1'\n[gestures]\nswipe_3_left='hello'\n";
    const r: policy.Rule = .{ .id = try policy.Text.init("pen"), .match_name = try policy.Text.init("Pen"), .output = try policy.Text.init("DP-2") };
    const first = try updateSource(std.testing.allocator, source, &r);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "# keep this") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "[input.mouse]\naccel_speed = 0.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "[gestures]\nswipe_3_left='hello'") != null);
    const second = try updateSource(std.testing.allocator, first, &r);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "generator chooses stable identities, disambiguates ports and rejects stale selections" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"devices":[
        \\{"id":"1","name":"Pen","type":"tablet","vendor":1386,"product":827,"path":"port-1"},
        \\{"id":"2","name":"Pen","type":"tablet","vendor":1386,"product":827,"path":"port-2"},
        \\{"id":"3","name":"Mouse","type":"pointer"},
        \\{"id":"4","name":"Virtual Pen","type":"tablet","virtual":true}],
        \\"outputs":[{"name":"DP-1","enabled":true,"edid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        \\{"name":"DP-2","enabled":true,"edid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        \\{"name":"HDMI-A-1","enabled":true,"edid":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
        \\{"name":"DP-3","enabled":false},{"name":"DP-4","enabled":true,"mirror":true}]}
    , .{});
    defer parsed.deinit();
    const snapshot = parsed.value;
    const connector = try generate(snapshot, "1", "kamvas", "DP-1", false);
    try std.testing.expectEqualStrings("port-1", connector.match_path.slice());
    try std.testing.expectEqualStrings("DP-1", connector.output.slice());
    const stable = try generate(snapshot, "2", "intuos", "HDMI-A-1", false);
    try std.testing.expect(stable.output.empty() and !stable.output_edid.empty());
    try std.testing.expect((try generate(snapshot, "1", "desktop", null, false)).mapping == .desktop);
    try std.testing.expect(!(try generate(snapshot, "1", "off", null, true)).enabled);
    try std.testing.expectError(error.DeviceNotFound, generate(snapshot, "99", "pen", "DP-1", false));
    try std.testing.expectError(error.NotPhysicalTablet, generate(snapshot, "3", "pen", "DP-1", false));
    try std.testing.expectError(error.NotPhysicalTablet, generate(snapshot, "4", "pen", "DP-1", false));
    try std.testing.expectError(error.OutputUnavailable, generate(snapshot, "1", "pen", "DP-3", false));
    try std.testing.expectError(error.OutputUnavailable, generate(snapshot, "1", "pen", "DP-4", false));
    try std.testing.expectError(error.OutputNotFound, generate(snapshot, "1", "pen", "gone", false));
    const ds = try array(snapshot, "devices");
    _ = ds[0].object.swapRemove("path");
    try std.testing.expectError(error.AmbiguousDeviceIdentity, generate(snapshot, "1", "pen", "DP-1", false));
}

test "scoped writer rejects malformed input and preserves multiline contents" {
    const r: policy.Rule = .{ .id = try policy.Text.init("pen"), .match_name = try policy.Text.init("Pen"), .enabled = false };
    for ([_][]const u8{
        "[input.mouse]\naccel_speed=garbage\n", "[input.mouse]\naccel_speed=1\naccel_speed=2\n",
        "[gestures]\na='unterminated\n",        "[[input.tablet]]\nid='pen'\nunknown=true\n",
    }) |bad| {
        if (updateSource(std.testing.allocator, bad, &r)) |result| {
            std.testing.allocator.free(result);
            return error.AcceptedInvalidToml;
        } else |_| {}
    }
    const source = "[gestures]\ncommand='''\n[[input.tablet]]\nid='fake'\n'''\n";
    const result = try updateSource(std.testing.allocator, source, &r);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, source));
    try std.testing.expect(policy.parse(result).count == 1);
}
