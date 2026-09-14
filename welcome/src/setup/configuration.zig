//! Reviewed configuration changes and version-1 recovery journals.
const std = @import("std");
const u = @import("common.zig");
const Context = u.Context;
const Value = u.Value;
const eq = u.eq;
const get = u.get;
const string = u.string;
const c = u.c;
const actions = .{
    .{ "actions.toggle_start_menu", "launcher", &[_][]const u8{ "noctalia msg panel-toggle launcher", "dms ipc call spotlight toggle", "pearlctl launcher toggle" } },
    .{ "actions.screenshot", "screenshot", &[_][]const u8{ "noctalia msg screenshot-region", "dms screenshot region", "grim -g \"$(slurp)\" - | wl-copy" } },
    .{ "actions.lock_screen", "lock", &[_][]const u8{ "noctalia msg lock", "dms ipc call lock lock", "pearlctl lock" } },
};
fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |known| if (eq(u8, known, value)) return true;
    return false;
}
pub const Request = struct { value: Value, preserved: Value };
pub fn request(ctx: *Context, snapshot: Value) !Request {
    var changes = ctx.array();
    var custom = ctx.array();
    var preserved = ctx.array();
    for (u.items(get(snapshot, "fields"))) |field| {
        inline for (actions) |action| if (eq(u8, string(field, "id"), action[0])) {
            const desired = "aqueous-shell-action " ++ action[1];
            if (!eq(u8, string(field, "value"), desired)) {
                if (u.yes(get(field, "inherited")) or contains(action[2], string(field, "value")))
                    try changes.array.append(try ctx.value(.{ .id = action[0], .value = desired }))
                else
                    try preserved.array.append(.{ .string = action[0] });
            }
        };
    }
    for (u.items(get(snapshot, "custom_keybinds"))) |binding| {
        const command = string(binding, "command");
        if (!std.mem.startsWith(u8, command, "spawn:")) continue;
        inline for (actions) |action| if (contains(action[2], command[6..])) {
            try custom.array.append(try ctx.value(.{ .id = get(binding, "id"), .op = "update", .chord = get(binding, "chord"), .command = "spawn:aqueous-shell-action " ++ action[1] }));
        };
    }
    if (get(snapshot, "generation") == .null) return ctx.fail("Configuration snapshot lacks a generation", .{});
    return .{ .value = try ctx.value(.{ .protocol = @as(u8, 1), .expected_generation = get(snapshot, "generation"), .create_user_override = true, .changes = changes, .custom_keybind_changes = custom }), .preserved = preserved };
}
pub const Portal = struct { path: []const u8, data: ?[]const u8, note: ?[]const u8 = null };
pub fn portal(ctx: *Context) !Portal {
    const root = try ctx.path(&.{ try ctx.config(), "xdg-desktop-portal-aqueous" });
    const upper = try ctx.path(&.{ root, "Aqueous" });
    const path = if (u.exists(upper)) upper else try ctx.path(&.{ root, "config" });
    const desired = "aqueous-shell-action chooser";
    const bytes = (try ctx.read(path)) orelse return .{ .path = path, .data = "[screencast]\nchooser_type=dmenu\nchooser_cmd=" ++ desired ++ "\n" };
    if (!std.unicode.utf8ValidateSlice(bytes)) return ctx.fail("Invalid portal configuration encoding", .{});
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var offset: usize = 0;
    var section_start: ?usize = null;
    var section_end = bytes.len;
    var in_section = false;
    var in_defaults = false;
    var default_command: ?[]const u8 = null;
    var cmd_span: ?[2]usize = null;
    var type_span: ?[2]usize = null;
    var old: []const u8 = "";
    var continuation = false;
    var had_section = false;
    while (lines.next()) |line| {
        const start = offset;
        offset += line.len + @intFromBool(offset + line.len < bytes.len);
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0 or text[0] == '#' or text[0] == ';') continue;
        if (text[0] == '[') {
            const end = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidPortal;
            if (in_section) section_end = start;
            in_section = eq(u8, text[1..end], "screencast");
            in_defaults = eq(u8, text[1..end], "DEFAULT");
            if (in_section) {
                if (section_start != null) return ctx.fail("Duplicate screencast section in portal configuration", .{});
                section_start = offset;
            }
            had_section = true;
            continuation = false;
            continue;
        }
        if (!had_section) return ctx.fail("Invalid portal configuration: missing section", .{});
        if (!in_section and !in_defaults) continue;
        // Multi-line chooser commands are custom and must remain untouched.
        if (continuation and (line[0] == ' ' or line[0] == '\t') and std.mem.indexOfAny(u8, text, "=:") == null)
            return .{ .path = path, .data = null, .note = try std.fmt.allocPrint(ctx.a, "Keep custom portal chooser: {s}", .{path}) };
        const equal = std.mem.indexOfAny(u8, text, "=:") orelse return error.InvalidPortal;
        const key = std.mem.trim(u8, text[0..equal], " \t");
        const value = std.mem.trim(u8, text[equal + 1 ..], " \t");
        continuation = std.ascii.eqlIgnoreCase(key, "chooser_cmd");
        if (in_defaults) {
            if (continuation) {
                if (default_command != null) return ctx.fail("Duplicate default portal chooser", .{});
                default_command = value;
            }
            continue;
        }
        if (continuation) {
            if (cmd_span != null) return ctx.fail("Duplicate portal chooser command", .{});
            cmd_span = .{ start, offset };
            old = value;
        } else if (std.ascii.eqlIgnoreCase(key, "chooser_type")) {
            if (type_span != null) return ctx.fail("Duplicate portal chooser type", .{});
            type_span = .{ start, offset };
        }
    }
    const known = &[_][]const u8{ "", "noctalia dmenu -p \"Select a source to share:\"", "/usr/lib/aqueous/aqueous-dms-portal-chooser", "/usr/bin/aqueous-shell-action chooser", desired };
    if (cmd_span == null) old = default_command orelse "";
    if (!contains(known, old)) return .{ .path = path, .data = null, .note = try std.fmt.allocPrint(ctx.a, "Keep custom portal chooser: {s}", .{path}) };
    var out: std.ArrayList(u8) = .empty;
    if (section_start) |start| {
        try out.appendSlice(ctx.a, bytes[0..start]);
        var i = start;
        while (i < section_end) {
            if (cmd_span) |span| if (i == span[0]) {
                try out.appendSlice(ctx.a, "chooser_cmd=" ++ desired ++ "\n");
                i = span[1];
                continue;
            };
            if (type_span) |span| if (i == span[0]) {
                try out.appendSlice(ctx.a, "chooser_type=dmenu\n");
                i = span[1];
                continue;
            };
            try out.append(ctx.a, bytes[i]);
            i += 1;
        }
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(ctx.a, '\n');
        if (cmd_span == null) try out.appendSlice(ctx.a, "chooser_cmd=" ++ desired ++ "\n");
        if (type_span == null) try out.appendSlice(ctx.a, "chooser_type=dmenu\n");
        try out.appendSlice(ctx.a, bytes[section_end..]);
    } else {
        try out.appendSlice(ctx.a, bytes);
        try out.appendSlice(ctx.a, "\n[screencast]\nchooser_type=dmenu\nchooser_cmd=" ++ desired ++ "\n");
    }
    return .{ .path = path, .data = try out.toOwnedSlice(ctx.a) };
}
pub fn startupConflicts(ctx: *Context) ![]const u8 {
    var conflicts: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "autostart", "systemd/user" }) |relative| {
        const base = try ctx.path(&.{ try ctx.config(), relative });
        var dir = std.Io.Dir.openDirAbsolute(ctx.io, base, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(ctx.io);
        var walker = try dir.walk(ctx.a);
        defer walker.deinit();
        while (try walker.next(ctx.io)) |entry| {
            if (entry.kind != .file or !(std.mem.endsWith(u8, entry.path, ".desktop") or std.mem.endsWith(u8, entry.path, ".service"))) continue;
            const path = try ctx.path(&.{ base, entry.path });
            const data = (try ctx.read(path)) orelse continue;
            if (std.mem.indexOf(u8, data, "Hidden=true") != null or std.mem.indexOf(u8, data, "aqueous-welcome") != null) continue;
            var lines = std.mem.splitScalar(u8, data, '\n');
            var applicable = true;
            var conflict = false;
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "OnlyShowIn=")) {
                    applicable = false;
                    var desktops = std.mem.splitScalar(u8, line[11..], ';');
                    while (desktops.next()) |desktop| if (eq(u8, desktop, "Aqueous")) {
                        applicable = true;
                    };
                }
                if (std.mem.startsWith(u8, line, "Exec=") or std.mem.startsWith(u8, line, "ExecStart=")) {
                    var tokens = std.mem.tokenizeAny(u8, line, " =/\t\r\"';&|");
                    while (tokens.next()) |token| if (contains(&.{ "dms", "noctalia", "pearl" }, token)) {
                        conflict = true;
                    };
                }
            }
            if (applicable and conflict) {
                try conflicts.appendSlice(ctx.a, path);
                try conflicts.append(ctx.a, '\n');
            }
        }
    }
    return conflicts.toOwnedSlice(ctx.a);
}
fn base64(ctx: *Context, bytes: []const u8) !Value {
    const result = try ctx.a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(result, bytes);
    return .{ .string = result };
}
fn decode(ctx: *Context, v: Value) !?[]const u8 {
    if (v == .null) return null;
    if (v != .string) return error.InvalidJournal;
    const result = try ctx.a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(v.string));
    try std.base64.standard.Decoder.decode(result, v.string);
    return result;
}
pub const Journal = struct {
    ctx: *Context,
    path: []const u8,
    value: Value,
    pub fn init(ctx: *Context) !Journal {
        // Kernel random bytes, with the existing 32-hex-digit journal ID format.
        var id: [16]u8 = undefined;
        const fd = c.open("/dev/urandom", c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return error.RandomFailed;
        defer u.close(fd);
        if (c.read(fd, &id, id.len) != id.len) return error.RandomFailed;
        const hex = std.fmt.bytesToHex(id, .lower);
        return .{ .ctx = ctx, .path = try ctx.path(&.{ try ctx.state(), "welcome-operation.json" }), .value = try ctx.value(.{ .version = @as(u8, 1), .id = &hex, .phase = "preparing", .files = ctx.array() }) };
    }
    pub fn save(self: *Journal) !void {
        try self.ctx.jsonWrite(self.path, self.value);
    }
    pub fn phase(self: *Journal, name: []const u8) !void {
        try self.value.object.put(self.ctx.a, "phase", .{ .string = name });
        try self.save();
    }
    pub fn write(self: *Journal, path: []const u8, data: []const u8) !void {
        const before = try self.ctx.read(path);
        var files = self.value.object.getPtr("files").?;
        try files.array.append(try self.ctx.value(.{ .path = path, .before = if (before) |bytes| try base64(self.ctx, bytes) else .null, .after = try base64(self.ctx, data) }));
        try self.save(); // Persist intent before changing the user's file.
        try self.ctx.atomic(path, data);
    }
    fn recoveryPath(self: *Journal, path: []const u8) !void {
        const ctx = self.ctx;
        var original_parts = std.mem.splitScalar(u8, path, '/');
        while (original_parts.next()) |part| if (eq(u8, part, "..")) return ctx.fail("Invalid recovery path", .{});
        const root = try std.fs.path.resolve(ctx.a, &.{try ctx.config()});
        const resolved = try std.fs.path.resolve(ctx.a, &.{path});
        if (!std.fs.path.isAbsolute(path) or !std.mem.startsWith(u8, resolved, root) or resolved.len <= root.len or resolved[root.len] != '/') return ctx.fail("Invalid recovery path", .{});
        // A legacy journal cannot traverse a newly introduced directory symlink.
        var parts = std.mem.splitScalar(u8, resolved[root.len + 1 ..], '/');
        var prefix: []const u8 = root;
        while (parts.next()) |part| {
            prefix = try ctx.path(&.{ prefix, part });
            var st: c.struct_stat = undefined;
            if (c.lstat(try ctx.z(prefix), &st) == 0 and st.st_mode & c.S_IFMT == c.S_IFLNK) return ctx.fail("Refusing recovery through a symbolic link: {s}", .{prefix});
        }
    }
    pub fn recover(self: *Journal) !void {
        const ctx = self.ctx;
        const data = (try ctx.read(self.path)) orelse return;
        var previous = try ctx.parse(data);
        if (get(previous, "version") != .integer or get(previous, "version").integer != 1 or get(previous, "files") != .array) return ctx.fail("Invalid recovery journal", .{});
        const phase_name = string(previous, "phase");
        if (eq(u8, phase_name, "complete") or eq(u8, phase_name, "recovered")) return;
        const files = u.items(get(previous, "files"));
        // Check every entry before making any restoration.
        for (files) |entry| {
            const path = string(entry, "path");
            try self.recoveryPath(path);
            const current = try ctx.read(path);
            const before = try decode(ctx, get(entry, "before"));
            const after = (try decode(ctx, get(entry, "after"))) orelse return error.InvalidJournal;
            if (!u.bytesSame(current, before) and !u.bytesSame(current, after)) return ctx.fail("Configuration changed since interrupted setup: {s}. Keep it and review {s}.", .{ path, self.path });
        }
        var i = files.len;
        while (i > 0) {
            i -= 1;
            const entry = files[i];
            const path = string(entry, "path");
            const before = try decode(ctx, get(entry, "before"));
            if (u.bytesSame(try ctx.read(path), before)) continue;
            if (before) |bytes| try ctx.atomic(path, bytes) else {
                if (c.unlink(try ctx.z(path)) != 0) return error.RemoveFailed;
                try ctx.syncDir(std.fs.path.dirname(path).?);
            }
        }
        const canonical = get(previous, "canonical");
        if (canonical != .null) {
            if (get(canonical, "before") != .object or get(canonical, "after") != .object) return error.InvalidJournal;
            const current = try ctx.helper("snapshot", null);
            const raw = get(current, "raw_files");
            if (!u.same(raw, get(canonical, "before"))) {
                if (!u.same(raw, get(canonical, "after"))) return ctx.fail("Aqueous configuration changed since interrupted setup; keep it and review {s}", .{self.path});
                _ = try ctx.helper("apply", try ctx.value(.{ .protocol = @as(u8, 1), .expected_generation = get(current, "generation"), .create_user_override = true, .raw_files = get(canonical, "before") }));
            }
        }
        try previous.object.put(ctx.a, "phase", .{ .string = "recovered" });
        try ctx.jsonWrite(self.path, previous);
    }
};
