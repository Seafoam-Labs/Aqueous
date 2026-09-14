//! Opt-in protected collection requests. Preconditions prove ID reuse; only a
//! freshly calculated full candidate digest authorizes the candidate to save.
const std = @import("std");
const config = @import("config_document.zig");
const schema = @import("schema.zig");
const tx = @import("display_config").transaction;
const A = std.mem.Allocator;
const Json = std.json.Value;
pub const source_ids = [_]schema.FileId{ .wm, .rules, .layout };

pub const Report = struct {
    version: u32 = 1,
    requested_generation: []const u8,
    effective_generation: []const u8,
    rebased: bool,
    candidate_digest: []const u8,
    base_preconditions: Json,
};

pub const Contract = struct {
    touched: [schema.file_count]bool,
    preconditions: Json,

    pub fn check(self: Contract, a: A, files: *const config.ConfigFiles) !void {
        const sources = self.preconditions.object.get("sources").?.object;
        for (source_ids) |id| {
            if (!self.touched[@intFromEnum(id)]) continue;
            const file = &files.items[@intFromEnum(id)];
            const supplied = sources.get(id.name()).?.object;
            const present = try exists(file.path);
            const actual = try sourceDigest(a, file, present);
            if (!std.mem.eql(u8, supplied.get("path").?.string, file.path) or
                supplied.get("exists").?.bool != present or
                !std.mem.eql(u8, supplied.get("digest").?.string, &actual)) return error.ExternalChange;
        }
    }
};

pub fn parse(request: std.json.ObjectMap) !?Contract {
    const version = request.get("collection_apply_version") orelse {
        // Never silently ignore new preconditions on an unnegotiated request.
        if (request.contains("collection_preconditions_v2")) return error.InvalidCollectionContract;
        return null;
    };
    if (version != .integer or version.integer != 1) return error.InvalidCollectionContract;
    const protected = request.get("protected_apply") orelse return error.InvalidCollectionContract;
    if (protected != .bool or !protected.bool) return error.InvalidCollectionContract;
    const generation = request.get("expected_generation") orelse return error.MissingGeneration;
    if (generation != .string or !hex(generation.string, 16)) return error.InvalidGeneration;
    var touched = [_]bool{false} ** schema.file_count;
    for (request.keys()) |key| {
        if (mutationSource(key)) |id| {
            touched[@intFromEnum(id)] = true;
            const value = request.get(key).?;
            if (std.mem.eql(u8, key, "default_snap_layout")) {
                // This field belongs to replacement; legacy standalone use was
                // ignored. It must not authorize an unchecked layout edit.
                if (!request.contains("snap_layouts") or value != .string) return error.InvalidCollectionContract;
            } else if (value != .array) return error.InvalidCollectionContract;
            continue;
        }
        if (oneOf(key, &.{ "protocol", "expected_generation", "collection_apply_version", "protected_apply", "collection_preconditions_v2", "candidate_digest" })) continue;
        if (std.mem.eql(u8, key, "backup_dir")) {
            const value = request.get(key).?;
            if (value != .string or value.string.len == 0) return error.InvalidCollectionContract;
            continue;
        }
        if (std.mem.eql(u8, key, "create_user_override")) {
            if (request.get(key).? != .bool) return error.InvalidCollectionContract;
            continue;
        }
        // In particular raw_files, display/monitor changes, scalar changes and
        // toolkit synchronization cannot use the collection rebase exception.
        return error.InvalidCollectionContract;
    }
    if (request.get("candidate_digest")) |digest| if (digest != .string or !hex(digest.string, 64)) return error.CandidateMismatch;
    const preconditions = request.get("collection_preconditions_v2") orelse return error.InvalidCollectionPreconditions;
    if (preconditions != .object or preconditions.object.count() != 2) return error.InvalidCollectionPreconditions;
    const pv = preconditions.object.get("version") orelse return error.InvalidCollectionPreconditions;
    if (pv != .integer or pv.integer != 2) return error.InvalidCollectionPreconditions;
    const sources = preconditions.object.get("sources") orelse return error.InvalidCollectionPreconditions;
    if (sources != .object) return error.InvalidCollectionPreconditions;
    var count: usize = 0;
    for (source_ids) |id| if (touched[@intFromEnum(id)]) {
        count += 1;
        const source = sources.object.get(id.name()) orelse return error.InvalidCollectionPreconditions;
        if (source != .object or source.object.count() != 3) return error.InvalidCollectionPreconditions;
        const path = source.object.get("path") orelse return error.InvalidCollectionPreconditions;
        const present = source.object.get("exists") orelse return error.InvalidCollectionPreconditions;
        const digest = source.object.get("digest") orelse return error.InvalidCollectionPreconditions;
        if (path != .string or path.string.len == 0 or present != .bool or digest != .string or !hex(digest.string, 64)) return error.InvalidCollectionPreconditions;
    };
    if (count == 0 or sources.object.count() != count) return error.InvalidCollectionPreconditions;
    return .{ .touched = touched, .preconditions = preconditions };
}

fn mutationSource(key: []const u8) ?schema.FileId {
    if (std.mem.eql(u8, key, "window_rule_changes")) return .rules;
    if (std.mem.eql(u8, key, "custom_keybind_changes")) return .wm;
    if (oneOf(key, &.{ "snap_layouts", "snap_zone_changes", "default_snap_layout" })) return .layout;
    return null;
}

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

pub fn exists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn sourceDigest(a: A, file: *const config.ConfigFiles.File, present: bool) ![64]u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, .{ "aqueous-collection-source-v2", file.path, present, file.document.source }, .{});
    defer a.free(bytes);
    return tx.digest(bytes);
}

pub fn writePreconditions(json: *std.json.Stringify, files: *const config.ConfigFiles) !void {
    try json.beginObject();
    try json.objectField("version");
    try json.write(@as(u32, 2));
    try json.objectField("sources");
    try json.beginObject();
    for (source_ids) |id| {
        const file = &files.items[@intFromEnum(id)];
        const present = try exists(file.path);
        const digest = try sourceDigest(files.allocator, file, present);
        try json.objectField(id.name());
        try json.write(.{ .path = file.path, .exists = present, .digest = @as([]const u8, &digest) });
    }
    try json.endObject();
    try json.endObject();
}

pub fn checkCandidateDigest(request: std.json.ObjectMap, actual: []const u8) !void {
    const supplied = request.get("candidate_digest") orelse return error.CandidateMismatch;
    if (supplied != .string or !hex(supplied.string, 64) or !std.mem.eql(u8, supplied.string, actual)) return error.CandidateMismatch;
}

fn hex(value: []const u8, length: usize) bool {
    if (value.len != length) return false;
    for (value) |ch| if (!(ch >= '0' and ch <= '9') and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}
