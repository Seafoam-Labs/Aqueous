const std = @import("std");
const j = @import("json.zig");
pub const choices = [_][]const u8{ "tile", "monocle", "grid", "rows", "dwindle", "reverse-dwindle", "scrolling", "stacking", "game-mode", "composable" };
pub const State = struct {
    generation: u64 = 0,
    workspace: ?u32 = null,
    active: ?usize = null,
    selected: ?usize = null,
    pending: bool = false,
    failed: bool = false,

    pub fn reset(self: *State) void {
        self.* = .{ .generation = self.generation +% 1 };
    }
    pub fn choose(self: *State, index: usize) void {
        if (index >= choices.len) return;
        self.selected = index;
        self.pending = self.active != index;
    }
    pub fn accept(self: *State, response: j.Value, output: []const u8, generation: u64) !void {
        if (generation != self.generation) return;
        if (!j.boolean(j.get(response, "ok")) or !std.mem.eql(u8, j.text(response, "output"), output)) return error.InvalidLayoutResponse;
        const workspace = j.get(response, "workspace");
        if (workspace != .integer or workspace.integer < 0 or workspace.integer > std.math.maxInt(u32)) return error.InvalidLayoutResponse;
        const name = j.text(response, "layout");
        const canonical = if (std.mem.eql(u8, name, "float") or std.mem.eql(u8, name, "floating") or std.mem.eql(u8, name, "stack")) "stacking" else name;
        const index = for (choices, 0..) |choice, i| {
            if (std.mem.eql(u8, choice, canonical)) break i;
        } else return error.UnknownRuntimeLayout;
        const next_workspace: u32 = @intCast(workspace.integer);
        if (self.workspace != next_workspace or self.failed) self.pending = false;
        self.workspace = next_workspace;
        self.active = index;
        self.failed = false;
        if (!self.pending) self.selected = index;
        if (self.selected == self.active) self.pending = false;
    }
};

test "live layout follows compositor and preserves an unapplied choice only on the same workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    try std.testing.expectEqual(@as(?usize, null), state.selected);
    const live = try j.parse(a, "{\"ok\":true,\"output\":\"DP-1\",\"workspace\":2,\"layout\":\"game-mode\"}");
    try state.accept(live, "DP-1", 0);
    try std.testing.expectEqualStrings("game-mode", choices[state.selected.?]);
    state.choose(2);
    try state.accept(live, "DP-1", 0);
    try std.testing.expectEqualStrings("grid", choices[state.selected.?]);
    try state.accept(try j.parse(a, "{\"ok\":true,\"output\":\"DP-1\",\"workspace\":3,\"layout\":\"scrolling\"}"), "DP-1", 0);
    try std.testing.expectEqualStrings("scrolling", choices[state.selected.?]);
    state.reset();
    try state.accept(live, "DP-1", 0);
    try std.testing.expectEqual(@as(?usize, null), state.selected);
    try std.testing.expectError(error.InvalidLayoutResponse, state.accept(live, "HDMI-A-1", 1));
    try std.testing.expectError(error.InvalidLayoutResponse, state.accept(.null, "DP-1", 1));
}

test "floating aliases populate the supported stacking choice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{};
    try state.accept(try j.parse(arena.allocator(), "{\"ok\":true,\"output\":\"DP-1\",\"workspace\":1,\"layout\":\"float\"}"), "DP-1", 0);
    try std.testing.expectEqualStrings("stacking", choices[state.selected.?]);
}
