const std = @import("std");
pub const Source = enum { builtin, dms, noctalia };
pub const Choice = enum { follow, dms, noctalia, builtin };
pub const Mode = enum { dark, light };
pub fn resolve(choice: Choice, shell: []const u8) Source {
    return switch (choice) {
        .follow => std.meta.stringToEnum(Source, shell) orelse .builtin,
        .dms => .dms,
        .noctalia => .noctalia,
        .builtin => .builtin,
    };
}
pub const Palette = struct {
    background: u32 = 0x101D2B,
    on_background: u32 = 0xE4EAF5,
    surface_container: u32 = 0x152536,
    on_surface: u32 = 0xE4EAF5,
    surface_container_high: u32 = 0x293B50,
    on_surface_variant: u32 = 0xB7C4D6,
    primary: u32 = 0x8CCFEF,
    on_primary: u32 = 0x062535,
    primary_container: u32 = 0x3D6078,
    on_primary_container: u32 = 0xFFFFFF,
    outline: u32 = 0x73869C,
    error_container: u32 = 0x593139,
    on_error_container: u32 = 0xFFDAD6,
};
pub const FontSpec = struct {
    family: [256]u8 = @splat(0),
    length: usize = 0,
    pixels: f32 = 16,
    weight: u16 = 400,
    pub fn name(self: *const FontSpec) []const u8 {
        return self.family[0..self.length];
    }
    pub fn setName(self: *FontSpec, text: []const u8) !void {
        if (text.len > self.family.len or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfAny(u8, text, "\x00\n\r") != null) return error.InvalidFont;
        self.family = @splat(0);
        @memcpy(self.family[0..text.len], text);
        self.length = text.len;
    }
    pub fn setPixels(self: *FontSpec, value: f64) !void {
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidFontSize;
        self.pixels = @floatCast(std.math.clamp(value, 10, 32));
    }
};
pub const Snapshot = struct { palette: Palette = .{}, font: FontSpec = .{}, radius: f32 = 5, source: Source = .builtin, mode: Mode = .dark };
pub fn color(text: []const u8) !u32 {
    if (text.len != 7 or text[0] != '#') return error.InvalidColor;
    for (text[1..]) |digit| if (!std.ascii.isHex(digit)) return error.InvalidColor;
    return std.fmt.parseInt(u32, text[1..], 16) catch error.InvalidColor;
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8, source: Source) !Snapshot {
    if (bytes.len > 65536) return error.ThemeTooLarge;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value;
    if (obj != .object) return error.InvalidTheme;
    const version = obj.object.get("version") orelse return error.InvalidTheme;
    if (version != .integer or version.integer != 1) return error.UnsupportedThemeVersion;
    const identity = obj.object.get("source") orelse return error.InvalidTheme;
    if (identity != .string or !std.mem.eql(u8, identity.string, @tagName(source)) or source == .builtin) return error.WrongThemeSource;
    const mode = obj.object.get("mode") orelse return error.InvalidTheme;
    if (mode != .string) return error.InvalidTheme;
    var result: Snapshot = .{ .source = source, .mode = std.meta.stringToEnum(Mode, mode.string) orelse return error.InvalidThemeMode };
    // Validate both modes, even the inactive one, before publishing any colors.
    inline for (.{ "dark", "light" }) |name| {
        const roles = obj.object.get(name) orelse return error.InvalidTheme;
        if (roles != .object) return error.InvalidTheme;
        var palette: Palette = .{};
        inline for (std.meta.fields(Palette)) |field| {
            const value = roles.object.get(field.name) orelse return error.MissingThemeRole;
            if (value != .string) return error.InvalidColor;
            @field(palette, field.name) = try color(value.string);
        }
        if (std.mem.eql(u8, name, mode.string)) result.palette = palette;
    }
    return result;
}

test "theme colors reject alpha and malformed input" {
    try std.testing.expectEqual(@as(u32, 0xAbCdEf), try color("#AbCdEf"));
    for ([_][]const u8{ "abcdef", "#abcd", "#000000ff", "#gg0000", "#+00000", "#00_000" }) |value| try std.testing.expectError(error.InvalidColor, color(value));
}
test "source selection and font units are bounded" {
    try std.testing.expectEqual(Source.builtin, resolve(.follow, "none"));
    try std.testing.expectEqual(Source.noctalia, resolve(.noctalia, "dms"));
    var font: FontSpec = .{};
    try font.setPixels(12 * 96.0 / 72.0);
    try std.testing.expectEqual(@as(f32, 16), font.pixels);
    try std.testing.expectError(error.InvalidFontSize, font.setPixels(std.math.nan(f64)));
    try std.testing.expectError(error.InvalidFont, font.setName("bad\nfont"));
}

/// Serialize the portable export contract (also used by adapter fixtures).
pub fn encode(a: std.mem.Allocator, source: Source, mode: Mode, dark: Palette, light: Palette) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(1);
    try json.objectField("source");
    try json.write(@tagName(source));
    try json.objectField("mode");
    try json.write(@tagName(mode));
    for ([_]Palette{ dark, light }, [_][]const u8{ "dark", "light" }) |palette, name| {
        try json.objectField(name);
        try json.beginObject();
        inline for (std.meta.fields(Palette)) |field| {
            var buffer: [7]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, "#{x:0>6}", .{@field(palette, field.name)});
            try json.objectField(field.name);
            try json.write(text);
        }
        try json.endObject();
    }
    try json.endObject();
    return a.dupe(u8, out.written());
}
test "complete exports validate both modes and reject wrong identities or versions" {
    const a = std.testing.allocator;
    const bytes = try encode(a, .dms, .light, .{}, .{ .background = 0xffffff });
    defer a.free(bytes);
    const snapshot = try decode(a, bytes, .dms);
    try std.testing.expectEqual(@as(u32, 0xffffff), snapshot.palette.background);
    try std.testing.expectError(error.WrongThemeSource, decode(a, bytes, .noctalia));
    const version = std.mem.indexOf(u8, bytes, "\"version\":1").? + "\"version\":".len;
    bytes[version] = '2';
    try std.testing.expectError(error.UnsupportedThemeVersion, decode(a, bytes, .dms));
    bytes[version] = '1';
    bytes[std.mem.indexOfScalar(u8, bytes, '#').?] = 'x';
    try std.testing.expectError(error.InvalidColor, decode(a, bytes, .dms));
    try std.testing.expectError(error.MissingThemeRole, decode(a, "{\"version\":1,\"source\":\"dms\",\"mode\":\"dark\",\"dark\":{},\"light\":{}}", .dms));
    const huge = try a.alloc(u8, 65537);
    defer a.free(huge);
    try std.testing.expectError(error.ThemeTooLarge, decode(a, huge, .dms));
}
