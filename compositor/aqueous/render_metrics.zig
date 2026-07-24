// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const wlr = @import("wlroots");

var enabled_cache: ?bool = null;
var gpu_enabled_cache: ?bool = null;

fn environmentFlag(name: [*:0]const u8) bool {
    return if (std.c.getenv(name)) |raw| blk: {
        const text = std.mem.span(raw);
        break :blk text.len != 0 and
            !std.mem.eql(u8, text, "0") and
            !std.ascii.eqlIgnoreCase(text, "false");
    } else false;
}

pub fn enabled() bool {
    if (enabled_cache) |value| return value;
    const value = environmentFlag("AQUEOUS_RENDER_METRICS");
    enabled_cache = value;
    return value;
}

fn gpuEnabled() bool {
    if (gpu_enabled_cache) |value| return value;
    const value = environmentFlag("AQUEOUS_RENDER_GPU_METRICS");
    gpu_enabled_cache = value;
    return value;
}

pub const SceneSample = struct {
    timer: wlr.SceneTimer = .{
        .pre_render_duration = 0,
        .render_timer = null,
    },

    pub fn finish(sample: *SceneSample, output_name: []const u8) void {
        const duration_ns = if (gpuEnabled())
            sample.timer.getDurationNs()
        else
            -1;
        std.log.info(
            "render-metric kind=scene output={s} duration_ns={d} pre_render_ns={d}",
            .{ output_name, duration_ns, sample.timer.pre_render_duration },
        );
        sample.timer.finish();
    }

    pub fn discard(sample: *SceneSample) void {
        sample.timer.finish();
    }
};

pub const BlurCacheEvent = enum {
    create,
    configure_dirty,
    damage_dirty,
    enable,
    disable,
    destroy,
};

pub fn recordBlurCache(event: BlurCacheEvent) void {
    if (!enabled()) return;
    std.log.info("render-metric kind=blur-cache event={s}", .{@tagName(event)});
}

pub const VulkanEffectsSample = struct {
    gpu_duration_ns: u64,
    cache_hits: u32,
    cache_partial_rebuilds: u32,
    cache_full_rebuilds: u32,
    pixels_processed: u64,

    pub fn record(sample: VulkanEffectsSample, output_name: []const u8) void {
        if (!enabled()) return;
        std.log.info(
            "render-metric kind=vulkan-effects output={s} duration_ns={d} cache_hits={d} cache_partial_rebuilds={d} cache_full_rebuilds={d} pixels_processed={d}",
            .{
                output_name,
                sample.gpu_duration_ns,
                sample.cache_hits,
                sample.cache_partial_rebuilds,
                sample.cache_full_rebuilds,
                sample.pixels_processed,
            },
        );
    }
};
