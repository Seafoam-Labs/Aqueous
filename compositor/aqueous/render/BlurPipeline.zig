// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const BlurPipeline = @This();

const std = @import("std");
const c = @import("c");

const util = @import("../util.zig");
const BlurCache = @import("BlurCache.zig");
const EffectMetadata = @import("EffectMetadata.zig");

const fullscreen_vertex_shader align(4) =
    @embedFile("shaders/blur_fullscreen.vert.spv").*;
const downsample_fragment_shader align(4) =
    @embedFile("shaders/blur_downsample.frag.spv").*;
const separable_fragment_shader align(4) =
    @embedFile("shaders/blur_separable.frag.spv").*;
const composite_vertex_shader align(4) =
    @embedFile("shaders/blur_composite.vert.spv").*;
const composite_fragment_shader align(4) =
    @embedFile("shaders/blur_composite.frag.spv").*;

const OffscreenPush = extern struct {
    data: [4]f32,
    sample_bounds: [4]f32,
};

const CompositePush = extern struct {
    box: [4]f32,
    radii: [4]f32,
    output_data: [4]f32,
    appearance_data: [4]f32,
    sample_bounds: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(OffscreenPush) == 32);
    std.debug.assert(@sizeOf(CompositePush) == 80);
}

pub const Kernel = EffectMetadata.BlurKernel;
pub const Appearance = EffectMetadata.BlurAppearance;

pub const Effect = struct {
    box: c.struct_wlr_box,
    radii: [4]f32,
};

const Image = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    framebuffer: c.VkFramebuffer,
    initialized: bool = false,
};

const Resources = struct {
    width: u32,
    height: u32,
    source_view: c.VkImageView,
    source_descriptor: c.VkDescriptorSet,
    half_extent: c.VkExtent2D,
    ping: Image,
    pong: Image,
    ping_descriptor: c.VkDescriptorSet,
    pong_descriptor: c.VkDescriptorSet,

    fn deinit(resources: *Resources, pipeline: *BlurPipeline) void {
        const descriptors = [_]c.VkDescriptorSet{
            resources.source_descriptor,
            resources.ping_descriptor,
            resources.pong_descriptor,
        };
        pipeline.freeDescriptors(&descriptors);
        destroyImage(pipeline.device, resources.ping);
        destroyImage(pipeline.device, resources.pong);
    }
};

const CompositePipeline = struct {
    render_pass: c.VkRenderPass,
    subpass: u32,
    pipeline: c.VkPipeline,
};

const OffscreenCall = struct {
    pipeline: *BlurPipeline,
    kernel: Kernel,
    domain: c.struct_wlr_box,
    resources: ?*Resources = null,
    failed: bool = false,
};

const CacheImage = struct {
    device: c.VkDevice,
    image: Image,
    descriptor: c.VkDescriptorSet,
    extent: c.VkExtent2D,
    inflight: u32 = 0,
    retired: bool = false,
};

const CacheEntry = struct {
    key: u64,
    resource: ?*CacheImage = null,
    effect: Effect,
    window_generation: u64 = 0,
    config_generation: u64 = 0,
    invalidation_generation: u64 = 0,
    kernel_passes: u32 = 0,
    kernel_sample_step: f32 = 0,
    last_seen_frame: u64 = 0,
};

pub const CacheStats = struct {
    hits: u32 = 0,
    partial_rebuilds: u32 = 0,
    full_rebuilds: u32 = 0,
    pixels_processed: u64 = 0,
};

pub const OutputCache = struct {
    entries: std.ArrayList(CacheEntry) = .empty,
    damage: c.pixman_region32_t = std.mem.zeroes(c.pixman_region32_t),
    damage_initialized: bool = false,
    frame: u64 = 0,
    stats: CacheStats = .{},

    pub fn beginFrame(
        cache: *OutputCache,
        damage: ?*const c.pixman_region32_t,
    ) void {
        cache.frame +%= 1;
        if (cache.frame == 0) cache.frame = 1;
        if (!cache.damage_initialized) {
            c.pixman_region32_init(&cache.damage);
            cache.damage_initialized = true;
        }
        if (damage) |region| {
            _ = c.pixman_region32_copy(&cache.damage, region);
        } else {
            c.pixman_region32_clear(&cache.damage);
        }
        cache.stats = .{};
    }

    pub fn markVisible(cache: *OutputCache, key: u64) bool {
        for (cache.entries.items) |*entry| {
            if (entry.key != key) continue;
            entry.last_seen_frame = cache.frame;
            return entry.resource != null;
        }
        return false;
    }

    pub fn removeInvisible(
        cache: *OutputCache,
        pipeline: *BlurPipeline,
    ) void {
        var index: usize = 0;
        while (index < cache.entries.items.len) {
            const entry = &cache.entries.items[index];
            if (entry.last_seen_frame != cache.frame) {
                pipeline.retireCacheImage(entry.resource);
                _ = cache.entries.swapRemove(index);
                continue;
            }
            index += 1;
        }
    }

    pub fn clear(cache: *OutputCache, pipeline: *BlurPipeline) void {
        for (cache.entries.items) |entry| {
            pipeline.retireCacheImage(entry.resource);
        }
        cache.entries.clearRetainingCapacity();
        if (cache.damage_initialized) {
            c.pixman_region32_clear(&cache.damage);
        }
    }

    pub fn deinit(cache: *OutputCache, pipeline: *BlurPipeline) void {
        cache.clear(pipeline);
        if (cache.damage_initialized) {
            c.pixman_region32_fini(&cache.damage);
            cache.damage_initialized = false;
        }
        cache.entries.deinit(util.gpa);
    }
};

const CachedOffscreenCall = struct {
    pipeline: *BlurPipeline,
    kernel: Kernel,
    target: *CacheImage,
    update: c.struct_wlr_box,
    domain: c.struct_wlr_box,
    pixels_processed: u64 = 0,
    failed: bool = false,
};

const CacheUse = struct {
    resource: *CacheImage,
};

physical_device: c.VkPhysicalDevice,
device: c.VkDevice,
pipeline_cache: c.VkPipelineCache,
sampler: c.VkSampler,
descriptor_set_layout: c.VkDescriptorSetLayout,
descriptor_pool: c.VkDescriptorPool,
pipeline_layout: c.VkPipelineLayout,
offscreen_render_pass: c.VkRenderPass,
downsample_pipeline: c.VkPipeline,
separable_pipeline: c.VkPipeline,
resources: std.ArrayList(Resources) = .empty,
composite_pipelines: std.ArrayList(CompositePipeline) = .empty,
checkpoint_count: u64 = 0,
offscreen_draw_count: u64 = 0,
composite_draw_count: u64 = 0,
cache_hit_count: u64 = 0,
cache_partial_rebuild_count: u64 = 0,
cache_full_rebuild_count: u64 = 0,
cache_pixels_processed: u64 = 0,
scratch_resource_create_count: u64 = 0,
image_allocation_count: u64 = 0,
descriptor_allocation_count: u64 = 0,
cache_image_create_count: u64 = 0,

pub const resolveKernel = EffectMetadata.resolveBlurKernel;

pub fn recordCacheHits(
    pipeline: *BlurPipeline,
    cache: *OutputCache,
    count: u32,
) void {
    cache.stats.hits += count;
    pipeline.cache_hit_count += count;
}

pub fn init(
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    pipeline_cache: c.VkPipelineCache,
) !BlurPipeline {
    const sampler = try createSampler(device);
    errdefer c.vkDestroySampler(device, sampler, null);

    const descriptor_set_layout = try createDescriptorSetLayout(device);
    errdefer c.vkDestroyDescriptorSetLayout(
        device,
        descriptor_set_layout,
        null,
    );

    const descriptor_pool = try createDescriptorPool(device);
    errdefer c.vkDestroyDescriptorPool(device, descriptor_pool, null);

    const pipeline_layout = try createPipelineLayout(
        device,
        descriptor_set_layout,
    );
    errdefer c.vkDestroyPipelineLayout(device, pipeline_layout, null);

    const offscreen_render_pass = try createOffscreenRenderPass(device);
    errdefer c.vkDestroyRenderPass(device, offscreen_render_pass, null);

    var pipeline: BlurPipeline = .{
        .physical_device = physical_device,
        .device = device,
        .pipeline_cache = pipeline_cache,
        .sampler = sampler,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_pool = descriptor_pool,
        .pipeline_layout = pipeline_layout,
        .offscreen_render_pass = offscreen_render_pass,
        .downsample_pipeline = null,
        .separable_pipeline = null,
    };
    errdefer pipeline.deinit();

    pipeline.downsample_pipeline = try pipeline.createGraphicsPipeline(
        offscreen_render_pass,
        0,
        &fullscreen_vertex_shader,
        &downsample_fragment_shader,
        false,
    );
    pipeline.separable_pipeline = try pipeline.createGraphicsPipeline(
        offscreen_render_pass,
        0,
        &fullscreen_vertex_shader,
        &separable_fragment_shader,
        false,
    );
    std.log.info("Vulkan backdrop-blur pipeline initialized", .{});
    return pipeline;
}

pub fn deinit(pipeline: *BlurPipeline) void {
    const composite_pipeline_count = pipeline.composite_pipelines.items.len;
    for (pipeline.composite_pipelines.items) |entry| {
        c.vkDestroyPipeline(pipeline.device, entry.pipeline, null);
    }
    pipeline.composite_pipelines.deinit(util.gpa);
    _ = pipeline.clearScratchResources();
    pipeline.resources.deinit(util.gpa);

    if (pipeline.separable_pipeline != null) {
        c.vkDestroyPipeline(
            pipeline.device,
            pipeline.separable_pipeline,
            null,
        );
    }
    if (pipeline.downsample_pipeline != null) {
        c.vkDestroyPipeline(
            pipeline.device,
            pipeline.downsample_pipeline,
            null,
        );
    }
    c.vkDestroyRenderPass(pipeline.device, pipeline.offscreen_render_pass, null);
    c.vkDestroyPipelineLayout(pipeline.device, pipeline.pipeline_layout, null);
    c.vkDestroyDescriptorPool(pipeline.device, pipeline.descriptor_pool, null);
    c.vkDestroyDescriptorSetLayout(
        pipeline.device,
        pipeline.descriptor_set_layout,
        null,
    );
    c.vkDestroySampler(pipeline.device, pipeline.sampler, null);
    std.log.info(
        "destroyed Vulkan blur after {d} checkpoints, {d} offscreen draws, and {d} composites ({d} cache hits, {d} partial rebuilds, {d} full rebuilds, {d} pixels processed)",
        .{
            pipeline.checkpoint_count,
            pipeline.offscreen_draw_count,
            pipeline.composite_draw_count,
            pipeline.cache_hit_count,
            pipeline.cache_partial_rebuild_count,
            pipeline.cache_full_rebuild_count,
            pipeline.cache_pixels_processed,
        },
    );
    std.log.info(
        "Vulkan blur resources created: {d} scratch sets, {d} images, {d} descriptors, {d} cache images, {d} composite pipelines",
        .{
            pipeline.scratch_resource_create_count,
            pipeline.image_allocation_count,
            pipeline.descriptor_allocation_count,
            pipeline.cache_image_create_count,
            composite_pipeline_count,
        },
    );
}

/// Discard scratch images and descriptors tied to wlroots render-buffer image
/// views. The caller must ensure that all queue submissions using these
/// resources have completed before calling this function.
pub fn clearScratchResources(pipeline: *BlurPipeline) usize {
    const count = pipeline.resources.items.len;
    for (pipeline.resources.items) |*resources| {
        resources.deinit(pipeline);
    }
    pipeline.resources.clearRetainingCapacity();
    return count;
}

pub fn render(
    pipeline: *BlurPipeline,
    render_pass: *c.struct_wlr_render_pass,
    effect: Effect,
    render_region: *const c.pixman_region32_t,
    radius: c_int,
    passes: c_int,
    scale: f32,
    appearance: Appearance,
) !bool {
    const kernel = resolveKernel(radius, passes, scale) orelse return false;
    if (effect.box.width <= 0 or effect.box.height <= 0) return false;

    var call: OffscreenCall = .{
        .pipeline = pipeline,
        .kernel = kernel,
        .domain = effect.box,
    };
    if (!c.wlr_vk_render_pass_run_offscreen(
        render_pass,
        offscreenCallback,
        &call,
    ) or call.failed) {
        return error.VulkanBlurOffscreenFailed;
    }

    const resources = call.resources orelse
        return error.VulkanBlurOffscreenFailed;
    if (!try pipeline.composite(
        render_pass,
        effect,
        render_region,
        resources.ping_descriptor,
        appearance,
    )) return false;
    pipeline.checkpoint_count += 1;
    return true;
}

pub fn renderCached(
    pipeline: *BlurPipeline,
    cache: *OutputCache,
    render_pass: *c.struct_wlr_render_pass,
    key: u64,
    effect: Effect,
    render_region: *const c.pixman_region32_t,
    window_generation: u64,
    config_generation: u64,
    invalidation_generation: u64,
    radius: c_int,
    passes: c_int,
    scale: f32,
    appearance: Appearance,
) !bool {
    const kernel = resolveKernel(radius, passes, scale) orelse return false;
    if (effect.box.width <= 0 or effect.box.height <= 0) return false;

    var attributes = std.mem.zeroes(c.struct_wlr_vk_render_pass_attribs);
    if (!c.wlr_vk_render_pass_get_attribs(render_pass, &attributes)) {
        return error.VulkanBlurPassAttributesUnavailable;
    }

    var entry = blk: {
        for (cache.entries.items) |*candidate| {
            if (candidate.key == key) break :blk candidate;
        }
        try cache.entries.append(util.gpa, .{
            .key = key,
            .effect = effect,
        });
        break :blk &cache.entries.items[cache.entries.items.len - 1];
    };
    entry.last_seen_frame = cache.frame;

    const half_extent: c.VkExtent2D = .{
        .width = @max(1, (attributes.extent.width + 1) / 2),
        .height = @max(1, (attributes.extent.height + 1) / 2),
    };
    var full_rebuild = entry.resource == null or
        entry.resource.?.extent.width != half_extent.width or
        entry.resource.?.extent.height != half_extent.height or
        entry.window_generation != window_generation or
        entry.config_generation != config_generation or
        entry.invalidation_generation != invalidation_generation or
        entry.kernel_passes != kernel.passes or
        entry.kernel_sample_step != kernel.sample_step or
        !std.meta.eql(entry.effect, effect);

    if (entry.resource) |resource| {
        if (resource.extent.width != half_extent.width or
            resource.extent.height != half_extent.height)
        {
            pipeline.retireCacheImage(resource);
            entry.resource = null;
        }
    }
    if (entry.resource == null) {
        entry.resource = try pipeline.createCacheImage(half_extent);
        full_rebuild = true;
    }

    const resource = entry.resource.?;
    const update_clip = clippedBox(effect.box, attributes.extent);
    if (update_clip.width <= 0 or update_clip.height <= 0) return false;

    var updates: c.pixman_region32_t = undefined;
    if (full_rebuild) {
        c.pixman_region32_init_rect(
            &updates,
            update_clip.x,
            update_clip.y,
            @intCast(update_clip.width),
            @intCast(update_clip.height),
        );
    } else {
        c.pixman_region32_init(&updates);
        if (cache.damage_initialized) {
            c.wlr_region_expand(
                &updates,
                &cache.damage,
                @intCast(@min(
                    kernel.reach,
                    @as(u32, std.math.maxInt(c_int)),
                )),
            );
            _ = c.pixman_region32_intersect_rect(
                &updates,
                &updates,
                update_clip.x,
                update_clip.y,
                @intCast(update_clip.width),
                @intCast(update_clip.height),
            );
        }
    }
    defer c.pixman_region32_fini(&updates);

    var update_count: c_int = 0;
    const update_rectangles =
        c.pixman_region32_rectangles(&updates, &update_count);
    if (update_count <= 0) {
        cache.stats.hits += 1;
        pipeline.cache_hit_count += 1;
        try pipeline.retainForPass(render_pass, resource);
        if (!try pipeline.composite(
            render_pass,
            effect,
            render_region,
            resource.descriptor,
            appearance,
        )) return false;
        pipeline.checkpoint_count += 1;
        return true;
    }

    var pixels_processed: u64 = 0;
    var update_index: usize = 0;
    while (update_index < @as(usize, @intCast(update_count))) : (update_index += 1) {
        const rectangle = update_rectangles[update_index];
        var call: CachedOffscreenCall = .{
            .pipeline = pipeline,
            .kernel = kernel,
            .target = resource,
            .domain = effect.box,
            .update = .{
                .x = rectangle.x1,
                .y = rectangle.y1,
                .width = rectangle.x2 - rectangle.x1,
                .height = rectangle.y2 - rectangle.y1,
            },
        };
        if (!c.wlr_vk_render_pass_run_offscreen(
            render_pass,
            cachedOffscreenCallback,
            &call,
        ) or call.failed) {
            return error.VulkanBlurOffscreenFailed;
        }
        pixels_processed += call.pixels_processed;
    }

    entry.effect = effect;
    entry.window_generation = window_generation;
    entry.config_generation = config_generation;
    entry.invalidation_generation = invalidation_generation;
    entry.kernel_passes = kernel.passes;
    entry.kernel_sample_step = kernel.sample_step;
    if (full_rebuild) {
        cache.stats.full_rebuilds += 1;
        pipeline.cache_full_rebuild_count += 1;
    } else {
        cache.stats.partial_rebuilds += 1;
        pipeline.cache_partial_rebuild_count += 1;
    }
    cache.stats.pixels_processed += pixels_processed;
    pipeline.cache_pixels_processed += pixels_processed;

    try pipeline.retainForPass(render_pass, resource);
    if (!try pipeline.composite(
        render_pass,
        effect,
        render_region,
        resource.descriptor,
        appearance,
    )) return false;
    pipeline.checkpoint_count += 1;
    return true;
}

fn composite(
    pipeline: *BlurPipeline,
    render_pass: *c.struct_wlr_render_pass,
    effect: Effect,
    render_region: *const c.pixman_region32_t,
    descriptor: c.VkDescriptorSet,
    appearance: Appearance,
) !bool {
    var attributes = std.mem.zeroes(c.struct_wlr_vk_render_pass_attribs);
    if (!c.wlr_vk_render_pass_get_attribs(render_pass, &attributes)) {
        return error.VulkanBlurPassAttributesUnavailable;
    }
    const graphics_pipeline = try pipeline.compositePipelineFor(&attributes);
    const push: CompositePush = .{
        .box = .{
            @floatFromInt(effect.box.x),
            @floatFromInt(effect.box.y),
            @floatFromInt(effect.box.width),
            @floatFromInt(effect.box.height),
        },
        .radii = effect.radii,
        .output_data = .{
            @floatFromInt(attributes.extent.width),
            @floatFromInt(attributes.extent.height),
            appearance.noise,
            0,
        },
        .appearance_data = .{
            appearance.contrast,
            appearance.brightness,
            appearance.vibrancy,
            appearance.vibrancy_darkness,
        },
        .sample_bounds = normalizedSampleBounds(
            halfResolutionBox(effect.box, attributes.extent),
            halfExtent(attributes.extent),
        ),
    };

    c.vkCmdBindPipeline(
        attributes.command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        graphics_pipeline,
    );
    setViewport(attributes.command_buffer, attributes.extent);
    c.vkCmdBindDescriptorSets(
        attributes.command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        pipeline.pipeline_layout,
        0,
        1,
        &descriptor,
        0,
        null,
    );
    c.vkCmdPushConstants(
        attributes.command_buffer,
        pipeline.pipeline_layout,
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(CompositePush),
        &push,
    );
    // Never write outside this marker's scene damage. Higher window nodes are
    // only redrawn inside the same region, so a wider composite would place
    // blur over retained client content on partial SDR or HDR frames.
    if (drawClipped(
        attributes.command_buffer,
        render_region,
        effect.box,
        attributes.extent,
    ) == 0) return false;
    pipeline.composite_draw_count += 1;
    return true;
}

fn offscreenCallback(
    attributes: ?*const c.struct_wlr_vk_render_offscreen_attribs,
    data: ?*anyopaque,
) callconv(.c) bool {
    const call: *OffscreenCall =
        @ptrCast(@alignCast(data orelse return false));
    const attribs = attributes orelse return false;
    const resources = call.pipeline.processOffscreen(
        attribs,
        call.kernel,
        call.domain,
    ) catch |err| {
        call.failed = true;
        std.log.err(
            "Vulkan uncached blur processing failed: {s}",
            .{@errorName(err)},
        );
        return false;
    };
    call.resources = resources;
    return true;
}

fn cachedOffscreenCallback(
    attributes: ?*const c.struct_wlr_vk_render_offscreen_attribs,
    data: ?*anyopaque,
) callconv(.c) bool {
    const call: *CachedOffscreenCall =
        @ptrCast(@alignCast(data orelse return false));
    call.pixels_processed = call.pipeline.processCachedOffscreen(
        attributes orelse return false,
        call.kernel,
        call.target,
        call.update,
        call.domain,
    ) catch |err| {
        call.failed = true;
        std.log.err(
            "Vulkan cached blur processing failed: {s}",
            .{@errorName(err)},
        );
        return false;
    };
    return true;
}

fn processCachedOffscreen(
    pipeline: *BlurPipeline,
    attributes: *const c.struct_wlr_vk_render_offscreen_attribs,
    kernel: Kernel,
    target: *CacheImage,
    update: c.struct_wlr_box,
    domain: c.struct_wlr_box,
) !u64 {
    if (attributes.command_buffer == null or
        attributes.source_image_view == null or
        attributes.source_format != c.VK_FORMAT_R16G16B16A16_SFLOAT or
        attributes.extent.width == 0 or attributes.extent.height == 0)
    {
        return error.VulkanBlurOffscreenAttributesInvalid;
    }

    const resources = try pipeline.resourcesFor(
        attributes.extent,
        attributes.source_image_view,
    );
    if (resources.half_extent.width != target.extent.width or
        resources.half_extent.height != target.extent.height)
    {
        return error.VulkanBlurCacheExtentMismatch;
    }

    const plan = BlurCache.planUpdate(
        toCacheBox(update),
        toCacheExtent(resources.half_extent),
        kernel.passes,
        kernel.tap_reach,
    );
    const clipped_domain = clippedBox(domain, attributes.extent);
    if (clipped_domain.width <= 0 or clipped_domain.height <= 0) return 0;
    const half_domain = halfResolutionBox(
        clipped_domain,
        attributes.extent,
    );
    const source_bounds = normalizedSampleBounds(
        clipped_domain,
        attributes.extent,
    );
    const half_bounds = normalizedSampleBounds(
        half_domain,
        resources.half_extent,
    );
    const final_box = fromCacheBox(plan.final);
    const downsample_box = fromCacheBox(plan.downsample);

    const downsample_push: OffscreenPush = .{ .data = .{
        @floatFromInt(attributes.extent.width),
        @floatFromInt(attributes.extent.height),
        0,
        0,
    }, .sample_bounds = source_bounds };
    pipeline.drawOffscreen(
        attributes.command_buffer,
        resources,
        &resources.ping,
        pipeline.downsample_pipeline,
        resources.source_descriptor,
        downsample_push,
        downsample_box,
    );

    const inverse_width =
        1.0 / @as(f32, @floatFromInt(resources.half_extent.width));
    const inverse_height =
        1.0 / @as(f32, @floatFromInt(resources.half_extent.height));
    var iteration: u32 = 0;
    while (iteration < kernel.passes) : (iteration += 1) {
        pipeline.drawOffscreen(
            attributes.command_buffer,
            resources,
            &resources.pong,
            pipeline.separable_pipeline,
            resources.ping_descriptor,
            .{ .data = .{
                inverse_width,
                0,
                kernel.sample_step,
                0,
            }, .sample_bounds = half_bounds },
            fromCacheBox(plan.horizontal[iteration]),
        );
        pipeline.drawOffscreen(
            attributes.command_buffer,
            resources,
            &resources.ping,
            pipeline.separable_pipeline,
            resources.pong_descriptor,
            .{ .data = .{
                0,
                inverse_height,
                kernel.sample_step,
                0,
            }, .sample_bounds = half_bounds },
            fromCacheBox(plan.vertical[iteration]),
        );
    }
    pipeline.copyToCache(
        attributes.command_buffer,
        &resources.ping,
        target,
        final_box,
    );
    return plan.pixels_processed;
}

fn processOffscreen(
    pipeline: *BlurPipeline,
    attributes: *const c.struct_wlr_vk_render_offscreen_attribs,
    kernel: Kernel,
    domain: c.struct_wlr_box,
) !*Resources {
    if (attributes.command_buffer == null or
        attributes.source_image_view == null or
        attributes.source_format != c.VK_FORMAT_R16G16B16A16_SFLOAT or
        attributes.extent.width == 0 or attributes.extent.height == 0)
    {
        return error.VulkanBlurOffscreenAttributesInvalid;
    }

    const resources = try pipeline.resourcesFor(
        attributes.extent,
        attributes.source_image_view,
    );
    const clipped_domain = clippedBox(domain, attributes.extent);
    if (clipped_domain.width <= 0 or clipped_domain.height <= 0) {
        return error.VulkanBlurOffscreenAttributesInvalid;
    }
    const half_domain = halfResolutionBox(
        clipped_domain,
        attributes.extent,
    );
    const source_bounds = normalizedSampleBounds(
        clipped_domain,
        attributes.extent,
    );
    const half_bounds = normalizedSampleBounds(
        half_domain,
        resources.half_extent,
    );

    const downsample_push: OffscreenPush = .{ .data = .{
        @floatFromInt(attributes.extent.width),
        @floatFromInt(attributes.extent.height),
        0,
        0,
    }, .sample_bounds = source_bounds };
    pipeline.drawOffscreen(
        attributes.command_buffer,
        resources,
        &resources.ping,
        pipeline.downsample_pipeline,
        resources.source_descriptor,
        downsample_push,
        fullBox(resources.half_extent),
    );

    const inverse_width =
        1.0 / @as(f32, @floatFromInt(resources.half_extent.width));
    const inverse_height =
        1.0 / @as(f32, @floatFromInt(resources.half_extent.height));
    var iteration: u32 = 0;
    while (iteration < kernel.passes) : (iteration += 1) {
        pipeline.drawOffscreen(
            attributes.command_buffer,
            resources,
            &resources.pong,
            pipeline.separable_pipeline,
            resources.ping_descriptor,
            .{ .data = .{
                inverse_width,
                0,
                kernel.sample_step,
                0,
            }, .sample_bounds = half_bounds },
            fullBox(resources.half_extent),
        );
        pipeline.drawOffscreen(
            attributes.command_buffer,
            resources,
            &resources.ping,
            pipeline.separable_pipeline,
            resources.pong_descriptor,
            .{ .data = .{
                0,
                inverse_height,
                kernel.sample_step,
                0,
            }, .sample_bounds = half_bounds },
            fullBox(resources.half_extent),
        );
    }
    return resources;
}

fn drawOffscreen(
    pipeline: *BlurPipeline,
    command_buffer: c.VkCommandBuffer,
    resources: *Resources,
    target: *Image,
    graphics_pipeline: c.VkPipeline,
    source_descriptor: c.VkDescriptorSet,
    push: OffscreenPush,
    scissor: c.struct_wlr_box,
) void {
    transitionForAttachment(command_buffer, target);
    var begin_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    begin_info.renderPass = pipeline.offscreen_render_pass;
    begin_info.framebuffer = target.framebuffer;
    begin_info.renderArea.extent = resources.half_extent;
    c.vkCmdBeginRenderPass(
        command_buffer,
        &begin_info,
        c.VK_SUBPASS_CONTENTS_INLINE,
    );
    c.vkCmdBindPipeline(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        graphics_pipeline,
    );
    setViewportAndScissor(
        command_buffer,
        resources.half_extent,
        scissor,
    );
    c.vkCmdBindDescriptorSets(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        pipeline.pipeline_layout,
        0,
        1,
        &source_descriptor,
        0,
        null,
    );
    c.vkCmdPushConstants(
        command_buffer,
        pipeline.pipeline_layout,
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(OffscreenPush),
        &push,
    );
    c.vkCmdDraw(command_buffer, 4, 1, 0, 0);
    c.vkCmdEndRenderPass(command_buffer);
    target.initialized = true;
    pipeline.offscreen_draw_count += 1;
}

fn resourcesFor(
    pipeline: *BlurPipeline,
    extent: c.VkExtent2D,
    source_view: c.VkImageView,
) !*Resources {
    for (pipeline.resources.items) |*resources| {
        if (resources.width == extent.width and
            resources.height == extent.height and
            resources.source_view == source_view)
        {
            return resources;
        }
    }

    const half_extent: c.VkExtent2D = .{
        .width = @max(1, (extent.width + 1) / 2),
        .height = @max(1, (extent.height + 1) / 2),
    };
    const ping = try pipeline.createImage(half_extent);
    errdefer destroyImage(pipeline.device, ping);
    const pong = try pipeline.createImage(half_extent);
    errdefer destroyImage(pipeline.device, pong);
    const ping_descriptor = try pipeline.allocateDescriptor(ping.view);
    const pong_descriptor = try pipeline.allocateDescriptor(pong.view);
    const source_descriptor =
        try pipeline.allocateDescriptor(source_view);

    try pipeline.resources.append(util.gpa, .{
        .width = extent.width,
        .height = extent.height,
        .source_view = source_view,
        .source_descriptor = source_descriptor,
        .half_extent = half_extent,
        .ping = ping,
        .pong = pong,
        .ping_descriptor = ping_descriptor,
        .pong_descriptor = pong_descriptor,
    });
    pipeline.scratch_resource_create_count += 1;
    return &pipeline.resources.items[pipeline.resources.items.len - 1];
}

fn allocateDescriptor(
    pipeline: *BlurPipeline,
    view: c.VkImageView,
) !c.VkDescriptorSet {
    var allocate_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    allocate_info.sType =
        c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocate_info.descriptorPool = pipeline.descriptor_pool;
    allocate_info.descriptorSetCount = 1;
    allocate_info.pSetLayouts = &pipeline.descriptor_set_layout;
    var descriptor_set: c.VkDescriptorSet = null;
    const result = c.vkAllocateDescriptorSets(
        pipeline.device,
        &allocate_info,
        &descriptor_set,
    );
    if (result != c.VK_SUCCESS) {
        return error.VulkanBlurDescriptorAllocateFailed;
    }
    pipeline.descriptor_allocation_count += 1;
    const image_info: c.VkDescriptorImageInfo = .{
        .sampler = pipeline.sampler,
        .imageView = view,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    var write = std.mem.zeroes(c.VkWriteDescriptorSet);
    write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = descriptor_set;
    write.dstBinding = 0;
    write.descriptorCount = 1;
    write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &image_info;
    c.vkUpdateDescriptorSets(pipeline.device, 1, &write, 0, null);
    return descriptor_set;
}

fn freeDescriptors(
    pipeline: *BlurPipeline,
    descriptors: []const c.VkDescriptorSet,
) void {
    if (descriptors.len == 0) return;
    const result = c.vkFreeDescriptorSets(
        pipeline.device,
        pipeline.descriptor_pool,
        @intCast(descriptors.len),
        descriptors.ptr,
    );
    if (result != c.VK_SUCCESS and result != c.VK_ERROR_DEVICE_LOST) {
        std.log.warn(
            "freeing Vulkan blur descriptors failed with result {d}",
            .{result},
        );
    }
}

fn createImage(
    pipeline: *BlurPipeline,
    extent: c.VkExtent2D,
) !Image {
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    image_info.extent = .{
        .width = extent.width,
        .height = extent.height,
        .depth = 1,
    };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
        c.VK_IMAGE_USAGE_SAMPLED_BIT |
        c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    var image: c.VkImage = null;
    var result = c.vkCreateImage(
        pipeline.device,
        &image_info,
        null,
        &image,
    );
    if (result != c.VK_SUCCESS) return error.VulkanBlurImageCreateFailed;
    errdefer c.vkDestroyImage(pipeline.device, image, null);

    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(pipeline.device, image, &requirements);
    const memory_type = findMemoryType(
        pipeline.physical_device,
        requirements.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse return error.VulkanBlurMemoryTypeUnavailable;
    var allocate_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    allocate_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocate_info.allocationSize = requirements.size;
    allocate_info.memoryTypeIndex = memory_type;
    var memory: c.VkDeviceMemory = null;
    result = c.vkAllocateMemory(
        pipeline.device,
        &allocate_info,
        null,
        &memory,
    );
    if (result != c.VK_SUCCESS) return error.VulkanBlurMemoryAllocateFailed;
    errdefer c.vkFreeMemory(pipeline.device, memory, null);
    result = c.vkBindImageMemory(pipeline.device, image, memory, 0);
    if (result != c.VK_SUCCESS) return error.VulkanBlurImageBindFailed;

    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.layerCount = 1;
    var view: c.VkImageView = null;
    result = c.vkCreateImageView(
        pipeline.device,
        &view_info,
        null,
        &view,
    );
    if (result != c.VK_SUCCESS) return error.VulkanBlurImageViewCreateFailed;
    errdefer c.vkDestroyImageView(pipeline.device, view, null);

    var framebuffer_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
    framebuffer_info.sType =
        c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    framebuffer_info.renderPass = pipeline.offscreen_render_pass;
    framebuffer_info.attachmentCount = 1;
    framebuffer_info.pAttachments = &view;
    framebuffer_info.width = extent.width;
    framebuffer_info.height = extent.height;
    framebuffer_info.layers = 1;
    var framebuffer: c.VkFramebuffer = null;
    result = c.vkCreateFramebuffer(
        pipeline.device,
        &framebuffer_info,
        null,
        &framebuffer,
    );
    if (result != c.VK_SUCCESS) return error.VulkanBlurFramebufferCreateFailed;
    pipeline.image_allocation_count += 1;

    return .{
        .image = image,
        .memory = memory,
        .view = view,
        .framebuffer = framebuffer,
    };
}

fn createCacheImage(
    pipeline: *BlurPipeline,
    extent: c.VkExtent2D,
) !*CacheImage {
    const resource = try util.gpa.create(CacheImage);
    errdefer util.gpa.destroy(resource);
    const image = try pipeline.createImage(extent);
    errdefer destroyImage(pipeline.device, image);
    resource.* = .{
        .device = pipeline.device,
        .image = image,
        .descriptor = try pipeline.allocateDescriptor(image.view),
        .extent = extent,
    };
    pipeline.cache_image_create_count += 1;
    return resource;
}

fn retireCacheImage(
    pipeline: *BlurPipeline,
    optional: ?*CacheImage,
) void {
    _ = pipeline;
    const resource = optional orelse return;
    resource.retired = true;
    if (resource.inflight == 0) destroyCacheImage(resource);
}

fn retainForPass(
    pipeline: *BlurPipeline,
    render_pass: *c.struct_wlr_render_pass,
    resource: *CacheImage,
) !void {
    _ = pipeline;
    const use = try util.gpa.create(CacheUse);
    errdefer util.gpa.destroy(use);
    use.* = .{ .resource = resource };
    if (!c.wlr_vk_render_pass_add_completion(
        render_pass,
        cacheUseComplete,
        use,
    )) {
        return error.VulkanBlurCompletionRegistrationFailed;
    }
    resource.inflight += 1;
}

fn cacheUseComplete(data: ?*anyopaque) callconv(.c) void {
    const use: *CacheUse =
        @ptrCast(@alignCast(data orelse return));
    const resource = use.resource;
    std.debug.assert(resource.inflight > 0);
    resource.inflight -= 1;
    util.gpa.destroy(use);
    if (resource.retired and resource.inflight == 0) {
        destroyCacheImage(resource);
    }
}

fn destroyCacheImage(resource: *CacheImage) void {
    destroyImage(resource.device, resource.image);
    util.gpa.destroy(resource);
}

fn copyToCache(
    pipeline: *BlurPipeline,
    command_buffer: c.VkCommandBuffer,
    source: *Image,
    target: *CacheImage,
    box: c.struct_wlr_box,
) void {
    _ = pipeline;
    transitionForTransferSource(command_buffer, source);
    transitionForTransferDestination(command_buffer, &target.image);

    const copy: c.VkImageCopy = .{
        .srcSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .srcOffset = .{ .x = box.x, .y = box.y, .z = 0 },
        .dstSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .dstOffset = .{ .x = box.x, .y = box.y, .z = 0 },
        .extent = .{
            .width = @intCast(box.width),
            .height = @intCast(box.height),
            .depth = 1,
        },
    };
    c.vkCmdCopyImage(
        command_buffer,
        source.image,
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        target.image.image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &copy,
    );
    transitionTransferToShader(command_buffer, source, true);
    transitionTransferToShader(command_buffer, &target.image, false);
    target.image.initialized = true;
}

fn compositePipelineFor(
    pipeline: *BlurPipeline,
    attributes: *const c.struct_wlr_vk_render_pass_attribs,
) !c.VkPipeline {
    for (pipeline.composite_pipelines.items) |entry| {
        if (entry.render_pass == attributes.render_pass and
            entry.subpass == attributes.subpass)
        {
            return entry.pipeline;
        }
    }
    const graphics_pipeline = try pipeline.createGraphicsPipeline(
        attributes.render_pass,
        attributes.subpass,
        &composite_vertex_shader,
        &composite_fragment_shader,
        true,
    );
    errdefer c.vkDestroyPipeline(pipeline.device, graphics_pipeline, null);
    try pipeline.composite_pipelines.append(util.gpa, .{
        .render_pass = attributes.render_pass,
        .subpass = attributes.subpass,
        .pipeline = graphics_pipeline,
    });
    return graphics_pipeline;
}

fn createGraphicsPipeline(
    pipeline: *BlurPipeline,
    render_pass: c.VkRenderPass,
    subpass: u32,
    vertex_code: []align(4) const u8,
    fragment_code: []align(4) const u8,
    blend: bool,
) !c.VkPipeline {
    const vertex_module = try createShaderModule(pipeline.device, vertex_code);
    defer c.vkDestroyShaderModule(pipeline.device, vertex_module, null);
    const fragment_module =
        try createShaderModule(pipeline.device, fragment_code);
    defer c.vkDestroyShaderModule(pipeline.device, fragment_module, null);

    var stages = [_]c.VkPipelineShaderStageCreateInfo{
        std.mem.zeroes(c.VkPipelineShaderStageCreateInfo),
        std.mem.zeroes(c.VkPipelineShaderStageCreateInfo),
    };
    stages[0].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vertex_module;
    stages[0].pName = "main";
    stages[1].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragment_module;
    stages[1].pName = "main";

    var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vertex_input.sType =
        c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    var input_assembly =
        std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
    input_assembly.sType =
        c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN;

    var viewport_state =
        std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    viewport_state.sType =
        c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    var rasterization =
        std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    rasterization.sType =
        c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterization.polygonMode = c.VK_POLYGON_MODE_FILL;
    rasterization.cullMode = c.VK_CULL_MODE_NONE;
    rasterization.frontFace = c.VK_FRONT_FACE_CLOCKWISE;
    rasterization.lineWidth = 1;

    var multisample = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    multisample.sType =
        c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisample.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    attachment.blendEnable = if (blend) c.VK_TRUE else c.VK_FALSE;
    attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
    attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
    attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
    attachment.colorWriteMask =
        c.VK_COLOR_COMPONENT_R_BIT |
        c.VK_COLOR_COMPONENT_G_BIT |
        c.VK_COLOR_COMPONENT_B_BIT |
        c.VK_COLOR_COMPONENT_A_BIT;

    var color_blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    color_blend.sType =
        c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    color_blend.attachmentCount = 1;
    color_blend.pAttachments = &attachment;

    var dynamic_states = [_]c.VkDynamicState{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
    };
    var dynamic = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    dynamic.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic.dynamicStateCount = dynamic_states.len;
    dynamic.pDynamicStates = &dynamic_states;

    var create_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    create_info.stageCount = stages.len;
    create_info.pStages = &stages;
    create_info.pVertexInputState = &vertex_input;
    create_info.pInputAssemblyState = &input_assembly;
    create_info.pViewportState = &viewport_state;
    create_info.pRasterizationState = &rasterization;
    create_info.pMultisampleState = &multisample;
    create_info.pColorBlendState = &color_blend;
    create_info.pDynamicState = &dynamic;
    create_info.layout = pipeline.pipeline_layout;
    create_info.renderPass = render_pass;
    create_info.subpass = subpass;
    create_info.basePipelineIndex = -1;

    var graphics_pipeline: c.VkPipeline = null;
    const result = c.vkCreateGraphicsPipelines(
        pipeline.device,
        pipeline.pipeline_cache,
        1,
        &create_info,
        null,
        &graphics_pipeline,
    );
    if (result != c.VK_SUCCESS) {
        std.log.err(
            "failed to create Vulkan blur pipeline: {s}",
            .{resultName(result)},
        );
        return error.VulkanBlurPipelineCreateFailed;
    }
    return graphics_pipeline;
}

fn createSampler(device: c.VkDevice) !c.VkSampler {
    var create_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    create_info.magFilter = c.VK_FILTER_LINEAR;
    create_info.minFilter = c.VK_FILTER_LINEAR;
    create_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
    create_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    create_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    create_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    var sampler: c.VkSampler = null;
    const result = c.vkCreateSampler(device, &create_info, null, &sampler);
    if (result != c.VK_SUCCESS) return error.VulkanBlurSamplerCreateFailed;
    return sampler;
}

fn createDescriptorSetLayout(
    device: c.VkDevice,
) !c.VkDescriptorSetLayout {
    var binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
    binding.binding = 0;
    binding.descriptorType =
        c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount = 1;
    binding.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
    var create_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    create_info.sType =
        c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    create_info.bindingCount = 1;
    create_info.pBindings = &binding;
    var layout: c.VkDescriptorSetLayout = null;
    const result =
        c.vkCreateDescriptorSetLayout(device, &create_info, null, &layout);
    if (result != c.VK_SUCCESS) {
        return error.VulkanBlurDescriptorLayoutCreateFailed;
    }
    return layout;
}

fn createDescriptorPool(device: c.VkDevice) !c.VkDescriptorPool {
    const pool_size: c.VkDescriptorPoolSize = .{
        .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 4096,
    };
    var create_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    create_info.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    create_info.maxSets = 4096;
    create_info.poolSizeCount = 1;
    create_info.pPoolSizes = &pool_size;
    var pool: c.VkDescriptorPool = null;
    const result =
        c.vkCreateDescriptorPool(device, &create_info, null, &pool);
    if (result != c.VK_SUCCESS) {
        return error.VulkanBlurDescriptorPoolCreateFailed;
    }
    return pool;
}

fn createPipelineLayout(
    device: c.VkDevice,
    descriptor_set_layout: c.VkDescriptorSetLayout,
) !c.VkPipelineLayout {
    const push_range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(CompositePush),
    };
    var create_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    create_info.setLayoutCount = 1;
    create_info.pSetLayouts = &descriptor_set_layout;
    create_info.pushConstantRangeCount = 1;
    create_info.pPushConstantRanges = &push_range;
    var layout: c.VkPipelineLayout = null;
    const result =
        c.vkCreatePipelineLayout(device, &create_info, null, &layout);
    if (result != c.VK_SUCCESS) {
        return error.VulkanBlurPipelineLayoutCreateFailed;
    }
    return layout;
}

fn createOffscreenRenderPass(device: c.VkDevice) !c.VkRenderPass {
    const attachment: c.VkAttachmentDescription = .{
        .flags = 0,
        .format = c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const color_reference: c.VkAttachmentReference = .{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const subpass: c.VkSubpassDescription = .{
        .flags = 0,
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_reference,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };
    const dependencies = [_]c.VkSubpassDependency{
        .{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT |
                c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT |
                c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        },
        .{
            .srcSubpass = 0,
            .dstSubpass = c.VK_SUBPASS_EXTERNAL,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
            .dependencyFlags = 0,
        },
    };
    var create_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    create_info.attachmentCount = 1;
    create_info.pAttachments = &attachment;
    create_info.subpassCount = 1;
    create_info.pSubpasses = &subpass;
    create_info.dependencyCount = dependencies.len;
    create_info.pDependencies = &dependencies;
    var render_pass: c.VkRenderPass = null;
    const result =
        c.vkCreateRenderPass(device, &create_info, null, &render_pass);
    if (result != c.VK_SUCCESS) {
        return error.VulkanBlurRenderPassCreateFailed;
    }
    return render_pass;
}

fn transitionForAttachment(
    command_buffer: c.VkCommandBuffer,
    image: *Image,
) void {
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = if (image.initialized)
        c.VK_ACCESS_SHADER_READ_BIT
    else
        0;
    barrier.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.oldLayout = if (image.initialized)
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    else
        c.VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image.image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    c.vkCmdPipelineBarrier(
        command_buffer,
        if (image.initialized)
            c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        else
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn transitionForTransferSource(
    command_buffer: c.VkCommandBuffer,
    image: *Image,
) void {
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image.image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn transitionForTransferDestination(
    command_buffer: c.VkCommandBuffer,
    image: *Image,
) void {
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = if (image.initialized)
        c.VK_ACCESS_SHADER_READ_BIT
    else
        0;
    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.oldLayout = if (image.initialized)
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    else
        c.VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image.image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    c.vkCmdPipelineBarrier(
        command_buffer,
        if (image.initialized)
            c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        else
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn transitionTransferToShader(
    command_buffer: c.VkCommandBuffer,
    image: *Image,
    source: bool,
) void {
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = if (source)
        c.VK_ACCESS_TRANSFER_READ_BIT
    else
        c.VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    barrier.oldLayout = if (source)
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
    else
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image.image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn setViewportAndScissor(
    command_buffer: c.VkCommandBuffer,
    extent: c.VkExtent2D,
    box: c.struct_wlr_box,
) void {
    setViewport(command_buffer, extent);
    _ = setScissor(command_buffer, extent, box);
}

fn setViewport(
    command_buffer: c.VkCommandBuffer,
    extent: c.VkExtent2D,
) void {
    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.width = @floatFromInt(extent.width);
    viewport.height = @floatFromInt(extent.height);
    viewport.maxDepth = 1;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
}

fn setScissor(
    command_buffer: c.VkCommandBuffer,
    extent: c.VkExtent2D,
    box: c.struct_wlr_box,
) bool {
    const left = @max(0, box.x);
    const top = @max(0, box.y);
    const right = @min(
        @as(i32, @intCast(extent.width)),
        box.x + box.width,
    );
    const bottom = @min(
        @as(i32, @intCast(extent.height)),
        box.y + box.height,
    );
    if (right <= left or bottom <= top) return false;
    const scissor: c.VkRect2D = .{
        .offset = .{ .x = left, .y = top },
        .extent = .{
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        },
    };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
    return true;
}

fn drawClipped(
    command_buffer: c.VkCommandBuffer,
    clip: *const c.pixman_region32_t,
    box: c.struct_wlr_box,
    extent: c.VkExtent2D,
) u32 {
    var count: c_int = 0;
    const rectangles = c.pixman_region32_rectangles(clip, &count);
    var draws: u32 = 0;
    var index: usize = 0;
    while (index < @as(usize, @intCast(@max(0, count)))) : (index += 1) {
        const rectangle = rectangles[index];
        const clip_box: c.struct_wlr_box = .{
            .x = rectangle.x1,
            .y = rectangle.y1,
            .width = rectangle.x2 - rectangle.x1,
            .height = rectangle.y2 - rectangle.y1,
        };
        const draw_box = intersection(box, clip_box) orelse continue;
        if (!setScissor(command_buffer, extent, draw_box)) continue;
        c.vkCmdDraw(command_buffer, 4, 1, 0, 0);
        draws += 1;
    }
    return draws;
}

fn fullBox(extent: c.VkExtent2D) c.struct_wlr_box {
    return fromCacheBox(BlurCache.fullBox(toCacheExtent(extent)));
}

fn halfExtent(extent: c.VkExtent2D) c.VkExtent2D {
    return .{
        .width = @max(1, (extent.width + 1) / 2),
        .height = @max(1, (extent.height + 1) / 2),
    };
}

fn halfResolutionBox(
    box: c.struct_wlr_box,
    full_extent: c.VkExtent2D,
) c.struct_wlr_box {
    return fromCacheBox(BlurCache.halfResolution(
        toCacheBox(box),
        toCacheExtent(halfExtent(full_extent)),
    ));
}

/// Normalized pixel-center limits for sampling one isolated blur domain.
/// Explicit shader clamps are required because the Vulkan sampler only clamps
/// at the output texture edge, not at an individual window's edge.
fn normalizedSampleBounds(
    box: c.struct_wlr_box,
    extent: c.VkExtent2D,
) [4]f32 {
    std.debug.assert(
        box.width > 0 and box.height > 0 and
            extent.width > 0 and extent.height > 0,
    );
    const inverse_width =
        1.0 / @as(f32, @floatFromInt(extent.width));
    const inverse_height =
        1.0 / @as(f32, @floatFromInt(extent.height));
    return .{
        (@as(f32, @floatFromInt(box.x)) + 0.5) * inverse_width,
        (@as(f32, @floatFromInt(box.y)) + 0.5) * inverse_height,
        (@as(f32, @floatFromInt(box.x + box.width)) - 0.5) *
            inverse_width,
        (@as(f32, @floatFromInt(box.y + box.height)) - 0.5) *
            inverse_height,
    };
}

fn clippedBox(
    box: c.struct_wlr_box,
    extent: c.VkExtent2D,
) c.struct_wlr_box {
    return fromCacheBox(BlurCache.clipped(
        toCacheBox(box),
        toCacheExtent(extent),
    ));
}

fn intersection(
    a: c.struct_wlr_box,
    b: c.struct_wlr_box,
) ?c.struct_wlr_box {
    const box = BlurCache.intersection(
        toCacheBox(a),
        toCacheBox(b),
    ) orelse return null;
    return fromCacheBox(box);
}

fn toCacheBox(box: c.struct_wlr_box) BlurCache.Box {
    return .{
        .x = box.x,
        .y = box.y,
        .width = box.width,
        .height = box.height,
    };
}

fn fromCacheBox(box: BlurCache.Box) c.struct_wlr_box {
    return .{
        .x = box.x,
        .y = box.y,
        .width = box.width,
        .height = box.height,
    };
}

fn toCacheExtent(extent: c.VkExtent2D) BlurCache.Extent {
    return .{ .width = extent.width, .height = extent.height };
}

test "blur sample bounds stop at domain pixel centers" {
    const bounds = normalizedSampleBounds(
        .{ .x = 4, .y = 2, .width = 8, .height = 4 },
        .{ .width = 16, .height = 8 },
    );
    try std.testing.expectEqualDeep(
        [4]f32{ 4.5 / 16.0, 2.5 / 8.0, 11.5 / 16.0, 5.5 / 8.0 },
        bounds,
    );
    try std.testing.expectEqualDeep(
        c.struct_wlr_box{ .x = 2, .y = 1, .width = 4, .height = 2 },
        halfResolutionBox(
            .{ .x = 4, .y = 2, .width = 8, .height = 4 },
            .{ .width = 16, .height = 8 },
        ),
    );
}

fn findMemoryType(
    physical_device: c.VkPhysicalDevice,
    allowed: u32,
    required: c.VkMemoryPropertyFlags,
) ?u32 {
    var properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &properties);
    var index: u32 = 0;
    while (index < properties.memoryTypeCount) : (index += 1) {
        const bit = @as(u32, 1) << @intCast(index);
        if (allowed & bit != 0 and
            properties.memoryTypes[index].propertyFlags & required == required)
        {
            return index;
        }
    }
    return null;
}

fn destroyImage(device: c.VkDevice, image: Image) void {
    c.vkDestroyFramebuffer(device, image.framebuffer, null);
    c.vkDestroyImageView(device, image.view, null);
    c.vkDestroyImage(device, image.image, null);
    c.vkFreeMemory(device, image.memory, null);
}

fn createShaderModule(
    device: c.VkDevice,
    code: []align(4) const u8,
) !c.VkShaderModule {
    var create_info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = code.len;
    create_info.pCode = @ptrCast(code.ptr);
    var module: c.VkShaderModule = null;
    const result =
        c.vkCreateShaderModule(device, &create_info, null, &module);
    if (result != c.VK_SUCCESS) {
        return error.VulkanBlurShaderModuleCreateFailed;
    }
    return module;
}

fn resultName(result: c.VkResult) []const u8 {
    return switch (result) {
        c.VK_SUCCESS => "VK_SUCCESS",
        c.VK_ERROR_OUT_OF_HOST_MEMORY => "VK_ERROR_OUT_OF_HOST_MEMORY",
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        c.VK_ERROR_DEVICE_LOST => "VK_ERROR_DEVICE_LOST",
        else => "unknown Vulkan result",
    };
}
