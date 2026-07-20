const std = @import("std");
const setting = @import("settings.zig");
const Settings = setting.Settings;

const max_config_bytes = 1024 * 1024;

/// A small, preserving parser for the TOML subset used by Aqueous. Values can
/// be read by section/key and a single value can be replaced without losing
/// comments, formatting, or unrelated configuration.
pub const Document = struct {
    allocator: std.mem.Allocator,
    source: []u8,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Document {
        return .{
            .allocator = allocator,
            .source = try allocator.dupe(u8, source),
        };
    }

    pub fn read(allocator: std.mem.Allocator, path: []const u8) !Document {
        const io = std.Io.Threaded.global_single_threaded.io();
        const source = std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            io,
            path,
            allocator,
            .limited(max_config_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return init(allocator, ""),
            else => return err,
        };
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.source);
        self.* = undefined;
    }

    pub fn getRaw(self: *const Document, section: []const u8, key: []const u8) ?[]const u8 {
        var current_section: []const u8 = "";
        var result: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, self.source, '\n');
        while (lines.next()) |raw_line| {
            const line = cleanLine(raw_line);
            if (line.len == 0) continue;
            if (sectionName(line)) |name| {
                current_section = name;
                continue;
            }
            if (!std.mem.eql(u8, current_section, section)) continue;
            const equal = indexUnquoted(line, '=') orelse continue;
            const found_key = unquote(std.mem.trim(u8, line[0..equal], " \t"));
            if (!std.mem.eql(u8, found_key, key)) continue;
            result = std.mem.trim(u8, line[equal + 1 ..], " \t\r");
        }
        return result;
    }

    pub fn getBool(self: *const Document, section: []const u8, key: []const u8) ?bool {
        const value = self.getRaw(section, key) orelse return null;
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return null;
    }

    pub fn getString(self: *const Document, section: []const u8, key: []const u8) ?[]const u8 {
        const value = self.getRaw(section, key) orelse return null;
        if (value.len < 2) return null;
        if ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\''))
        {
            return value[1 .. value.len - 1];
        }
        return null;
    }

    /// Set a key to an already TOML-encoded value, such as `true`, `12`, or
    /// `"text"`. Existing values are replaced in place; missing keys or
    /// sections are appended using the compositor's section/key syntax.
    pub fn setRaw(
        self: *Document,
        section: []const u8,
        key: []const u8,
        encoded_value: []const u8,
    ) !void {
        var current_section: []const u8 = "";
        var found_section = false;
        var insertion_index: ?usize = null;
        var value_range: ?Range = null;
        var offset: usize = 0;

        while (offset < self.source.len) {
            const newline = std.mem.indexOfScalarPos(u8, self.source, offset, '\n');
            const line_end = newline orelse self.source.len;
            const raw_line = self.source[offset..line_end];
            const line_without_comment = withoutComment(raw_line);
            const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");

            if (sectionName(trimmed)) |name| {
                if (std.mem.eql(u8, current_section, section)) {
                    insertion_index = offset;
                }
                current_section = name;
                if (std.mem.eql(u8, name, section)) {
                    found_section = true;
                    insertion_index = if (newline != null) line_end + 1 else line_end;
                }
            } else if (std.mem.eql(u8, current_section, section)) {
                const equal = indexUnquoted(line_without_comment, '=');
                if (equal) |equal_index| {
                    const found_key = unquote(std.mem.trim(
                        u8,
                        line_without_comment[0..equal_index],
                        " \t",
                    ));
                    if (std.mem.eql(u8, found_key, key)) {
                        var value_start = equal_index + 1;
                        while (value_start < line_without_comment.len and
                            (line_without_comment[value_start] == ' ' or
                                line_without_comment[value_start] == '\t'))
                        {
                            value_start += 1;
                        }
                        const value = std.mem.trimEnd(
                            u8,
                            line_without_comment[value_start..],
                            " \t\r",
                        );
                        value_range = .{
                            .start = offset + value_start,
                            .end = offset + value_start + value.len,
                        };
                    }
                }
                insertion_index = if (newline != null) line_end + 1 else line_end;
            }

            offset = if (newline != null) line_end + 1 else self.source.len;
        }

        if (value_range) |range| {
            try self.replace(range.start, range.end, encoded_value);
            return;
        }

        if (found_section) {
            const at = insertion_index orelse self.source.len;
            const separator = if (at > 0 and self.source[at - 1] != '\n') "\n" else "";
            const assignment = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s} = {s}\n",
                .{ separator, key, encoded_value },
            );
            defer self.allocator.free(assignment);
            try self.replace(at, at, assignment);
            return;
        }

        var addition = std.ArrayList(u8).empty;
        defer addition.deinit(self.allocator);
        if (self.source.len > 0 and self.source[self.source.len - 1] != '\n') {
            try addition.append(self.allocator, '\n');
        }
        if (self.source.len > 0) try addition.append(self.allocator, '\n');
        const table = try std.fmt.allocPrint(
            self.allocator,
            "[{s}]\n{s} = {s}\n",
            .{ section, key, encoded_value },
        );
        defer self.allocator.free(table);
        try addition.appendSlice(self.allocator, table);
        try self.replace(self.source.len, self.source.len, addition.items);
    }

    pub fn setBool(self: *Document, section: []const u8, key: []const u8, value: bool) !void {
        try self.setRaw(section, key, if (value) "true" else "false");
    }

    pub fn write(self: *const Document, path: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic_file.deinit(io);
        try atomic_file.file.writeStreamingAll(io, self.source);
        try atomic_file.file.sync(io);
        try atomic_file.replace(io);
    }

    fn replace(self: *Document, start: usize, end: usize, replacement: []const u8) !void {
        var updated = std.ArrayList(u8).empty;
        errdefer updated.deinit(self.allocator);
        try updated.ensureTotalCapacity(
            self.allocator,
            self.source.len - (end - start) + replacement.len,
        );
        try updated.appendSlice(self.allocator, self.source[0..start]);
        try updated.appendSlice(self.allocator, replacement);
        try updated.appendSlice(self.allocator, self.source[end..]);
        const owned = try updated.toOwnedSlice(self.allocator);
        self.allocator.free(self.source);
        self.source = owned;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    wm_path: []u8,
    input_path: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) !Store {
        const wm_path = try resolveWmPath(allocator);
        errdefer allocator.free(wm_path);

        var wm_document = try Document.read(allocator, wm_path);
        defer wm_document.deinit();

        const configured_input = wm_document.getString("input", "path");
        const input_path = try resolveInputPath(allocator, configured_input);
        return .{
            .allocator = allocator,
            .wm_path = wm_path,
            .input_path = input_path,
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.wm_path);
        if (self.input_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn load(self: *const Store) !Settings {
        var result: Settings = .{};
        var wm_document = try Document.read(self.allocator, self.wm_path);
        defer wm_document.deinit();
        applyDocument(&result, &wm_document, true);

        if (self.input_path) |path| {
            var input_document = try Document.read(self.allocator, path);
            defer input_document.deinit();
            applyDocument(&result, &input_document, false);
        }
        return result;
    }

    /// Persist only values changed by the user. Documents are re-read at apply
    /// time so unrelated edits made while the settings window is open survive.
    pub fn save(self: *const Store, previous: Settings, next: Settings) !void {
        var wm_document = try Document.read(self.allocator, self.wm_path);
        defer wm_document.deinit();
        var wm_changed = false;

        if (previous.blur != next.blur) {
            try wm_document.setBool("blur", "enabled", next.blur);
            wm_changed = true;
        }
        if (previous.animations != next.animations) {
            try wm_document.setBool(
                "workspace_transition",
                "enabled",
                next.animations,
            );
            wm_changed = true;
        }

        const input_is_wm = self.input_path == null or
            std.mem.eql(u8, self.input_path.?, self.wm_path);
        if (input_is_wm) {
            if (previous.natural_scroll != next.natural_scroll) {
                try wm_document.setBool(
                    "input.touchpad",
                    "natural_scroll",
                    next.natural_scroll,
                );
                wm_changed = true;
            }
            if (previous.tap_to_click != next.tap_to_click) {
                try wm_document.setBool(
                    "input.touchpad",
                    "tap",
                    next.tap_to_click,
                );
                wm_changed = true;
            }
        } else if (previous.natural_scroll != next.natural_scroll or
            previous.tap_to_click != next.tap_to_click)
        {
            var input_document = try Document.read(
                self.allocator,
                self.input_path.?,
            );
            defer input_document.deinit();
            if (previous.natural_scroll != next.natural_scroll) {
                try input_document.setBool(
                    "input.touchpad",
                    "natural_scroll",
                    next.natural_scroll,
                );
            }
            if (previous.tap_to_click != next.tap_to_click) {
                try input_document.setBool(
                    "input.touchpad",
                    "tap",
                    next.tap_to_click,
                );
            }
            try input_document.write(self.input_path.?);
        }

        if (wm_changed) try wm_document.write(self.wm_path);
    }
};

const Range = struct { start: usize, end: usize };

fn applyDocument(settings: *Settings, document: *const Document, include_wm: bool) void {
    if (include_wm) {
        settings.blur = document.getBool("blur", "enabled") orelse settings.blur;
        settings.animations = document.getBool(
            "workspace_transition",
            "enabled",
        ) orelse settings.animations;
    }
    settings.natural_scroll = document.getBool(
        "input.touchpad",
        "natural_scroll",
    ) orelse settings.natural_scroll;
    settings.tap_to_click = document.getBool(
        "input.touchpad",
        "tap",
    ) orelse settings.tap_to_click;
}

fn resolveWmPath(allocator: std.mem.Allocator) ![]u8 {
    const home = getenv("HOME");
    if (getenv("AQUEOUS_CONFIG")) |path| return expandHome(allocator, path, home);
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/aqueous/wm.toml", .{xdg});
        if (exists(candidate)) return candidate;
        allocator.free(candidate);
    }
    if (home) |base| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/.config/aqueous/wm.toml", .{base});
        if (exists(candidate)) return candidate;
        allocator.free(candidate);
    }
    if (exists("/etc/xdg/aqueous/wm.toml")) {
        return allocator.dupe(u8, "/etc/xdg/aqueous/wm.toml");
    }
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/aqueous/wm.toml", .{xdg});
    }
    if (home) |base| {
        return std.fmt.allocPrint(allocator, "{s}/.config/aqueous/wm.toml", .{base});
    }
    return error.ConfigPathUnavailable;
}

fn resolveInputPath(
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
) !?[]u8 {
    const home = getenv("HOME");
    if (getenv("AQUEOUS_INPUT")) |path| return try expandHome(allocator, path, home);
    if (configured) |path| if (path.len > 0) {
        return try expandHome(allocator, path, home);
    };
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/aqueous/input.toml", .{xdg});
        if (exists(candidate)) return candidate;
        allocator.free(candidate);
    }
    if (home) |base| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/.config/aqueous/input.toml", .{base});
        if (exists(candidate)) return candidate;
        allocator.free(candidate);
    }
    if (exists("/etc/xdg/aqueous/input.toml")) {
        return try allocator.dupe(u8, "/etc/xdg/aqueous/input.toml");
    }
    return null;
}

fn expandHome(
    allocator: std.mem.Allocator,
    path: []const u8,
    home: ?[]const u8,
) ![]u8 {
    if (path.len > 0 and path[0] == '~') {
        const base = home orelse return error.HomeUnavailable;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path[1..] });
    }
    return allocator.dupe(u8, path);
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const result = std.mem.span(value);
    return if (result.len == 0) null else result;
}

fn exists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn sectionName(line: []const u8) ?[]const u8 {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;
    if (line.len >= 4 and line[1] == '[') return null;
    return std.mem.trim(u8, line[1 .. line.len - 1], " \t");
}

fn cleanLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, withoutComment(line), " \t\r");
}

fn withoutComment(line: []const u8) []const u8 {
    return line[0 .. indexUnquoted(line, '#') orelse line.len];
}

fn indexUnquoted(text: []const u8, needle: u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote != null and byte == '\\' and quote.? == '"') {
            escaped = true;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            if (quote == byte) quote = null else if (quote == null) quote = byte;
            continue;
        }
        if (quote == null and byte == needle) return index;
    }
    return null;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }
    return value;
}

test "document reads booleans without treating quoted comments as comments" {
    var document = try Document.init(std.testing.allocator,
        \\[blur]
        \\enabled = true # live value
        \\label = "a # is data"
        \\[workspace_transition]
        \\enabled = false
    );
    defer document.deinit();

    try std.testing.expectEqual(true, document.getBool("blur", "enabled"));
    try std.testing.expectEqual(false, document.getBool("workspace_transition", "enabled"));
    try std.testing.expectEqualStrings("\"a # is data\"", document.getRaw("blur", "label").?);
}

test "setting a key preserves comments and unrelated TOML" {
    var document = try Document.init(std.testing.allocator,
        \\# heading
        \\[blur]
        \\enabled = true  # retain me
        \\radius = 10
        \\[opacity]
        \\enabled = true
    );
    defer document.deinit();

    try document.setBool("blur", "enabled", false);
    try document.setBool("input.touchpad", "tap", true);
    try std.testing.expectEqualStrings(
        \\# heading
        \\[blur]
        \\enabled = false  # retain me
        \\radius = 10
        \\[opacity]
        \\enabled = true
        \\
        \\[input.touchpad]
        \\tap = true
        \\
    , document.source);
}

test "setting a missing key terminates a final line" {
    var document = try Document.init(
        std.testing.allocator,
        "[input.touchpad]\nnatural_scroll = true",
    );
    defer document.deinit();

    try document.setBool("input.touchpad", "tap", false);
    try std.testing.expectEqualStrings(
        "[input.touchpad]\nnatural_scroll = true\ntap = false\n",
        document.source,
    );
}

test "store loads and updates wm and input documents independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try tmp.dir.writeFile(io, .{
        .sub_path = "wm.toml",
        .data =
        \\# keep wm comment
        \\[blur]
        \\enabled = true
        \\[workspace_transition]
        \\enabled = false
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "input.toml",
        .data =
        \\# keep input comment
        \\[input.touchpad]
        \\natural_scroll = true
        \\tap = false
        ,
    });

    const allocator = std.testing.allocator;
    const wm_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/wm.toml",
        .{tmp.sub_path},
    );
    errdefer allocator.free(wm_path);
    const input_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/input.toml",
        .{tmp.sub_path},
    );
    errdefer allocator.free(input_path);
    var store: Store = .{
        .allocator = allocator,
        .wm_path = wm_path,
        .input_path = input_path,
    };
    defer store.deinit();

    const loaded = try store.load();
    try std.testing.expect(loaded.blur);
    try std.testing.expect(!loaded.animations);
    try std.testing.expect(loaded.natural_scroll);
    try std.testing.expect(!loaded.tap_to_click);

    var changed = loaded;
    changed.blur = false;
    changed.tap_to_click = true;
    try store.save(loaded, changed);

    var wm_document = try Document.read(allocator, wm_path);
    defer wm_document.deinit();
    var input_document = try Document.read(allocator, input_path);
    defer input_document.deinit();
    try std.testing.expectEqual(false, wm_document.getBool("blur", "enabled"));
    try std.testing.expectEqual(false, wm_document.getBool(
        "workspace_transition",
        "enabled",
    ));
    try std.testing.expectEqual(true, input_document.getBool(
        "input.touchpad",
        "natural_scroll",
    ));
    try std.testing.expectEqual(true, input_document.getBool(
        "input.touchpad",
        "tap",
    ));
    try std.testing.expect(std.mem.startsWith(u8, wm_document.source, "# keep wm comment"));
    try std.testing.expect(std.mem.startsWith(u8, input_document.source, "# keep input comment"));
}
