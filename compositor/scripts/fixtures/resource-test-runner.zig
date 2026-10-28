// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const builtin = @import("builtin");
pub const std_options: std.Options = .{ .log_level = .warn };

// Route production heap allocations through the leak-checking test allocator.
var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
pub const aqueous_test_allocator = allocations.allocator();

export fn aqueous_heap_fail_after(count: usize) void {
    allocations.fail_index = allocations.alloc_index + count;
}
export fn aqueous_heap_allow() void {
    allocations.fail_index = std.math.maxInt(usize);
}
export fn aqueous_heap_live_bytes() usize {
    return allocations.allocated_bytes - allocations.freed_bytes;
}

// Fault injection deliberately logs production errors. Print them normally;
// test assertions and allocator diagnostics determine success, not log level.
pub fn main(init: std.process.Init.Minimal) !void {
    var failed = false;
    for (builtin.test_functions) |entry| {
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        allocations = .init(std.testing.allocator, .{});
        std.testing.io_instance = .init(std.testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
        std.testing.environ = init.environ;
        entry.func() catch |err| {
            std.debug.print("FAIL {s}: {t}\n", .{ entry.name, err });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            failed = true;
        };
        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() != 0) failed = true;
        // Stop on failure so leaked mock handles cannot contaminate later tests.
        if (failed) return error.ResourceTestFailed;
    }
    std.debug.print("{d} resource tests passed, no heap leaks\n", .{builtin.test_functions.len});
}
