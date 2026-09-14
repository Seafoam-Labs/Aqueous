//! Parsed candidate classification. Unknown semantics are never save-only.
const std = @import("std");
const config = @import("config_document.zig");
const schema = @import("schema.zig");
const review = @import("candidate_review.zig");
const display = @import("display_config");
const A = std.mem.Allocator;
const Change = struct { file: []const u8, section: []const u8, declaration: usize, key: []const u8 };
pub fn prepare(a: A, files: *const config.ConfigFiles, originals: [6][]u8, generation: []const u8, digest: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var changes: std.ArrayList(Change) = .empty;
    var unknown = false;
    var display_change = false;
    var runtime = false;
    var changed_files: std.ArrayList([]const u8) = .empty;
    for (files.items, 0..) |file, index| {
        if (std.mem.eql(u8, originals[index], file.document.source)) continue;
        try changed_files.append(temp, @as(schema.FileId, @enumFromInt(index)).name());
        if (try review.triviaOnly(temp, originals[index], file.document.source)) continue;
        // These parsers do not share a full multiline TOML AST. Preserve such
        // input and report uncertainty instead of scanning inside its strings.
        if (std.mem.indexOf(u8, originals[index], "\"\"\"") != null or std.mem.indexOf(u8, file.document.source, "\"\"\"") != null or
            std.mem.indexOf(u8, originals[index], "'''") != null or std.mem.indexOf(u8, file.document.source, "'''") != null)
        {
            unknown = true;
            continue;
        }
        if (index == 3) {
            const before_display = display.config.parse(originals[index]);
            const after_display = display.config.parse(file.document.source);
            if (before_display.unknown_fields == 0 and after_display.unknown_fields == 0 and
                before_display.rejected_declarations == 0 and after_display.rejected_declarations == 0)
            {
                var left: std.Io.Writer.Allocating = .init(temp);
                var right: std.Io.Writer.Allocating = .init(temp);
                var lj: std.json.Stringify = .{ .writer = &left.writer };
                var rj: std.json.Stringify = .{ .writer = &right.writer };
                try display.writeSource(&lj, &before_display);
                try display.writeSource(&rj, &after_display);
                // Only recognized display tables can use this equality proof.
                var doc = try config.Document.init(temp, file.document.source);
                const tables = try doc.tables(temp);
                var known = true;
                for (tables) |table| if (table.index != 0 and !std.mem.eql(u8, table.name, "output") and !std.mem.eql(u8, table.name, "display") and !std.mem.eql(u8, table.name, "display.profile") and !std.mem.eql(u8, table.name, "display.profile.output")) {
                    known = false;
                };
                const entries = try doc.entries(temp);
                for (entries) |entry| if (entry.table_index == 0) {
                    known = false;
                };
                var old_doc = try config.Document.init(temp, originals[index]);
                const old_tables = try old_doc.tables(temp);
                const old_entries = try old_doc.entries(temp);
                for (old_tables) |table| if (table.index != 0 and !std.mem.eql(u8, table.name, "output") and !std.mem.eql(u8, table.name, "display") and !std.mem.eql(u8, table.name, "display.profile") and !std.mem.eql(u8, table.name, "display.profile.output")) {
                    known = false;
                };
                for (old_entries) |entry| if (entry.table_index == 0) {
                    known = false;
                };
                if (known and std.mem.eql(u8, left.written(), right.written())) continue;
            }
        }
        var before = try config.Document.init(temp, originals[index]);
        const before_tables = try before.tables(temp);
        const after_tables = try file.document.tables(temp);
        const before_entries = try before.entries(temp);
        const after_entries = try file.document.entries(temp);
        const file_id: schema.FileId = @enumFromInt(index);
        for ([_][]const config.Document.Entry{ before_entries, after_entries }, 0..) |entries, direction| {
            const tables = if (direction == 0) before_tables else after_tables;
            const other_entries = if (direction == 0) after_entries else before_entries;
            const other_tables = if (direction == 0) after_tables else before_tables;
            for (entries) |entry| {
                const table = tables[entry.table_index];
                const same = for (other_entries) |other| {
                    if (other.table_index != entry.table_index or !std.mem.eql(u8, other.key, entry.key) or
                        !std.mem.eql(u8, table.name, other_tables[other.table_index].name)) continue;
                    if (std.mem.eql(u8, entry.value, other.value)) break true;
                } else false;
                if (same) continue;
                try changes.append(temp, .{ .file = file_id.name(), .section = table.name, .declaration = table.index, .key = entry.key });
                if ((file_id == .wm or file_id == .outputs) and (std.mem.eql(u8, table.name, "output") or std.mem.startsWith(u8, table.name, "display"))) {
                    if ((std.mem.eql(u8, table.name, "output") or std.mem.eql(u8, table.name, "display.profile.output")) and display.config.knownSpecKey(entry.key)) display_change = true else if (std.mem.eql(u8, table.name, "display") and display.config.knownPolicyKey(entry.key)) display_change = true else if (std.mem.eql(u8, table.name, "display.profile") and std.mem.eql(u8, entry.key, "name")) display_change = true else unknown = true;
                } else {
                    const known = for (schema.fields) |field| {
                        if (field.file == file_id and std.mem.eql(u8, field.section, table.name) and std.mem.eql(u8, field.key, entry.key)) break true;
                    } else false;
                    if (known) runtime = true else unknown = true;
                }
            }
        }
        // Empty declarations also have semantics; don't lose their ordering.
        if (before_tables.len != after_tables.len and changes.items.len == 0) unknown = true;
    }
    var native: ?std.json.Value = null;
    var effects: std.ArrayList([]const u8) = .empty;
    if (runtime) try effects.append(temp, "runtime_non_display");
    if (display_change) {
        var client = display.ipc.Client.open(temp) catch null;
        if (client) |*c| {
            defer c.close();
            const bytes = c.call(temp, "display.candidate", .{ .expected_generation = generation, .wm_source = files.items[0].document.source, .outputs_source = files.items[3].document.source }) catch null;
            if (bytes) |value| {
                native = try std.json.parseFromSliceLeaky(std.json.Value, temp, value, .{});
                const projection = native.?.object;
                if (projection.get("complete")) |complete| {
                    if (complete == .bool and complete.bool) {
                        for (projection.get("effects").?.array.items) |effect| try effects.append(temp, effect.string);
                    } else unknown = true;
                } else unknown = true;
            } else unknown = true;
        } else unknown = true;
    }
    if (unknown) try effects.append(temp, "unknown");
    if (effects.items.len == 0) try effects.append(temp, "none");
    return std.json.Stringify.valueAlloc(a, .{
        .version = 1,
        .original_generation = generation,
        .candidate_digest = digest,
        .changed_files = changed_files.items,
        .changed_fields = changes.items,
        .effects = effects.items,
        .complete = !unknown,
        .display = native,
        .reason = if (unknown) @as(?[]const u8, "unproven_semantics_or_live_projection_unavailable") else null,
    }, .{});
}
