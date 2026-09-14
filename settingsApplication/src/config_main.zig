// Canonical configuration CLI for Pearl and other protocol-1 clients.
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

    if (response.written().len > 16 * 1024 * 1024) {
        response.clearRetainingCapacity();
        try backend.writeFailure(&response.writer, error.ResponseTooLarge);
        exit_code = 1;
    }
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll(response.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len < 2) return error.MissingCommand;
    if (@import("build_options").fault_injection) backend.transaction.fault = fault;
    if (std.mem.eql(u8, args[1], "operation-status")) {
        const id = option(args, "--operation-id") orelse return error.InvalidOperationId;
        const bytes = try backend.receipts.status(allocator, io, id);
        defer allocator.free(bytes);
        return writer.writeAll(bytes);
    }
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
    if (option(args, "--result")) |format| {
        if (op != .apply or !std.mem.eql(u8, format, "v1")) return error.InvalidResultFormat;
        if (option(args, "--operation-id")) |id| {
            control.operation_id = id;
            if (try backend.receipts.begin(allocator, io, id, @tagName(shell), request)) |bytes| {
                defer allocator.free(bytes);
                return writer.writeAll(bytes);
            }
        }
        var snapshot: std.Io.Writer.Allocating = .init(allocator);
        defer snapshot.deinit();
        var failure: ?anyerror = null;
        backend.execute(allocator, io, op, shell, request, &control, &snapshot.writer) catch |err| {
            failure = err;
        };
        var result: std.Io.Writer.Allocating = .init(allocator);
        defer result.deinit();
        try writeResult(allocator, &result.writer, &control, if (snapshot.written().len > 15 * 1024 * 1024) "" else snapshot.written(), if (snapshot.written().len > 15 * 1024 * 1024) error.SnapshotTooLarge else failure);
        if (control.operation_id) |id| try backend.receipts.finish(allocator, io, id, result.written());
        try writer.writeAll(result.written());
    } else {
        if (option(args, "--operation-id") != null) return error.InvalidResultFormat;
        try backend.execute(allocator, io, op, shell, request, &control, writer);
    }
    if (option(args, "--report-reload")) |_| std.debug.print("reload={s}\n", .{@tagName(control.reload)});
}

fn writeResult(a: Allocator, writer: *std.Io.Writer, state: *const backend.Control, snapshot: []const u8, failure: ?anyerror) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, snapshot, .{}) catch null;
    defer if (parsed) |value| value.deinit();
    const value: ?std.json.ObjectMap = if (parsed) |p| if (p.value == .object) p.value.object else null else null;
    const decision_bytes = if (state.operation_id) |id| backend.receipts.decision(a, std.Io.Threaded.global_single_threaded.io(), id) catch null else null;
    defer if (decision_bytes) |bytes| a.free(bytes);
    const decision = if (decision_bytes) |bytes| std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch null else null;
    defer if (decision) |v| v.deinit();
    const save: []const u8 = if (state.saved and state.writing) "saved" else if (state.writing) "uncertain" else if (failure != null) "failed" else "unchanged";
    try std.json.Stringify.value(.{
        .ok = failure == null,
        .protocol = 1,
        .result_version = 1,
        .save = save,
        .reload = @tagName(state.reload),
        .reload_acknowledgement = .{
            .session = if (state.reload_session) |*v| @as(?[]const u8, v) else null,
            .generation = if (state.reload_generation) |*v| @as(?[]const u8, v) else null,
            .candidate_digest = if (state.reload_digest) |*v| @as(?[]const u8, v) else null,
            .sequence = state.reload_sequence[0..state.reload_sequence_len],
        },
        .display = @tagName(state.display),
        .before_generation = if (state.before_generation) |*v| @as(?[]const u8, v) else null,
        .after_generation = if (state.saved or failure == null) if (state.after_generation) |*v| @as(?[]const u8, v) else null else null,
        .candidate_digest = if (state.candidate_digest) |*v| @as(?[]const u8, v) else null,
        .files = if (decision) |v| v.value.object.get("files") else null,
        .toolkit = .{
            .typography = if (value) |v| v.get("desktop_typography") else null,
            .cursor = if (value) |v| v.get("desktop_cursor") else null,
        },
        .snapshot = if (parsed) |p| p.value else null,
        .failure = if (failure) |err| .{ .code = backend.errorCode(err), .message = @errorName(err), .retryable = !state.writing and err == error.ConfigWriterBusy } else null,
        .operation_id = state.operation_id,
        .receipt = if (state.operation_id != null) "complete" else "unavailable",
    }, .{}, writer);
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

fn fault(label: []const u8) void {
    const wanted = std.c.getenv("AQUEOUS_TEST_CRASH_AT") orelse return;
    if (std.mem.eql(u8, label, std.mem.span(wanted))) std.process.exit(97);
}
