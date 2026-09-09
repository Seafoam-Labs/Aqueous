const std = @import("std");
const backend = @import("backend");
const process = @import("process");
const a = std.heap.page_allocator;
pub const Result = struct {
    arena: ?std.heap.ArenaAllocator = null,
    output: []const u8 = "",
    status: c_int = 0,
    exit_code: c_int = 0,
    saved: bool = false,
    reload: backend.ReloadStatus = .not_requested,
    uncertain: bool = false,
    pub fn stdout(self: *const Result) []const u8 {
        return self.output;
    }
    pub fn deinit(self: *Result) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};
pub const Client = struct {
    io: std.Io,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: Result = .{},
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(a),
    control: backend.Control = undefined,
    kind: enum { backend, external } = .backend,
    operation: []const u8 = "",
    command: backend.Command = .snapshot,
    shell: backend.Shell = .none,
    input: []const u8 = "",
    args: []const []const u8 = &.{},
    pub fn init(io: std.Io) Client {
        return .{ .io = io };
    }
    pub fn busy(self: *const Client) bool {
        return self.thread != null;
    }
    fn prepare(self: *Client, op: []const u8, input: []const u8) !void {
        if (self.busy()) return error.Busy;
        self.result.deinit();
        _ = self.arena.reset(.free_all);
        self.operation = try self.arena.allocator().dupe(u8, op);
        self.input = try self.arena.allocator().dupe(u8, input);
        self.control = backend.Control.init();
        self.done.store(false, .release);
    }
    pub fn startBackend(self: *Client, op: []const u8, shell: []const u8, input: []const u8) !void {
        try self.prepare(op, input);
        self.kind = .backend;
        self.command = if (std.mem.eql(u8, op, "inspect") or std.mem.eql(u8, op, "refresh-live")) .snapshot else std.meta.stringToEnum(backend.Command, op) orelse return error.UnknownOperation;
        self.shell = std.meta.stringToEnum(backend.Shell, shell) orelse return error.UnknownShell;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }
    pub fn start(self: *Client, op: []const u8, args: []const []const u8, input: []const u8) !void {
        try self.prepare(op, input);
        self.kind = .external;
        const argv = try self.arena.allocator().alloc([]const u8, args.len);
        for (args, 0..) |arg, i| argv[i] = try self.arena.allocator().dupe(u8, arg);
        self.args = argv;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }
    pub fn cancel(self: *Client) bool {
        return self.busy() and self.kind == .backend and self.control.cancel();
    }
    fn worker(self: *Client) void {
        var arena = std.heap.ArenaAllocator.init(a);
        const allocator = arena.allocator();
        var output: std.Io.Writer.Allocating = .init(allocator);
        var status: c_int = 0;
        var code: c_int = 0;
        if (self.kind == .backend) {
            backend.execute(allocator, self.io, self.command, self.shell, self.input, &self.control, &output.writer) catch |err| {
                output.clearRetainingCapacity();
                backend.writeFailure(&output.writer, err) catch {
                    status = 1;
                };
                code = 1;
            };
        } else {
            var external = process.run(allocator, self.args, self.input, 10000) catch process.Result{ .status = 1 };
            defer external.deinit();
            status = external.status;
            code = external.exit_code;
            output.writer.writeAll(external.stdout()) catch {
                status = 1;
            };
        }
        self.result = .{ .arena = arena, .output = output.written(), .status = status, .exit_code = code, .saved = self.kind == .backend and self.control.saved, .reload = if (self.kind == .backend) self.control.reload else .not_requested, .uncertain = self.kind == .backend and self.control.writing and code != 0 };
        self.done.store(true, .release);
    }
    pub fn poll(self: *Client) bool {
        if (self.thread == null or !self.done.load(.acquire)) return false;
        self.thread.?.join();
        self.thread = null;
        return true;
    }
    pub fn deinit(self: *Client) void {
        if (self.thread) |thread| {
            _ = self.cancel();
            thread.join();
        }
        self.result.deinit();
        self.arena.deinit();
    }
};
