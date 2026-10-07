// SPDX-License-Identifier: GPL-3.0-only
//! Presentation experiments are opt-in until physical and VM qualification passes.
const std = @import("std");
const build_options = @import("build_options");
const c = @import("c");
const wlr = @import("wlroots");

pub const Mode = enum { direct, auto, copy };

pub fn mode() !Mode {
    const raw = std.c.getenv("AQUEOUS_VULKAN_PRESENTATION") orelse
        return if (build_options.experimental_presentation) .auto else .direct;
    const selected = std.meta.stringToEnum(Mode, std.mem.span(raw)) orelse
        return error.InvalidPresentationMode;
    if (selected != .direct and !build_options.experimental_presentation)
        return error.ExperimentalPresentationDisabled;
    return selected;
}

pub fn configure(output: *wlr.Output) !void {
    if (comptime !build_options.vulkan_effects) return;
    const selected = try mode();
    if (selected == .direct) {
        if (c.wlr_vk_renderer_requires_copy(@ptrCast(output.renderer.?)))
            return error.ExperimentalPresentationDisabled;
        return;
    }
    if (!c.wlr_output_allow_presentation_copy(@ptrCast(output), true))
        return error.PresentationInitializationFailed;
    if (selected == .copy or c.wlr_vk_renderer_requires_copy(@ptrCast(output.renderer.?))) {
        if (!c.wlr_output_try_presentation_copy(@ptrCast(output)))
            return error.PresentationCopyUnavailable;
    }
}

pub fn tryCopy(output: *wlr.Output) bool {
    if (comptime !build_options.experimental_presentation or !build_options.vulkan_effects) return false;
    return c.wlr_output_try_presentation_copy(@ptrCast(output));
}

pub fn usesCopy(output: *wlr.Output) bool {
    return c.wlr_output_uses_presentation_copy(@ptrCast(output));
}

pub fn name(output: *wlr.Output) []const u8 {
    if (!usesCopy(output)) return "direct";
    return if (c.wlr_output_presentation_copy_committed(@ptrCast(output))) "cpu-copy" else "cpu-copy-pending";
}
