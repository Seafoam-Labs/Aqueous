const std = @import("std");

pub const ThemeMode = enum {
    dark,
    light,
    auto,

    pub fn label(self: ThemeMode) []const u8 {
        return switch (self) {
            .dark => "Dark",
            .light => "Light",
            .auto => "Auto",
        };
    }
};

pub const Source = enum {
    unknown,
    builtin,
    wallpaper,
    community,
    custom,

    pub fn parse(text: []const u8) Source {
        if (std.mem.eql(u8, text, "builtin")) return .builtin;
        if (std.mem.eql(u8, text, "wallpaper")) return .wallpaper;
        if (std.mem.eql(u8, text, "community")) return .community;
        if (std.mem.eql(u8, text, "custom")) return .custom;
        return .unknown;
    }
};

pub const State = struct {
    available: bool = false,
    theme_mode: ThemeMode = .dark,
    source: Source = .unknown,
    palette: [64]u8 = @splat(0),
    palette_len: usize = 0,
    wallpaper: [256]u8 = @splat(0),
    wallpaper_len: usize = 0,

    pub fn paletteName(self: *const State) []const u8 {
        return self.palette[0..self.palette_len];
    }

    pub fn wallpaperPath(self: *const State) []const u8 {
        return self.wallpaper[0..self.wallpaper_len];
    }
};

pub const builtin_palettes: []const []const u8 = &.{
    "Ayu",
    "Catppuccin",
    "Dracula",
    "Eldritch",
    "Gruvbox",
    "Kanagawa",
    "Noctalia",
    "Nord",
    "Rosé Pine",
    "Tokyo-Night",
};

pub const wallpaper_schemes: []const []const u8 = &.{
    "vibrant",
    "faithful",
    "soft",
    "muted",
    "dysfunctional",
    "m3-tonal-spot",
    "m3-content",
    "m3-fruit-salad",
    "m3-rainbow",
    "m3-monochrome",
};

pub fn parseThemeMode(text: []const u8) ?ThemeMode {
    if (std.mem.eql(u8, text, "dark")) return .dark;
    if (std.mem.eql(u8, text, "light")) return .light;
    if (std.mem.eql(u8, text, "auto")) return .auto;
    return null;
}

/// Parses `color-scheme-get` output: "<source> <name>".
pub fn parseColorScheme(text: []const u8, state: *State) void {
    const source_end = std.mem.indexOfScalar(u8, text, ' ') orelse {
        state.source = Source.parse(text);
        state.palette_len = 0;
        return;
    };
    state.source = Source.parse(text[0..source_end]);
    const name = std.mem.trim(u8, text[source_end + 1 ..], " \t");
    state.palette_len = @min(name.len, state.palette.len);
    @memcpy(state.palette[0..state.palette_len], name[0..state.palette_len]);
}

pub fn isAvailable(
    allocator: std.mem.Allocator,
    io: std.Io,
    noctalia_path: []const u8,
) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ noctalia_path, "--version" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return succeeded(result.term);
}

/// Reads the live Noctalia state through `noctalia msg` queries. Fields that
/// cannot be read keep their previous values.
pub fn readState(
    allocator: std.mem.Allocator,
    io: std.Io,
    noctalia_path: []const u8,
    state: *State,
) !void {
    if (!isAvailable(allocator, io, noctalia_path)) return error.Unavailable;
    state.available = true;

    if (runTrimmed(allocator, io, &.{ noctalia_path, "msg", "theme-mode-get" })) |line| {
        defer allocator.free(line);
        if (parseThemeMode(line)) |mode| state.theme_mode = mode;
    } else |_| {}

    if (runTrimmed(allocator, io, &.{ noctalia_path, "msg", "color-scheme-get" })) |line| {
        defer allocator.free(line);
        parseColorScheme(line, state);
    } else |_| {}

    if (runTrimmed(allocator, io, &.{ noctalia_path, "msg", "wallpaper-get" })) |line| {
        defer allocator.free(line);
        state.wallpaper_len = @min(line.len, state.wallpaper.len);
        @memcpy(state.wallpaper[0..state.wallpaper_len], line[0..state.wallpaper_len]);
    } else |_| {}
}

pub fn setThemeMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    noctalia_path: []const u8,
    mode: ThemeMode,
) !void {
    try runQuiet(allocator, io, &.{
        noctalia_path, "msg", "theme-mode-set", @tagName(mode),
    });
}

pub fn setColorScheme(
    allocator: std.mem.Allocator,
    io: std.Io,
    noctalia_path: []const u8,
    source: Source,
    name: []const u8,
) !void {
    if (source == .unknown) return error.UnknownSource;
    try runQuiet(allocator, io, &.{
        noctalia_path, "msg", "color-scheme-set", @tagName(source), name,
    });
}

pub fn setWallpaper(
    allocator: std.mem.Allocator,
    io: std.Io,
    noctalia_path: []const u8,
    path: []const u8,
) !void {
    try runQuiet(allocator, io, &.{ noctalia_path, "msg", "wallpaper-set", path });
}

/// Lists image files in `directory`, sorted alphabetically. The returned slice
/// and every entry are owned by the caller.
pub fn listWallpapers(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
) ![][]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (!isImageName(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, orderByName);
    return try names.toOwnedSlice(allocator);
}

fn isImageName(name: []const u8) bool {
    const extensions = [_][]const u8{ ".avif", ".png", ".jpg", ".jpeg", ".webp" };
    for (extensions) |extension| {
        if (name.len > extension.len and
            std.ascii.endsWithIgnoreCase(name, extension))
        {
            return true;
        }
    }
    return false;
}

fn orderByName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn runTrimmed(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!succeeded(result.term)) return error.CommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn runQuiet(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!succeeded(result.term)) return error.CommandFailed;
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "theme mode parsing accepts documented modes only" {
    try std.testing.expectEqual(ThemeMode.dark, parseThemeMode("dark").?);
    try std.testing.expectEqual(ThemeMode.light, parseThemeMode("light").?);
    try std.testing.expectEqual(ThemeMode.auto, parseThemeMode("auto").?);
    try std.testing.expect(parseThemeMode("sepia") == null);
}

test "color scheme parsing splits source and palette name" {
    var state: State = .{};
    parseColorScheme("wallpaper vibrant", &state);
    try std.testing.expectEqual(Source.wallpaper, state.source);
    try std.testing.expectEqualStrings("vibrant", state.paletteName());

    parseColorScheme("builtin Catppuccin", &state);
    try std.testing.expectEqual(Source.builtin, state.source);
    try std.testing.expectEqualStrings("Catppuccin", state.paletteName());

    parseColorScheme("community Lilac AMOLED", &state);
    try std.testing.expectEqual(Source.community, state.source);
    try std.testing.expectEqualStrings("Lilac AMOLED", state.paletteName());

    parseColorScheme("wallpaper", &state);
    try std.testing.expectEqual(Source.wallpaper, state.source);
    try std.testing.expectEqualStrings("", state.paletteName());
}

test "wallpaper listing filters images and sorts by name" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "b.avif", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "a.png", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "" });
    try temporary.dir.createDirPath(std.testing.io, "nested");

    const current = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(current);
    const directory = try std.fs.path.join(std.testing.allocator, &.{
        current,
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
    });
    defer std.testing.allocator.free(directory);

    const names = try listWallpapers(std.testing.allocator, std.testing.io, directory);
    defer {
        for (names) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a.png", names[0]);
    try std.testing.expectEqualStrings("b.avif", names[1]);
}

test "setters fail when the noctalia binary is missing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try std.testing.expectError(
        error.FileNotFound,
        setThemeMode(std.testing.allocator, io, "/nonexistent/noctalia", .dark),
    );
    try std.testing.expectError(
        error.UnknownSource,
        setColorScheme(std.testing.allocator, io, "/nonexistent/noctalia", .unknown, "x"),
    );
}
