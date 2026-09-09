const std = @import("std");
pub const j = @import("json.zig");
const V = j.Value;
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: V = .null,
    draft: V = .null,
    errors: V = .null,
    inputs: V = .null,
    next_id: u64 = 0,
    raw_owned: std.StringHashMapUnmanaged([]u8) = .empty,
    pub fn init(a: std.mem.Allocator) Model {
        return .{ .arena = std.heap.ArenaAllocator.init(a) };
    }
    pub fn deinit(self: *Model) void {
        var values = self.raw_owned.valueIterator();
        while (values.next()) |value| self.arena.child_allocator.free(value.*);
        self.raw_owned.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }
    pub fn allocator(self: *Model) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn accept(self: *Model, bytes: []const u8, shell: []const u8) !void {
        var candidate = Model.init(self.arena.child_allocator);
        errdefer candidate.deinit();
        candidate.snapshot = try j.parse(candidate.allocator(), bytes);
        try compatible(candidate.snapshot, shell);
        if (j.text(candidate.snapshot, "generation").len == 0 or j.get(candidate.snapshot, "fields") != .array or j.get(candidate.snapshot, "raw_files") != .object) return error.InvalidSnapshot;
        try candidate.clear();
        self.deinit();
        self.* = candidate;
    }
    pub fn clear(self: *Model) !void {
        var values = self.raw_owned.valueIterator();
        while (values.next()) |value| self.arena.child_allocator.free(value.*);
        self.raw_owned.clearRetainingCapacity();
        const a = self.allocator();
        self.draft = j.object(a);
        self.errors = j.object(a);
        self.inputs = j.object(a);
        for ([_][]const u8{ "changes", "raw_files", "monitor_changes", "snap_zone_changes", "custom_keybind_changes" }) |key| try j.put(self.allocator(), &self.draft, key, j.object(a));
        try j.put(self.allocator(), &self.draft, "window_rule_changes", j.array(a));
    }
    pub fn count(self: *const Model) usize {
        if (self.draft != .object) return 0;
        var n: usize = 0;
        for (self.draft.object.values()) |v| n += switch (v) {
            .object => v.object.count(),
            .array => @max(1, v.array.items.len),
            .bool => @intFromBool(v.bool),
            .null => 0,
            else => 1,
        };
        // Empty rule operations are not a draft.
        if (j.items(j.get(self.draft, "window_rule_changes")).len == 0) n -= 1;
        return n;
    }
    pub fn field(self: *const Model, id: []const u8) V {
        for (j.items(j.get(self.snapshot, "fields"))) |f| if (std.mem.eql(u8, j.text(f, "id"), id)) return f;
        return .null;
    }
    pub fn getValue(self: *const Model, id: []const u8) V {
        const changes = j.get(self.draft, "changes");
        return if (changes == .object) changes.object.get(id) orelse j.get(self.field(id), "value") else j.get(self.field(id), "value");
    }
    pub fn change(self: *Model, id: []const u8, value: V) !void {
        const f = self.field(id);
        if (f == .null) return error.UnknownField;
        const map = self.draft.object.getPtr("changes").?;
        if (try j.eq(self.allocator(), j.get(f, "value"), value)) {
            _ = map.object.swapRemove(id);
            return;
        }
        try j.put(self.allocator(), map, try self.allocator().dupe(u8, id), try j.clone(self.allocator(), value));
    }
    pub fn input(self: *Model, id: []const u8, text: []const u8) !void {
        const f = self.field(id);
        const kind = j.text(f, "type");
        const a = self.allocator();
        const value: V = blk: {
            if (std.mem.eql(u8, kind, "integer")) break :blk .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger };
            if (std.mem.eql(u8, kind, "double")) {
                const n = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
                if (!std.math.isFinite(n)) return error.InvalidNumber;
                break :blk .{ .float = n };
            }
            if (std.mem.eql(u8, kind, "string_list")) {
                var v = j.array(a);
                var chords = std.mem.splitScalar(u8, text, ',');
                while (chords.next()) |chord| {
                    const trimmed = std.mem.trim(u8, chord, " \t");
                    if (trimmed.len > 0) try v.array.append(try j.string(a, trimmed));
                }
                break :blk v;
            }
            break :blk try j.string(a, text);
        };
        if (value == .integer or value == .float) {
            const n = j.number(value);
            if (j.get(f, "min") != .null and n < j.number(j.get(f, "min"))) return error.BelowMinimum;
            if (j.get(f, "max") != .null and n > j.number(j.get(f, "max"))) return error.AboveMaximum;
        }
        try self.change(id, value);
    }
    pub fn raw(self: *Model, file: []const u8, text: []const u8) !void {
        if (text.len > 1024 * 1024) return error.FileTooLarge;
        const map = self.draft.object.getPtr("raw_files").?;
        const child = self.arena.child_allocator;
        if (std.mem.eql(u8, j.text(j.get(self.snapshot, "raw_files"), file), text)) {
            _ = map.object.swapRemove(file);
            if (self.raw_owned.fetchRemove(file)) |old| child.free(old.value);
            return;
        }
        const key = try self.allocator().dupe(u8, file);
        const owned = try child.dupe(u8, text);
        errdefer child.free(owned);
        const previous = self.raw_owned.get(file);
        try self.raw_owned.ensureUnusedCapacity(child, 1);
        try j.put(self.allocator(), map, key, .{ .string = owned });
        self.raw_owned.putAssumeCapacity(key, owned);
        if (previous) |old| child.free(old);
    }
    pub fn rawText(self: *const Model, file: []const u8) []const u8 {
        const map = j.get(self.draft, "raw_files");
        return if (map == .object) j.str(map.object.get(file) orelse j.get(j.get(self.snapshot, "raw_files"), file)) else "";
    }
    pub fn flag(self: *Model, key: []const u8) !void {
        try j.put(self.allocator(), &self.draft, key, .{ .bool = true });
    }
    pub fn unique(self: *Model, prefix: []const u8) ![]const u8 {
        while (true) {
            self.next_id += 1;
            const id = try std.fmt.allocPrint(self.allocator(), "{s}{d}", .{ prefix, self.next_id });
            if (!containsId(self.snapshot, id) and !containsId(self.draft, id)) return id;
        }
    }
    pub fn merge(self: *Model, collection: []const u8, id: []const u8, key: []const u8, value: V) !void {
        const a = self.allocator();
        const map = self.draft.object.getPtr(collection) orelse return error.UnknownCollection;
        if (!map.object.contains(id)) {
            var op = j.object(a);
            try j.put(self.allocator(), &op, "id", try j.string(a, id));
            try j.put(self.allocator(), map, try a.dupe(u8, id), op);
        }
        try j.put(self.allocator(), map.object.getPtr(id).?, try a.dupe(u8, key), try j.clone(a, value));
    }
    pub fn rule(self: *Model, operation: V) !void {
        const a = self.allocator();
        const ops = self.draft.object.getPtr("window_rule_changes").?;
        const moving = std.mem.eql(u8, j.text(operation, "op"), "move");
        if (moving and ops.array.items.len > 0) return error.ApplyRuleEditsBeforeMoving;
        for (ops.array.items) |op| if (std.mem.eql(u8, j.text(op, "op"), "move")) return error.ApplyRuleMoveFirst;
        for (ops.array.items, 0..) |*op, i| {
            if (!std.mem.eql(u8, j.text(op.*, "id"), j.text(operation, "id"))) continue;
            if (std.mem.eql(u8, j.text(operation, "op"), "delete")) {
                if (std.mem.eql(u8, j.text(op.*, "op"), "add")) {
                    _ = ops.array.orderedRemove(i);
                } else op.* = try j.clone(a, operation);
            } else {
                const values = j.get(operation, "values");
                if (values == .object) for (values.object.keys(), values.object.values()) |key, v| try j.put(self.allocator(), op.object.getPtr("values").?, try a.dupe(u8, key), try j.clone(a, v));
            }
            return;
        }
        try ops.array.append(try j.clone(a, operation));
    }
    pub fn rows(self: *Model, source: []const u8, changes: []const u8) !V {
        const a = self.allocator();
        var rows_value = try j.clone(a, j.get(self.snapshot, source));
        if (rows_value != .array) rows_value = j.array(a);
        const ops = j.get(self.draft, changes);
        const values = if (ops == .object) ops.object.values() else j.items(ops);
        for (values) |op| {
            const id = j.text(op, "id");
            var index: ?usize = null;
            for (rows_value.array.items, 0..) |row, i| if (std.mem.eql(u8, j.text(row, "id"), id)) {
                index = i;
                break;
            };
            const verb = j.text(op, "op");
            if (index) |i| {
                if (std.mem.eql(u8, verb, "delete")) {
                    _ = rows_value.array.orderedRemove(i);
                    continue;
                }
                if (std.mem.eql(u8, verb, "move")) {
                    const target: usize = @intFromFloat(std.math.clamp(@as(f64, @floatFromInt(i)) + j.number(j.get(op, "direction")), 0, @as(f64, @floatFromInt(rows_value.array.items.len - 1))));
                    const row = rows_value.array.orderedRemove(i);
                    try rows_value.array.insert(target, row);
                    continue;
                }
                const dst = if (std.mem.eql(u8, source, "window_rules")) rows_value.array.items[i].object.getPtr("values").? else &rows_value.array.items[i];
                const src = if (std.mem.eql(u8, source, "window_rules")) j.get(op, "values") else op;
                for (src.object.keys(), src.object.values()) |key, v| try j.put(self.allocator(), dst, key, v);
            } else if (!std.mem.eql(u8, verb, "delete")) try rows_value.array.append(try j.clone(a, op));
        }
        return rows_value;
    }
    pub fn request(self: *Model, backup: []const u8) ![]const u8 {
        const a = self.allocator();
        if (self.errors == .object and self.errors.object.count() > 0) return error.InvalidFields;
        const generation = j.text(self.snapshot, "generation");
        if (generation.len == 0) return error.LoadFirst;
        const raw_files = j.get(self.draft, "raw_files");
        const changes = j.get(self.draft, "changes");
        for (changes.object.keys()) |id| if (raw_files.object.contains(j.text(self.field(id), "file"))) return error.RawTypedConflict;
        const collections = [_][]const u8{ "monitor_changes", "custom_keybind_changes", "window_rule_changes", "snap_zone_changes" };
        const files = [_][]const u8{ "outputs", "wm", "rules", "layout" };
        for (collections, files) |key, file| {
            const v = j.get(self.draft, key);
            const count_value = if (v == .object) v.object.count() else j.items(v).len;
            if (count_value > 0 and raw_files.object.contains(file)) return error.RawTypedConflict;
        }
        if ((j.get(self.draft, "snap_layouts") != .null or j.boolean(j.get(self.draft, "normalize_stacking"))) and raw_files.object.contains("layout")) return error.RawTypedConflict;
        var r = try j.clone(a, self.draft);
        try j.put(self.allocator(), &r, "protocol", .{ .integer = 1 });
        try j.put(self.allocator(), &r, "expected_generation", try j.string(a, generation));
        try j.put(self.allocator(), &r, "backup_dir", try j.string(a, backup));
        try j.put(self.allocator(), &r, "create_user_override", .{ .bool = true });
        var list = j.array(a);
        for (changes.object.keys(), changes.object.values()) |id, v| {
            var change_value = j.object(a);
            try j.put(self.allocator(), &change_value, "id", try j.string(a, id));
            try j.put(self.allocator(), &change_value, "value", v);
            try list.array.append(change_value);
        }
        try j.put(self.allocator(), &r, "changes", list);
        for ([_][]const u8{ "monitor_changes", "snap_zone_changes", "custom_keybind_changes" }) |key| {
            list = j.array(a);
            for (j.get(self.draft, key).object.values()) |v| try list.array.append(v);
            try j.put(self.allocator(), &r, key, list);
        }
        const encoded = try j.encode(a, r);
        if (encoded.len > 4 * 1024 * 1024) return error.RequestTooLarge;
        return encoded;
    }
};
pub fn compatible(response: V, shell: []const u8) !void {
    if (!j.boolean(j.get(response, "ok"))) return error.BackendFailure;
    if (j.number(j.get(response, "protocol")) != 1) return error.IncompatibleProtocol;
    _ = shell;
}
pub fn hasCapability(v: V, cap: []const u8) bool {
    for (j.items(j.get(v, "capabilities"))) |item| if (std.mem.eql(u8, j.str(item), cap)) return true;
    return false;
}

fn containsId(v: V, id: []const u8) bool {
    switch (v) {
        .object => |obj| {
            if (std.mem.eql(u8, j.text(v, "id"), id)) return true;
            for (obj.values()) |child| if (containsId(child, id)) return true;
        },
        .array => |arr| for (arr.items) |child| {
            if (containsId(child, id)) return true;
        },
        else => {},
    }
    return false;
}
