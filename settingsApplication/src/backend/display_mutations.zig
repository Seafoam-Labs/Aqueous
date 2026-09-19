//! Generation/source-bound declaration edits. Only the helper edits TOML;
//! native candidate classification and preview leases still authorize display saves.
const std = @import("std");
const cfg = @import("config_document.zig");
const schema = @import("schema.zig");
const native = @import("display_config");
const source_tx = @import("collection_transaction.zig");
const review = @import("candidate_review.zig");
const A = std.mem.Allocator;
const Json = std.json.Value;
const Kind = enum { other, policy, output, profile, member };

fn kind(table: cfg.Document.Table) Kind {
    if (std.mem.eql(u8, table.name, "display") and !table.repeated) return .policy;
    if (!table.repeated) return .other;
    if (std.mem.eql(u8, table.name, "output")) return .output;
    if (std.mem.eql(u8, table.name, "display.profile")) return .profile;
    if (std.mem.eql(u8, table.name, "display.profile.output")) return .member;
    return .other;
}
fn header(k: Kind) []const u8 {
    return switch (k) {
        .policy => "[display]",
        .output => "[[output]]",
        .profile => "[[display.profile]]",
        .member => "[[display.profile.output]]",
        .other => unreachable,
    };
}
fn text(v: Json) ![]const u8 {
    return if (v == .string) v.string else error.InvalidDisplayMutation;
}
fn get(o: std.json.ObjectMap, key: []const u8) !Json {
    return o.get(key) orelse error.InvalidDisplayMutation;
}
fn keys(o: std.json.ObjectMap, allowed: []const []const u8) !void {
    for (o.keys()) |key| {
        for (allowed) |allow| {
            if (std.mem.eql(u8, key, allow)) break;
        } else return error.InvalidDisplayMutation;
    }
}
fn source(value: Json) !schema.FileId {
    const id = schema.FileId.fromName(try text(value)) orelse return error.InvalidDisplayMutation;
    return if (id == .wm or id == .outputs) id else error.InvalidDisplayMutation;
}

pub fn identity(a: A, files: *const cfg.ConfigFiles, id: schema.FileId, table: usize) ![]const u8 {
    const file = &files.items[@intFromEnum(id)];
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const generation = native.document.generation(files);
    const present = [_]u8{@intFromBool(try source_tx.exists(file.path))};
    var ordinal: [8]u8 = undefined;
    std.mem.writeInt(u64, &ordinal, table, .big);
    for ([_][]const u8{ "aqueous-display-declaration-v1", &generation, id.name(), file.path, &present, file.document.source, &ordinal }) |part| {
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, part.len, .big);
        hash.update(&size);
        hash.update(part);
    }
    const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.fmt.allocPrint(a, "display-v1:{s}", .{digest});
}

pub fn writeIdentity(json: *std.json.Stringify, files: *const cfg.ConfigFiles, id: schema.FileId, table: cfg.Document.Table, parent: ?usize) !void {
    const a = files.allocator;
    const value = try identity(a, files, id, table.index);
    defer a.free(value);
    try native.field(json, "id", value);
    try native.field(json, "kind", @tagName(kind(table)));
    try json.objectField("parent_id");
    if (parent) |p| {
        const parent_id = try identity(a, files, id, p);
        defer a.free(parent_id);
        try json.write(parent_id);
    } else try json.write(null);
}

// Preflight before any raw or other structured edits can shift table indices.
pub fn preflight(request: std.json.ObjectMap) !?[schema.file_count]bool {
    const changes = request.get("display_declaration_changes") orelse return null;
    try keys(request, &.{ "protocol", "expected_generation", "protected_apply", "display_declaration_changes", "candidate_digest", "preview_token", "expected_display_revision", "expected_session", "backup_dir", "create_user_override", "raw_files", "changes", "custom_keybind_changes", "window_rule_changes", "snap_layouts", "snap_zone_changes", "default_snap_layout", "normalize_stacking", "sync_cursor", "sync_typography", "monitor_changes", "collection_preconditions", "collection_preconditions_v2", "collection_apply_version" });
    if (changes != .object) return error.InvalidDisplayMutation;
    try keys(changes.object, &.{ "version", "sources", "operations" });
    const version = try get(changes.object, "version");
    if (version != .integer or version.integer != 1) return error.InvalidDisplayMutation;
    const protected = try get(request, "protected_apply");
    if (protected != .bool or !protected.bool) return error.InvalidDisplayMutation;
    if (request.get("candidate_digest")) |digest| {
        try source_tx.checkCandidateDigest(request, if (digest == .string) digest.string else "");
    }
    for ([_][]const u8{ "create_user_override", "sync_cursor", "sync_typography", "normalize_stacking" }) |key| {
        if (request.get(key)) |v| if (v != .bool) return error.InvalidDisplayMutation;
    }
    for ([_][]const u8{ "preview_token", "expected_display_revision", "expected_session", "backup_dir" }) |key| {
        if (request.get(key)) |v| if (v != .string) return error.InvalidDisplayMutation;
    }
    if (request.contains("collection_preconditions") or request.contains("collection_preconditions_v2") or request.contains("collection_apply_version")) return error.ConflictingDisplayEdits;
    const operations = try get(changes.object, "operations");
    if (operations != .array or operations.array.items.len == 0 or operations.array.items.len > 256) return error.InvalidDisplayMutation;
    var touched = [_]bool{false} ** schema.file_count;
    for (operations.array.items) |op| {
        if (op != .object) return error.InvalidDisplayMutation;
        touched[@intFromEnum(try source(try get(op.object, "source")))] = true;
    }
    const sources = try get(changes.object, "sources");
    if (sources != .object) return error.InvalidDisplayMutation;
    var source_count: usize = 0;
    for ([_]schema.FileId{ .wm, .outputs }) |id| if (touched[@intFromEnum(id)]) {
        source_count += 1;
        _ = try text(try get(sources.object, id.name()));
    };
    if (sources.object.count() != source_count) return error.InvalidDisplayMutation;
    if (request.get("raw_files")) |raw| {
        if (raw != .object) return error.InvalidRawFiles;
        for (raw.object.keys()) |name| if (schema.FileId.fromName(name)) |id| {
            if (touched[@intFromEnum(id)]) return error.ConflictingDisplayEdits;
        };
    }
    if (request.contains("monitor_changes")) return error.ConflictingDisplayEdits;
    if (touched[0] and request.contains("custom_keybind_changes")) return error.ConflictingDisplayEdits;
    if (request.get("changes")) |changes_list| {
        if (changes_list == .array) for (changes_list.array.items) |change| {
            if (change != .object) return error.InvalidChange;
            const field = schema.find(try text(try get(change.object, "id"))) orelse return error.UnknownField;
            if (touched[@intFromEnum(field.file)]) return error.ConflictingDisplayEdits;
        };
    }
    return touched;
}

const Node = struct {
    id: []const u8,
    local_ref: ?[]const u8 = null,
    source: schema.FileId,
    kind: Kind,
    parent: ?*Node = null,
    doc: cfg.Document,
    used: bool = false,
    deleted: bool = false,
};
const Batch = struct {
    a: A,
    nodes: std.ArrayList(*Node) = .empty,
    // Includes deleted nodes, so references cannot alias a later insertion.
    all: std.ArrayList(*Node) = .empty,

    fn resolve(self: *Batch, value: Json, id: schema.FileId) !*Node {
        const wanted = try text(value);
        if (!std.mem.startsWith(u8, wanted, "new:") and
            (wanted.len != 75 or !std.mem.startsWith(u8, wanted, "display-v1:"))) return error.InvalidDisplayId;
        for (self.all.items) |node| {
            const matches = std.mem.eql(u8, wanted, node.id) or (if (node.local_ref) |ref| std.mem.eql(u8, wanted, ref) else false);
            if (matches) {
                if (node.source != id or node.kind == .other) return error.InvalidDisplayId;
                if (node.deleted) return error.ConflictingDisplayEdits;
                return node;
            }
        }
        return error.InvalidDisplayId;
    }
    fn parent(self: *Batch, value: Json, id: schema.FileId) !?*Node {
        if (value == .null) return null;
        const p = try self.resolve(value, id);
        if (p.kind != .profile) return error.InvalidDisplayId;
        return p;
    }
    fn index(self: *Batch, node: *Node) usize {
        for (self.nodes.items, 0..) |n, i| if (n == node) return i;
        unreachable;
    }
    fn end(self: *Batch, node: *Node) usize {
        var i = self.index(node) + 1;
        if (node.kind == .profile) while (i < self.nodes.items.len and self.nodes.items[i].parent == node) : (i += 1) {};
        return i;
    }
    fn relocate(self: *Batch, node: *Node, parent_node: ?*Node, before: ?*Node) !void {
        if (node.kind != .profile and node.kind != .output and node.kind != .member) return error.InvalidDisplayMutation;
        if (node.kind == .profile and parent_node != null) return error.InvalidDisplayMutation;
        if (before) |b| {
            if (b == node or b.source != node.source or b.parent != parent_node or
                (if (node.kind == .profile) b.kind != .profile else b.kind != .output and b.kind != .member)) return error.InvalidDisplayMutation;
        }
        const first = self.index(node);
        const last = self.end(node);
        const moving = try self.a.dupe(*Node, self.nodes.items[first..last]);
        for (first..last) |_| _ = self.nodes.orderedRemove(first);
        if (node.kind == .output or node.kind == .member) {
            const new_kind: Kind = if (parent_node == null) .output else .member;
            if (new_kind != node.kind) {
                const newline = std.mem.indexOfScalar(u8, node.doc.source, '\n') orelse node.doc.source.len;
                // Header spelling changes, but retain its inline comment.
                const comment = std.mem.indexOfScalar(u8, node.doc.source[0..newline], '#');
                const suffix = if (comment) |c| node.doc.source[c..] else node.doc.source[newline..];
                node.doc = try cfg.Document.init(self.a, try std.fmt.allocPrint(self.a, "{s}{s}{s}", .{ header(new_kind), if (comment != null) " " else "", suffix }));
                node.kind = new_kind;
            }
            node.parent = parent_node;
        }
        const insertion = if (before) |b| self.index(b) else if (parent_node) |p| self.end(p) else self.nodes.items.len;
        try self.nodes.insertSlice(self.a, insertion, moving);
    }
    fn remove(self: *Batch, node: *Node) !void {
        if (node.used) return error.ConflictingDisplayEdits;
        node.deleted = true;
        _ = self.nodes.orderedRemove(self.index(node));
    }
};

pub fn apply(a: A, files: *cfg.ConfigFiles, request: std.json.ObjectMap, touched: [schema.file_count]bool) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var batch: Batch = .{ .a = temp };
    for ([_]schema.FileId{ .wm, .outputs }) |id| {
        if (!touched[@intFromEnum(id)]) continue;
        const file = &files.items[@intFromEnum(id)];
        // Bind creation as well as existing IDs: absent and empty sources share
        // a protocol-1 generation, but must not share mutation authorization.
        const source_id = try identity(temp, files, id, 0);
        const supplied = request.get("display_declaration_changes").?.object.get("sources").?.object.get(id.name()).?.string;
        if (!std.mem.eql(u8, supplied, source_id)) return error.ExternalChange;
        try validateSource(temp, &file.document);
        var parent_node: ?*Node = null;
        for (try file.document.tables(temp)) |table| {
            const k = kind(table);
            const node = try temp.create(Node);
            node.* = .{ .id = try identity(temp, files, id, table.index), .source = id, .kind = k, .doc = try cfg.Document.init(temp, file.document.tableSource(table.index).?) };
            if (k == .member) node.parent = parent_node orelse return error.InvalidDisplaySource else parent_node = if (k == .profile) node else null;
            try batch.nodes.append(temp, node);
            try batch.all.append(temp, node);
        }
    }
    const operations = request.get("display_declaration_changes").?.object.get("operations").?.array.items;
    for (operations) |value| {
        const op = value.object;
        const action = try text(try get(op, "op"));
        const id = try source(try get(op, "source"));
        if (std.mem.eql(u8, action, "add")) {
            try keys(op, &.{ "op", "source", "kind", "ref", "parent", "before", "set" });
            const requested_kind = try text(try get(op, "kind"));
            const k: Kind = if (std.mem.eql(u8, requested_kind, "output")) .output else if (std.mem.eql(u8, requested_kind, "profile")) .profile else if (std.mem.eql(u8, requested_kind, "policy")) .policy else return error.InvalidDisplayMutation;
            const p = if (k == .output) try batch.parent(try get(op, "parent"), id) else null;
            if (k != .output and op.contains("parent")) return error.InvalidDisplayMutation;
            if (k == .policy and op.contains("before")) return error.InvalidDisplayMutation;
            const node = try temp.create(Node);
            const actual_kind: Kind = if (p != null) .member else k;
            node.* = .{ .id = "", .source = id, .kind = actual_kind, .doc = try cfg.Document.init(temp, try std.fmt.allocPrint(temp, "{s}\n", .{header(actual_kind)})) };
            if (op.get("ref")) |ref| {
                const name = try text(ref);
                if (name.len == 0 or name.len > 64) return error.InvalidDisplayMutation;
                for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidDisplayMutation;
                const local = try std.fmt.allocPrint(temp, "new:{s}", .{name});
                for (batch.all.items) |n| if (n.local_ref) |r| {
                    if (std.mem.eql(u8, r, local)) return error.ConflictingDisplayEdits;
                };
                node.local_ref = local;
            }
            try patch(temp, node, try get(op, "set"), null);
            try batch.nodes.append(temp, node);
            try batch.all.append(temp, node);
            if (k != .policy) try batch.relocate(node, p, if (op.get("before")) |b| try batch.resolve(b, id) else null);
        } else {
            const node = try batch.resolve(try get(op, "id"), id);
            if (node.used) return error.ConflictingDisplayEdits;
            if (std.mem.eql(u8, action, "update")) {
                try keys(op, &.{ "op", "source", "id", "set", "unset" });
                if (!op.contains("set") and !op.contains("unset")) return error.InvalidDisplayMutation;
                try patch(temp, node, op.get("set"), op.get("unset"));
            } else if (std.mem.eql(u8, action, "move")) {
                try keys(op, &.{ "op", "source", "id", "parent", "before" });
                const p = if (node.kind == .output or node.kind == .member) try batch.parent(try get(op, "parent"), id) else null;
                if (node.kind == .profile and op.contains("parent")) return error.InvalidDisplayMutation;
                try batch.relocate(node, p, if (op.get("before")) |b| try batch.resolve(b, id) else null);
            } else if (std.mem.eql(u8, action, "delete")) {
                try keys(op, &.{ "op", "source", "id", "members", "parent" });
                if (node.kind == .profile) {
                    const choice = try text(try get(op, "members"));
                    const move = std.mem.eql(u8, choice, "move");
                    if (!move and !std.mem.eql(u8, choice, "delete")) return error.InvalidDisplayMutation;
                    if (!move and op.contains("parent")) return error.InvalidDisplayMutation;
                    const p = if (move) try batch.parent(try get(op, "parent"), id) else null;
                    if (p == node) return error.InvalidDisplayMutation;
                    const children = try temp.dupe(*Node, batch.nodes.items[batch.index(node) + 1 .. batch.end(node)]);
                    for (children) |child| {
                        if (child.used) return error.ConflictingDisplayEdits;
                        if (move) {
                            try batch.relocate(child, p, null);
                            child.used = true;
                        } else try batch.remove(child);
                    }
                } else if (op.contains("members") or op.contains("parent")) return error.InvalidDisplayMutation;
                try batch.remove(node);
            } else return error.InvalidDisplayMutation;
            node.used = true;
        }
    }
    for ([_]schema.FileId{ .wm, .outputs }) |id| {
        if (!touched[@intFromEnum(id)]) continue;
        var writer: std.Io.Writer.Allocating = .init(temp);
        for (batch.nodes.items) |node| if (node.source == id) {
            if (writer.written().len > 0 and !std.mem.endsWith(u8, writer.written(), "\n")) try writer.writer.writeByte('\n');
            try writer.writer.writeAll(node.doc.source);
        };
        var candidate = try cfg.Document.init(a, writer.written());
        errdefer candidate.deinit();
        try validateSource(temp, &candidate);
        files.items[@intFromEnum(id)].document.deinit();
        files.items[@intFromEnum(id)].document = candidate;
    }
    // A rename/deletion never silently retargets policy by profile name. Clients
    // update that policy explicitly in the same batch when required.
    const wm = native.config.parse(files.items[0].document.source);
    const outputs = native.config.parse(files.items[3].document.source);
    for ([_]*const native.config.Snapshot{ &wm, &outputs }) |s| {
        if (s.fallback_profile_set and !s.fallback_profile.empty() and native.config.effectiveProfile(&wm, &outputs, s.fallback_profile.slice()) == null) return error.InvalidDisplayReference;
    }
}

fn patch(a: A, node: *Node, set: ?Json, unset: ?Json) !void {
    if (set) |values| {
        if (values != .object) return error.InvalidDisplayMutation;
        var it = values.object.iterator();
        while (it.next()) |entry| {
            const encoded = try encode(a, node.kind, entry.key_ptr.*, entry.value_ptr.*);
            var found = false;
            for (try node.doc.entries(a)) |e| if (std.mem.eql(u8, e.key, entry.key_ptr.*)) {
                try node.doc.setEntryRaw(e.index, encoded);
                found = true;
                break;
            };
            if (!found) try node.doc.addToTable(1, entry.key_ptr.*, encoded);
        }
    }
    if (unset) |values| {
        if (values != .array) return error.InvalidDisplayMutation;
        for (values.array.items, 0..) |value, i| {
            const key = try text(value);
            if (!known(node.kind, key)) return error.InvalidDisplayField;
            if (set) |v| if (v.object.contains(key)) return error.ConflictingDisplayEdits;
            for (values.array.items[0..i]) |prior| if (std.mem.eql(u8, try text(prior), key)) return error.ConflictingDisplayEdits;
            _ = try node.doc.deleteTableEntry(1, key);
        }
    }
}
fn known(k: Kind, key: []const u8) bool {
    return switch (k) {
        .policy => native.config.knownPolicyKey(key),
        .profile => std.mem.eql(u8, key, "name"),
        .output, .member => native.config.knownSpecKey(key),
        .other => false,
    };
}
fn boolean(key: []const u8) bool {
    for ([_][]const u8{ "enabled", "primary", "hdr", "auto_hdr", "adaptive_sync", "fullscreen_only_adaptive_sync", "apply_on_start", "apply_on_reload" }) |s| if (std.mem.eql(u8, key, s)) return true;
    return false;
}
fn numeric(key: []const u8) bool {
    for ([_][]const u8{ "scale", "sdr_white_level", "auto_hdr_boost", "rollback_seconds" }) |s| if (std.mem.eql(u8, key, s)) return true;
    return false;
}
fn encode(a: A, k: Kind, key: []const u8, value: Json) ![]const u8 {
    if (!known(k, key)) return error.InvalidDisplayField;
    const encoded = blk: {
        if (boolean(key)) {
            if (value != .bool) return error.InvalidDisplayValue;
        } else if (numeric(key)) {
            if (value != .float and value != .integer) return error.InvalidDisplayValue;
            if (std.mem.eql(u8, key, "rollback_seconds") and value != .integer) return error.InvalidDisplayValue;
        } else if (std.mem.eql(u8, key, "position")) {
            if (value != .array or value.array.items.len != 2) return error.InvalidDisplayValue;
            for (value.array.items) |n| if (n != .integer) return error.InvalidDisplayValue;
        } else {
            if (value != .string or value.string.len > 256) return error.InvalidDisplayValue;
            for (value.string) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidDisplayValue;
            // Native display strings are unquoted but not escape-decoded.
            if (std.mem.indexOfScalar(u8, value.string, '\'') == null) break :blk try std.fmt.allocPrint(a, "'{s}'", .{value.string});
            if (std.mem.indexOfAny(u8, value.string, "\"\\") != null) return error.InvalidDisplayValue;
        }
        break :blk try std.json.Stringify.valueAlloc(a, value, .{});
    };
    const test_source = try std.fmt.allocPrint(a, "{s}\n{s}{s} = {s}\n", .{ if (k == .policy) "[display]" else if (k == .profile) "[[display.profile]]" else "[[output]]", if (k == .output or k == .member) (if (std.mem.eql(u8, key, "name")) "edid = 'validation-edid'\n" else "name = 'validation-output'\n") else "", key, encoded });
    const parsed = native.config.parse(test_source);
    if (parsed.unknown_fields != 0 or parsed.rejected_declarations != 0) return error.InvalidDisplayValue;
    return encoded;
}

// No table surgery in ambiguous input. Match the shared document scanner to the
// actual line-oriented parser, then validate original and final display values.
fn validateSource(a: A, doc: *const cfg.Document) !void {
    if (!try review.triviaOnly(a, doc.source, doc.source)) return error.InvalidDisplaySource;
    const tables = try doc.tables(a);
    const entries = try doc.entries(a);
    var table: usize = 0;
    var entry: usize = 0;
    var policies: usize = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    while (lines.next()) |raw| {
        const line = native.collection_toml.cleanLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            table += 1;
            if (table >= tables.len) return error.InvalidDisplaySource;
            const k = kind(tables[table]);
            if (k != .other) {
                if (!std.mem.eql(u8, line, header(k))) return error.InvalidDisplaySource;
                if (k == .policy) policies += 1;
            } else if (std.mem.eql(u8, tables[table].name, "output") or std.mem.startsWith(u8, tables[table].name, "display")) return error.InvalidDisplaySource;
        } else {
            if (entry >= entries.len or entries[entry].table_index != table) return error.InvalidDisplaySource;
            const e = entries[entry];
            entry += 1;
            const k = kind(tables[table]);
            if (k == .other) continue;
            const equal = native.collection_toml.indexUnquoted(line, '=') orelse return error.InvalidDisplaySource;
            if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equal], " \t"), e.key) or !known(k, e.key)) return error.InvalidDisplaySource;
            for (entries[0 .. entry - 1]) |prior| if (prior.table_index == table and std.mem.eql(u8, prior.key, e.key)) return error.InvalidDisplaySource;
            const v: Json = if (boolean(e.key)) b: {
                if (std.mem.eql(u8, e.value, "true")) break :b .{ .bool = true };
                if (std.mem.eql(u8, e.value, "false")) break :b .{ .bool = false };
                return error.InvalidDisplaySource;
            } else if (numeric(e.key) or std.mem.eql(u8, e.key, "position")) std.json.parseFromSliceLeaky(Json, a, e.value, .{}) catch return error.InvalidDisplaySource else b: {
                if (e.value.len < 2 or (e.value[0] != '\'' and e.value[0] != '"') or e.value[e.value.len - 1] != e.value[0]) {
                    // Native HDR presets also accept unquoted integer values.
                    if (std.mem.eql(u8, e.key, "hdr_level")) break :b .{ .string = e.value };
                    return error.InvalidDisplaySource;
                }
                break :b .{ .string = native.collection_toml.unquote(e.value) };
            };
            _ = encode(a, k, e.key, v) catch return error.InvalidDisplaySource;
        }
    }
    if (entry != entries.len or table + 1 != tables.len or policies > 1) return error.InvalidDisplaySource;
    const parsed = native.config.parse(doc.source);
    if (parsed.unknown_fields != 0 or parsed.rejected_declarations != 0) return error.InvalidDisplaySource;
}
