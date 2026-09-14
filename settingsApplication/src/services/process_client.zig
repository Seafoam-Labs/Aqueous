const std = @import("std");
pub const Result = extern struct {
    out: ?[*]u8 = null,
    err: ?[*]u8 = null,
    out_len: usize = 0,
    err_len: usize = 0,
    status: c_int = 0,
    exit_code: c_int = 0,
    pub fn stdout(self: *const Result) []const u8 {
        return if (self.out) |p| p[0..self.out_len] else "";
    }
    pub fn stderr(self: *const Result) []const u8 {
        return if (self.err) |p| p[0..self.err_len] else "";
    }
    pub fn deinit(self: *Result) void {
        aq_result_free(self);
    }
};
extern fn aq_result_free(result: *Result) void;
pub fn run(a: std.mem.Allocator, args: []const []const u8, input: []const u8, timeout: c_int) !Result {
    return runLimited(a, args, input, timeout, 16 * 1024 * 1024, 64 * 1024);
}
extern fn aq_run_limits(argv: [*:null]const ?[*:0]const u8, input: [*]const u8, len: usize, timeout: c_int, out_limit: usize, err_limit: usize, result: *Result) void;
pub fn runLimited(a: std.mem.Allocator, args: []const []const u8, input: []const u8, timeout: c_int, out_limit: usize, err_limit: usize) !Result {
    const argv = try a.allocSentinel(?[*:0]const u8, args.len, null);
    defer a.free(argv);
    var count: usize = 0;
    defer for (argv[0..count]) |p| a.free(std.mem.span(p.?));
    for (args, 0..) |arg, i| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
        argv[i] = try a.dupeZ(u8, arg);
        count += 1;
    }
    var result: Result = .{};
    aq_run_limits(argv.ptr, input.ptr, input.len, timeout, out_limit, err_limit, &result);
    return result;
}

test "transport drains stderr and stdin independently and times out" {
    var result = try run(std.testing.allocator, &.{ "python3", "-c", "import sys; sys.stderr.write('e'*60000); sys.stderr.flush(); print(sys.stdin.read())" }, "literal $() `command`", 3000);
    defer result.deinit();
    try std.testing.expectEqual(@as(c_int, 0), result.status);
    try std.testing.expectEqualStrings("literal $() `command`\n", result.stdout());
    var timeout = try run(std.testing.allocator, &.{ "python3", "-c", "import time; time.sleep(5)" }, "", 60);
    defer timeout.deinit();
    try std.testing.expectEqual(@as(c_int, 2), timeout.status);
    var missing = try run(std.testing.allocator, &.{"/does-not-exist-aqueous-config"}, "", 100);
    defer missing.deinit();
    try std.testing.expectEqual(@as(c_int, 1), missing.status);
}
test "bounded transport kills children with oversized output" {
    var result = try run(std.testing.allocator, &.{ "python3", "-c", "import sys; sys.stderr.write('x'*1000000)" }, "", 2000);
    defer result.deinit();
    try std.testing.expectEqual(@as(c_int, 3), result.status);
    try std.testing.expect(result.err_len <= 64 * 1024);
}
