const std = @import("std");
const process = @import("process");
const control = @import("control.zig");
const Options = struct { argv: []const []const u8, stdout_limit: std.Io.Limit = .limited(16 * 1024 * 1024), stderr_limit: std.Io.Limit = .limited(64 * 1024) };
/// External programs keep their own deadline and process group. This never mutates
/// the application's environment; all backend jobs inherit the launch profile.
pub fn run(a: std.mem.Allocator, io: std.Io, options: Options) !std.process.RunResult {
    _ = io;
    var result = try process.runLimited(a, options.argv, "", try control.commandTimeout(), options.stdout_limit.toInt() orelse 16 * 1024 * 1024, options.stderr_limit.toInt() orelse 64 * 1024);
    defer result.deinit();
    switch (result.status) {
        0 => {},
        2 => return error.CommandTimedOut,
        3 => return error.StreamTooLong,
        else => return error.CommandFailed,
    }
    const stdout = try a.dupe(u8, result.stdout());
    errdefer a.free(stdout);
    const stderr = try a.dupe(u8, result.stderr());
    return .{ .stdout = stdout, .stderr = stderr, .term = if (result.exit_code >= 0) .{ .exited = @intCast(result.exit_code) } else .{ .signal = .KILL } };
}

test "external command respects the operation deadline and output bound" {
    var state = control.Control.init();
    control.current = &state;
    defer control.current = null;
    state.deadline_ms -= 29940;
    try std.testing.expectError(error.CommandTimedOut, run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "python3", "-c", "import time; time.sleep(5)" } }));
    state = control.Control.init();
    try std.testing.expectError(error.StreamTooLong, run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "python3", "-c", "print('a'*8192)" }, .stdout_limit = .limited(100) }));
}
