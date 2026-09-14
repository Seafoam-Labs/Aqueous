const std = @import("std");
const commands = @import("commands.zig");

pub fn request(a: std.mem.Allocator, io: std.Io) !void {
    const result = try commands.run(a, io, .{
        .argv = &.{ "aqueousctl", "session", "reload", "--json" },
        .stdout_limit = .limited(4096),
    });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ReloadFailed,
        else => return error.ReloadFailed,
    }
    try confirm(a, result.stdout);
}

fn confirm(a: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ReloadNotConfirmed;
    const ok = parsed.value.object.get("ok") orelse return error.ReloadNotConfirmed;
    const status = parsed.value.object.get("status") orelse return error.ReloadNotConfirmed;
    if (ok != .bool or !ok.bool or status != .string or !std.mem.eql(u8, status.string, "applied")) return error.ReloadNotConfirmed;
}

test "reload requires an applied acknowledgement, not just command success" {
    try confirm(std.testing.allocator, "{\"ok\":true,\"status\":\"applied\",\"sequence\":\"2\"}\n");
    for ([_][]const u8{ "{}", "null", "{\"ok\":true,\"status\":\"accepted\"}", "{\"ok\":false,\"status\":\"applied\"}", "{\"ok\":true,\"status\":\"unsupported\"}" }) |bytes| {
        try std.testing.expectError(error.ReloadNotConfirmed, confirm(std.testing.allocator, bytes));
    }
}

pub fn requestRecorded(a: std.mem.Allocator, io: std.Io, state: *@import("control.zig").Control) !void {
    var client = @import("display_config").ipc.Client.open(a) catch return request(a, io);
    defer client.close();
    const bytes = try client.call(a, "command", .{ .action = "session.reload", .fields = struct {}{} });
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const status = obj.get("status") orelse return error.ReloadNotConfirmed;
    if (status != .string or !std.mem.eql(u8, status.string, "applied")) return error.ReloadNotConfirmed;
    const generation = obj.get("loaded_generation") orelse return error.ReloadNotConfirmed;
    const digest = obj.get("candidate_digest") orelse return error.ReloadNotConfirmed;
    const session = obj.get("session") orelse return error.ReloadNotConfirmed;
    const sequence = obj.get("sequence") orelse return error.ReloadNotConfirmed;
    if (generation != .string or digest != .string or session != .string or sequence != .string or
        generation.string.len != 16 or digest.string.len != 64 or session.string.len != 32 or sequence.string.len > 20) return error.ReloadNotConfirmed;
    state.reload_session = session.string[0..32].*;
    state.reload_generation = generation.string[0..16].*;
    state.reload_digest = digest.string[0..64].*;
    @memcpy(state.reload_sequence[0..sequence.string.len], sequence.string);
    state.reload_sequence_len = sequence.string.len;
    if (state.after_generation) |expected| if (!std.mem.eql(u8, generation.string, &expected)) return error.ReloadGenerationMismatch;
    if (state.candidate_digest) |expected| if (!std.mem.eql(u8, digest.string, &expected)) return error.ReloadGenerationMismatch;
}
