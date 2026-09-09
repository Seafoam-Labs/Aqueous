const std = @import("std");
extern fn aq_now_ms() i64;
pub const Phase = enum(u8) { preparing, cancelled, committing, synchronizing, done };
pub const ReloadStatus = enum { not_requested, applied, failed };
pub const Control = struct {
    phase: std.atomic.Value(Phase) = .init(.preparing),
    deadline_ms: i64,
    writing: bool = false,
    saved: bool = false,
    reload: ReloadStatus = .not_requested,
    pub fn init() Control {
        return .{ .deadline_ms = aq_now_ms() + 30000 };
    }
    pub fn cancel(self: *Control) bool {
        return self.phase.cmpxchgStrong(.preparing, .cancelled, .acq_rel, .acquire) == null;
    }
};
pub threadlocal var current: ?*Control = null;
pub fn check() !void {
    if (current) |c| {
        if (c.phase.load(.acquire) == .cancelled) return error.Cancelled;
        if (aq_now_ms() >= c.deadline_ms) return error.OperationTimedOut;
    }
}
pub fn beginCommit() !void {
    try check();
    if (current) |c| if (c.phase.cmpxchgStrong(.preparing, .committing, .acq_rel, .acquire) != null) return error.Cancelled;
}
pub fn markWriting() void {
    if (current) |c| {
        c.writing = true;
    }
}
pub fn markSaved() void {
    if (current) |c| {
        c.saved = true;
        c.phase.store(.synchronizing, .release);
    }
}
pub fn commandTimeout() !c_int {
    try check();
    return if (current) |c| @intCast(@min(5000, @max(1, c.deadline_ms - aq_now_ms()))) else 5000;
}
test "cancellation cannot interrupt committing files" {
    var c = Control.init();
    current = &c;
    defer current = null;
    try beginCommit();
    try std.testing.expect(!c.cancel());
    markWriting();
    markSaved();
    try std.testing.expect(c.saved and c.writing);
}
test "cancel and deadline stop before writes" {
    var c = Control.init();
    current = &c;
    defer current = null;
    try std.testing.expect(c.cancel());
    try std.testing.expectError(error.Cancelled, beginCommit());
    try std.testing.expect(!c.writing);
    c = Control.init();
    c.deadline_ms = 0;
    try std.testing.expectError(error.OperationTimedOut, beginCommit());
}
