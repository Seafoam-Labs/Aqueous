// Test-only driver for migrated CLI regression fixtures. Never installed by packages.
const std = @import("std");
const backend = @import("backend");
const Allocator = std.mem.Allocator;
const Command = backend.Command;
pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    var exit_code: u8 = 0;
    run(allocator, init.io, args, &response.writer) catch |err| {
        response.clearRetainingCapacity();
        backend.writeFailure(&response.writer, err) catch {};
        exit_code = 1;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll(response.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len < 2) return error.MissingCommand;
    const op = parseCommand(args[1]) orelse return error.UnknownCommand;
    const shell = std.meta.stringToEnum(backend.Shell, option(args, "--shell") orelse "noctalia") orelse return error.UnknownShell;
    var request: []const u8 = option(args, "--file") orelse "";
    if (op == .validate or op == .apply) {
        const path = option(args, "--request") orelse return error.MissingRequest;
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(io, &buffer);
        request = if (std.mem.eql(u8, path, "-")) try reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024)) else try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    }
    var control = backend.Control.init();
    try backend.execute(allocator, io, op, shell, request, &control, writer);
    if (option(args, "--report-reload")) |_| std.debug.print("reload={s}\n", .{@tagName(control.reload)});
}

fn parseCommand(value: []const u8) ?Command {
    inline for (std.meta.fields(Command)) |command_field| {
        if (std.mem.eql(u8, value, command_field.name)) return @enumFromInt(command_field.value);
    }
    return null;
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args[0..args.len -| 1], 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name)) return args[index + 1];
    }
    return null;
}
