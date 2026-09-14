const std = @import("std");
const operations = @import("operations.zig");
const control = @import("control.zig");
pub const Control = control.Control;
pub const receipts = @import("receipts.zig");
pub const transaction = @import("display_config").transaction;
pub const Document = @import("config_document.zig").Document;
pub const ReloadStatus = control.ReloadStatus;
pub const Command = operations.Command;
pub const Shell = operations.Shell;
pub const writeFailure = operations.writeFailure;
pub const errorCode = operations.errorCode;
/// Caller owns allocator/I/O and keeps control alive until completion. No UI access.
pub fn execute(a: std.mem.Allocator, io: std.Io, command: Command, shell: Shell, request: []const u8, state: *Control, writer: *std.Io.Writer) !void {
    control.current = state;
    defer {
        control.current = null;
        state.phase.store(.done, .release);
    }
    const execution_error: ?anyerror = blk: {
        const lock = if (command != .version) try @import("writer_lock.zig").Lock.acquire(a, io, command == .apply) else null;
        defer if (lock) |held| held.release();
        if (lock != null) _ = try transaction.recover(a, io);
        operations.execute(a, io, command, shell, request, writer) catch |err| {
            if (!state.saved) return err;
            break :blk err;
        };
        break :blk null;
    };
    if (state.phase.load(.acquire) == .preparing or state.phase.load(.acquire) == .cancelled) try control.check();
    if (command == .apply and (state.preview_token == null or state.display == .kept)) {
        // Reload only after the complete save succeeds. A reload failure does
        // not undo saved files or turn the result into an uncertain write.
        // An unchanged Apply also permits retrying a previous failed reload.
        if (state.phase.load(.acquire) == .preparing) try control.beginCommit();
        state.phase.store(.synchronizing, .release);
        state.reload = .applied;
        (if (state.operation_id != null) @import("reload.zig").requestRecorded(a, io, state) else @import("reload.zig").request(a, io)) catch {
            state.reload = .failed;
        };
    }
    if (execution_error) |err| return err;
}
test {
    std.testing.refAllDecls(@This());
    _ = @import("config_document.zig");
    _ = @import("schema.zig");
    _ = @import("toolkit_sync.zig");
    _ = @import("cursor_sync.zig");
    _ = @import("commands.zig");
    _ = @import("reload.zig");
    _ = @import("display_config");
    _ = @import("candidate_review.zig");
}
