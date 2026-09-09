const std = @import("std");
pub const State = struct {
    scroll: [8]f32 = @splat(0),
    collapsed: std.StringHashMapUnmanaged(bool) = .empty,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        var it = self.collapsed.keyIterator();
        while (it.next()) |key| a.free(key.*);
        self.collapsed.deinit(a);
    }
    pub fn toggle(self: *State, a: std.mem.Allocator, id: []const u8) !void {
        if (self.collapsed.getPtr(id)) |v| v.* = !v.* else try self.collapsed.put(a, try a.dupe(u8, id), true);
    }
    pub fn open(self: *State, id: []const u8) void {
        if (self.collapsed.getPtr(id)) |v| v.* = false;
    }
};
