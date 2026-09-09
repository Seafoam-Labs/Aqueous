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
