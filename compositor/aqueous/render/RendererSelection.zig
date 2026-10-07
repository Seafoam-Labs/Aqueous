// SPDX-License-Identifier: GPL-3.0-only
//! Startup candidates outlive rejected Server instances. No clients are started
//! until a candidate has initialized effects, an allocator and presentation.
const Selection = @This();
const std = @import("std");
const c = @import("c");
const wlr = @import("wlroots");
const build_options = @import("build_options");
const VulkanContext = if (build_options.vulkan_effects) @import("VulkanContext.zig") else void;
const Candidates = if (build_options.vulkan_effects) c.struct_wlr_vk_renderer_candidates else opaque {};

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

candidates: ?*Candidates = null,
attempt: usize = 0,

pub const Resources = struct {
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    context: VulkanContext,

    fn init(backend: *wlr.Backend, renderer: *wlr.Renderer, attempt: usize) !Resources {
        errdefer renderer.destroy();
        if (testFails(attempt, "renderer")) return error.InjectedRendererFailure;
        var context = if (comptime build_options.vulkan_effects) try VulkanContext.init(renderer) else {};
        errdefer if (comptime build_options.vulkan_effects) context.deinit();
        if (testFails(attempt, "effects")) return error.InjectedEffectsFailure;
        const allocator = try wlr.Allocator.autocreate(backend, renderer);
        errdefer allocator.destroy();
        if (testFails(attempt, "allocator")) return error.InjectedAllocatorFailure;
        return .{ .renderer = renderer, .allocator = allocator, .context = context };
    }
};

pub fn deinit(selection: *Selection) void {
    if (comptime build_options.vulkan_effects) c.wlr_vk_renderer_candidates_destroy(selection.candidates);
    selection.* = .{};
}

pub fn next(selection: *Selection, backend: *wlr.Backend) !Resources {
    if (comptime !build_options.vulkan_effects) {
        if (selection.attempt != 0) return error.RendererUnavailable;
        selection.attempt += 1;
        return Resources.init(backend, try wlr.Renderer.autocreate(backend), selection.attempt);
    }
    const presentation = try @import("Presentation.zig").mode();
    // Preserve the Vulkan policy for any internal wlroots renderers too (for
    // example a secondary DRM backend's blit renderer).
    if (setenv("WLR_RENDERER", "vulkan", 1) != 0) return error.VulkanRendererSelectionFailed;
    if (selection.candidates == null) {
        // WLR_RENDERER cannot bypass the Vulkan-only contract.
        selection.candidates = c.wlr_vk_renderer_candidates_create(@ptrCast(backend), presentation != .direct) orelse
            return error.VulkanRendererUnavailable;
    }
    while (c.wlr_vk_renderer_candidates_next(selection.candidates)) |raw| {
        selection.attempt += 1;
        const renderer: *wlr.Renderer = @ptrCast(raw);
        if (presentation == .direct and c.wlr_vk_renderer_requires_copy(raw)) {
            renderer.destroy();
            std.log.warn("Vulkan candidate requires copy; direct presentation requested", .{});
            continue;
        }
        return Resources.init(backend, renderer, selection.attempt) catch |err| {
            std.log.warn("Vulkan candidate rejected during initialization: {s}", .{@errorName(err)});
            continue;
        };
    }
    return error.VulkanRendererUnavailable;
}

pub fn recover(backend: *wlr.Backend, old: *wlr.Renderer) !Resources {
    const renderer: *wlr.Renderer = if (comptime build_options.vulkan_effects)
        @ptrCast(c.wlr_vk_renderer_recreate(@ptrCast(old)) orelse return error.VulkanRendererUnavailable)
    else
        try wlr.Renderer.autocreate(backend);
    return Resources.init(backend, renderer, 0);
}

/// Test builds only: fail a candidate after real resource creation, so normal
/// rollback is exercised. Example: 1:effects,2:allocator,3:commit.
pub fn testFails(attempt: usize, phase: []const u8) bool {
    if (comptime !build_options.output_retry_testing) return false;
    if (attempt == 0) return false;
    const raw = std.c.getenv("AQUEOUS_TEST_VULKAN_FAILURES") orelse return false;
    var entries = std.mem.splitScalar(u8, std.mem.span(raw), ',');
    while (entries.next()) |entry| {
        var parts = std.mem.splitScalar(u8, entry, ':');
        const index = std.fmt.parseInt(usize, parts.next() orelse continue, 10) catch continue;
        if (index == attempt and std.mem.eql(u8, parts.next() orelse continue, phase)) return true;
    }
    return false;
}
