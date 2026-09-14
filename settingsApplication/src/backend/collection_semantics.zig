//! Ordered collection semantics, independent of the caller's mutation claims.
//! Ambiguous source is deliberately not a proof of non-display impact.
const std = @import("std");
const config = @import("config_document.zig");
const schema = @import("schema.zig");
const fields = @import("collection_schema.zig");
const native = @import("display_config");
const A = std.mem.Allocator;
const Json = std.json.Value;

pub const Kind = enum { none, rule, binding, layout, zone, legacy_zone };
pub fn kind(file: schema.FileId, table: config.Document.Table) Kind {
    if (file == .rules and std.mem.eql(u8, table.name, "window")) return .rule;
    if (file == .wm and std.mem.eql(u8, table.name, "keybinds.custom")) return .binding;
    if (file == .layout) {
        if (fields.parseSnapTablePath(table.name)) |path| return if (path.zone_id == null) .layout else .zone;
        inline for (.{ "layout.snap-zone.", "layout.snap_zone." }) |prefix| {
            if (std.mem.startsWith(u8, table.name, prefix)) {
                const id = table.name[prefix.len..];
                if (id.len == 1 and id[0] >= 'a' and id[0] <= 'd') return .legacy_zone;
            }
        }
    }
    return .none;
}

pub fn ownsEntry(file: schema.FileId, table: config.Document.Table, key: []const u8) bool {
    return kind(file, table) != .none or
        (file == .layout and std.mem.eql(u8, table.name, "layout") and std.mem.eql(u8, key, "snap_layout"));
}

const Property = struct { key: []const u8, value: Json };
const Record = struct { section: []const u8, properties: []Property };
pub const Comparison = struct { complete: bool, changed: bool };

pub fn compare(a: A, file: schema.FileId, before: *const config.Document, after: *const config.Document) !Comparison {
    const left = signature(a, file, before) catch |err| switch (err) {
        error.UnprovenSemantics => return .{ .complete = false, .changed = true },
        else => return err,
    };
    const right = signature(a, file, after) catch |err| switch (err) {
        error.UnprovenSemantics => return .{ .complete = false, .changed = true },
        else => return err,
    };
    return .{ .complete = true, .changed = !std.mem.eql(u8, left, right) };
}

// Called with a temporary arena. Include declarations even when empty and
// preserve order wherever the native parser processes assignments in sequence.
fn signature(a: A, file: schema.FileId, doc: *const config.Document) ![]const u8 {
    const tables = try doc.tables(a);
    const entries = try doc.entries(a);
    try validateNativeSyntax(file, doc.source, tables, entries);
    var records: std.ArrayList(Record) = .empty;
    var layouts: std.StringHashMap(void) = .init(a);
    var zones: std.StringHashMap(usize) = .init(a);
    var named_tables: std.StringHashMap(void) = .init(a);
    var default_layout: ?[]const u8 = null;
    var binding_count: usize = 0;
    for (tables) |table| {
        const k = kind(file, table);
        if (k == .none and collectionNamespace(file, table.name)) return error.UnprovenSemantics;
        var properties: std.ArrayList(Property) = .empty;
        var matcher = false;
        for (entries) |entry| {
            if (entry.table_index != table.index or !ownsEntry(file, table, entry.key)) continue;
            for (properties.items) |property| if (std.mem.eql(u8, property.key, entry.key)) return error.UnprovenSemantics;
            const value: Json = switch (k) {
                .rule => blk: {
                    if (!fields.ruleKnown(entry.key)) return error.UnprovenSemantics;
                    fields.validateRuleRaw(entry.key, entry.value) catch return error.UnprovenSemantics;
                    if (fields.ruleBoolean(entry.key)) break :blk .{ .bool = std.mem.eql(u8, entry.value, "true") };
                    if (fields.ruleInteger(entry.key)) break :blk .{ .integer = std.fmt.parseInt(i64, entry.value, 10) catch return error.UnprovenSemantics };
                    if (fields.ruleDouble(entry.key)) break :blk try number(entry.value);
                    var text = try string(a, entry.value);
                    if (std.mem.eql(u8, entry.key, "tag")) {
                        // The native rule parser decodes only double-quoted tags.
                        if (entry.value[0] == '"') text = try std.json.parseFromSliceLeaky([]const u8, a, entry.value, .{});
                    }
                    if (std.mem.eql(u8, entry.key, "layout")) text = schema.normalizeLayout(text);
                    inline for (.{ "app_id", "class", "title", "content_type", "tag" }) |key| {
                        if (std.mem.eql(u8, entry.key, key) and (text.len != 0 or std.mem.eql(u8, key, "tag"))) matcher = true;
                    }
                    break :blk .{ .string = text };
                },
                .binding => blk: {
                    const raw_command = try string(a, entry.value);
                    const buffer = try a.alloc(u8, 256);
                    const command = native.decodeBindingCommand(raw_command, buffer) orelse return error.UnprovenSemantics;
                    const chord = native.collection_actions.parseChord(entry.key) orelse return error.UnprovenSemantics;
                    // The compositor stores verbs in wm.Text (256 bytes).
                    if (entry.key.len > 128 or command.len > 256 or command.len == 0) return error.UnprovenSemantics;
                    const colon = std.mem.indexOfScalar(u8, command, ':') orelse return error.UnprovenSemantics;
                    const prefix = command[0..colon];
                    const argument = command[colon + 1 ..];
                    if (std.mem.trim(u8, argument, " \t").len == 0) return error.UnprovenSemantics;
                    if (!std.mem.eql(u8, prefix, "spawn") and !std.mem.eql(u8, prefix, "launch") and
                        !std.mem.eql(u8, prefix, "set_layout") and !std.mem.eql(u8, prefix, "builtin")) return error.UnprovenSemantics;
                    if (std.mem.eql(u8, prefix, "set_layout")) {
                        const layout = schema.normalizeLayout(std.mem.trim(u8, argument, " \t"));
                        var known = false;
                        for (schema.find("layout.slots.primary").?.options) |option| if (std.mem.eql(u8, layout, option)) {
                            known = true;
                        };
                        if (!known) return error.UnprovenSemantics;
                    }
                    if (std.mem.eql(u8, prefix, "builtin")) {
                        const builtin = std.mem.trim(u8, argument, " \t");
                        const name = builtin[0 .. std.mem.indexOfScalar(u8, builtin, ':') orelse builtin.len];
                        var known = false;
                        for (schema.fields) |field| if (field.category == .keybinds and std.mem.eql(u8, field.key, name)) {
                            known = true;
                        };
                        // Native parameterized actions not exposed as scalar bindings.
                        inline for (.{ "snap_zone", "set_snap_layout", "focus_composable", "move_to_composable" }) |name_with_argument|
                            if (std.mem.eql(u8, name, name_with_argument) and builtin.len > name.len + 1) {
                                known = true;
                            };
                        if (!known) return error.UnprovenSemantics;
                    }
                    if (chord.wheel != null and std.mem.eql(u8, command, "builtin:untrap_pointer")) return error.UnprovenSemantics;
                    binding_count += 1;
                    if (binding_count > native.collection_actions.max_bindings) return error.UnprovenSemantics;
                    // Arguments remain opaque command bytes, never split on commas,
                    // spaces or colons and never executed during classification.
                    break :blk .{ .string = command };
                },
                .layout, .zone, .legacy_zone => blk: {
                    if (std.mem.eql(u8, entry.key, "name") and k != .legacy_zone) {
                        const text = try string(a, entry.value);
                        // The layout parser currently strips # without quote awareness.
                        if (text.len > 64 or std.mem.indexOfScalar(u8, text, '#') != null) return error.UnprovenSemantics;
                        break :blk .{ .string = text };
                    }
                    if (k == .layout) {
                        if (!std.mem.eql(u8, entry.key, "padding")) return error.UnprovenSemantics;
                        const padding = std.fmt.parseInt(i64, entry.value, 10) catch return error.UnprovenSemantics;
                        if (padding < 0 or padding > 512) return error.UnprovenSemantics;
                        break :blk .{ .integer = padding };
                    }
                    if (!std.mem.eql(u8, entry.key, "x") and !std.mem.eql(u8, entry.key, "y") and
                        !std.mem.eql(u8, entry.key, "width") and !std.mem.eql(u8, entry.key, "height")) return error.UnprovenSemantics;
                    break :blk try number(entry.value);
                },
                .none => blk: {
                    if (table.repeated or default_layout != null) return error.UnprovenSemantics;
                    default_layout = try string(a, entry.value);
                    break :blk .{ .string = default_layout.? };
                },
            };
            try properties.append(a, .{ .key = entry.key, .value = value });
        }
        if (k == .none and properties.items.len == 0) continue;
        if (table.repeated != (k == .rule)) return error.UnprovenSemantics;
        if (k == .rule and !matcher) return error.UnprovenSemantics;
        if (k == .zone or k == .legacy_zone) {
            if (!fields.validSnapZone(propertyNumber(properties.items, "x"), propertyNumber(properties.items, "y"), propertyNumber(properties.items, "width"), propertyNumber(properties.items, "height"))) return error.UnprovenSemantics;
        }
        var section = table.name;
        if (fields.parseSnapTablePath(table.name)) |path| {
            section = if (path.zone_id) |zone|
                try std.fmt.allocPrint(a, "layout.snap-layout.{s}.zone.{s}", .{ path.layout_id, zone })
            else
                try std.fmt.allocPrint(a, "layout.snap-layout.{s}", .{path.layout_id});
            if (named_tables.contains(section)) return error.UnprovenSemantics;
            try named_tables.put(section, {});
            try layouts.put(path.layout_id, {});
            if (layouts.count() > native.collection_layout.max_snap_layouts) return error.UnprovenSemantics;
            if (path.zone_id != null) {
                const count = try zones.getOrPut(path.layout_id);
                if (!count.found_existing) count.value_ptr.* = 0;
                count.value_ptr.* += 1;
                if (count.value_ptr.* > native.collection_layout.max_snap_zones) return error.UnprovenSemantics;
            }
        }
        // Binding aliases can resolve to the same chord. Rule layout=stacking
        // also sets floating, so a later floating=false can override it.
        if (k != .binding and k != .rule) std.mem.sort(Property, properties.items, {}, struct {
            fn less(_: void, left: Property, right: Property) bool {
                return std.mem.lessThan(u8, left.key, right.key);
            }
        }.less);
        try records.append(a, .{ .section = section, .properties = properties.items });
    }
    if (default_layout) |id| if (id.len != 0 and !layouts.contains(id)) return error.UnprovenSemantics;
    return std.json.Stringify.valueAlloc(a, records.items, .{});
}

fn collectionNamespace(file: schema.FileId, name: []const u8) bool {
    if (file == .rules) return std.mem.startsWith(u8, name, "window.");
    if (file == .wm) return std.mem.startsWith(u8, name, "keybinds.custom.");
    if (file == .layout) inline for (.{ "layout.snap-layout", "layout.snap_layout", "layout.snap-zone", "layout.snap_zone" }) |prefix| {
        if (std.mem.eql(u8, name, prefix) or std.mem.startsWith(u8, name, prefix ++ ".")) return true;
    };
    return false;
}

// Document accepts some spellings the runtime parsers do not (e.g. [[ window ]]
// and quoted rule keys). They cannot participate in a semantic equality proof.
fn validateNativeSyntax(file: schema.FileId, source: []const u8, tables: []const config.Document.Table, entries: []const config.Document.Entry) !void {
    var table_index: usize = 0;
    var entry_index: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = native.collection_toml.cleanLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            table_index += 1;
            if (table_index >= tables.len) return error.UnprovenSemantics;
            switch (kind(file, tables[table_index])) {
                .rule => if (!std.mem.eql(u8, line, "[[window]]")) return error.UnprovenSemantics,
                .binding => if (!std.mem.eql(u8, line, "[keybinds.custom]")) return error.UnprovenSemantics,
                else => {},
            }
            continue;
        }
        if (entry_index >= entries.len) return error.UnprovenSemantics;
        const entry = entries[entry_index];
        entry_index += 1;
        if (!ownsEntry(file, tables[table_index], entry.key)) continue;
        const equal = native.collection_toml.indexUnquoted(line, '=') orelse return error.UnprovenSemantics;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        if (file != .wm and !std.mem.eql(u8, key, entry.key)) return error.UnprovenSemantics;
    }
}

fn propertyNumber(properties: []const Property, key: []const u8) ?f64 {
    for (properties) |property| if (std.mem.eql(u8, property.key, key)) return property.value.float;
    return null;
}

fn number(raw: []const u8) !Json {
    const value = fields.parseFinite(raw) orelse return error.UnprovenSemantics;
    return .{ .float = value };
}

// Validate the single-line envelope; callers apply the native tag/binding
// escape rules separately. Other matchers retain the literal inner bytes.
fn string(a: A, raw: []const u8) ![]const u8 {
    if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'') or raw[raw.len - 1] != raw[0]) return error.UnprovenSemantics;
    var escaped = false;
    for (raw[1 .. raw.len - 1]) |ch| {
        if (ch < 0x20) return error.UnprovenSemantics;
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and raw[0] == '"') {
            escaped = true;
            continue;
        }
        if (ch == raw[0]) return error.UnprovenSemantics;
    }
    if (escaped) return error.UnprovenSemantics;
    if (raw[0] == '"') _ = std.json.parseFromSliceLeaky([]const u8, a, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.UnprovenSemantics,
    };
    return raw[1 .. raw.len - 1];
}
