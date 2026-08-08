const std = @import("std");
const config = @import("aqueous_config_document");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const max_request_bytes = 4 * 1024 * 1024;

const Command = enum { version, snapshot, validate, apply, raw };

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const args = try init.args.toSlice(allocator);

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    var exit_code: u8 = 0;
    run(allocator, args, &response.writer) catch |err| {
        response.clearRetainingCapacity();
        writeError(&response.writer, errorCode(err), @errorName(err)) catch {};
        exit_code = 1;
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(response.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: Allocator, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len < 2) return error.MissingCommand;
    const command = parseCommand(args[1]) orelse return error.UnknownCommand;
    switch (command) {
        .version => try writeVersion(writer),
        .snapshot => {
            var files = try config.ConfigFiles.init(allocator);
            defer files.deinit();
            try writeSnapshot(writer, &files);
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
            try handleRequest(allocator, writer, request_path, command == .apply);
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
    try json.endObject();
}

fn writeSnapshot(writer: *std.Io.Writer, files: *const config.ConfigFiles) !void {
    var generation_buffer: [16]u8 = undefined;
    const generation = generationText(files, &generation_buffer);
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "ok", true);
    try field(&json, "protocol", schema.protocol_version);
    try field(&json, "helper_version", schema.helper_version);
    try field(&json, "generation", generation);

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

    try json.objectField("custom_keybinds");
    try writeCustomKeybinds(&json, &files.items[@intFromEnum(schema.FileId.wm)].document);

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
    var configured_raw = file_item.document.getRaw(schema_field.section, schema_field.key);
    var inherited = false;
    if (configured_raw == null and schema_field.file == .outputs) {
        configured_raw = files.items[@intFromEnum(schema.FileId.wm)].document.getRaw(schema_field.section, schema_field.key);
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
        .string, .select => try json.write(unquoteToml(raw)),
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

fn handleRequest(allocator: Allocator, writer: *std.Io.Writer, request_path: []const u8, do_apply: bool) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, request_path, allocator, .limited(max_request_bytes));
    var parsed = try std.json.parseFromSlice(Json, allocator, source, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const request = parsed.value.object;
    const protocol = jsonInteger(request.get("protocol")) orelse return error.MissingProtocol;
    if (protocol != schema.protocol_version) return error.UnsupportedProtocol;
    const expected = jsonString(request.get("expected_generation")) orelse return error.MissingGeneration;

    var files = try config.ConfigFiles.init(allocator);
    defer files.deinit();
    var generation_buffer: [16]u8 = undefined;
    if (!std.mem.eql(u8, expected, generationText(&files, &generation_buffer))) return error.ExternalChange;

    var originals: [5][]u8 = undefined;
    for (files.items, 0..) |file_item, index| originals[index] = try allocator.dupe(u8, file_item.document.source);
    defer for (originals) |original| allocator.free(original);

    var dirty = [_]bool{false} ** 5;
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
                try files.items[@intFromEnum(schema_field.file)].document.setRaw(schema_field.section, schema_field.key, encoded);
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

    if (do_apply and changed_count > 0) {
        if (changed_count > 1) {
            const backup_dir = jsonString(request.get("backup_dir")) orelse return error.BackupDirRequired;
            try backupOriginals(allocator, backup_dir, expected, &files, originals, dirty);
        }
        for (&files.items, 0..) |*file_item, index| file_item.dirty = dirty[index];
        files.save() catch |save_error| {
            rollbackOriginals(allocator, &files, originals, dirty);
            return save_error;
        };
    }

    try writeSnapshot(writer, &files);
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
        inline for (.{ "enabled", "mode", "scale", "transform", "position", "adaptive_sync", "hdr", "hdr_level", "sdr_white_level", "primary" }) |key| {
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

const CustomKeybindChange = struct {
    entry_index: usize,
    table_index: usize,
    old_chord: []const u8,
    chord: []const u8,
    command: []const u8,
};

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
    for (requested) |raw_change| {
        if (raw_change != .object) return error.InvalidCustomKeybindChange;
        const id = jsonString(raw_change.object.get("id")) orelse return error.InvalidCustomKeybindChange;
        if (!std.mem.startsWith(u8, id, "custom:")) return error.InvalidCustomKeybindId;
        const entry_index = std.fmt.parseInt(usize, id["custom:".len..], 10) catch return error.InvalidCustomKeybindId;
        const chord = jsonString(raw_change.object.get("chord")) orelse return error.InvalidCustomKeybindChord;
        const command = jsonString(raw_change.object.get("command")) orelse return error.InvalidCustomKeybindCommand;
        if (chord.len == 0 or chord.len > 128 or command.len == 0 or command.len > 1024) {
            return error.InvalidCustomKeybindChange;
        }
        var found: ?config.Document.Entry = null;
        for (entries) |entry| if (entry.index == entry_index) {
            found = entry;
            break;
        };
        const entry = found orelse return error.UnknownCustomKeybind;
        if (entry.table_index >= tables.len or
            !std.mem.eql(u8, tables[entry.table_index].name, "keybinds.custom"))
            return error.UnknownCustomKeybind;
        for (entries) |other| {
            if (other.index != entry.index and other.table_index == entry.table_index and
                std.mem.eql(u8, other.key, chord)) return error.DuplicateCustomKeybind;
        }
        try changes.append(allocator, .{
            .entry_index = entry_index,
            .table_index = entry.table_index,
            .old_chord = try allocator.dupe(u8, entry.key),
            .chord = chord,
            .command = command,
        });
    }
    std.mem.sort(CustomKeybindChange, changes.items, {}, struct {
        fn lessThan(_: void, left: CustomKeybindChange, right: CustomKeybindChange) bool {
            return left.entry_index > right.entry_index;
        }
    }.lessThan);
    for (changes.items) |change| {
        const encoded_command = try jsonStringLiteral(allocator, change.command);
        if (std.mem.eql(u8, change.old_chord, change.chord)) {
            try document.setEntryRaw(change.entry_index, encoded_command);
        } else {
            try document.deleteEntry(change.entry_index);
            const encoded_chord = try jsonStringLiteral(allocator, change.chord);
            try document.addToTable(change.table_index, encoded_chord, encoded_command);
        }
    }
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
            const text = jsonString(value) orelse return error.InvalidSelection;
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
            if (!validColor(text)) return error.InvalidColor;
            return allocator.dupe(u8, text);
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
        const raw = files.items[@intFromEnum(schema_field.file)].document.getRaw(schema_field.section, schema_field.key) orelse continue;
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
                const text = unquoteToml(raw);
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
    originals: [5][]u8,
    dirty: [5]bool,
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

fn rollbackOriginals(allocator: Allocator, files: *const config.ConfigFiles, originals: [5][]u8, dirty: [5]bool) void {
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
    var value = unquoteToml(raw_value);
    if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X")) value = value[2..];
    if (value.len != 8) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
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
        error.InvalidMonitorId,
        error.UnknownMonitor,
        error.InvalidCustomKeybindChanges,
        error.InvalidCustomKeybindChange,
        error.InvalidCustomKeybindId,
        error.InvalidCustomKeybindChord,
        error.InvalidCustomKeybindCommand,
        error.UnknownCustomKeybind,
        error.DuplicateCustomKeybind,
        error.ConflictingEdits,
        error.InvalidAssignment,
        error.InvalidTableHeader,
        error.ConfigTooLarge,
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
