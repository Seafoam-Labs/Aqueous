const std = @import("std");
const operations = @import("operations.zig");
const control = @import("control.zig");
pub const Control = control.Control;
pub const Document = @import("config_document.zig").Document;
pub const ReloadStatus = control.ReloadStatus;
pub const Command = operations.Command;
pub const Shell = operations.Shell;
pub const writeFailure = operations.writeFailure;
/// Caller owns allocator/I/O and keeps control alive until completion. No UI access.
pub fn execute(a: std.mem.Allocator, io: std.Io, command: Command, shell: Shell, request: []const u8, state: *Control, writer: *std.Io.Writer) !void {
    control.current = state;
    defer {
        control.current = null;
        state.phase.store(.done, .release);
    }
    try operations.execute(a, io, command, shell, request, writer);
    if (state.phase.load(.acquire) == .preparing or state.phase.load(.acquire) == .cancelled) try control.check();
    if (command == .apply) {
        // Reload only after the complete save succeeds. A reload failure does
        // not undo saved files or turn the result into an uncertain write.
        // An unchanged Apply also permits retrying a previous failed reload.
        if (state.phase.load(.acquire) == .preparing) try control.beginCommit();
        state.phase.store(.synchronizing, .release);
        state.reload = .applied;
        @import("reload.zig").request(a, io) catch {
            state.reload = .failed;
        };
    }
}
test {
    std.testing.refAllDecls(@This());
    _ = @import("config_document.zig");
    _ = @import("schema.zig");
    _ = @import("toolkit_sync.zig");
    _ = @import("cursor_sync.zig");
    _ = @import("commands.zig");
    _ = @import("reload.zig");
}
