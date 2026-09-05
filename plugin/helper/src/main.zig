const std = @import("std");
const config = @import("aqueous_config_document");
const toolkit_sync = @import("aqueous_toolkit_sync");
const cursor_sync = @import("aqueous_cursor_sync");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const max_request_bytes = 4 * 1024 * 1024;

const Command = enum { version, snapshot, validate, apply, raw };

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    var exit_code: u8 = 0;
    run(allocator, init.io, args, &response.writer) catch |err| {
        response.clearRetainingCapacity();
        writeError(&response.writer, errorCode(err), @errorName(err)) catch {};
        exit_code = 1;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll(response.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len < 2) return error.MissingCommand;
    const command = parseCommand(args[1]) orelse return error.UnknownCommand;
    const shell_name = option(args, "--shell") orelse "noctalia";
    const shell: toolkit_sync.Shell = if (std.mem.eql(u8, shell_name, "dms")) .dms else if (std.mem.eql(u8, shell_name, "noctalia")) .noctalia else return error.UnknownShell;
    switch (command) {
        .version => try writeVersion(writer),
        .snapshot => {
            var files = try config.ConfigFiles.init(allocator);
            defer files.deinit();
            try writeSnapshot(io, writer, &files, null, null, shell);
        },
        .raw => {
            const wanted = option(args, "--file") orelse return error.MissingFile;
            const file_id = schema.FileId.fromName(wanted) orelse return error.UnknownFile;
            var files = try config.ConfigFiles.init(allocator);
            defer files.deinit();
            try writeRaw(writer, &files, file_id);
        },
        .validate, .apply => {
            const request_path = option(args, "--request") orelse return error.MissingRequest;
            try handleRequest(allocator, io, writer, request_path, command == .apply, shell);
        },
    }
}

fn parseCommand(value: []const u8) ?Command {
    inline for (std.meta.fields(Command)) |command_field| {
        if (std.mem.eql(u8, value, command_field.name)) return @enumFromInt(command_field.value);
    }
    return null;
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args[0..args.len -| 1], 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name)) return args[index + 1];
    }
    return null;
}

fn writeVersion(writer: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "ok", true);
    try field(&json, "protocol", schema.protocol_version);
    try field(&json, "version", schema.helper_version);
    try field(&json, "capabilities", schema.capabilities);
    try json.endObject();
}

fn writeSnapshot(
    io: std.Io,
    writer: *std.Io.Writer,
    files: *const config.ConfigFiles,
    applied_report: ?*const toolkit_sync.Report,
    applied_cursor_report: ?*const cursor_sync.Report,
    shell: toolkit_sync.Shell,
) !void {
    var generation_buffer: [16]u8 = undefined;
    const generation = generationText(files, &generation_buffer);
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "ok", true);
    try field(&json, "protocol", schema.protocol_version);
    try field(&json, "helper_version", schema.helper_version);
    try field(&json, "capabilities", schema.capabilities);
    try field(&json, "generation", generation);
    const stacking_schema = schema.find("layout.options.float.placement").?;
    try field(
        &json,
        "stacking_alias_count",
        files.items[@intFromEnum(schema.FileId.layout)].document.countSections(stacking_schema.section, stacking_schema.section_aliases),
    );

    try json.objectField("files");
    try json.beginObject();
    for (files.items, 0..) |file_item, index| {
        const file_id: schema.FileId = @enumFromInt(index);
        try json.objectField(file_id.name());
        try json.beginObject();
        try field(&json, "path", file_item.path);
        try field(&json, "writable", !std.mem.startsWith(u8, file_item.path, "/etc/xdg/"));
        try field(&json, "exists", pathExists(file_item.path));
        try field(&json, "size", file_item.document.source.len);
        try json.endObject();
    }
    try json.endObject();

    try json.objectField("categories");
    try json.beginArray();
    inline for (std.meta.fields(schema.Category)) |category| try json.write(category.name);
    try json.endArray();

    try json.objectField("fields");
    try json.beginArray();
    for (&schema.fields) |*schema_field| try writeSchemaField(&json, files, schema_field);
    try json.endArray();

    try json.objectField("monitors");
    try writeConfiguredMonitors(
        &json,
        &files.items[@intFromEnum(schema.FileId.outputs)].document,
        &files.items[@intFromEnum(schema.FileId.wm)].document,
    );

    try json.objectField("live_outputs");
    try writeLiveOutputs(io, &json, files.allocator);

    try json.objectField("custom_keybinds");
    try writeCustomKeybinds(&json, &files.items[@intFromEnum(schema.FileId.wm)].document);

    try json.objectField("snap_zones");
    try writeSnapZones(&json, &files.items[@intFromEnum(schema.FileId.layout)].document);

    try json.objectField("snap_layouts");
    try writeSnapLayouts(&json, &files.items[@intFromEnum(schema.FileId.layout)].document);
    try field(&json, "default_snap_layout", unquoteToml(
        files.items[@intFromEnum(schema.FileId.layout)].document.getRaw("layout", "snap_layout") orelse "",
    ));

    try json.objectField("window_rules");
    try writeWindowRules(&json, &files.items[@intFromEnum(schema.FileId.rules)].document);

    try json.objectField("raw_files");
    try json.beginObject();
    for (files.items, 0..) |file_item, index| {
        const file_id: schema.FileId = @enumFromInt(index);
        try field(&json, file_id.name(), file_item.document.source);
    }
    try json.endObject();

    try json.objectField("warnings");
    try json.beginArray();
    if (hasLegacyDisplayPolicy(&files.items[@intFromEnum(schema.FileId.wm)].document)) {
        try json.write("Display policy inherited from wm.toml remains active until the corresponding setting is written to outputs.toml.");
    }
    const layout_document = &files.items[@intFromEnum(schema.FileId.layout)].document;
    const stacking_field = schema.find("layout.options.float.placement").?;
    if (layout_document.countSections(stacking_field.section, stacking_field.section_aliases) > 1) {
        try json.write("Multiple stacking option aliases are configured; the last assignment for each key is effective and typed edits update that section.");
    }
    try json.endArray();

    const typography = desktopTypography(files);
    const families = try toolkit_sync.installedFamilies(files.allocator, io, typography.family);
    const faces = try toolkit_sync.installedFaces(files.allocator, io);
    const inspected = if (applied_report == null)
        toolkit_sync.inspectForShell(files.allocator, io, &typography, shell)
    else
        undefined;
    const report = applied_report orelse &inspected;
    try json.objectField("desktop_typography");
    try json.beginObject();
    try field(&json, "applied", applied_report != null);
    try field(&json, "family", typography.family);
    try field(&json, "families", families);
    try field(&json, "style", typography.style);
    try field(&json, "weight", typography.weight);
    try field(&json, "slant", typography.slant);
    try field(&json, "width", typography.width);
    try field(&json, "size_pt", typography.size_pt);
    try json.objectField("faces");
    try json.beginArray();
    for (faces) |face| {
        try json.beginObject();
        try field(&json, "family", face.family);
        try field(&json, "style", face.style);
        try field(&json, "weight", face.weight);
        try field(&json, "slant", face.slant);
        try field(&json, "width", face.width);
        try json.endObject();
    }
    try json.endArray();
    try field(&json, "baseline_size_pt", toolkit_sync.baseline_size_pt);
    try field(&json, "failed_count", report.failedCount());
    try json.objectField("targets");
    try json.beginArray();
    for (report.targets) |target| {
        try json.beginObject();
        try field(&json, "id", target.id);
        try field(&json, "available", target.available);
        try field(&json, "active", target.active);
        try field(&json, "synced", target.synced);
        try field(&json, "state", target.state);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try writeDesktopCursor(io, &json, files, applied_cursor_report);
    try json.endObject();
}

const DesktopTypography = toolkit_sync.FontSpec;

fn desktopTypography(files: *const config.ConfigFiles) DesktopTypography {
    return desktopTypographyFromDocument(&files.items[@intFromEnum(schema.FileId.appearance)].document);
}

fn desktopTypographyFromSource(allocator: Allocator, source: []const u8) !DesktopTypography {
    var document = try config.Document.init(allocator, source);
    defer document.deinit();
    const spec = desktopTypographyFromDocument(&document);
    return .{
        .family = try allocator.dupe(u8, spec.family),
        .style = try allocator.dupe(u8, spec.style),
        .weight = spec.weight,
        .slant = try allocator.dupe(u8, spec.slant),
        .width = try allocator.dupe(u8, spec.width),
        .size_pt = spec.size_pt,
    };
}

fn desktopTypographyFromDocument(document: *const config.Document) DesktopTypography {
    const family_field = schema.find("desktop.font.family").?;
    const style_field = schema.find("desktop.font.style").?;
    const weight_field = schema.find("desktop.font.weight").?;
    const slant_field = schema.find("desktop.font.slant").?;
    const width_field = schema.find("desktop.font.width").?;
    const size_field = schema.find("desktop.font.size_pt").?;
    const family = unquoteToml(document.getRaw(family_field.section, family_field.key) orelse family_field.default_raw);
    const style = unquoteToml(document.getRaw(style_field.section, style_field.key) orelse style_field.default_raw);
    const weight_raw = document.getRaw(weight_field.section, weight_field.key) orelse weight_field.default_raw;
    const slant = unquoteToml(document.getRaw(slant_field.section, slant_field.key) orelse slant_field.default_raw);
    const width = unquoteToml(document.getRaw(width_field.section, width_field.key) orelse width_field.default_raw);
    const size_raw = document.getRaw(size_field.section, size_field.key) orelse size_field.default_raw;
    return .{
        .family = family,
        .style = style,
        .weight = std.fmt.parseInt(i64, std.mem.trim(u8, weight_raw, " \t\r"), 10) catch 400,
        .slant = slant,
        .width = width,
        .size_pt = std.fmt.parseInt(i64, std.mem.trim(u8, size_raw, " \t\r"), 10) catch 12,
    };
}

fn typographySpecsEqual(a: *const DesktopTypography, b: *const DesktopTypography) bool {
    return std.mem.eql(u8, a.family, b.family) and std.mem.eql(u8, a.style, b.style) and
        a.weight == b.weight and std.mem.eql(u8, a.slant, b.slant) and
        std.mem.eql(u8, a.width, b.width) and a.size_pt == b.size_pt;
}

fn desktopCursor(files: *const config.ConfigFiles) cursor_sync.CursorSpec {
    return desktopCursorFromDocument(&files.items[@intFromEnum(schema.FileId.appearance)].document);
}

fn desktopCursorFromSource(allocator: Allocator, source: []const u8) !cursor_sync.CursorSpec {
    var document = try config.Document.init(allocator, source);
    defer document.deinit();
    const spec = desktopCursorFromDocument(&document);
    return .{
        .managed = spec.managed,
        .theme = try allocator.dupe(u8, spec.theme),
        .size = spec.size,
    };
}

fn desktopCursorFromDocument(document: *const config.Document) cursor_sync.CursorSpec {
    const managed_field = schema.find("desktop.cursor.managed").?;
    const theme_field = schema.find("desktop.cursor.theme").?;
    const size_field = schema.find("desktop.cursor.size").?;
    const managed_raw = document.getRaw(managed_field.section, managed_field.key) orelse managed_field.default_raw;
    const theme_raw = document.getRaw(theme_field.section, theme_field.key) orelse theme_field.default_raw;
    const size_raw = document.getRaw(size_field.section, size_field.key) orelse size_field.default_raw;
    return .{
        .managed = std.mem.eql(u8, std.mem.trim(u8, managed_raw, " \t\r"), "true"),
        .theme = unquoteToml(theme_raw),
        .size = std.fmt.parseInt(u32, std.mem.trim(u8, size_raw, " \t\r"), 10) catch 24,
    };
}

fn cursorSpecsEqual(a: *const cursor_sync.CursorSpec, b: *const cursor_sync.CursorSpec) bool {
    return a.managed == b.managed and a.size == b.size and std.mem.eql(u8, a.theme, b.theme);
}

fn writeDesktopCursor(
    io: std.Io,
    json: *std.json.Stringify,
    files: *const config.ConfigFiles,
    applied_report: ?*const cursor_sync.Report,
) !void {
    const spec = desktopCursor(files);
    const themes = try cursor_sync.installedThemes(files.allocator, io, spec.theme);
    const live = cursor_sync.queryLive(files.allocator, io);
    const inspected = if (applied_report == null) cursor_sync.inspect(files.allocator, io, &spec) else undefined;
    const report = applied_report orelse &inspected;

    try json.objectField("desktop_cursor");
    try json.beginObject();
    try field(json, "applied", applied_report != null);
    try field(json, "managed", spec.managed);
    try field(json, "theme", spec.theme);
    try field(json, "theme_available", cursor_sync.themeExists(files.allocator, spec.theme));
    try field(json, "size", spec.size);
    try field(json, "effective_available", live.available);
    try field(json, "effective_theme", live.theme);
    try field(json, "effective_size", live.size);
    try field(json, "failed_count", report.failedCount());
    try json.objectField("themes");
    try json.beginArray();
    for (themes) |theme| try json.write(theme);
    try json.endArray();
    try json.objectField("targets");
    try json.beginArray();
    for (report.targets) |target| {
        try json.beginObject();
        try field(json, "id", target.id);
        try field(json, "available", target.available);
        try field(json, "active", target.active);
        try field(json, "synced", target.synced);
        try field(json, "state", target.state);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn writeRaw(writer: *std.Io.Writer, files: *const config.ConfigFiles, file_id: schema.FileId) !void {
    const file_item = files.items[@intFromEnum(file_id)];
    var generation_buffer: [16]u8 = undefined;
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "ok", true);
    try field(&json, "protocol", schema.protocol_version);
    try field(&json, "generation", generationText(files, &generation_buffer));
    try field(&json, "file", file_id.name());
    try field(&json, "path", file_item.path);
    try field(&json, "source", file_item.document.source);
    try json.endObject();
}

fn writeSchemaField(json: *std.json.Stringify, files: *const config.ConfigFiles, schema_field: *const schema.Field) !void {
    const file_item = files.items[@intFromEnum(schema_field.file)];
    var resolved = resolveFieldRaw(&file_item.document, schema_field);
    var configured_raw = if (resolved) |item| item.value else null;
    var inherited = false;
    if (configured_raw == null and schema_field.file == .outputs) {
        resolved = resolveFieldRaw(&files.items[@intFromEnum(schema.FileId.wm)].document, schema_field);
        configured_raw = if (resolved) |item| item.value else null;
        inherited = configured_raw != null;
    }
    const raw = configured_raw orelse schema_field.default_raw;
    try json.beginObject();
    try field(json, "id", schema_field.id);
    try field(json, "category", schema_field.category.name());
    try field(json, "label", schema_field.label);
    try field(json, "description", schema_field.description);
    try field(json, "file", schema_field.file.name());
    try field(json, "section", schema_field.section);
    if (resolved) |item| try field(json, "configured_section", item.section);
    try field(json, "key", schema_field.key);
    try field(json, "type", schema_field.kind.name());
    try field(json, "configured", configured_raw != null);
    try field(json, "inherited", inherited);
    try field(json, "advanced", schema_field.advanced);
    try json.objectField("value");
    try writeTomlValue(json, schema_field, raw);
    try json.objectField("default");
    try writeTomlValue(json, schema_field, schema_field.default_raw);
    try json.objectField("raw");
    try json.write(raw);
    if (schema_field.min) |value| try field(json, "min", value);
    if (schema_field.max) |value| try field(json, "max", value);
    if (schema_field.options.len > 0) {
        try json.objectField("options");
        try json.beginArray();
        for (schema_field.options) |value| try json.write(value);
        try json.endArray();
    }
    try json.endObject();
}

fn writeTomlValue(json: *std.json.Stringify, schema_field: *const schema.Field, raw: []const u8) !void {
    switch (schema_field.kind) {
        .boolean => try json.write(std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "true")),
        .integer => try json.write(std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r"), 10) catch 0),
        .double => try json.write(std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r")) catch 0),
        .string => try json.write(unquoteToml(raw)),
        .select => try json.write(schema.normalizeLayout(unquoteToml(raw))),
        .string_list => try writeStringList(json, raw),
        .color => try json.write(std.mem.trim(u8, raw, " \t\r")),
    }
}

fn writeStringList(json: *std.json.Stringify, raw_value: []const u8) !void {
    const raw = std.mem.trim(u8, raw_value, " \t\r");
    try json.beginArray();
    if (raw.len == 0 or std.mem.eql(u8, raw, "[]")) {
        try json.endArray();
        return;
    }
    if (raw[0] != '[') {
        try json.write(unquoteToml(raw));
        try json.endArray();
        return;
    }
    if (raw.len < 2 or raw[raw.len - 1] != ']') return error.InvalidStringList;
    var parts = std.mem.splitScalar(u8, raw[1 .. raw.len - 1], ',');
    while (parts.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\r");
        if (item.len == 0) continue;
        try json.write(unquoteToml(item));
    }
    try json.endArray();
}

fn handleRequest(allocator: Allocator, io: std.Io, writer: *std.Io.Writer, request_path: []const u8, do_apply: bool, shell: toolkit_sync.Shell) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const source = if (std.mem.eql(u8, request_path, "-"))
        try stdin_reader.interface.allocRemaining(allocator, .limited(max_request_bytes))
    else
        try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, request_path, allocator, .limited(max_request_bytes));
    var parsed = try std.json.parseFromSlice(Json, allocator, source, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const request = parsed.value.object;
    const protocol = jsonInteger(request.get("protocol")) orelse return error.MissingProtocol;
    if (protocol != schema.protocol_version) return error.UnsupportedProtocol;
    const expected = jsonString(request.get("expected_generation")) orelse return error.MissingGeneration;
    const typography_sync_requested = if (request.get("sync_typography")) |value|
        jsonBool(value) orelse return error.InvalidTypographySyncRequest
    else
        false;
    const cursor_sync_requested = if (request.get("sync_cursor")) |value|
        jsonBool(value) orelse return error.InvalidCursorSyncRequest
    else
        false;

    var files = try config.ConfigFiles.init(allocator);
    defer files.deinit();
    var generation_buffer: [16]u8 = undefined;
    if (!std.mem.eql(u8, expected, generationText(&files, &generation_buffer))) return error.ExternalChange;

    var originals: [schema.file_count][]u8 = undefined;
    for (files.items, 0..) |file_item, index| originals[index] = try allocator.dupe(u8, file_item.document.source);
    defer for (originals) |original| allocator.free(original);

    var dirty = [_]bool{false} ** schema.file_count;
    if (request.get("raw_files")) |raw_files| {
        if (raw_files != .object) return error.InvalidRawFiles;
        var iterator = raw_files.object.iterator();
        while (iterator.next()) |entry| {
            const file_id = schema.FileId.fromName(entry.key_ptr.*) orelse return error.UnknownFile;
            if (entry.value_ptr.* != .string) return error.InvalidRawFile;
            const file_index = @intFromEnum(file_id);
            try validateBasicToml(entry.value_ptr.string);
            try replaceDocumentSource(&files.items[file_index].document, entry.value_ptr.string);
            dirty[file_index] = true;
        }
    }

    if (request.get("normalize_stacking")) |normalize| {
        if (jsonBool(normalize) != true) return error.InvalidNormalizeRequest;
        if (request.get("raw_files")) |raw_files| {
            if (raw_files == .object and raw_files.object.get("layout") != null) return error.ConflictingEdits;
        }
        try normalizeStackingSections(
            allocator,
            &files.items[@intFromEnum(schema.FileId.layout)].document,
        );
        dirty[@intFromEnum(schema.FileId.layout)] = true;
    }

    // Custom binding IDs are document entry indices. Apply them before ordinary
    // keybind edits, which may insert a new key into [keybinds] and shift every
    // later [keybinds.custom] entry.
    if (request.get("custom_keybind_changes")) |custom_changes| {
        // Noctalia's Luau JSON bridge represents an empty table as `{}`.
        // Accept only that empty-object form as the equivalent of an empty
        // array; populated objects remain malformed requests.
        if (custom_changes == .object and custom_changes.object.count() == 0) {
            // Nothing to apply.
        } else if (custom_changes != .array) {
            return error.InvalidCustomKeybindChanges;
        } else if (custom_changes.array.items.len > 0) {
            if (request.get("raw_files")) |raw_files| {
                if (raw_files == .object and raw_files.object.get("wm") != null) return error.ConflictingEdits;
            }
            try applyCustomKeybindChanges(
                allocator,
                &files.items[@intFromEnum(schema.FileId.wm)].document,
                custom_changes.array.items,
            );
            dirty[@intFromEnum(schema.FileId.wm)] = true;
        }
    }

    if (request.get("snap_zone_changes")) |zone_changes| {
        if (zone_changes == .object and zone_changes.object.count() == 0) {
            // Nothing to apply.
        } else if (zone_changes != .array) {
            return error.InvalidSnapZoneChanges;
        } else if (zone_changes.array.items.len > 0) {
            if (request.get("raw_files")) |raw_files| {
                if (raw_files == .object and raw_files.object.get("layout") != null) return error.ConflictingEdits;
            }
            try applySnapZoneChanges(
                allocator,
                &files.items[@intFromEnum(schema.FileId.layout)].document,
                zone_changes.array.items,
            );
            dirty[@intFromEnum(schema.FileId.layout)] = true;
        }
    }

    if (request.get("snap_layouts")) |snap_layouts| {
        if (snap_layouts != .array) return error.InvalidSnapLayouts;
        if (request.get("raw_files")) |raw_files| {
            if (raw_files == .object and raw_files.object.get("layout") != null) return error.ConflictingEdits;
        }
        const default_id = jsonString(request.get("default_snap_layout")) orelse "";
        try replaceSnapLayouts(
            allocator,
            &files.items[@intFromEnum(schema.FileId.layout)].document,
            snap_layouts.array.items,
            default_id,
        );
        dirty[@intFromEnum(schema.FileId.layout)] = true;
    }

    if (request.get("window_rule_changes")) |rule_changes| {
        if (rule_changes == .object and rule_changes.object.count() == 0) {
            // Nothing to apply.
        } else if (rule_changes != .array) {
            return error.InvalidWindowRuleChanges;
        } else if (rule_changes.array.items.len > 0) {
            if (request.get("raw_files")) |raw_files| {
                if (raw_files == .object and raw_files.object.get("rules") != null) return error.ConflictingEdits;
            }
            try applyWindowRuleChanges(
                allocator,
                &files.items[@intFromEnum(schema.FileId.rules)].document,
                rule_changes.array.items,
            );
            dirty[@intFromEnum(schema.FileId.rules)] = true;
        }
    }

    if (request.get("changes")) |changes| {
        if (changes == .object and changes.object.count() == 0) {
            // Nothing to apply.
        } else if (changes != .array) {
            return error.InvalidChanges;
        } else {
            for (changes.array.items) |change| {
                if (change != .object) return error.InvalidChange;
                const id = jsonString(change.object.get("id")) orelse return error.MissingFieldId;
                const schema_field = schema.find(id) orelse return error.UnknownField;
                const value = change.object.get("value") orelse return error.MissingValue;
                const encoded = try encodeTomlValue(allocator, schema_field, value);
                try setFieldRaw(&files.items[@intFromEnum(schema_field.file)].document, schema_field, encoded);
                dirty[@intFromEnum(schema_field.file)] = true;
            }
        }
    }

    if (request.get("monitor_changes")) |monitor_changes| {
        if (monitor_changes == .object and monitor_changes.object.count() == 0) {
            // Nothing to apply.
        } else if (monitor_changes != .array) {
            return error.InvalidMonitorChanges;
        } else if (monitor_changes.array.items.len > 0) {
            if (request.get("raw_files")) |raw_files| {
                if (raw_files == .object and raw_files.object.get("outputs") != null) return error.ConflictingEdits;
            }
            try applyMonitorChanges(
                allocator,
                &files.items[@intFromEnum(schema.FileId.outputs)].document,
                &files.items[@intFromEnum(schema.FileId.wm)].document,
                monitor_changes.array.items,
            );
            dirty[@intFromEnum(schema.FileId.outputs)] = true;
        }
    }

    var changed_count: usize = 0;
    for (dirty, 0..) |is_dirty, index| {
        if (!is_dirty) continue;
        changed_count += 1;
        if (std.mem.startsWith(u8, files.items[index].path, "/etc/xdg/")) {
            const create_override = request.get("create_user_override") orelse return error.SystemConfigReadOnly;
            if (jsonBool(create_override) != true) return error.SystemConfigReadOnly;
            try retargetUserOverride(allocator, &files.items[index], @enumFromInt(index));
        }
        try validateBasicToml(files.items[index].document.source);
    }
    try validateKnownFields(&files);
    try validateConfiguredSnapZones(&files.items[@intFromEnum(schema.FileId.layout)].document);
    try validateWindowRules(&files.items[@intFromEnum(schema.FileId.rules)].document);
    const typography = desktopTypography(&files);
    const original_typography = try desktopTypographyFromSource(allocator, originals[@intFromEnum(schema.FileId.appearance)]);
    const typography_changed = !typographySpecsEqual(&original_typography, &typography);
    const original_cursor = try desktopCursorFromSource(allocator, originals[@intFromEnum(schema.FileId.appearance)]);
    const cursor = desktopCursor(&files);
    const cursor_changed = !cursorSpecsEqual(&original_cursor, &cursor);
    try toolkit_sync.validateFamily(typography.family);
    try toolkit_sync.validateStyle(typography.style);
    try cursor_sync.validateTheme(cursor.theme);
    if (cursor.managed and (cursor_changed or cursor_sync_requested)) try cursor_sync.validateInstalledTheme(allocator, cursor.theme);
    if (typography_changed or typography_sync_requested) {
        try toolkit_sync.validateInstalledFont(allocator, io, &typography);
    }

    var sync_report: ?toolkit_sync.Report = null;
    var cursor_report: ?cursor_sync.Report = null;

    if (do_apply and (changed_count > 0 or cursor_sync_requested or typography_sync_requested)) {
        if (changed_count > 1) {
            const backup_dir = jsonString(request.get("backup_dir")) orelse return error.BackupDirRequired;
            try backupOriginals(allocator, backup_dir, expected, &files, originals, dirty);
        }
        if (changed_count > 0) {
            for (&files.items, 0..) |*file_item, index| file_item.dirty = dirty[index];
            files.save() catch |save_error| {
                rollbackOriginals(allocator, &files, originals, dirty);
                return save_error;
            };
        }
        if (typography_changed or typography_sync_requested) {
            sync_report = toolkit_sync.applyForShell(allocator, io, &typography, shell);
        }
        if (cursor_changed or cursor_sync_requested) {
            cursor_report = cursor_sync.apply(allocator, io, &cursor);
        }
    }

    try writeSnapshot(
        io,
        writer,
        &files,
        if (sync_report) |*report| report else null,
        if (cursor_report) |*report| report else null,
        shell,
    );
}

fn writeConfiguredMonitors(
    json: *std.json.Stringify,
    preferred: *const config.Document,
    fallback: *const config.Document,
) !void {
    const preferred_tables = try preferred.tables(preferred.allocator);
    defer preferred.allocator.free(preferred_tables);
    const preferred_entries = try preferred.entries(preferred.allocator);
    defer preferred.allocator.free(preferred_entries);
    const fallback_tables = try fallback.tables(fallback.allocator);
    defer fallback.allocator.free(fallback_tables);
    const fallback_entries = try fallback.entries(fallback.allocator);
    defer fallback.allocator.free(fallback_entries);

    try json.beginArray();
    for (preferred_tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "output")) continue;
        const raw_name = tableEntryRaw(preferred_entries, table.index, "name") orelse continue;
        const name = unquoteToml(raw_name);
        if (name.len == 0) continue;
        const fallback_table = outputTableByExactName(fallback_tables, fallback_entries, name);
        try writeConfiguredMonitor(json, preferred_entries, table.index, fallback_entries, fallback_table, "output", name);
    }
    for (fallback_tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "output")) continue;
        const raw_name = tableEntryRaw(fallback_entries, table.index, "name") orelse continue;
        const name = unquoteToml(raw_name);
        if (name.len == 0 or outputTableByExactName(preferred_tables, preferred_entries, name) != null) continue;
        try writeConfiguredMonitor(json, fallback_entries, table.index, &.{}, null, "wm-output", name);
    }
    try json.endArray();
}

fn writeConfiguredMonitor(
    json: *std.json.Stringify,
    entries: []const config.Document.Entry,
    table_index: usize,
    fallback_entries: []const config.Document.Entry,
    fallback_table: ?usize,
    id_prefix: []const u8,
    name: []const u8,
) !void {
    const raw_position = tableEntryRaw(entries, table_index, "position") orelse if (fallback_table) |index| tableEntryRaw(fallback_entries, index, "position") else null;
    const position = if (raw_position) |raw| parsePosition(raw) else null;
    const raw_transform = tableEntryRaw(entries, table_index, "transform") orelse if (fallback_table) |index| tableEntryRaw(fallback_entries, index, "transform") else null;
    const transform = if (raw_transform) |raw| unquoteToml(raw) else "normal";
    const raw_mode = tableEntryRaw(entries, table_index, "mode") orelse if (fallback_table) |index| tableEntryRaw(fallback_entries, index, "mode") else null;
    const dimensions = if (raw_mode) |raw| parseModeDimensions(unquoteToml(raw)) else null;
    const raw_scale = tableEntryRaw(entries, table_index, "scale") orelse if (fallback_table) |index| tableEntryRaw(fallback_entries, index, "scale") else null;
    const scale = if (raw_scale) |raw| std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r")) catch 1.0 else 1.0;
    var id_buffer: [40]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buffer, "{s}:{d}", .{ id_prefix, table_index });

    try json.beginObject();
    try field(json, "id", id);
    try field(json, "name", name);
    try field(json, "configured", true);
    try field(json, "inherited", std.mem.eql(u8, id_prefix, "wm-output"));
    try field(json, "positioned", position != null);
    if (position) |point| {
        try field(json, "x", point[0]);
        try field(json, "y", point[1]);
    }
    try field(json, "transform", transform);
    try field(json, "scale", scale);
    try field(json, "scale_configured", raw_scale != null);
    try field(json, "mode", if (raw_mode) |raw| unquoteToml(raw) else "");
    try field(json, "mode_inherited", tableEntryRaw(entries, table_index, "mode") == null and raw_mode != null or (std.mem.eql(u8, id_prefix, "wm-output") and raw_mode != null));
    if (dimensions) |size| {
        try field(json, "width", size[0]);
        try field(json, "height", size[1]);
    }
    try json.endObject();
}

fn outputTableByExactName(
    tables: []const config.Document.Table,
    entries: []const config.Document.Entry,
    name: []const u8,
) ?usize {
    for (tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "output")) continue;
        const raw_name = tableEntryRaw(entries, table.index, "name") orelse continue;
        if (std.mem.eql(u8, unquoteToml(raw_name), name)) return table.index;
    }
    return null;
}

fn hasLegacyDisplayPolicy(document: *const config.Document) bool {
    inline for (.{ "apply_on_start", "apply_on_reload", "fallback_profile", "identify_by", "rollback_seconds" }) |key| {
        if (document.getRaw("display", key) != null) return true;
    }
    const tables = document.tables(document.allocator) catch return false;
    defer document.allocator.free(tables);
    const entries = document.entries(document.allocator) catch return false;
    defer document.allocator.free(entries);
    for (tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "output")) continue;
        inline for (.{ "enabled", "mode", "scale", "transform", "position", "adaptive_sync", "hdr", "hdr_level", "sdr_white_level", "auto_hdr", "auto_hdr_boost", "primary" }) |key| {
            if (tableEntryRaw(entries, table.index, key) != null) return true;
        }
    }
    return false;
}

fn writeCustomKeybinds(json: *std.json.Stringify, document: *const config.Document) !void {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    try json.beginArray();
    for (entries) |entry| {
        if (entry.table_index >= tables.len or
            !std.mem.eql(u8, tables[entry.table_index].name, "keybinds.custom")) continue;
        var id_buffer: [40]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "custom:{d}", .{entry.index});
        try json.beginObject();
        try field(json, "id", id);
        try field(json, "chord", entry.key);
        try field(json, "command", unquoteToml(entry.value));
        try json.endObject();
    }
    try json.endArray();
}

fn writeSnapZones(json: *std.json.Stringify, document: *const config.Document) !void {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    try json.beginArray();
    for (0..4) |index| {
        const name = [_]u8{@as(u8, 'a') + @as(u8, @intCast(index))};
        var canonical_buffer: [32]u8 = undefined;
        var legacy_buffer: [32]u8 = undefined;
        const canonical = try std.fmt.bufPrint(&canonical_buffer, "layout.snap-zone.{s}", .{&name});
        const legacy = try std.fmt.bufPrint(&legacy_buffer, "layout.snap_zone.{s}", .{&name});
        var table_index: ?usize = null;
        for (tables) |table| {
            if (!table.repeated and (std.mem.eql(u8, table.name, canonical) or std.mem.eql(u8, table.name, legacy))) table_index = table.index;
        }
        const x = if (table_index) |table| parseFinite(tableEntryRaw(entries, table, "x")) else null;
        const y = if (table_index) |table| parseFinite(tableEntryRaw(entries, table, "y")) else null;
        const width = if (table_index) |table| parseFinite(tableEntryRaw(entries, table, "width")) else null;
        const height = if (table_index) |table| parseFinite(tableEntryRaw(entries, table, "height")) else null;
        const complete = validSnapZone(x, y, width, height);
        try json.beginObject();
        try field(json, "id", &name);
        try field(json, "configured", table_index != null);
        try field(json, "complete", complete);
        try field(json, "x", x orelse 0);
        try field(json, "y", y orelse 0);
        try field(json, "width", width orelse 0);
        try field(json, "height", height orelse 0);
        try json.endObject();
    }
    try json.endArray();
}

const SnapTablePath = struct {
    layout_id: []const u8,
    zone_id: ?[]const u8 = null,
};

fn parseSnapTablePath(name: []const u8) ?SnapTablePath {
    const prefixes = [_][]const u8{ "layout.snap-layout.", "layout.snap_layout." };
    var suffix: ?[]const u8 = null;
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) {
        suffix = name[prefix.len..];
        break;
    };
    const path = suffix orelse return null;
    if (std.mem.indexOf(u8, path, ".zone.")) |separator| {
        const layout_id = path[0..separator];
        const zone_id = path[separator + ".zone.".len ..];
        if (!validSnapId(layout_id) or !validSnapId(zone_id)) return null;
        return .{ .layout_id = layout_id, .zone_id = zone_id };
    }
    if (!validSnapId(path)) return null;
    return .{ .layout_id = path };
}

fn writeSnapLayouts(json: *std.json.Stringify, document: *const config.Document) !void {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(document.allocator);
    for (tables) |table| {
        if (table.repeated) continue;
        const path = parseSnapTablePath(table.name) orelse continue;
        var seen = false;
        for (ids.items) |id| if (std.mem.eql(u8, id, path.layout_id)) {
            seen = true;
            break;
        };
        if (!seen) try ids.append(document.allocator, path.layout_id);
    }

    try json.beginArray();
    for (ids.items) |layout_id| {
        var base_table: ?usize = null;
        for (tables) |table| {
            const path = parseSnapTablePath(table.name) orelse continue;
            if (path.zone_id == null and std.mem.eql(u8, path.layout_id, layout_id)) base_table = table.index;
        }
        const raw_name = if (base_table) |index| tableEntryRaw(entries, index, "name") else null;
        const padding = if (base_table) |index| std.fmt.parseInt(i64, std.mem.trim(u8, tableEntryRaw(entries, index, "padding") orelse "0", " \t\r"), 10) catch 0 else 0;
        try json.beginObject();
        try field(json, "id", layout_id);
        try field(json, "name", if (raw_name) |name| unquoteToml(name) else layout_id);
        try field(json, "padding", padding);
        try json.objectField("zones");
        try json.beginArray();
        for (tables) |table| {
            const path = parseSnapTablePath(table.name) orelse continue;
            const zone_id = path.zone_id orelse continue;
            if (!std.mem.eql(u8, path.layout_id, layout_id)) continue;
            const x = parseFinite(tableEntryRaw(entries, table.index, "x"));
            const y = parseFinite(tableEntryRaw(entries, table.index, "y"));
            const width = parseFinite(tableEntryRaw(entries, table.index, "width"));
            const height = parseFinite(tableEntryRaw(entries, table.index, "height"));
            try json.beginObject();
            try field(json, "id", zone_id);
            try field(json, "name", if (tableEntryRaw(entries, table.index, "name")) |name| unquoteToml(name) else zone_id);
            try field(json, "complete", validSnapZone(x, y, width, height));
            try field(json, "x", x orelse 0);
            try field(json, "y", y orelse 0);
            try field(json, "width", width orelse 0);
            try field(json, "height", height orelse 0);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
}

fn replaceSnapLayouts(
    allocator: Allocator,
    document: *config.Document,
    requested: []const Json,
    requested_default: []const u8,
) !void {
    if (requested.len > 8) return error.TooManySnapLayouts;
    for (requested, 0..) |raw_layout, layout_index| {
        if (raw_layout != .object) return error.InvalidSnapLayout;
        const id = jsonString(raw_layout.object.get("id")) orelse return error.InvalidSnapLayoutId;
        if (!validSnapId(id)) return error.InvalidSnapLayoutId;
        for (requested[0..layout_index]) |prior| {
            if (prior == .object and std.mem.eql(u8, jsonString(prior.object.get("id")) orelse "", id)) return error.DuplicateSnapLayoutId;
        }
        const zones = raw_layout.object.get("zones") orelse return error.InvalidSnapZones;
        if (zones != .array or zones.array.items.len > 16) return error.InvalidSnapZones;
        for (zones.array.items, 0..) |raw_zone, zone_index| {
            if (raw_zone != .object) return error.InvalidSnapZoneChange;
            const zone_id = jsonString(raw_zone.object.get("id")) orelse return error.InvalidSnapZoneId;
            if (!validSnapId(zone_id)) return error.InvalidSnapZoneId;
            for (zones.array.items[0..zone_index]) |prior| {
                if (prior == .object and std.mem.eql(u8, jsonString(prior.object.get("id")) orelse "", zone_id)) return error.DuplicateSnapZoneId;
            }
            if (!validSnapZone(
                jsonNumber(raw_zone.object.get("x") orelse return error.InvalidSnapZoneValue),
                jsonNumber(raw_zone.object.get("y") orelse return error.InvalidSnapZoneValue),
                jsonNumber(raw_zone.object.get("width") orelse return error.InvalidSnapZoneValue),
                jsonNumber(raw_zone.object.get("height") orelse return error.InvalidSnapZoneValue),
            )) return error.InvalidSnapZoneValue;
        }
    }
    if (requested.len != 0) {
        if (!validSnapId(requested_default)) return error.InvalidDefaultSnapLayout;
        var found_default = false;
        for (requested) |raw_layout| if (std.mem.eql(u8, jsonString(raw_layout.object.get("id")) orelse "", requested_default)) {
            found_default = true;
            break;
        };
        if (!found_default) return error.InvalidDefaultSnapLayout;
    }

    const old_tables = try document.tables(allocator);
    defer allocator.free(old_tables);
    var delete_indices = std.ArrayList(usize).empty;
    defer delete_indices.deinit(allocator);
    for (old_tables) |table| if (!table.repeated and parseSnapTablePath(table.name) != null) try delete_indices.append(allocator, table.index);
    var delete_index = delete_indices.items.len;
    while (delete_index > 0) {
        delete_index -= 1;
        try document.deleteTable(delete_indices.items[delete_index]);
    }

    if (requested.len == 0) {
        const tables = try document.tables(allocator);
        defer allocator.free(tables);
        for (tables) |table| {
            if (!table.repeated and std.mem.eql(u8, table.name, "layout")) {
                _ = try document.deleteTableEntry(table.index, "snap_layout");
                break;
            }
        }
        return;
    }
    const encoded_default = try jsonStringLiteral(allocator, requested_default);
    try document.setRaw("layout", "snap_layout", encoded_default);
    for (requested) |raw_layout| {
        const id = jsonString(raw_layout.object.get("id")).?;
        const name = jsonString(raw_layout.object.get("name")) orelse id;
        const padding = jsonInteger(raw_layout.object.get("padding") orelse .{ .integer = 0 }) orelse return error.InvalidSnapLayoutPadding;
        if (padding < 0 or padding > 512) return error.InvalidSnapLayoutPadding;
        const section = try std.fmt.allocPrint(allocator, "layout.snap-layout.{s}", .{id});
        const encoded_name = try jsonStringLiteral(allocator, name);
        try document.setRaw(section, "name", encoded_name);
        const encoded_padding = try std.fmt.allocPrint(allocator, "{d}", .{padding});
        try document.setRaw(section, "padding", encoded_padding);
        for (raw_layout.object.get("zones").?.array.items) |raw_zone| {
            const zone_id = jsonString(raw_zone.object.get("id")).?;
            const zone_name = jsonString(raw_zone.object.get("name")) orelse zone_id;
            const zone_section = try std.fmt.allocPrint(allocator, "layout.snap-layout.{s}.zone.{s}", .{ id, zone_id });
            const encoded_zone_name = try jsonStringLiteral(allocator, zone_name);
            try document.setRaw(zone_section, "name", encoded_zone_name);
            inline for (.{ "x", "y", "width", "height" }) |key| {
                const value = jsonNumber(raw_zone.object.get(key).?).?;
                const encoded = try std.fmt.allocPrint(allocator, "{d}", .{value});
                try document.setRaw(zone_section, key, encoded);
            }
        }
    }
}

fn validSnapId(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return false;
    return true;
}

fn applySnapZoneChanges(allocator: Allocator, document: *config.Document, requested: []const Json) !void {
    for (requested) |raw_change| {
        if (raw_change != .object) return error.InvalidSnapZoneChange;
        const id = jsonString(raw_change.object.get("id")) orelse return error.InvalidSnapZoneId;
        if (id.len != 1 or id[0] < 'a' or id[0] > 'd') return error.InvalidSnapZoneId;
        const operation = jsonString(raw_change.object.get("op")) orelse "update";
        var canonical_buffer: [32]u8 = undefined;
        var legacy_buffer: [32]u8 = undefined;
        const canonical = try std.fmt.bufPrint(&canonical_buffer, "layout.snap-zone.{s}", .{id});
        const legacy = try std.fmt.bufPrint(&legacy_buffer, "layout.snap_zone.{s}", .{id});
        const aliases = &.{legacy};
        if (std.mem.eql(u8, operation, "delete")) {
            try deleteNamedSections(document, canonical, aliases);
            continue;
        }
        if (!std.mem.eql(u8, operation, "update")) return error.InvalidSnapZoneOperation;
        const x = jsonNumber(raw_change.object.get("x") orelse return error.InvalidSnapZoneValue) orelse return error.InvalidSnapZoneValue;
        const y = jsonNumber(raw_change.object.get("y") orelse return error.InvalidSnapZoneValue) orelse return error.InvalidSnapZoneValue;
        const width = jsonNumber(raw_change.object.get("width") orelse return error.InvalidSnapZoneValue) orelse return error.InvalidSnapZoneValue;
        const height = jsonNumber(raw_change.object.get("height") orelse return error.InvalidSnapZoneValue) orelse return error.InvalidSnapZoneValue;
        if (!validSnapZone(x, y, width, height)) return error.InvalidSnapZoneValue;
        inline for (.{ .{ "x", x }, .{ "y", y }, .{ "width", width }, .{ "height", height } }) |item| {
            const encoded = try std.fmt.allocPrint(allocator, "{d}", .{item[1]});
            try document.setRawAliases(canonical, aliases, item[0], encoded);
        }
    }
}

fn parseFinite(raw: ?[]const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, std.mem.trim(u8, raw orelse return null, " \t\r")) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

fn validSnapZone(x: ?f64, y: ?f64, width: ?f64, height: ?f64) bool {
    const actual_x = x orelse return false;
    const actual_y = y orelse return false;
    const actual_width = width orelse return false;
    const actual_height = height orelse return false;
    return actual_x >= 0 and actual_y >= 0 and actual_width > 0 and actual_height > 0 and
        actual_x + actual_width <= 1 and actual_y + actual_height <= 1;
}

fn validateConfiguredSnapZones(document: *const config.Document) !void {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    for (tables) |table| {
        if (table.repeated) continue;
        const legacy = std.mem.startsWith(u8, table.name, "layout.snap-zone.") or std.mem.startsWith(u8, table.name, "layout.snap_zone.");
        const named_zone = if (parseSnapTablePath(table.name)) |path| path.zone_id != null else false;
        if (!legacy and !named_zone) continue;
        if (!validSnapZone(
            parseFinite(tableEntryRaw(entries, table.index, "x")),
            parseFinite(tableEntryRaw(entries, table.index, "y")),
            parseFinite(tableEntryRaw(entries, table.index, "width")),
            parseFinite(tableEntryRaw(entries, table.index, "height")),
        )) return error.InvalidSnapZoneValue;
    }
}

fn deleteNamedSections(document: *config.Document, canonical: []const u8, aliases: []const []const u8) !void {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    var indices = std.ArrayList(usize).empty;
    defer indices.deinit(document.allocator);
    for (tables) |table| {
        if (table.index == 0 or table.repeated) continue;
        var matches = std.mem.eql(u8, table.name, canonical);
        for (aliases) |alias| if (std.mem.eql(u8, table.name, alias)) {
            matches = true;
            break;
        };
        if (matches) try indices.append(document.allocator, table.index);
    }
    var index = indices.items.len;
    while (index > 0) {
        index -= 1;
        try document.deleteTable(indices.items[index]);
    }
}

fn normalizeStackingSections(allocator: Allocator, document: *config.Document) !void {
    const stacking_field = schema.find("layout.options.float.placement").?;
    const tables = try document.tables(allocator);
    defer allocator.free(tables);
    const entries = try document.entries(allocator);
    defer allocator.free(entries);
    const Item = struct { key: []const u8, value: []const u8 };
    var effective = std.ArrayList(Item).empty;
    defer effective.deinit(allocator);
    for (tables) |table| {
        if (table.repeated) continue;
        var matches = std.mem.eql(u8, table.name, stacking_field.section);
        for (stacking_field.section_aliases) |alias| if (std.mem.eql(u8, table.name, alias)) {
            matches = true;
            break;
        };
        if (!matches) continue;
        for (entries) |entry| {
            if (entry.table_index != table.index) continue;
            var found = false;
            for (effective.items) |*item| if (std.mem.eql(u8, item.key, entry.key)) {
                item.value = try allocator.dupe(u8, entry.value);
                found = true;
                break;
            };
            if (!found) try effective.append(allocator, .{
                .key = try allocator.dupe(u8, entry.key),
                .value = try allocator.dupe(u8, entry.value),
            });
        }
    }
    if (effective.items.len == 0) return;
    try deleteNamedSections(document, stacking_field.section, stacking_field.section_aliases);
    const first = effective.items[0];
    const header = try std.fmt.allocPrint(allocator, "[{s}]", .{stacking_field.section});
    try document.appendTable(header, first.key, first.value);
    for (effective.items[1..]) |item| try document.setRaw(stacking_field.section, item.key, item.value);
}

const rule_keys: []const []const u8 = &.{
    "app_id",           "class",         "title",         "content_type", "layout",         "output",        "workspace",
    "floating",         "fullscreen",    "ignore_struts", "width",        "height",         "x",             "y",
    "placement_policy", "anchor",        "size",          "scale",        "blur",           "opacity",       "buffer_scale_policy",
    "hdr_expand",       "overlay_plane", "stack_layer",   "focus",        "fixed_position", "skip_switcher", "skip_taskbar",
};

fn writeWindowRules(json: *std.json.Stringify, document: *const config.Document) !void {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    try json.beginArray();
    var position: usize = 0;
    for (tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "window")) continue;
        var id_buffer: [40]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "rule:{d}", .{table.index});
        try json.beginObject();
        try field(json, "id", id);
        try field(json, "position", position);
        try json.objectField("values");
        try json.beginObject();
        for (entries) |entry| {
            if (entry.table_index != table.index) continue;
            try json.objectField(entry.key);
            try writeRuleJsonValue(json, entry.key, entry.value);
        }
        try json.endObject();
        try json.endObject();
        position += 1;
    }
    try json.endArray();
}

fn writeRuleJsonValue(json: *std.json.Stringify, key: []const u8, raw: []const u8) !void {
    if (ruleBoolean(key)) {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "true")) return json.write(true);
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "false")) return json.write(false);
    }
    if (ruleInteger(key)) {
        if (std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r"), 10)) |value| return json.write(value) else |_| {}
    }
    if (ruleDouble(key)) {
        if (std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r"))) |value| return json.write(value) else |_| {}
    }
    const text = if (std.mem.eql(u8, key, "layout")) schema.normalizeLayout(unquoteToml(raw)) else if (ruleKnown(key)) unquoteToml(raw) else raw;
    try json.write(text);
}

fn applyWindowRuleChanges(allocator: Allocator, document: *config.Document, requested: []const Json) !void {
    var move_change: ?Json = null;
    var non_move_count: usize = 0;
    for (requested) |change| {
        if (change != .object) return error.InvalidWindowRuleChange;
        const operation = jsonString(change.object.get("op")) orelse "update";
        if (std.mem.eql(u8, operation, "move")) move_change = change else non_move_count += 1;
    }
    if (move_change != null and (non_move_count > 0 or requested.len > 1)) return error.ConflictingRuleOperations;
    if (move_change) |change| {
        const table_index = try ruleTableFromId(document, jsonString(change.object.get("id")) orelse return error.InvalidWindowRuleId);
        const direction = jsonInteger(change.object.get("direction")) orelse return error.InvalidWindowRuleMove;
        if (direction != -1 and direction != 1) return error.InvalidWindowRuleMove;
        const peer = try adjacentWindowRuleTable(document, table_index, direction);
        if (peer) |target| try document.moveTable(table_index, target, direction > 0);
        return;
    }

    // Updates do not alter table indices, so apply them before descending
    // deletes. Adds are appended last and receive IDs in the returned snapshot.
    for (requested) |change| {
        const operation = jsonString(change.object.get("op")) orelse "update";
        if (!std.mem.eql(u8, operation, "update")) continue;
        const table_index = try ruleTableFromId(document, jsonString(change.object.get("id")) orelse return error.InvalidWindowRuleId);
        const values = change.object.get("values") orelse return error.InvalidWindowRuleValues;
        if (values != .object) return error.InvalidWindowRuleValues;
        try applyRuleValues(allocator, document, table_index, values.object);
    }

    var deletes = std.ArrayList(usize).empty;
    defer deletes.deinit(allocator);
    for (requested) |change| {
        const operation = jsonString(change.object.get("op")) orelse "update";
        if (std.mem.eql(u8, operation, "delete")) {
            try deletes.append(allocator, try ruleTableFromId(document, jsonString(change.object.get("id")) orelse return error.InvalidWindowRuleId));
        } else if (!std.mem.eql(u8, operation, "update") and !std.mem.eql(u8, operation, "add")) {
            return error.InvalidWindowRuleOperation;
        }
    }
    std.mem.sort(usize, deletes.items, {}, std.sort.desc(usize));
    for (deletes.items) |table_index| try document.deleteTable(table_index);

    for (requested) |change| {
        const operation = jsonString(change.object.get("op")) orelse "update";
        if (!std.mem.eql(u8, operation, "add")) continue;
        const values = change.object.get("values") orelse return error.InvalidWindowRuleValues;
        if (values != .object or values.object.count() == 0) return error.InvalidWindowRuleValues;
        var iterator = values.object.iterator();
        var first_key: ?[]const u8 = null;
        var first_value: ?Json = null;
        while (iterator.next()) |entry| {
            if (!ruleKnown(entry.key_ptr.*)) return error.InvalidWindowRuleKey;
            if (entry.value_ptr.* == .null or jsonEmptyString(entry.value_ptr.*)) continue;
            first_key = entry.key_ptr.*;
            first_value = entry.value_ptr.*;
            break;
        }
        const key = first_key orelse return error.InvalidWindowRuleValues;
        const first_encoded = try encodeRuleValue(allocator, key, first_value.?);
        const header = "[[window]]";
        try document.appendTable(header, key, first_encoded);
        const table_index = try lastWindowRuleTable(document);
        iterator = values.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;
            if (!ruleKnown(entry.key_ptr.*) or entry.value_ptr.* == .null or jsonEmptyString(entry.value_ptr.*)) continue;
            const encoded = try encodeRuleValue(allocator, entry.key_ptr.*, entry.value_ptr.*);
            try setTableRaw(document, table_index, entry.key_ptr.*, encoded);
        }
    }
    try validateWindowRules(document);
}

fn applyRuleValues(allocator: Allocator, document: *config.Document, table_index: usize, values: std.json.ObjectMap) !void {
    var iterator = values.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!ruleKnown(key)) return error.InvalidWindowRuleKey;
        if (entry.value_ptr.* == .null or jsonEmptyString(entry.value_ptr.*)) {
            _ = try document.deleteTableEntry(table_index, key);
        } else {
            const encoded = try encodeRuleValue(allocator, key, entry.value_ptr.*);
            try setTableRaw(document, table_index, key, encoded);
        }
    }
}

fn jsonEmptyString(value: Json) bool {
    return value == .string and value.string.len == 0;
}

fn encodeRuleValue(allocator: Allocator, key: []const u8, value: Json) ![]const u8 {
    if (ruleBoolean(key)) {
        const actual = jsonBool(value) orelse return error.InvalidWindowRuleValue;
        return if (actual) "true" else "false";
    }
    if (ruleInteger(key)) {
        const actual = jsonInteger(value) orelse return error.InvalidWindowRuleValue;
        if ((std.mem.eql(u8, key, "workspace") and (actual < 1 or actual > std.math.maxInt(u32))) or
            ((std.mem.eql(u8, key, "width") or std.mem.eql(u8, key, "height")) and (actual < 1 or actual > 100_000)) or
            ((std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y")) and (actual < -100_000 or actual > 100_000))) return error.InvalidWindowRuleValue;
        return std.fmt.allocPrint(allocator, "{d}", .{actual});
    }
    if (ruleDouble(key)) {
        const actual = jsonNumber(value) orelse return error.InvalidWindowRuleValue;
        if (!std.math.isFinite(actual) or
            (std.mem.eql(u8, key, "scale") and (actual <= 0 or actual > 16)) or
            (std.mem.eql(u8, key, "opacity") and (actual < 0 or actual > 1))) return error.InvalidWindowRuleValue;
        return std.fmt.allocPrint(allocator, "{d}", .{actual});
    }
    var text = jsonString(value) orelse return error.InvalidWindowRuleValue;
    if (text.len > 1024) return error.InvalidWindowRuleValue;
    if (std.mem.eql(u8, key, "layout")) text = schema.normalizeLayout(text);
    if (!validRuleText(key, text)) return error.InvalidWindowRuleValue;
    return jsonStringLiteral(allocator, text);
}

fn validateWindowRules(document: *const config.Document) !void {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    for (tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "window")) continue;
        var matcher = false;
        for (entries) |entry| {
            if (entry.table_index != table.index) continue;
            if (ruleKnown(entry.key)) try validateRuleRaw(entry.key, entry.value);
            if ((std.mem.eql(u8, entry.key, "app_id") or std.mem.eql(u8, entry.key, "class") or std.mem.eql(u8, entry.key, "title") or std.mem.eql(u8, entry.key, "content_type")) and unquoteToml(entry.value).len > 0) matcher = true;
        }
        if (!matcher) return error.WindowRuleMissingMatcher;
    }
}

fn ruleTableFromId(document: *const config.Document, id: []const u8) !usize {
    if (!std.mem.startsWith(u8, id, "rule:")) return error.InvalidWindowRuleId;
    const wanted = std.fmt.parseInt(usize, id["rule:".len..], 10) catch return error.InvalidWindowRuleId;
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    for (tables) |table| if (table.index == wanted and table.repeated and std.mem.eql(u8, table.name, "window")) return wanted;
    return error.UnknownWindowRule;
}

fn lastWindowRuleTable(document: *const config.Document) !usize {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    var result: ?usize = null;
    for (tables) |table| {
        if (table.repeated and std.mem.eql(u8, table.name, "window")) result = table.index;
    }
    return result orelse error.UnknownWindowRule;
}

fn adjacentWindowRuleTable(document: *const config.Document, wanted: usize, direction: i64) !?usize {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    var previous: ?usize = null;
    var seen = false;
    for (tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "window")) continue;
        if (direction < 0 and table.index == wanted) return previous;
        if (seen) return table.index;
        if (table.index == wanted) seen = true;
        previous = table.index;
    }
    return null;
}

fn ruleKnown(key: []const u8) bool {
    for (rule_keys) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

fn ruleBoolean(key: []const u8) bool {
    inline for (.{ "floating", "fullscreen", "ignore_struts", "blur", "hdr_expand", "focus", "fixed_position", "skip_switcher", "skip_taskbar" }) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

fn ruleInteger(key: []const u8) bool {
    inline for (.{ "workspace", "width", "height", "x", "y" }) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

fn ruleDouble(key: []const u8) bool {
    return std.mem.eql(u8, key, "scale") or std.mem.eql(u8, key, "opacity");
}

fn validateRuleRaw(key: []const u8, raw: []const u8) !void {
    if (ruleBoolean(key)) {
        const value = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidWindowRuleValue;
        return;
    }
    if (ruleInteger(key)) {
        const value = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r"), 10) catch return error.InvalidWindowRuleValue;
        if ((std.mem.eql(u8, key, "workspace") and (value < 1 or value > std.math.maxInt(u32))) or
            ((std.mem.eql(u8, key, "width") or std.mem.eql(u8, key, "height")) and (value < 1 or value > 100_000)) or
            ((std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y")) and (value < -100_000 or value > 100_000))) return error.InvalidWindowRuleValue;
        return;
    }
    if (ruleDouble(key)) {
        const value = std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r")) catch return error.InvalidWindowRuleValue;
        if (!std.math.isFinite(value) or
            (std.mem.eql(u8, key, "scale") and (value <= 0 or value > 16)) or
            (std.mem.eql(u8, key, "opacity") and (value < 0 or value > 1))) return error.InvalidWindowRuleValue;
        return;
    }
    var value = unquoteToml(raw);
    if (std.mem.eql(u8, key, "layout")) value = schema.normalizeLayout(value);
    if (!validRuleText(key, value)) return error.InvalidWindowRuleValue;
}

fn validRuleText(key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "layout")) return valueIn(value, &.{ "tile", "monocle", "grid", "rows", "dwindle", "reverse-dwindle", "scrolling", "stacking", "game-mode", "composable" });
    if (std.mem.eql(u8, key, "content_type")) return valueIn(value, &.{ "none", "photo", "video", "game" });
    if (std.mem.eql(u8, key, "placement_policy")) return valueIn(value, &.{ "cascade", "center", "under-pointer", "minimal-overlap" });
    if (std.mem.eql(u8, key, "anchor")) return valueIn(value, &.{ "center", "top", "bottom", "left", "right" });
    if (std.mem.eql(u8, key, "buffer_scale_policy")) return valueIn(value, &.{ "native", "integer-ceil" });
    if (std.mem.eql(u8, key, "overlay_plane")) return valueIn(value, &.{ "off", "prefer" });
    if (std.mem.eql(u8, key, "stack_layer")) return valueIn(value, &.{ "below", "normal", "above" });
    if (std.mem.eql(u8, key, "size")) return validRuleSize(value);
    return true;
}

fn validRuleSize(value: []const u8) bool {
    if (std.mem.eql(u8, value, "native")) return true;
    const split = std.mem.indexOfScalar(u8, value, 'x') orelse return false;
    const left = value[0..split];
    const right = value[split + 1 ..];
    if (std.mem.indexOfScalar(u8, left, '.') != null or std.mem.indexOfScalar(u8, right, '.') != null) {
        const width = std.fmt.parseFloat(f64, left) catch return false;
        const height = std.fmt.parseFloat(f64, right) catch return false;
        return std.math.isFinite(width) and std.math.isFinite(height) and width > 0 and width <= 1 and height > 0 and height <= 1;
    }
    const width = std.fmt.parseInt(i64, left, 10) catch return false;
    const height = std.fmt.parseInt(i64, right, 10) catch return false;
    return width > 0 and height > 0;
}

fn valueIn(value: []const u8, options: []const []const u8) bool {
    for (options) |option_value| if (std.mem.eql(u8, value, option_value)) return true;
    return false;
}

const CustomKeybindChange = struct {
    operation: enum { update, delete },
    entry_index: usize,
    table_index: usize,
    old_chord: []const u8 = "",
    chord: []const u8,
    command: []const u8,
};

const NewCustomKeybind = struct { chord: []const u8, command: []const u8 };

fn applyCustomKeybindChanges(
    allocator: Allocator,
    document: *config.Document,
    requested: []const Json,
) !void {
    const tables = try document.tables(allocator);
    defer allocator.free(tables);
    const entries = try document.entries(allocator);
    defer allocator.free(entries);
    var changes = std.ArrayList(CustomKeybindChange).empty;
    defer changes.deinit(allocator);
    var additions = std.ArrayList(NewCustomKeybind).empty;
    defer additions.deinit(allocator);
    var claimed = std.StringHashMap(void).init(allocator);
    defer claimed.deinit();

    for (requested) |raw_change| {
        if (raw_change != .object) return error.InvalidCustomKeybindChange;
        const operation = jsonString(raw_change.object.get("op")) orelse "update";
        if (std.mem.eql(u8, operation, "add")) {
            const chord = jsonString(raw_change.object.get("chord")) orelse return error.InvalidCustomKeybindChord;
            const command = jsonString(raw_change.object.get("command")) orelse return error.InvalidCustomKeybindCommand;
            try validateCustomKeybind(chord, command);
            try additions.append(allocator, .{ .chord = chord, .command = command });
            continue;
        }
        const id = jsonString(raw_change.object.get("id")) orelse return error.InvalidCustomKeybindId;
        if (!std.mem.startsWith(u8, id, "custom:")) return error.InvalidCustomKeybindId;
        const entry_index = std.fmt.parseInt(usize, id["custom:".len..], 10) catch return error.InvalidCustomKeybindId;
        var found: ?config.Document.Entry = null;
        for (entries) |entry| if (entry.index == entry_index) {
            found = entry;
            break;
        };
        const entry = found orelse return error.UnknownCustomKeybind;
        if (entry.table_index >= tables.len or
            !std.mem.eql(u8, tables[entry.table_index].name, "keybinds.custom"))
            return error.UnknownCustomKeybind;
        if (std.mem.eql(u8, operation, "delete")) {
            try changes.append(allocator, .{
                .operation = .delete,
                .entry_index = entry_index,
                .table_index = entry.table_index,
                .chord = "",
                .command = "",
            });
            continue;
        }
        if (!std.mem.eql(u8, operation, "update")) return error.InvalidCustomKeybindChange;
        const chord = jsonString(raw_change.object.get("chord")) orelse return error.InvalidCustomKeybindChord;
        const command = jsonString(raw_change.object.get("command")) orelse return error.InvalidCustomKeybindCommand;
        try validateCustomKeybind(chord, command);
        try changes.append(allocator, .{
            .operation = .update,
            .entry_index = entry_index,
            .table_index = entry.table_index,
            .old_chord = try allocator.dupe(u8, entry.key),
            .chord = chord,
            .command = command,
        });
    }

    // Validate the final custom chord set before changing the document.
    for (entries) |entry| {
        if (entry.table_index >= tables.len or !std.mem.eql(u8, tables[entry.table_index].name, "keybinds.custom")) continue;
        var replacement: ?[]const u8 = null;
        var removed = false;
        for (changes.items) |change| if (change.entry_index == entry.index) {
            removed = change.operation == .delete;
            if (!removed) replacement = change.chord;
        };
        if (!removed) {
            const chord = replacement orelse entry.key;
            if (try chordConfiguredInBuiltins(document, chord)) return error.DuplicateCustomKeybind;
            if (claimed.contains(chord)) return error.DuplicateCustomKeybind;
            try claimed.put(chord, {});
        }
    }
    for (additions.items) |addition| {
        if (try chordConfiguredInBuiltins(document, addition.chord)) return error.DuplicateCustomKeybind;
        if (claimed.contains(addition.chord)) return error.DuplicateCustomKeybind;
        try claimed.put(addition.chord, {});
    }
    std.mem.sort(CustomKeybindChange, changes.items, {}, struct {
        fn lessThan(_: void, left: CustomKeybindChange, right: CustomKeybindChange) bool {
            return left.entry_index > right.entry_index;
        }
    }.lessThan);
    for (changes.items) |change| {
        if (change.operation == .delete) {
            try document.deleteEntry(change.entry_index);
            continue;
        }
        const encoded_command = try jsonStringLiteral(allocator, change.command);
        if (std.mem.eql(u8, change.old_chord, change.chord)) {
            try document.setEntryRaw(change.entry_index, encoded_command);
        } else {
            try document.deleteEntry(change.entry_index);
            const encoded_chord = try jsonStringLiteral(allocator, change.chord);
            try document.addToTable(change.table_index, encoded_chord, encoded_command);
        }
    }
    if (additions.items.len > 0) {
        var table_index = try customKeybindTable(document);
        for (additions.items) |addition| {
            const encoded_chord = try jsonStringLiteral(allocator, addition.chord);
            const encoded_command = try jsonStringLiteral(allocator, addition.command);
            if (table_index) |table| {
                try document.addToTable(table, encoded_chord, encoded_command);
            } else {
                try document.appendTable("[keybinds.custom]", encoded_chord, encoded_command);
                table_index = try customKeybindTable(document);
            }
        }
    }
}

fn validateCustomKeybind(chord: []const u8, command: []const u8) !void {
    if (chord.len == 0 or chord.len > 128) return error.InvalidCustomKeybindChord;
    if (command.len == 0 or command.len > 1024) return error.InvalidCustomKeybindCommand;
}

fn customKeybindTable(document: *const config.Document) !?usize {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    var result: ?usize = null;
    for (tables) |table| {
        if (!table.repeated and std.mem.eql(u8, table.name, "keybinds.custom")) result = table.index;
    }
    return result;
}

fn chordConfiguredInBuiltins(document: *const config.Document, chord: []const u8) !bool {
    for (&schema.fields) |*schema_field| {
        if (schema_field.category != .keybinds or !std.mem.eql(u8, schema_field.section, "keybinds")) continue;
        const raw = document.getRaw("keybinds", schema_field.key) orelse schema_field.default_raw;
        if (rawStringListContains(raw, chord)) return true;
    }
    return false;
}

fn rawStringListContains(raw_value: []const u8, wanted: []const u8) bool {
    const raw = std.mem.trim(u8, raw_value, " \t\r");
    if (raw.len == 0) return false;
    if (raw[0] != '[') return std.mem.eql(u8, unquoteToml(raw), wanted);
    if (raw.len < 2 or raw[raw.len - 1] != ']') return false;
    var items = std.mem.splitScalar(u8, raw[1 .. raw.len - 1], ',');
    while (items.next()) |item| if (std.mem.eql(u8, unquoteToml(std.mem.trim(u8, item, " \t\r")), wanted)) return true;
    return false;
}

fn applyMonitorChanges(
    allocator: Allocator,
    document: *config.Document,
    legacy: *const config.Document,
    monitor_changes: []const Json,
) !void {
    for (monitor_changes) |change| {
        if (change != .object) return error.InvalidMonitorChange;
        const id = jsonString(change.object.get("id")) orelse return error.MissingMonitorId;
        const name = jsonString(change.object.get("name")) orelse return error.MissingMonitorName;
        if (name.len == 0 or name.len > 128) return error.InvalidMonitorName;
        const x = jsonInteger(change.object.get("x")) orelse return error.InvalidMonitorPosition;
        const y = jsonInteger(change.object.get("y")) orelse return error.InvalidMonitorPosition;
        if (x < -100_000 or x > 100_000 or y < -100_000 or y > 100_000) return error.InvalidMonitorPosition;
        const transform = jsonString(change.object.get("transform")) orelse return error.InvalidMonitorTransform;
        if (!validMonitorTransform(transform)) return error.InvalidMonitorTransform;

        const mode = if (change.object.get("mode")) |value| jsonString(value) orelse return error.InvalidMonitorMode else null;
        if (mode) |value| if (!validMonitorMode(value)) return error.InvalidMonitorMode;

        var table_index: ?usize = null;
        if (std.mem.startsWith(u8, id, "output:")) {
            table_index = std.fmt.parseInt(usize, id["output:".len..], 10) catch return error.InvalidMonitorId;
            if (!isOutputTable(document, table_index.?)) return error.UnknownMonitor;
        } else if (std.mem.startsWith(u8, id, "wm-output:")) {
            const legacy_index = std.fmt.parseInt(usize, id["wm-output:".len..], 10) catch return error.InvalidMonitorId;
            if (!isOutputTable(legacy, legacy_index)) return error.UnknownMonitor;
            table_index = try outputTableByName(document, name);
            if (table_index == null) {
                const encoded_name = try jsonStringLiteral(allocator, name);
                try document.appendTable("[[output]]", "name", encoded_name);
                table_index = try lastOutputTable(document);
            }
        } else if (std.mem.startsWith(u8, id, "live:")) {
            if (!std.mem.eql(u8, id["live:".len..], name)) return error.InvalidMonitorId;
            table_index = try outputTableByName(document, name);
            if (table_index == null) {
                const encoded_name = try jsonStringLiteral(allocator, name);
                try document.appendTable("[[output]]", "name", encoded_name);
                table_index = try lastOutputTable(document);
            }
        } else return error.InvalidMonitorId;

        const encoded_position = try std.fmt.allocPrint(allocator, "[{d}, {d}]", .{ x, y });
        const encoded_transform = try jsonStringLiteral(allocator, transform);
        try setTableRaw(document, table_index.?, "position", encoded_position);
        try setTableRaw(document, table_index.?, "transform", encoded_transform);
        if (mode) |value| {
            const encoded_mode = try jsonStringLiteral(allocator, value);
            try setTableRaw(document, table_index.?, "mode", encoded_mode);
        }
    }
}

fn tableEntryRaw(entries: []const config.Document.Entry, table_index: usize, key: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (entries) |entry| {
        if (entry.table_index == table_index and std.mem.eql(u8, entry.key, key)) result = entry.value;
    }
    return result;
}

fn isOutputTable(document: *const config.Document, wanted: usize) bool {
    const tables = document.tables(document.allocator) catch return false;
    defer document.allocator.free(tables);
    for (tables) |table| {
        if (table.index == wanted) return table.repeated and std.mem.eql(u8, table.name, "output");
    }
    return false;
}

fn outputTableByName(document: *const config.Document, name: []const u8) !?usize {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    for (tables) |table| {
        if (!table.repeated or !std.mem.eql(u8, table.name, "output")) continue;
        const raw = tableEntryRaw(entries, table.index, "name") orelse continue;
        if (std.mem.eql(u8, unquoteToml(raw), name)) return table.index;
    }
    return null;
}

fn lastOutputTable(document: *const config.Document) !usize {
    const tables = try document.tables(document.allocator);
    defer document.allocator.free(tables);
    var result: ?usize = null;
    for (tables) |table| {
        if (table.repeated and std.mem.eql(u8, table.name, "output")) result = table.index;
    }
    return result orelse error.UnknownMonitor;
}

fn setTableRaw(document: *config.Document, table_index: usize, key: []const u8, encoded: []const u8) !void {
    const entries = try document.entries(document.allocator);
    defer document.allocator.free(entries);
    var entry_index: ?usize = null;
    for (entries) |entry| {
        if (entry.table_index == table_index and std.mem.eql(u8, entry.key, key)) entry_index = entry.index;
    }
    if (entry_index) |wanted| {
        try document.setEntryRaw(wanted, encoded);
    } else {
        try document.addToTable(table_index, key, encoded);
    }
}

fn parsePosition(raw_value: []const u8) ?[2]i64 {
    const value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len < 5 or value[0] != '[' or value[value.len - 1] != ']') return null;
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return null;
    return .{
        std.fmt.parseInt(i64, std.mem.trim(u8, value[1..comma], " \t"), 10) catch return null,
        std.fmt.parseInt(i64, std.mem.trim(u8, value[comma + 1 .. value.len - 1], " \t"), 10) catch return null,
    };
}

// The compositor accepts WxH or WxH@Hz. Bound values before its conversion
// to integer millihertz and reject malformed strings before touching a file.
fn validMonitorMode(value: []const u8) bool {
    const dimensions = parseModeDimensions(value) orelse return false;
    if (dimensions[0] > 100_000 or dimensions[1] > 100_000) return false;
    if (std.mem.indexOfScalar(u8, value, '@')) |at| {
        const hz = std.fmt.parseFloat(f64, value[at + 1 ..]) catch return false;
        return std.math.isFinite(hz) and hz >= 0.001 and hz <= 1000;
    }
    return true;
}

fn writeLiveOutputs(io: std.Io, json: *std.json.Stringify, allocator: Allocator) !void {
    const process_allocator = std.heap.c_allocator;
    const result = std.process.run(process_allocator, io, .{
        .argv = &.{ "aqueousctl", "outputs", "--json" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return json.write([_]Json{});
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return json.write([_]Json{});
    var parsed = std.json.parseFromSlice(Json, allocator, result.stdout, .{}) catch return json.write([_]Json{});
    defer parsed.deinit();
    if (parsed.value != .array) return json.write([_]Json{});
    try json.write(parsed.value);
}

fn parseModeDimensions(value: []const u8) ?[2]i64 {
    const x = std.mem.indexOfScalar(u8, value, 'x') orelse return null;
    const at = std.mem.indexOfScalarPos(u8, value, x + 1, '@') orelse value.len;
    const width = std.fmt.parseInt(i64, value[0..x], 10) catch return null;
    const height = std.fmt.parseInt(i64, value[x + 1 .. at], 10) catch return null;
    if (width <= 0 or height <= 0) return null;
    return .{ width, height };
}

fn validMonitorTransform(value: []const u8) bool {
    const transforms = [_][]const u8{
        "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270",
    };
    for (transforms) |transform| if (std.mem.eql(u8, value, transform)) return true;
    return false;
}

fn encodeTomlValue(allocator: Allocator, schema_field: *const schema.Field, value: Json) ![]const u8 {
    switch (schema_field.kind) {
        .boolean => {
            const boolean = jsonBool(value) orelse return error.InvalidBoolean;
            return if (boolean) "true" else "false";
        },
        .integer => {
            const integer = jsonInteger(value) orelse return error.InvalidInteger;
            const number: f64 = @floatFromInt(integer);
            try validateRange(schema_field, number);
            return std.fmt.allocPrint(allocator, "{d}", .{integer});
        },
        .double => {
            const number = jsonNumber(value) orelse return error.InvalidNumber;
            try validateRange(schema_field, number);
            return std.fmt.allocPrint(allocator, "{d}", .{number});
        },
        .string => {
            const text = jsonString(value) orelse return error.InvalidString;
            return try jsonStringLiteral(allocator, text);
        },
        .string_list => return try encodeStringList(allocator, value),
        .select => {
            const raw_text = jsonString(value) orelse return error.InvalidSelection;
            const text = schema.normalizeLayout(raw_text);
            var valid = false;
            for (schema_field.options) |option_value| {
                if (std.mem.eql(u8, option_value, text)) {
                    valid = true;
                    break;
                }
            }
            if (!valid) return error.InvalidSelection;
            return try jsonStringLiteral(allocator, text);
        },
        .color => {
            const text = jsonString(value) orelse return error.InvalidColor;
            const color = parseTypedColor(text) orelse return error.InvalidColor;
            return std.fmt.allocPrint(allocator, "0x{X:0>8}", .{color});
        },
    }
}

fn encodeStringList(allocator: Allocator, value: Json) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.append(allocator, '[');
    var count: usize = 0;
    switch (value) {
        .array => |items| for (items.items) |item| {
            const text = jsonString(item) orelse return error.InvalidStringList;
            const trimmed = std.mem.trim(u8, text, " \t\r");
            if (trimmed.len == 0) continue;
            if (count > 0) try result.appendSlice(allocator, ", ");
            const encoded = try jsonStringLiteral(allocator, trimmed);
            try result.appendSlice(allocator, encoded);
            count += 1;
        },
        .string => |text| {
            var parts = std.mem.splitScalar(u8, text, ',');
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t\r");
                if (trimmed.len == 0) continue;
                if (count > 0) try result.appendSlice(allocator, ", ");
                const encoded = try jsonStringLiteral(allocator, trimmed);
                try result.appendSlice(allocator, encoded);
                count += 1;
            }
        },
        else => return error.InvalidStringList,
    }
    try result.append(allocator, ']');
    return result.toOwnedSlice(allocator);
}

fn validateRange(schema_field: *const schema.Field, value: f64) !void {
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    if (schema_field.min) |minimum| if (value < minimum) return error.ValueTooSmall;
    if (schema_field.max) |maximum| if (value > maximum) return error.ValueTooLarge;
}

fn validateKnownFields(files: *const config.ConfigFiles) !void {
    for (&schema.fields) |*schema_field| {
        const raw = (resolveFieldRaw(&files.items[@intFromEnum(schema_field.file)].document, schema_field) orelse continue).value;
        switch (schema_field.kind) {
            .boolean => if (!std.mem.eql(u8, raw, "true") and !std.mem.eql(u8, raw, "false")) return error.InvalidBoolean,
            .integer => {
                const value = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r"), 10) catch return error.InvalidInteger;
                try validateRange(schema_field, @floatFromInt(value));
            },
            .double => {
                const value = std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r")) catch return error.InvalidNumber;
                try validateRange(schema_field, value);
            },
            .select => {
                const text = schema.normalizeLayout(unquoteToml(raw));
                var valid = false;
                for (schema_field.options) |option_value| if (std.mem.eql(u8, text, option_value)) {
                    valid = true;
                    break;
                };
                if (!valid) return error.InvalidSelection;
            },
            .color => if (!validColor(std.mem.trim(u8, raw, " \t\r"))) return error.InvalidColor,
            .string => {},
            .string_list => {
                var buffer: [256]u8 = undefined;
                var sink: std.Io.Writer.Discarding = .init(&buffer);
                var json: std.json.Stringify = .{ .writer = &sink.writer };
                try writeStringList(&json, raw);
            },
        }
    }
}

const FieldRaw = struct {
    section: []const u8,
    value: []const u8,
};

fn resolveFieldRaw(document: *const config.Document, schema_field: *const schema.Field) ?FieldRaw {
    if (schema_field.section_aliases.len > 0) {
        const resolved = document.getRawAliases(schema_field.section, schema_field.section_aliases, schema_field.key) orelse return null;
        return .{ .section = resolved.section, .value = resolved.value };
    }
    const value = document.getRaw(schema_field.section, schema_field.key) orelse return null;
    return .{ .section = schema_field.section, .value = value };
}

fn setFieldRaw(document: *config.Document, schema_field: *const schema.Field, encoded: []const u8) !void {
    if (schema_field.section_aliases.len > 0) {
        return document.setRawAliases(schema_field.section, schema_field.section_aliases, schema_field.key, encoded);
    }
    return document.setRaw(schema_field.section, schema_field.key, encoded);
}

fn validateBasicToml(source: []const u8) !void {
    if (source.len > 1024 * 1024) return error.ConfigTooLarge;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, withoutComment(raw_line), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const ordinary = line.len >= 3 and line[line.len - 1] == ']' and line[1] != '[';
            const repeated = line.len >= 5 and std.mem.startsWith(u8, line, "[[") and std.mem.endsWith(u8, line, "]]");
            if (!ordinary and !repeated) return error.InvalidTableHeader;
            continue;
        }
        const equal = indexUnquoted(line, '=') orelse return error.InvalidAssignment;
        if (std.mem.trim(u8, line[0..equal], " \t").len == 0 or std.mem.trim(u8, line[equal + 1 ..], " \t").len == 0) return error.InvalidAssignment;
    }
}

fn replaceDocumentSource(document: *config.Document, source: []const u8) !void {
    const replacement = try document.allocator.dupe(u8, source);
    document.allocator.free(document.source);
    document.source = replacement;
}

fn retargetUserOverride(allocator: Allocator, file_item: *config.ConfigFiles.File, file_id: schema.FileId) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.toml", .{file_id.name()});
    const replacement = if (getenv("XDG_CONFIG_HOME")) |xdg|
        try std.fmt.allocPrint(allocator, "{s}/aqueous/{s}", .{ xdg, filename })
    else if (getenv("HOME")) |home|
        try std.fmt.allocPrint(allocator, "{s}/.config/aqueous/{s}", .{ home, filename })
    else
        return error.ConfigPathUnavailable;
    file_item.document.allocator.free(file_item.path);
    file_item.path = replacement;
}

fn backupOriginals(
    allocator: Allocator,
    backup_dir: []const u8,
    generation: []const u8,
    files: *const config.ConfigFiles,
    originals: [schema.file_count][]u8,
    dirty: [schema.file_count]bool,
) !void {
    for (dirty, 0..) |is_dirty, index| {
        if (!is_dirty) continue;
        const backup_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.toml", .{ backup_dir, generation, @as(schema.FileId, @enumFromInt(index)).name() });
        var document = try config.Document.init(allocator, originals[index]);
        defer document.deinit();
        try document.write(backup_path);
        _ = files;
    }
}

fn rollbackOriginals(allocator: Allocator, files: *const config.ConfigFiles, originals: [schema.file_count][]u8, dirty: [schema.file_count]bool) void {
    for (dirty, 0..) |is_dirty, index| {
        if (!is_dirty or std.mem.startsWith(u8, files.items[index].path, "/etc/xdg/")) continue;
        var document = config.Document.init(allocator, originals[index]) catch continue;
        defer document.deinit();
        document.write(files.items[index].path) catch {};
    }
}

fn generationText(files: *const config.ConfigFiles, buffer: *[16]u8) []const u8 {
    var state = std.hash.Wyhash.init(0x415155454f5553);
    for (files.items) |file_item| {
        state.update(file_item.path);
        state.update(&.{0});
        state.update(file_item.document.source);
        state.update(&.{0xff});
    }
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{state.final()}) catch unreachable;
}

fn jsonStringLiteral(allocator: Allocator, text: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

fn unquoteToml(raw_value: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn validColor(raw_value: []const u8) bool {
    return parseConfigColor(raw_value) != null;
}

fn parseConfigColor(raw_value: []const u8) ?u32 {
    var value = unquoteToml(raw_value);
    if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X")) value = value[2..];
    if (value.len != 8) return null;
    return std.fmt.parseInt(u32, value, 16) catch null;
}

fn parseTypedColor(raw_value: []const u8) ?u32 {
    const value = unquoteToml(raw_value);
    if (std.mem.startsWith(u8, value, "#")) {
        if (value.len != 7) return null;
        const rgb = std.fmt.parseInt(u32, value[1..], 16) catch return null;
        return 0xff000000 | rgb;
    }
    return parseConfigColor(value);
}

fn jsonString(value: ?Json) ?[]const u8 {
    const actual = value orelse return null;
    return if (actual == .string) actual.string else null;
}

fn jsonBool(value: Json) ?bool {
    return switch (value) {
        .bool => |boolean| boolean,
        .string => |text| if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else null,
        else => null,
    };
}

fn jsonInteger(value: ?Json) ?i64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |integer| integer,
        .float => |number| if (std.math.isFinite(number) and @floor(number) == number) @intFromFloat(number) else null,
        .number_string, .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn jsonNumber(value: Json) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |number| number,
        .number_string, .string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

fn pathExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
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
        if (quote == '"' and byte == '\\') {
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

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn writeError(writer: *std.Io.Writer, code: []const u8, message: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "ok", false);
    try field(&json, "protocol", schema.protocol_version);
    try field(&json, "code", code);
    try field(&json, "message", message);
    try json.endObject();
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ExternalChange => "external_change",
        error.SystemConfigReadOnly => "system_config_read_only",
        error.BackupDirRequired => "backup_dir_required",
        error.InvalidBoolean,
        error.InvalidInteger,
        error.InvalidNumber,
        error.InvalidString,
        error.InvalidStringList,
        error.InvalidSelection,
        error.InvalidColor,
        error.ValueTooSmall,
        error.ValueTooLarge,
        error.InvalidMonitorChanges,
        error.InvalidMonitorChange,
        error.MissingMonitorId,
        error.MissingMonitorName,
        error.InvalidMonitorName,
        error.InvalidMonitorPosition,
        error.InvalidMonitorTransform,
        error.InvalidMonitorMode,
        error.InvalidMonitorId,
        error.UnknownMonitor,
        error.InvalidCustomKeybindChanges,
        error.InvalidCustomKeybindChange,
        error.InvalidCustomKeybindId,
        error.InvalidCustomKeybindChord,
        error.InvalidCustomKeybindCommand,
        error.UnknownCustomKeybind,
        error.DuplicateCustomKeybind,
        error.InvalidSnapZoneChanges,
        error.InvalidSnapZoneChange,
        error.InvalidSnapZoneId,
        error.InvalidSnapZoneValue,
        error.InvalidSnapZoneOperation,
        error.InvalidWindowRuleChanges,
        error.InvalidWindowRuleChange,
        error.InvalidWindowRuleId,
        error.InvalidWindowRuleMove,
        error.InvalidWindowRuleValues,
        error.InvalidWindowRuleValue,
        error.InvalidWindowRuleKey,
        error.InvalidWindowRuleOperation,
        error.UnknownWindowRule,
        error.WindowRuleMissingMatcher,
        error.ConflictingRuleOperations,
        error.InvalidNormalizeRequest,
        error.ConflictingEdits,
        error.InvalidAssignment,
        error.InvalidTableHeader,
        error.ConfigTooLarge,
        error.EmptyFontFamily,
        error.FontFamilyTooLong,
        error.InvalidFontFamily,
        error.FontStyleTooLong,
        error.InvalidFontStyle,
        error.FontLookupFailed,
        error.FontFamilyNotInstalled,
        error.FontFaceNotInstalled,
        error.EmptyCursorTheme,
        error.CursorThemeTooLong,
        error.InvalidCursorTheme,
        error.CursorThemeNotInstalled,
        error.InvalidCursorSyncRequest,
        => "invalid_value",
        error.UnknownField => "unknown_field",
        error.UnknownFile => "unknown_file",
        error.UnsupportedProtocol => "unsupported_protocol",
        error.AccessDenied, error.PermissionDenied => "permission_denied",
        else => "helper_error",
    };
}

test "basic TOML validation respects quoted comments and equals" {
    try validateBasicToml(
        \\# keep
        \\[actions]
        \\screenshot = "grim -g \"$(slurp)\" - | wl-copy" # comment
        \\[[window]]
        \\title = "Dialog #1 = ready"
    );
    try std.testing.expectError(error.InvalidAssignment, validateBasicToml("[blur]\nenabled\n"));
}

test "schema ids are unique and defaults validate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (&schema.fields, 0..) |*left, index| {
        for (schema.fields[index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.id, right.id));
        }
        const json_value: Json = switch (left.kind) {
            .boolean => .{ .bool = std.mem.eql(u8, left.default_raw, "true") },
            .integer => .{ .integer = try std.fmt.parseInt(i64, left.default_raw, 10) },
            .double => .{ .float = try std.fmt.parseFloat(f64, left.default_raw) },
            .string, .select, .color => .{ .string = @constCast(left.default_raw) },
            .string_list => .{ .string = @constCast(left.default_raw) },
        };
        _ = try encodeTomlValue(arena.allocator(), left, json_value);
    }
}

test "typed colors serialize as canonical AARRGGBB" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const color_field = schema.find("layout.border_focused").?;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "0xFF88C0D0", .expected = "0xFF88C0D0" },
        .{ .input = "0x4088c0d0", .expected = "0x4088C0D0" },
        .{ .input = "00112233", .expected = "0x00112233" },
        .{ .input = "#112233", .expected = "0xFF112233" },
    };
    for (cases) |case| {
        const encoded = try encodeTomlValue(
            arena.allocator(),
            color_field,
            .{ .string = @constCast(case.input) },
        );
        try std.testing.expectEqualStrings(case.expected, encoded);
    }

    for ([_][]const u8{ "#12345", "#80112233", "0xGG112233", "0x112233" }) |invalid| {
        try std.testing.expectError(
            error.InvalidColor,
            encodeTomlValue(arena.allocator(), color_field, .{ .string = @constCast(invalid) }),
        );
    }
}

test "monitor modes retain fractional rates and reject invalid values" {
    for ([_][]const u8{ "1920x1080", "2560x1440@59.94", "3840x2160@143.999", "1920x1080@600" }) |mode| try std.testing.expect(validMonitorMode(mode));
    for ([_][]const u8{ "", "0x1080", "1920x-1", "100001x1080", "1920x1080@0", "1920x1080@nan", "1920x1080@inf", "1920x1080@1001", "1920x1080@60@75", "1920x1080\"\nfoo=1" }) |mode| try std.testing.expect(!validMonitorMode(mode));
}
