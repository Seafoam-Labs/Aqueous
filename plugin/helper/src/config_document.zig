const std = @import("std");

const max_config_bytes = 1024 * 1024;

pub const Document = struct {
    allocator: std.mem.Allocator,
    source: []u8,

    pub const Table = struct {
        index: usize,
        name: []const u8,
        repeated: bool,
    };

    pub const Entry = struct {
        index: usize,
        table_index: usize,
        key: []const u8,
        value: []const u8,
    };

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

    pub fn tables(self: *const Document, allocator: std.mem.Allocator) ![]Table {
        var result = std.ArrayList(Table).empty;
        errdefer result.deinit(allocator);
        try result.append(allocator, .{
            .index = 0,
            .name = "",
            .repeated = false,
        });

        var offset: usize = 0;
        while (offset < self.source.len) {
            const end = lineEnd(self.source, offset);
            if (parseHeader(cleanLine(self.source[offset..end]))) |header| {
                try result.append(allocator, .{
                    .index = result.items.len,
                    .name = header.name,
                    .repeated = header.repeated,
                });
            }
            offset = nextLine(self.source, end);
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn entries(self: *const Document, allocator: std.mem.Allocator) ![]Entry {
        var result = std.ArrayList(Entry).empty;
        errdefer result.deinit(allocator);
        var table_index: usize = 0;
        var entry_index: usize = 0;
        var offset: usize = 0;

        while (offset < self.source.len) {
            const end = lineEnd(self.source, offset);
            const line = cleanLine(self.source[offset..end]);
            if (parseHeader(line) != null) {
                table_index += 1;
            } else if (assignment(line)) |item| {
                try result.append(allocator, .{
                    .index = entry_index,
                    .table_index = table_index,
                    .key = item.key,
                    .value = item.value,
                });
                entry_index += 1;
            }
            offset = nextLine(self.source, end);
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getRaw(self: *const Document, section: []const u8, key: []const u8) ?[]const u8 {
        var current_section: []const u8 = "";
        var result: ?[]const u8 = null;
        var offset: usize = 0;
        while (offset < self.source.len) {
            const end = lineEnd(self.source, offset);
            const line = cleanLine(self.source[offset..end]);
            if (parseHeader(line)) |header| {
                current_section = header.name;
            } else if (std.mem.eql(u8, current_section, section)) {
                if (assignment(line)) |item| {
                    if (std.mem.eql(u8, item.key, key)) result = item.value;
                }
            }
            offset = nextLine(self.source, end);
        }
        return result;
    }

    pub fn setEntryRaw(self: *Document, wanted: usize, encoded_value: []const u8) !void {
        var entry_index: usize = 0;
        var offset: usize = 0;
        while (offset < self.source.len) {
            const end = lineEnd(self.source, offset);
            const raw_line = self.source[offset..end];
            const without_comment = withoutComment(raw_line);
            const trimmed = std.mem.trim(u8, without_comment, " \t\r");
            if (parseHeader(trimmed) == null and assignment(trimmed) != null) {
                if (entry_index == wanted) {
                    const equal = indexUnquoted(without_comment, '=').?;
                    var value_start = equal + 1;
                    while (value_start < without_comment.len and
                        (without_comment[value_start] == ' ' or without_comment[value_start] == '\t'))
                    {
                        value_start += 1;
                    }
                    const value = std.mem.trimEnd(
                        u8,
                        without_comment[value_start..],
                        " \t\r",
                    );
                    try self.replace(
                        offset + value_start,
                        offset + value_start + value.len,
                        encoded_value,
                    );
                    return;
                }
                entry_index += 1;
            }
            offset = nextLine(self.source, end);
        }
        return error.EntryNotFound;
    }

    pub fn deleteEntry(self: *Document, wanted: usize) !void {
        var entry_index: usize = 0;
        var offset: usize = 0;
        while (offset < self.source.len) {
            const end = lineEnd(self.source, offset);
            const line = cleanLine(self.source[offset..end]);
            if (parseHeader(line) == null and assignment(line) != null) {
                if (entry_index == wanted) {
                    try self.replace(offset, nextLine(self.source, end), "");
                    return;
                }
                entry_index += 1;
            }
            offset = nextLine(self.source, end);
        }
        return error.EntryNotFound;
    }

    pub fn deleteTable(self: *Document, wanted: usize) !void {
        if (wanted == 0) return error.CannotDeleteRootTable;
        var table_index: usize = 0;
        var start: ?usize = null;
        var offset: usize = 0;
        while (offset < self.source.len) {
            const end = lineEnd(self.source, offset);
            if (parseHeader(cleanLine(self.source[offset..end])) != null) {
                table_index += 1;
                if (table_index == wanted) start = offset else if (start != null) {
                    try self.replace(start.?, offset, "");
                    return;
                }
            }
            offset = nextLine(self.source, end);
        }
        if (start) |table_start| {
            try self.replace(table_start, self.source.len, "");
            return;
        }
        return error.TableNotFound;
    }

    pub fn addToTable(
        self: *Document,
        wanted: usize,
        key: []const u8,
        encoded_value: []const u8,
    ) !void {
        var table_index: usize = 0;
        var found = wanted == 0;
        var insertion = self.source.len;
        var offset: usize = 0;
        while (offset < self.source.len) {
            const end = lineEnd(self.source, offset);
            if (parseHeader(cleanLine(self.source[offset..end])) != null) {
                table_index += 1;
                if (found) {
                    insertion = offset;
                    break;
                }
                if (table_index == wanted) found = true;
            }
            offset = nextLine(self.source, end);
        }
        if (!found) return error.TableNotFound;

        const prefix = if (insertion > 0 and self.source[insertion - 1] != '\n') "\n" else "";
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s} = {s}\n",
            .{ prefix, key, encoded_value },
        );
        defer self.allocator.free(line);
        try self.replace(insertion, insertion, line);
    }

    pub fn setRaw(
        self: *Document,
        section: []const u8,
        key: []const u8,
        encoded_value: []const u8,
    ) !void {
        const all_tables = try self.tables(self.allocator);
        defer self.allocator.free(all_tables);
        const all_entries = try self.entries(self.allocator);
        defer self.allocator.free(all_entries);

        var table_index: ?usize = null;
        for (all_tables) |table| {
            if (!table.repeated and std.mem.eql(u8, table.name, section)) {
                table_index = table.index;
            }
        }
        if (table_index) |index| {
            var found_entry: ?usize = null;
            for (all_entries) |entry| {
                if (entry.table_index == index and std.mem.eql(u8, entry.key, key)) {
                    found_entry = entry.index;
                }
            }
            if (found_entry) |index_to_set| {
                try self.setEntryRaw(index_to_set, encoded_value);
            } else try self.addToTable(index, key, encoded_value);
            return;
        }

        const header = try std.fmt.allocPrint(self.allocator, "[{s}]", .{section});
        defer self.allocator.free(header);
        try self.appendTable(header, key, encoded_value);
    }

    pub fn appendTable(
        self: *Document,
        header: []const u8,
        key: []const u8,
        encoded_value: []const u8,
    ) !void {
        if (parseHeader(header) == null) return error.InvalidTableHeader;
        const first_newline = if (self.source.len > 0 and self.source[self.source.len - 1] != '\n') "\n" else "";
        const blank_line = if (self.source.len > 0) "\n" else "";
        const block = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}\n{s} = {s}\n",
            .{ first_newline, blank_line, header, key, encoded_value },
        );
        defer self.allocator.free(block);
        try self.replace(self.source.len, self.source.len, block);
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

pub const ConfigFiles = struct {
    pub const File = struct {
        name: []const u8,
        path: []u8,
        document: Document,
        dirty: bool = false,

        fn open(allocator: std.mem.Allocator, name: []const u8, path: []u8) !File {
            errdefer allocator.free(path);
            return .{
                .name = name,
                .path = path,
                .document = try Document.read(allocator, path),
            };
        }

        fn deinit(self: *File, allocator: std.mem.Allocator) void {
            self.document.deinit();
            allocator.free(self.path);
        }
    };

    allocator: std.mem.Allocator,
    items: [5]File,

    pub fn init(allocator: std.mem.Allocator) !ConfigFiles {
        const wm_path = try resolveWmPath(allocator);
        var wm = try File.open(allocator, "wm.toml", wm_path);
        errdefer wm.deinit(allocator);

        const layout_path = try resolveLayoutPath(
            allocator,
            wm.document.getRaw("layout", "path"),
            wm.path,
        );
        var layout = try File.open(allocator, "layout.toml", layout_path);
        errdefer layout.deinit(allocator);

        const input_path = try resolveInputPath(
            allocator,
            wm.document.getRaw("input", "path"),
        );
        var input = try File.open(allocator, "input.toml", input_path);
        errdefer input.deinit(allocator);

        const outputs_path = try resolveOutputsPath(allocator);
        var outputs = try File.open(allocator, "outputs.toml", outputs_path);
        errdefer outputs.deinit(allocator);

        const rules_path = try resolveRulesPath(
            allocator,
            wm.document.getRaw("rules", "path"),
        );
        var rules = try File.open(allocator, "rules.toml", rules_path);
        errdefer rules.deinit(allocator);

        return .{
            .allocator = allocator,
            .items = .{ wm, layout, input, outputs, rules },
        };
    }

    pub fn deinit(self: *ConfigFiles) void {
        for (&self.items) |*file| file.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn save(self: *ConfigFiles) !void {
        for (&self.items) |*file| {
            if (!file.dirty) continue;
            try file.document.write(file.path);
            file.dirty = false;
        }
    }

    pub fn reload(self: *ConfigFiles) !void {
        for (&self.items) |*file| {
            const replacement = try Document.read(self.allocator, file.path);
            file.document.deinit();
            file.document = replacement;
            file.dirty = false;
        }
    }
};

const Header = struct { name: []const u8, repeated: bool };
const Assignment = struct { key: []const u8, value: []const u8 };

fn parseHeader(line: []const u8) ?Header {
    if (line.len >= 5 and std.mem.startsWith(u8, line, "[[") and std.mem.endsWith(u8, line, "]]")) {
        const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
        return if (name.len == 0) null else .{ .name = name, .repeated = true };
    }
    if (line.len >= 3 and line[0] == '[' and line[line.len - 1] == ']') {
        const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
        return if (name.len == 0) null else .{ .name = name, .repeated = false };
    }
    return null;
}

fn assignment(line: []const u8) ?Assignment {
    const equal = indexUnquoted(line, '=') orelse return null;
    const key = unquote(std.mem.trim(u8, line[0..equal], " \t"));
    if (key.len == 0) return null;
    return .{
        .key = key,
        .value = std.mem.trim(u8, line[equal + 1 ..], " \t\r"),
    };
}

fn lineEnd(source: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
}

fn nextLine(source: []const u8, end: usize) usize {
    return if (end < source.len) end + 1 else source.len;
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

fn resolveWmPath(allocator: std.mem.Allocator) ![]u8 {
    const home = getenv("HOME");
    if (getenv("AQUEOUS_CONFIG")) |path| return expandHome(allocator, path, home);
    if (try existingUserPath(allocator, "wm.toml")) |path| return path;
    if (exists("/etc/xdg/aqueous/wm.toml")) return allocator.dupe(u8, "/etc/xdg/aqueous/wm.toml");
    return userPath(allocator, "wm.toml");
}

fn resolveLayoutPath(
    allocator: std.mem.Allocator,
    configured_raw: ?[]const u8,
    wm_path: []const u8,
) ![]u8 {
    const home = getenv("HOME");
    if (home) |base| {
        const path = try std.fmt.allocPrint(allocator, "{s}/.config/aqueous/layout.toml", .{base});
        if (exists(path)) return path;
        allocator.free(path);
    }
    if (getenv("AQUEOUS_LAYOUT")) |path| return expandHome(allocator, path, home);
    if (configured_raw) |raw| {
        const configured = unquote(raw);
        if (configured.len > 0) {
            if (configured[0] == '~' or std.fs.path.isAbsolute(configured)) {
                return expandHome(allocator, configured, home);
            }
            return std.fs.path.join(allocator, &.{ std.fs.path.dirname(wm_path) orelse ".", configured });
        }
    }
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        const path = try std.fmt.allocPrint(allocator, "{s}/aqueous/layout.toml", .{xdg});
        if (exists(path)) return path;
        allocator.free(path);
    }
    if (exists("/etc/xdg/aqueous/layout.toml")) return allocator.dupe(u8, "/etc/xdg/aqueous/layout.toml");
    return userPath(allocator, "layout.toml");
}

fn resolveInputPath(allocator: std.mem.Allocator, configured_raw: ?[]const u8) ![]u8 {
    const home = getenv("HOME");
    if (getenv("AQUEOUS_INPUT")) |path| return expandHome(allocator, path, home);
    if (configured_raw) |raw| {
        const configured = unquote(raw);
        if (configured.len > 0) return expandHome(allocator, configured, home);
    }
    if (try existingUserPath(allocator, "input.toml")) |path| return path;
    if (exists("/etc/xdg/aqueous/input.toml")) return allocator.dupe(u8, "/etc/xdg/aqueous/input.toml");
    return userPath(allocator, "input.toml");
}

fn resolveOutputsPath(allocator: std.mem.Allocator) ![]u8 {
    const home = getenv("HOME");
    if (getenv("AQUEOUS_OUTPUTS")) |path| return expandHome(allocator, path, home);
    // Match the helper's historical outputs.toml location when no override is
    // supplied. The session launcher seeds the packaged template there.
    return userPath(allocator, "outputs.toml");
}

fn resolveRulesPath(allocator: std.mem.Allocator, configured_raw: ?[]const u8) ![]u8 {
    const home = getenv("HOME");
    if (getenv("AQUEOUS_RULES")) |path| return expandHome(allocator, path, home);
    if (configured_raw) |raw| {
        const configured = unquote(raw);
        if (configured.len > 0) return expandHome(allocator, configured, home);
    }
    if (try existingUserPath(allocator, "rules.toml")) |path| return path;
    return userPath(allocator, "rules.toml");
}

fn existingUserPath(allocator: std.mem.Allocator, filename: []const u8) !?[]u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        const path = try std.fmt.allocPrint(allocator, "{s}/aqueous/{s}", .{ xdg, filename });
        if (exists(path)) return path;
        allocator.free(path);
    }
    if (getenv("HOME")) |home| {
        const path = try std.fmt.allocPrint(allocator, "{s}/.config/aqueous/{s}", .{ home, filename });
        if (exists(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn userPath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/aqueous/{s}", .{ xdg, filename });
    }
    if (getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/aqueous/{s}", .{ home, filename });
    }
    return error.ConfigPathUnavailable;
}

fn expandHome(allocator: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
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

test "document enumerates ordinary and repeated tables" {
    var document = try Document.init(std.testing.allocator,
        \\root = 1
        \\[blur]
        \\enabled = true
        \\[[window]]
        \\app_id = "one"
        \\[[window]]
        \\app_id = "two"
    );
    defer document.deinit();
    const tables = try document.tables(std.testing.allocator);
    defer std.testing.allocator.free(tables);
    const entries = try document.entries(std.testing.allocator);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 4), tables.len);
    try std.testing.expect(tables[2].repeated);
    try std.testing.expectEqualStrings("window", tables[3].name);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqual(@as(usize, 3), entries[3].table_index);
}

test "document edits entries and repeated tables without losing comments" {
    var document = try Document.init(std.testing.allocator,
        \\# keep
        \\[blur]
        \\enabled = true # comment
        \\[[window]]
        \\app_id = "game"
    );
    defer document.deinit();

    try document.setEntryRaw(0, "false");
    try document.addToTable(2, "fullscreen", "true");
    try document.appendTable("[[window]]", "title", "\"Dialog\"");
    try std.testing.expect(std.mem.indexOf(u8, document.source, "enabled = false # comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.source, "fullscreen = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.source, "title = \"Dialog\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, document.source, "# keep"));
}

test "document deletes one entry and one repeated table" {
    var document = try Document.init(std.testing.allocator,
        \\[one]
        \\a = 1
        \\b = 2
        \\[[item]]
        \\name = "first"
        \\[[item]]
        \\name = "second"
    );
    defer document.deinit();

    try document.deleteEntry(1);
    try document.deleteTable(2);
    try std.testing.expect(std.mem.indexOf(u8, document.source, "b = 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, document.source, "first") == null);
    try std.testing.expect(std.mem.indexOf(u8, document.source, "second") != null);
}
