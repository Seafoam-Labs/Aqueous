// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

/// Context returns the highest stacked eligible direct modal child. Bound by
/// the live window count; an invalid cycle leaves the original target intact.
pub fn resolve(context: anytype, initial: u64, count: usize) u64 {
    var target = initial;
    for (0..count) |_| {
        target = context.child(target) orelse return target;
    }
    return initial;
}

const Graph = struct {
    nodes: []const Node,
    const Node = struct { handle: u64, parent: u64 = 0, eligible: bool = true };
    pub fn child(graph: Graph, parent: u64) ?u64 {
        var result: ?u64 = null;
        for (graph.nodes) |node| {
            if (node.eligible and node.parent == parent) result = node.handle;
        }
        return result;
    }
};

test "modal focus follows topmost eligible sibling then nested children" {
    const graph: Graph = .{ .nodes = &.{
        .{ .handle = 1 },                                 .{ .handle = 2, .parent = 1 },
        .{ .handle = 3, .parent = 1 },                    .{ .handle = 4, .parent = 3 },
        .{ .handle = 5, .parent = 1, .eligible = false },
    } };
    try std.testing.expectEqual(@as(u64, 4), resolve(graph, 1, graph.nodes.len));
    try std.testing.expectEqual(@as(u64, 2), resolve(graph, 2, graph.nodes.len));
    try std.testing.expectEqual(@as(u64, 99), resolve(graph, 99, graph.nodes.len));
}

test "modal focus bounds cycles and empty graphs" {
    const graph: Graph = .{ .nodes = &.{ .{ .handle = 1, .parent = 2 }, .{ .handle = 2, .parent = 1 } } };
    try std.testing.expectEqual(@as(u64, 1), resolve(graph, 1, graph.nodes.len));
    try std.testing.expectEqual(@as(u64, 7), resolve(Graph{ .nodes = &.{} }, 7, 0));
}
