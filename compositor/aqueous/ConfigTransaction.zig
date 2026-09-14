// SPDX-License-Identifier: GPL-3.0-only
//! Shared helper/loader persistence boundary. Every public operation requires
//! the caller's Lock. Paths are local journal data, never compositor IPC input.
const std = @import("std");
const instance = @import("Instance.zig");
const Allocator = std.mem.Allocator;
pub const max_file_bytes = 1024 * 1024;
pub const max_journal_bytes = 80 * 1024 * 1024;
pub var fault: ?*const fn ([]const u8) void = null;
pub fn checkpoint(name: []const u8) void {
    if (fault) |hook| hook(name);
}
threadlocal var lock_depth: usize = 0;

pub fn rootPath(a: Allocator) ![]u8 {
    const base = if (std.c.getenv("XDG_STATE_HOME")) |p|
        try a.dupe(u8, std.mem.span(p))
    else if (std.c.getenv("HOME")) |p|
        try std.fmt.allocPrint(a, "{s}/.local/state", .{std.mem.span(p)})
    else
        return error.ConfigPathUnavailable;
    defer a.free(base);
    if (!std.fs.path.isAbsolute(base)) return error.ConfigPathUnavailable;
    return std.fmt.allocPrint(a, "{s}/" ++ instance.name ++ "/config-writer", .{base});
}

pub const Lock = struct {
    file: ?std.Io.File = null,
    io: std.Io,
    pub fn acquire(a: Allocator, io: std.Io, _: bool) !Lock {
        // Recursive only within the single loader/helper thread. Readers take
        // the same exclusive lock because they may need to recover a journal.
        if (lock_depth != 0) {
            lock_depth += 1;
            return .{ .io = io };
        }
        const root = try rootPath(a);
        defer a.free(root);
        const lock_path = try std.fmt.allocPrint(a, "{s}/lock", .{root});
        defer a.free(lock_path);
        try makeParents(a, io, lock_path);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
        defer dir.close(io);
        try dir.setPermissions(io, .fromMode(0o700));
        const file = try dir.createFile(io, "lock", .{ .read = true, .truncate = false, .permissions = .fromMode(0o600) });
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) return error.ConfigWriterBusy;
        lock_depth = 1;
        return .{ .file = file, .io = io };
    }
    pub fn release(self: Lock) void {
        std.debug.assert(lock_depth != 0);
        lock_depth -= 1;
        if (self.file) |file| {
            std.debug.assert(lock_depth == 0);
            file.unlock(self.io);
            file.close(self.io);
        }
    }
};

pub const Entry = struct {
    path: []const u8,
    before: ?[]const u8,
    after: []const u8,
    before_digest: ?[64]u8,
    after_digest: [64]u8,
    mode: u32 = 0o600,
};
pub const Journal = struct {
    version: u32 = 1,
    transaction_id: []const u8,
    operation_id: ?[]const u8 = null,
    preview_token: ?[]const u8 = null,
    candidate_digest: []const u8,
    before_generation: []const u8,
    after_generation: []const u8,
    phase: enum { prepared, committed },
    commit_deadline_ms: ?i64 = null,
    entries: []const Entry,
};
pub const Recovery = enum { none, rolled_back, committed };
pub fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn syncDir(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    while (true) switch (std.posix.errno(std.os.linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.DirectorySyncFailed,
    };
}

// Sync newly created ancestors as well as the renamed file's parent. Renames
// alone do not persist directory entries across power loss.
fn makeParents(a: Allocator, io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidJournal;
    std.Io.Dir.cwd().access(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try makeParents(a, io, parent);
            std.Io.Dir.cwd().createDir(io, parent, .fromMode(0o700)) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            try syncDir(io, std.fs.path.dirname(parent) orelse "/");
        },
        else => return err,
    };
}

pub fn durableWrite(a: Allocator, io: std.Io, path: []const u8, bytes: []const u8, mode: u32) !void {
    try makeParents(a, io, path);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = .fromMode(mode) });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try syncDir(io, std.fs.path.dirname(path) orelse "/");
}

pub fn readOptional(a: Allocator, io: std.Io, path: []const u8, limit: usize) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}
fn journalPath(a: Allocator) ![]u8 {
    const root = try rootPath(a);
    defer a.free(root);
    return std.fmt.allocPrint(a, "{s}/active.json", .{root});
}
fn writeJournal(a: Allocator, io: std.Io, journal: Journal) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, journal, .{});
    defer a.free(bytes);
    if (bytes.len > max_journal_bytes) return error.JournalTooLarge;
    const path = try journalPath(a);
    defer a.free(path);
    try durableWrite(a, io, path, bytes, 0o600);
}
fn removeJournal(a: Allocator, io: std.Io) !void {
    const path = try journalPath(a);
    defer a.free(path);
    try std.Io.Dir.cwd().deleteFile(io, path);
    try syncDir(io, std.fs.path.dirname(path).?);
}
fn matches(current: ?[]const u8, expected: ?[]const u8) bool {
    if (current == null or expected == null) return current == null and expected == null;
    return std.mem.eql(u8, current.?, expected.?);
}

fn validate(j: Journal) !void {
    if (j.version != 1 or j.entries.len > 6 or (j.entries.len == 0 and j.preview_token == null) or j.transaction_id.len != 64 or j.candidate_digest.len != 64 or j.before_generation.len != 16 or j.after_generation.len != 16) return error.InvalidJournal;
    for (j.entries, 0..) |e, index| {
        if (!std.fs.path.isAbsolute(e.path) or e.path.len > std.fs.max_path_bytes or std.mem.indexOfScalar(u8, e.path, 0) != null or e.after.len > max_file_bytes or e.mode & ~@as(u32, 0o777) != 0) return error.InvalidJournal;
        if (!std.mem.eql(u8, &digest(e.after), &e.after_digest)) return error.InvalidJournal;
        if (e.before) |before| {
            if (before.len > max_file_bytes or e.before_digest == null or !std.mem.eql(u8, &digest(before), &e.before_digest.?)) return error.InvalidJournal;
        } else if (e.before_digest != null) return error.InvalidJournal;
        for (j.entries[0..index]) |old| if (std.mem.eql(u8, old.path, e.path)) return error.InvalidJournal;
    }
}

pub fn pending(a: Allocator, io: std.Io) !bool {
    std.debug.assert(lock_depth != 0);
    const path = try journalPath(a);
    defer a.free(path);
    const bytes = try readOptional(a, io, path, max_journal_bytes) orelse return false;
    a.free(bytes);
    return true;
}

pub fn recover(a: Allocator, io: std.Io) !Recovery {
    std.debug.assert(lock_depth != 0);
    const path = try journalPath(a);
    defer a.free(path);
    const bytes = try readOptional(a, io, path, max_journal_bytes) orelse return .none;
    defer a.free(bytes);
    const parsed = std.json.parseFromSlice(Journal, a, bytes, .{}) catch return error.InvalidJournal;
    defer parsed.deinit();
    const j = parsed.value;
    try validate(j);
    // Check the entire set before changing anything; never clobber a file
    // edited after interruption, including a deletion or an empty new file.
    for (j.entries) |e| {
        const current = try readOptional(a, io, e.path, max_file_bytes);
        defer if (current) |s| a.free(s);
        if (!matches(current, e.before) and !matches(current, e.after)) return error.RecoveryConflict;
    }
    for (j.entries, 0..) |e, index| {
        const current = try readOptional(a, io, e.path, max_file_bytes);
        defer if (current) |s| a.free(s);
        const wanted = if (j.phase == .committed) e.after else e.before;
        if (matches(current, wanted)) continue;
        // A non-cooperating writer can still race this last content check.
        if (!matches(current, e.before) and !matches(current, e.after)) return error.RecoveryConflict;
        if (wanted) |s| try durableWrite(a, io, e.path, s, e.mode) else {
            try std.Io.Dir.cwd().deleteFile(io, e.path);
            try syncDir(io, std.fs.path.dirname(e.path).?);
        }
        var label: [40]u8 = undefined;
        checkpoint(try std.fmt.bufPrint(&label, "recovered_file_{d}", .{index}));
    }
    // Preserve a durable decision for an operation whose helper died before
    // delivering its result. External side effects are explicitly unknown.
    if (j.operation_id) |id| try recordDecision(a, io, id, j);
    try removeJournal(a, io);
    return if (j.phase == .committed) .committed else .rolled_back;
}

pub fn commit(a: Allocator, io: std.Io, journal: Journal, durable: *bool) !void {
    durable.* = false;
    std.debug.assert(lock_depth != 0);
    try validate(journal);
    const path = try journalPath(a);
    defer a.free(path);
    if (try readOptional(a, io, path, max_journal_bytes)) |old| {
        a.free(old);
        return error.RecoveryRequired;
    }
    for (journal.entries) |e| {
        const current = try readOptional(a, io, e.path, max_file_bytes);
        defer if (current) |s| a.free(s);
        if (!matches(current, e.before)) return error.ExternalChange;
    }
    try writeJournal(a, io, journal);
    checkpoint("journal_prepared");
    for (journal.entries, 0..) |e, index| {
        if (journal.commit_deadline_ms) |deadline| if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.CommitExpired;
        const current = try readOptional(a, io, e.path, max_file_bytes);
        defer if (current) |s| a.free(s);
        if (!matches(current, e.before)) return error.RecoveryConflict;
        try durableWrite(a, io, e.path, e.after, e.mode);
        var label: [40]u8 = undefined;
        checkpoint(try std.fmt.bufPrint(&label, "written_file_{d}", .{index}));
    }
    if (journal.commit_deadline_ms) |deadline| if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.CommitExpired;
    var committed = journal;
    committed.phase = .committed;
    try writeJournal(a, io, committed);
    durable.* = true;
    checkpoint("journal_committed");
    if (journal.operation_id) |id| try recordDecision(a, io, id, committed);
    try removeJournal(a, io);
    checkpoint("journal_cleaned");
}

pub fn validOperationId(id: []const u8) bool {
    if (id.len < 16 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
pub fn receiptPath(a: Allocator, id: []const u8, suffix: []const u8) ![]u8 {
    if (!validOperationId(id)) return error.InvalidOperationId;
    const root = try rootPath(a);
    defer a.free(root);
    return std.fmt.allocPrint(a, "{s}/receipts/{s}.{s}", .{ root, id, suffix });
}
fn recordDecision(a: Allocator, io: std.Io, id: []const u8, j: Journal) !void {
    const path = try receiptPath(a, id, "decision");
    defer a.free(path);
    const details = try fileDetails(a, j);
    defer a.free(details);
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .operation_id = id,
        .preview_token = j.preview_token,
        .save = if (j.phase == .committed) if (j.entries.len == 0) "unchanged" else "saved" else "failed",
        .before_generation = j.before_generation,
        .after_generation = if (j.phase == .committed) @as(?[]const u8, j.after_generation) else null,
        .candidate_digest = j.candidate_digest,
        .files = details,
    }, .{});
    defer a.free(bytes);
    try durableWrite(a, io, path, bytes, 0o600);
}

test "operation IDs are bounded and cannot escape receipt directory" {
    try std.testing.expect(validOperationId("client-0123456789abcdef"));
    for ([_][]const u8{ "", "short", "../../0123456789abcdef", "0123456789abcdef\x00" }) |id| try std.testing.expect(!validOperationId(id));
}

fn fileDetails(a: Allocator, j: Journal) ![]const FileDetail {
    const details = try a.alloc(FileDetail, j.entries.len);
    for (j.entries, details) |e, *d| d.* = .{ .path = e.path, .existed = e.before != null, .before_digest = e.before_digest, .after_digest = e.after_digest, .decision = if (j.phase == .committed) "committed" else "rolled_back" };
    return details;
}
pub const FileDetail = struct { path: []const u8, existed: bool, before_digest: ?[64]u8, after_digest: [64]u8, decision: []const u8 };
