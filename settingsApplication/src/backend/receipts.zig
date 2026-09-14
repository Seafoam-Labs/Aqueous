//! Opt-in, durable at-most-once operation records. Unknown external completion
//! is never permission to repeat a reload or toolkit side effect.
const std = @import("std");
const tx = @import("display_config").transaction;
const A = std.mem.Allocator;
pub const lifetime_seconds = 7 * 24 * 60 * 60;
pub const max_records = 256;
pub const max_result_bytes = 16 * 1024 * 1024;
const Intent = struct { version: u32 = 1, request_digest: [64]u8, operation_id: []const u8 };

fn timestamp(id: []const u8) !i64 {
    if (!tx.validOperationId(id) or id.len < 32 or id[10] != '-') return error.InvalidOperationId;
    return std.fmt.parseInt(i64, id[0..10], 10) catch error.InvalidOperationId;
}
fn prune(a: A, io: std.Io) !void {
    const root = try tx.rootPath(a);
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/receipts", .{root});
    defer a.free(path);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    var total: u64 = 0;
    const now = std.Io.Clock.real.now(io).toSeconds();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse continue;
        const started = timestamp(entry.name[0..dot]) catch continue;
        if (started < now - lifetime_seconds) {
            try dir.deleteFile(io, entry.name);
            continue;
        }
        const stat = try dir.statFile(io, entry.name, .{});
        total += stat.size;
        if (std.mem.endsWith(u8, entry.name, ".intent")) count += 1;
    }
    if (count >= max_records or total > 64 * 1024 * 1024) return error.ReceiptCapacity;
}

pub fn begin(a: A, io: std.Io, id: []const u8, shell: []const u8, request: []const u8) !?[]u8 {
    const lock = try tx.Lock.acquire(a, io, true);
    defer lock.release();
    _ = try tx.recover(a, io);
    const started = try timestamp(id);
    const now = std.Io.Clock.real.now(io).toSeconds();
    // An expired ID cannot become a new operation after its record is pruned.
    if (started < now - lifetime_seconds or started > now + 300) return error.OperationIdExpired;
    const input = try std.fmt.allocPrint(a, "aqueous-operation-v1\n{s}\n{s}", .{ shell, request });
    defer a.free(input);
    const fingerprint = tx.digest(input);
    const path = try tx.receiptPath(a, id, "intent");
    defer a.free(path);
    if (try tx.readOptional(a, io, path, 4096)) |bytes| {
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(Intent, a, bytes, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, &parsed.value.request_digest, &fingerprint)) return error.OperationIdReused;
        return try statusLocked(a, io, id);
    }
    try prune(a, io);
    const bytes = try std.json.Stringify.valueAlloc(a, Intent{ .request_digest = fingerprint, .operation_id = id }, .{});
    defer a.free(bytes);
    try tx.durableWrite(a, io, path, bytes, 0o600);
    tx.checkpoint("operation_intent");
    return null;
}

pub fn finish(a: A, io: std.Io, id: []const u8, result: []const u8) !void {
    if (result.len > max_result_bytes) return error.ResultTooLarge;
    const lock = try tx.Lock.acquire(a, io, true);
    defer lock.release();
    const path = try tx.receiptPath(a, id, "result");
    defer a.free(path);
    try tx.durableWrite(a, io, path, result, 0o600);
    tx.checkpoint("operation_result");
}
pub fn status(a: A, io: std.Io, id: []const u8) ![]u8 {
    _ = try timestamp(id);
    const lock = try tx.Lock.acquire(a, io, true);
    defer lock.release();
    _ = tx.recover(a, io) catch |err| {
        if (err != error.RecoveryConflict) return err;
        return std.json.Stringify.valueAlloc(a, .{ .ok = false, .protocol = 1, .result_version = 1, .operation_id = id, .receipt = "recovery_conflict", .save = "recovery_conflict", .reload = "unknown", .display = "not_requested" }, .{});
    };
    return statusLocked(a, io, id);
}
fn statusLocked(a: A, io: std.Io, id: []const u8) ![]u8 {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const started = try timestamp(id);
    if (started < now - lifetime_seconds) return unknown(a, id, "expired");
    const result_path = try tx.receiptPath(a, id, "result");
    defer a.free(result_path);
    if (try tx.readOptional(a, io, result_path, max_result_bytes)) |bytes| return bytes;
    const decision_path = try tx.receiptPath(a, id, "decision");
    defer a.free(decision_path);
    if (try tx.readOptional(a, io, decision_path, 64 * 1024)) |bytes| {
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer parsed.deinit();
        const j = parsed.value.object;
        return std.json.Stringify.valueAlloc(a, .{
            .ok = true,
            .protocol = 1,
            .result_version = 1,
            .operation_id = id,
            .receipt = "recovered",
            .save = j.get("save"),
            .reload = "unknown",
            .display = try displayState(a, j.get("preview_token")),
            .before_generation = j.get("before_generation"),
            .after_generation = j.get("after_generation"),
            .candidate_digest = j.get("candidate_digest"),
            .files = j.get("files"),
            .toolkit = .{ .typography = "unknown", .cursor = "unknown" },
        }, .{});
    }
    const intent_path = try tx.receiptPath(a, id, "intent");
    defer a.free(intent_path);
    if (try tx.readOptional(a, io, intent_path, 4096)) |bytes| {
        a.free(bytes);
        return unknown(a, id, "incomplete");
    }
    return unknown(a, id, "absent");
}
fn unknown(a: A, id: []const u8, reason: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .ok = true, .protocol = 1, .result_version = 1, .operation_id = id, .receipt = "unknown", .reason = reason, .save = "uncertain", .reload = "unknown", .display = "not_requested", .retry_allowed = false }, .{});
}

fn displayState(a: A, token: ?std.json.Value) ![]const u8 {
    const value = token orelse return "not_requested";
    if (value != .string) return "not_requested";
    var client = @import("display_config").ipc.Client.open(a) catch return "unknown";
    defer client.close();
    const bytes = client.call(a, "display.preview.status", .{ .token = value.string }) catch return "unknown";
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const state = parsed.value.object.get("state") orelse return "unknown";
    if (state != .string) return "unknown";
    inline for (.{ "kept", "reverted", "invalidated", "failed" }) |known| if (std.mem.eql(u8, state.string, known)) return known;
    return "previewing";
}
pub fn decision(a: A, io: std.Io, id: []const u8) !?[]u8 {
    const path = try tx.receiptPath(a, id, "decision");
    defer a.free(path);
    return tx.readOptional(a, io, path, 65536);
}
