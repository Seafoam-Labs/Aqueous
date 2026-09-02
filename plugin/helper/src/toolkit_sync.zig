const std = @import("std");
const config = @import("aqueous_config_document");

const Allocator = std.mem.Allocator;

pub const target_count = 6;
pub const baseline_size_pt: f64 = 12.0;

pub const FontSpec = struct {
    family: []const u8,
    style: []const u8,
    weight: i64,
    slant: []const u8,
    width: []const u8,
    size_pt: i64,

    pub fn isSpecific(self: *const FontSpec) bool {
        return self.style.len != 0;
    }
};

pub const FontFace = struct {
    family: []const u8,
    style: []const u8,
    weight: i64,
    slant: []const u8,
    width: []const u8,
};

pub const TargetStatus = struct {
    id: []const u8,
    available: bool,
    active: bool,
    synced: bool,
    state: []const u8,
};

pub const Report = struct {
    targets: [target_count]TargetStatus,

    pub fn failedCount(self: *const Report) usize {
        var count: usize = 0;
        for (self.targets) |target| {
            if (std.mem.eql(u8, target.state, "failed")) count += 1;
        }
        return count;
    }
};

pub fn validateFamily(family: []const u8) !void {
    const trimmed = std.mem.trim(u8, family, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyFontFamily;
    if (trimmed.len > 128) return error.FontFamilyTooLong;
    for (trimmed) |byte| {
        if (byte == '\n' or byte == '\r' or byte == 0 or byte == '\t' or byte == ',' or byte == '"' or byte == '\\') {
            return error.InvalidFontFamily;
        }
    }
}

pub fn validateStyle(style: []const u8) !void {
    if (style.len > 128) return error.FontStyleTooLong;
    for (style) |byte| {
        if (byte == '\n' or byte == '\r' or byte == 0 or byte == '\t' or byte == ',' or byte == '"' or byte == '\\') {
            return error.InvalidFontStyle;
        }
    }
}

pub fn validateInstalledFamily(allocator: Allocator, io: std.Io, family: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(family, "sans-serif") or
        std.ascii.eqlIgnoreCase(family, "serif") or
        std.ascii.eqlIgnoreCase(family, "monospace"))
    {
        return;
    }
    const executable = commandPath(allocator, "fc-match") orelse return;
    defer allocator.free(executable);
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = &.{ executable, "-f", "%{family[0]}\n", family },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.FontLookupFailed;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    if (!succeeded(result.term)) return error.FontLookupFailed;
    const matched = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(matched, family)) return error.FontFamilyNotInstalled;
}

pub fn validateInstalledFont(allocator: Allocator, io: std.Io, spec: *const FontSpec) !void {
    try validateFamily(spec.family);
    try validateStyle(spec.style);
    if (!spec.isSpecific()) return validateInstalledFamily(allocator, io, spec.family);

    const executable = commandPath(allocator, "fc-list") orelse return;
    defer allocator.free(executable);
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = &.{ executable, "-f", "%{family[0]}\t%{style[0]}\t%{weight}\t%{slant}\t%{width}\n" },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.FontLookupFailed;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    if (!succeeded(result.term)) return error.FontLookupFailed;

    var faces = std.ArrayList(FontFace).empty;
    defer freeFaces(allocator, &faces);
    try appendFaceLines(allocator, &faces, result.stdout);
    for (faces.items) |face| {
        if (std.ascii.eqlIgnoreCase(face.family, spec.family) and
            std.ascii.eqlIgnoreCase(face.style, spec.style) and
            face.weight == spec.weight and
            std.ascii.eqlIgnoreCase(face.slant, spec.slant) and
            std.ascii.eqlIgnoreCase(face.width, spec.width)) return;
    }
    return error.FontFaceNotInstalled;
}

pub fn installedFamilies(allocator: Allocator, io: std.Io, current: []const u8) ![]const []const u8 {
    var families = std.ArrayList([]const u8).empty;
    errdefer {
        for (families.items) |family| allocator.free(family);
        families.deinit(allocator);
    }

    try appendFamily(allocator, &families, "sans-serif");
    try appendFamily(allocator, &families, "serif");
    try appendFamily(allocator, &families, "monospace");
    try appendFamily(allocator, &families, current);

    if (commandPath(allocator, "fc-list")) |executable| {
        defer allocator.free(executable);
        const process_allocator = std.heap.c_allocator;
        const result = std.process.run(process_allocator, io, .{
            .argv = &.{ executable, "-f", "%{family[0]}\n" },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch null;
        if (result) |output| {
            defer process_allocator.free(output.stdout);
            defer process_allocator.free(output.stderr);
            if (succeeded(output.term)) try appendFamilyLines(allocator, &families, output.stdout);
        }
    }

    std.mem.sort([]const u8, families.items, {}, familyLessThan);
    return families.toOwnedSlice(allocator);
}

pub fn installedFaces(allocator: Allocator, io: std.Io) ![]const FontFace {
    var faces = std.ArrayList(FontFace).empty;
    errdefer freeFaces(allocator, &faces);
    if (commandPath(allocator, "fc-list")) |executable| {
        defer allocator.free(executable);
        const process_allocator = std.heap.c_allocator;
        const result = std.process.run(process_allocator, io, .{
            .argv = &.{ executable, "-f", "%{family[0]}\t%{style[0]}\t%{weight}\t%{slant}\t%{width}\n" },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch null;
        if (result) |output| {
            defer process_allocator.free(output.stdout);
            defer process_allocator.free(output.stderr);
            if (succeeded(output.term)) try appendFaceLines(allocator, &faces, output.stdout);
        }
    }
    std.mem.sort(FontFace, faces.items, {}, faceLessThan);
    return faces.toOwnedSlice(allocator);
}

fn appendFaceLines(allocator: Allocator, faces: *std.ArrayList(FontFace), text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const family = std.mem.trim(u8, parts.next() orelse continue, " \r");
        const style = std.mem.trim(u8, parts.next() orelse continue, " \r");
        const raw_weight = parts.next() orelse continue;
        const raw_slant = parts.next() orelse continue;
        const raw_width = parts.next() orelse continue;
        if (parts.next() != null) continue;
        validateFamily(family) catch continue;
        validateStyle(style) catch continue;
        if (style.len == 0) continue;
        const face: FontFace = .{
            .family = family,
            .style = style,
            .weight = cssWeight(std.fmt.parseInt(i64, std.mem.trim(u8, raw_weight, " \r"), 10) catch continue),
            .slant = cssSlant(std.fmt.parseInt(i64, std.mem.trim(u8, raw_slant, " \r"), 10) catch continue),
            .width = cssWidth(std.fmt.parseInt(i64, std.mem.trim(u8, raw_width, " \r"), 10) catch continue),
        };
        var duplicate = false;
        for (faces.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.family, face.family) and
                std.ascii.eqlIgnoreCase(existing.style, face.style) and
                existing.weight == face.weight and
                std.mem.eql(u8, existing.slant, face.slant) and
                std.mem.eql(u8, existing.width, face.width))
            {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const owned_family = try allocator.dupe(u8, face.family);
        errdefer allocator.free(owned_family);
        const owned_style = try allocator.dupe(u8, face.style);
        errdefer allocator.free(owned_style);
        try faces.append(allocator, .{
            .family = owned_family,
            .style = owned_style,
            .weight = face.weight,
            .slant = face.slant,
            .width = face.width,
        });
    }
}

fn freeFaces(allocator: Allocator, faces: *std.ArrayList(FontFace)) void {
    for (faces.items) |face| {
        allocator.free(face.family);
        allocator.free(face.style);
    }
    faces.deinit(allocator);
}

fn faceLessThan(_: void, lhs: FontFace, rhs: FontFace) bool {
    if (!std.ascii.eqlIgnoreCase(lhs.family, rhs.family)) return std.ascii.lessThanIgnoreCase(lhs.family, rhs.family);
    return std.ascii.lessThanIgnoreCase(lhs.style, rhs.style);
}

fn cssWeight(value: i64) i64 {
    if (value <= 20) return 100;
    if (value <= 45) return 200;
    if (value <= 52) return 300;
    if (value <= 90) return 400;
    if (value <= 140) return 500;
    if (value <= 190) return 600;
    if (value <= 202) return 700;
    if (value <= 207) return 800;
    return 900;
}

fn cssSlant(value: i64) []const u8 {
    if (value >= 105) return "oblique";
    if (value >= 50) return "italic";
    return "normal";
}

fn cssWidth(value: i64) []const u8 {
    if (value <= 56) return "ultra-condensed";
    if (value <= 69) return "extra-condensed";
    if (value <= 81) return "condensed";
    if (value <= 93) return "semi-condensed";
    if (value <= 106) return "normal";
    if (value <= 119) return "semi-expanded";
    if (value <= 137) return "expanded";
    if (value <= 175) return "extra-expanded";
    return "ultra-expanded";
}

fn appendFamilyLines(allocator: Allocator, families: *std.ArrayList([]const u8), text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try appendFamily(allocator, families, line);
}

fn appendFamily(allocator: Allocator, families: *std.ArrayList([]const u8), raw: []const u8) !void {
    const family = std.mem.trim(u8, raw, " \t\r\n");
    validateFamily(family) catch return;
    for (families.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, family)) return;
    }
    const owned = try allocator.dupe(u8, family);
    errdefer allocator.free(owned);
    try families.append(allocator, owned);
}

fn familyLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(lhs, rhs);
}

pub fn inspect(allocator: Allocator, io: std.Io, spec: *const FontSpec) Report {
    const gtk_value = gtkFontValue(allocator, spec) catch "";
    const qfont5_value = qfont5Value(allocator, spec) catch "";
    const qfont6_value = qfont6Value(allocator, spec) catch "";
    const scale = @as(f64, @floatFromInt(spec.size_pt)) / baseline_size_pt;
    const scale_raw = std.fmt.allocPrint(allocator, "{d}", .{scale}) catch "";
    const family_raw = tomlString(allocator, spec.family) catch "";
    const platform_theme = getenv("QT_QPA_PLATFORMTHEME") orelse "";

    const noctalia_path = noctaliaSettingsPath(allocator) catch "";
    const gtk3_path = configPath(allocator, "gtk-3.0/settings.ini") catch "";
    const gtk4_path = configPath(allocator, "gtk-4.0/settings.ini") catch "";
    const qt5_path = configPath(allocator, "qt5ct/qt5ct.conf") catch "";
    const qt6_path = configPath(allocator, "qt6ct/qt6ct.conf") catch "";

    const qt5_available = pathExists(qt5_path) or commandExists("qt5ct") or containsIgnoreCase(platform_theme, "qt5ct");
    const qt6_available = pathExists(qt6_path) or commandExists("qt6ct") or containsIgnoreCase(platform_theme, "qt6ct");
    const gsettings_available = commandExists("gsettings");

    return .{ .targets = .{
        statusWithCapability("noctalia", true, true, documentMatches3(allocator, noctalia_path, .{
            .{ "shell", "font_family", family_raw },
            .{ "accessibility", "ui_scale", scale_raw },
            .{ "bar.default", "font_scale", scale_raw },
        }), spec.isSpecific()),
        status("gtk3", true, true, documentMatches(allocator, gtk3_path, "Settings", "gtk-font-name", gtk_value)),
        status("gtk4", true, true, documentMatches(allocator, gtk4_path, "Settings", "gtk-font-name", gtk_value)),
        status("gsettings", gsettings_available, gsettings_available, gsettingsMatches(io, gtk_value)),
        statusWithCapability("qt5ct", qt5_available, containsIgnoreCase(platform_theme, "qt5ct"), qt5_available and documentMatches(allocator, qt5_path, "Fonts", "general", qfont5_value), spec.isSpecific() and !std.mem.eql(u8, spec.width, "normal")),
        status("qt6ct", qt6_available, containsIgnoreCase(platform_theme, "qt6ct"), qt6_available and documentMatches(allocator, qt6_path, "Fonts", "general", qfont6_value)),
    } };
}

pub fn apply(allocator: Allocator, io: std.Io, spec: *const FontSpec) Report {
    const gtk_value = gtkFontValue(allocator, spec) catch "";
    const qfont5_value = qfont5Value(allocator, spec) catch "";
    const qfont6_value = qfont6Value(allocator, spec) catch "";
    const scale = @as(f64, @floatFromInt(spec.size_pt)) / baseline_size_pt;
    const scale_raw = std.fmt.allocPrint(allocator, "{d}", .{scale}) catch "";
    const family_raw = tomlString(allocator, spec.family) catch "";
    const platform_theme = getenv("QT_QPA_PLATFORMTHEME") orelse "";

    const noctalia_path = noctaliaSettingsPath(allocator) catch "";
    const gtk3_path = configPath(allocator, "gtk-3.0/settings.ini") catch "";
    const gtk4_path = configPath(allocator, "gtk-4.0/settings.ini") catch "";
    const qt5_path = configPath(allocator, "qt5ct/qt5ct.conf") catch "";
    const qt6_path = configPath(allocator, "qt6ct/qt6ct.conf") catch "";

    const noctalia_ok = updateDocument3(allocator, noctalia_path, .{
        .{ "shell", "font_family", family_raw },
        .{ "accessibility", "ui_scale", scale_raw },
        .{ "bar.default", "font_scale", scale_raw },
    });
    if (noctalia_ok and commandExists("noctalia")) {
        _ = runQuiet(io, &.{ "noctalia", "msg", "config-reload" });
    }

    const gtk3_ok = updateDocument(allocator, gtk3_path, "Settings", "gtk-font-name", gtk_value);
    const gtk4_ok = updateDocument(allocator, gtk4_path, "Settings", "gtk-font-name", gtk_value);
    const gsettings_available = commandExists("gsettings");
    const gsettings_ok = !gsettings_available or runQuiet(io, &.{
        "gsettings", "set", "org.gnome.desktop.interface", "font-name", gtk_value,
    });

    const qt5_available = pathExists(qt5_path) or commandExists("qt5ct") or containsIgnoreCase(platform_theme, "qt5ct");
    const qt6_available = pathExists(qt6_path) or commandExists("qt6ct") or containsIgnoreCase(platform_theme, "qt6ct");
    const qt5_ok = !qt5_available or updateDocument(allocator, qt5_path, "Fonts", "general", qfont5_value);
    const qt6_ok = !qt6_available or updateDocument(allocator, qt6_path, "Fonts", "general", qfont6_value);

    return .{ .targets = .{
        appliedStatusWithCapability("noctalia", true, true, noctalia_ok, spec.isSpecific()),
        appliedStatus("gtk3", true, true, gtk3_ok),
        appliedStatus("gtk4", true, true, gtk4_ok),
        appliedStatus("gsettings", gsettings_available, gsettings_available, gsettings_ok),
        appliedStatusWithCapability("qt5ct", qt5_available, containsIgnoreCase(platform_theme, "qt5ct"), qt5_ok, spec.isSpecific() and !std.mem.eql(u8, spec.width, "normal")),
        appliedStatus("qt6ct", qt6_available, containsIgnoreCase(platform_theme, "qt6ct"), qt6_ok),
    } };
}

const Edit = struct { []const u8, []const u8, []const u8 };

fn status(id: []const u8, available: bool, active: bool, synced: bool) TargetStatus {
    return .{
        .id = id,
        .available = available,
        .active = active,
        .synced = synced,
        .state = if (!available) "unavailable" else if (synced) "synced" else "drifted",
    };
}

fn appliedStatus(id: []const u8, available: bool, active: bool, synced: bool) TargetStatus {
    return .{
        .id = id,
        .available = available,
        .active = active,
        .synced = synced,
        .state = if (!available) "unavailable" else if (synced) "synced" else "failed",
    };
}

fn statusWithCapability(id: []const u8, available: bool, active: bool, synced: bool, partial: bool) TargetStatus {
    if (available and synced and partial) return .{ .id = id, .available = true, .active = active, .synced = false, .state = "partial" };
    return status(id, available, active, synced);
}

fn appliedStatusWithCapability(id: []const u8, available: bool, active: bool, synced: bool, partial: bool) TargetStatus {
    if (available and synced and partial) return .{ .id = id, .available = true, .active = active, .synced = false, .state = "partial" };
    return appliedStatus(id, available, active, synced);
}

fn updateDocument(allocator: Allocator, path: []const u8, section: []const u8, key: []const u8, raw: []const u8) bool {
    if (path.len == 0) return false;
    var document = config.Document.read(allocator, path) catch return false;
    defer document.deinit();
    document.setRaw(section, key, raw) catch return false;
    document.write(path) catch return false;
    return true;
}

fn updateDocument3(allocator: Allocator, path: []const u8, edits: [3]Edit) bool {
    if (path.len == 0) return false;
    var document = config.Document.read(allocator, path) catch return false;
    defer document.deinit();
    for (edits) |edit| document.setRaw(edit[0], edit[1], edit[2]) catch return false;
    document.write(path) catch return false;
    return true;
}

fn documentMatches(allocator: Allocator, path: []const u8, section: []const u8, key: []const u8, raw: []const u8) bool {
    if (path.len == 0 or !pathExists(path)) return false;
    var document = config.Document.read(allocator, path) catch return false;
    defer document.deinit();
    const actual = document.getRaw(section, key) orelse return false;
    return std.mem.eql(u8, unquote(actual), unquote(raw));
}

fn documentMatches3(allocator: Allocator, path: []const u8, edits: [3]Edit) bool {
    if (path.len == 0 or !pathExists(path)) return false;
    var document = config.Document.read(allocator, path) catch return false;
    defer document.deinit();
    for (edits) |edit| {
        const actual = document.getRaw(edit[0], edit[1]) orelse return false;
        if (!valuesEqual(actual, edit[2])) return false;
    }
    return true;
}

fn valuesEqual(a_raw: []const u8, b_raw: []const u8) bool {
    const a = unquote(a_raw);
    const b = unquote(b_raw);
    if (std.mem.eql(u8, a, b)) return true;
    const a_number = std.fmt.parseFloat(f64, a) catch return false;
    const b_number = std.fmt.parseFloat(f64, b) catch return false;
    return @abs(a_number - b_number) < 0.0001;
}

fn gtkFontValue(allocator: Allocator, spec: *const FontSpec) ![]u8 {
    if (spec.isSpecific()) return std.fmt.allocPrint(allocator, "{s} {s} {d}", .{ spec.family, spec.style, spec.size_pt });
    return std.fmt.allocPrint(allocator, "{s} {d}", .{ spec.family, spec.size_pt });
}

fn qfont5Value(allocator: Allocator, spec: *const FontSpec) ![]u8 {
    const weight = if (spec.isSpecific()) spec.weight else 400;
    const style = if (spec.isSpecific()) qtStyle(spec.slant) else 0;
    const serialized = try std.fmt.allocPrint(allocator, "{s},{d},-1,5,{d},{d},0,0,0,0", .{ spec.family, spec.size_pt, qt5Weight(weight), style });
    return tomlString(allocator, serialized);
}

fn qfont6Value(allocator: Allocator, spec: *const FontSpec) ![]u8 {
    const weight = if (spec.isSpecific()) spec.weight else 400;
    const style = if (spec.isSpecific()) qtStyle(spec.slant) else 0;
    const stretch = if (spec.isSpecific()) qtStretch(spec.width) else 0;
    const serialized = try std.fmt.allocPrint(allocator, "{s},{d},-1,5,{d},{d},0,0,0,0,0,0,0,{d},1", .{ spec.family, spec.size_pt, weight, style, stretch });
    return tomlString(allocator, serialized);
}

fn qt5Weight(weight: i64) i64 {
    if (weight <= 100) return 0;
    if (weight <= 200) return 12;
    if (weight <= 300) return 25;
    if (weight <= 400) return 50;
    if (weight <= 500) return 57;
    if (weight <= 600) return 63;
    if (weight <= 700) return 75;
    if (weight <= 800) return 81;
    return 87;
}

fn qtStyle(slant: []const u8) i64 {
    if (std.mem.eql(u8, slant, "italic")) return 1;
    if (std.mem.eql(u8, slant, "oblique")) return 2;
    return 0;
}

fn qtStretch(width: []const u8) i64 {
    if (std.mem.eql(u8, width, "ultra-condensed")) return 50;
    if (std.mem.eql(u8, width, "extra-condensed")) return 63;
    if (std.mem.eql(u8, width, "condensed")) return 75;
    if (std.mem.eql(u8, width, "semi-condensed")) return 87;
    if (std.mem.eql(u8, width, "semi-expanded")) return 113;
    if (std.mem.eql(u8, width, "expanded")) return 125;
    if (std.mem.eql(u8, width, "extra-expanded")) return 150;
    if (std.mem.eql(u8, width, "ultra-expanded")) return 200;
    return 100;
}

fn tomlString(allocator: Allocator, text: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

fn gsettingsMatches(io: std.Io, expected: []const u8) bool {
    if (!commandExists("gsettings")) return false;
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", "font-name" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return false;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    if (!succeeded(result.term)) return false;
    return std.mem.eql(u8, unquote(std.mem.trim(u8, result.stdout, " \t\r\n")), expected);
}

fn runQuiet(io: std.Io, argv: []const []const u8) bool {
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    return succeeded(result.term);
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn commandExists(name: []const u8) bool {
    const candidate = commandPath(std.heap.c_allocator, name) orelse return false;
    std.heap.c_allocator.free(candidate);
    return true;
}

fn commandPath(allocator: Allocator, name: []const u8) ?[]u8 {
    const path = getenv("PATH") orelse return null;
    var parts = std.mem.splitScalar(u8, path, ':');
    while (parts.next()) |directory| {
        const candidate = std.fs.path.join(allocator, &.{ if (directory.len == 0) "." else directory, name }) catch continue;
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn configPath(allocator: Allocator, suffix: []const u8) ![]u8 {
    if (getenv("XDG_CONFIG_HOME")) |root| return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix });
    const home = getenv("HOME") orelse return error.HomeUnavailable;
    return std.fmt.allocPrint(allocator, "{s}/.config/{s}", .{ home, suffix });
}

fn noctaliaSettingsPath(allocator: Allocator) ![]u8 {
    if (getenv("NOCTALIA_STATE_HOME")) |root| return std.fmt.allocPrint(allocator, "{s}/noctalia/settings.toml", .{root});
    if (getenv("XDG_STATE_HOME")) |root| return std.fmt.allocPrint(allocator, "{s}/noctalia/settings.toml", .{root});
    const home = getenv("HOME") orelse return error.HomeUnavailable;
    return std.fmt.allocPrint(allocator, "{s}/.local/state/noctalia/settings.toml", .{home});
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn unquote(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

fn pathExists(path: []const u8) bool {
    if (path.len == 0) return false;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "font family validation rejects ambiguous QFont serialization" {
    try validateFamily("Inter");
    try std.testing.expectError(error.EmptyFontFamily, validateFamily("  "));
    try std.testing.expectError(error.InvalidFontFamily, validateFamily("Family, Alternate"));
    try std.testing.expectError(error.InvalidFontFamily, validateFamily("Quoted \"Font\""));
    try std.testing.expectError(error.InvalidFontFamily, validateFamily("Escaped\\Font"));
    try std.testing.expectError(error.InvalidFontFamily, validateFamily("Bad\nFont"));
}

test "font family lines are trimmed deduplicated and sorted" {
    const allocator = std.testing.allocator;
    var families = std.ArrayList([]const u8).empty;
    defer {
        for (families.items) |family| allocator.free(family);
        families.deinit(allocator);
    }

    try appendFamilyLines(allocator, &families, " Zed Sans \nAlpha Sans\nzed sans\nBad, Alternate\n\n");
    std.mem.sort([]const u8, families.items, {}, familyLessThan);

    try std.testing.expectEqual(@as(usize, 2), families.items.len);
    try std.testing.expectEqualStrings("Alpha Sans", families.items[0]);
    try std.testing.expectEqualStrings("Zed Sans", families.items[1]);
}

test "font faces map Fontconfig properties and deduplicate" {
    const allocator = std.testing.allocator;
    var faces = std.ArrayList(FontFace).empty;
    defer freeFaces(allocator, &faces);

    try appendFaceLines(allocator, &faces, "Test Sans\tRegular\t80\t0\t100\n" ++
        "Test Sans\tSemiBold Italic\t180\t100\t100\n" ++
        "test sans\tSemiBold Italic\t180\t100\t100\n" ++
        "Test Sans\tCondensed Black\t210\t110\t75\n");

    try std.testing.expectEqual(@as(usize, 3), faces.items.len);
    try std.testing.expectEqual(@as(i64, 400), faces.items[0].weight);
    try std.testing.expectEqualStrings("normal", faces.items[0].slant);
    try std.testing.expectEqual(@as(i64, 600), faces.items[1].weight);
    try std.testing.expectEqualStrings("italic", faces.items[1].slant);
    try std.testing.expectEqual(@as(i64, 900), faces.items[2].weight);
    try std.testing.expectEqualStrings("oblique", faces.items[2].slant);
    try std.testing.expectEqualStrings("condensed", faces.items[2].width);
}

test "toolkit font serializers preserve portable face properties" {
    const allocator = std.testing.allocator;
    const spec: FontSpec = .{
        .family = "Test Sans",
        .style = "SemiBold Italic",
        .weight = 600,
        .slant = "italic",
        .width = "normal",
        .size_pt = 14,
    };
    const gtk = try gtkFontValue(allocator, &spec);
    defer allocator.free(gtk);
    const qt5 = try qfont5Value(allocator, &spec);
    defer allocator.free(qt5);
    const qt6 = try qfont6Value(allocator, &spec);
    defer allocator.free(qt6);
    try std.testing.expectEqualStrings("Test Sans SemiBold Italic 14", gtk);
    try std.testing.expectEqualStrings("\"Test Sans,14,-1,5,63,1,0,0,0,0\"", qt5);
    try std.testing.expectEqualStrings("\"Test Sans,14,-1,5,600,1,0,0,0,0,0,0,0,100,1\"", qt6);
}

test "automatic font matching keeps legacy toolkit defaults" {
    const allocator = std.testing.allocator;
    const spec: FontSpec = .{
        .family = "Test Sans",
        .style = "",
        .weight = 900,
        .slant = "italic",
        .width = "condensed",
        .size_pt = 12,
    };
    const qt5 = try qfont5Value(allocator, &spec);
    defer allocator.free(qt5);
    const qt6 = try qfont6Value(allocator, &spec);
    defer allocator.free(qt6);
    try std.testing.expectEqualStrings("\"Test Sans,12,-1,5,50,0,0,0,0,0\"", qt5);
    try std.testing.expectEqualStrings("\"Test Sans,12,-1,5,400,0,0,0,0,0,0,0,0,0,1\"", qt6);
}
