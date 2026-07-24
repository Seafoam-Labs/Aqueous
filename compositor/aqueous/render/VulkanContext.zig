// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Aqueous-owned Vulkan state layered on wlroots' Vulkan renderer.
//! The instance, physical device, device, and queue are borrowed from wlroots.

const VulkanContext = @This();

const std = @import("std");
const c = @import("c");
const wlr = @import("wlroots");
const build_options = @import("build_options");

const util = @import("../util.zig");
const RenderProbe = if (build_options.vulkan_render_probe)
    @import("RenderProbe.zig")
else
    void;

pub const Capabilities = struct {
    rgba16f_sampled: bool,
    rgba16f_color_attachment: bool,
    bgra8_sampled: bool,
    bgra8_color_attachment: bool,
    linear_filtering: bool,
    sampler_anisotropy_supported: bool,
    fence_submission: bool,
    renderer_timeline: bool,
    timeline_semaphore_supported: bool,
    synchronization2_supported: bool,
    timestamp_queries: bool,
    timestamp_period_ns: f32,
};

pub const DeferredResource = union(enum) {
    pipeline: c.VkPipeline,
    pipeline_layout: c.VkPipelineLayout,
    descriptor_pool: c.VkDescriptorPool,
    image: c.VkImage,
    image_view: c.VkImageView,
    sampler: c.VkSampler,
    memory: c.VkDeviceMemory,
};

const Deferred = struct {
    fence: c.VkFence,
    resource: DeferredResource,
};

instance: c.VkInstance,
physical_device: c.VkPhysicalDevice,
device: c.VkDevice,
queue: c.VkQueue,
queue_family: u32,
pipeline_cache: c.VkPipelineCache,
capabilities: Capabilities,
deferred: std.ArrayList(Deferred) = .empty,
render_probe: if (build_options.vulkan_render_probe) RenderProbe else void,

pub fn init(renderer: *wlr.Renderer) !VulkanContext {
    if (!c.wlr_renderer_is_vk(@ptrCast(renderer))) {
        return error.RendererIsNotVulkan;
    }

    const instance = c.wlr_vk_renderer_get_instance(@ptrCast(renderer));
    const physical_device = c.wlr_vk_renderer_get_physical_device(@ptrCast(renderer));
    const device = c.wlr_vk_renderer_get_device(@ptrCast(renderer));
    const queue_family = c.wlr_vk_renderer_get_queue_family(@ptrCast(renderer));
    if (instance == null or physical_device == null or device == null) {
        std.log.err("wlroots' Vulkan renderer did not expose all required borrowed handles", .{});
        return error.VulkanBorrowedHandleUnavailable;
    }

    var queue: c.VkQueue = null;
    c.vkGetDeviceQueue(device, queue_family, 0, &queue);
    if (queue == null) return error.VulkanQueueUnavailable;

    var cache_info = std.mem.zeroes(c.VkPipelineCacheCreateInfo);
    cache_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO;
    var pipeline_cache: c.VkPipelineCache = null;
    const cache_result = c.vkCreatePipelineCache(device, &cache_info, null, &pipeline_cache);
    if (cache_result != c.VK_SUCCESS) {
        std.log.err("failed to create Vulkan pipeline cache: {s}", .{resultName(cache_result)});
        return error.VulkanPipelineCacheCreateFailed;
    }
    errdefer c.vkDestroyPipelineCache(device, pipeline_cache, null);

    const capabilities = queryCapabilities(physical_device, queue_family, renderer);
    var render_probe = if (comptime build_options.vulkan_render_probe)
        try RenderProbe.init(device, pipeline_cache)
    else {};
    errdefer if (comptime build_options.vulkan_render_probe)
        render_probe.deinit();
    var properties = std.mem.zeroes(c.VkPhysicalDeviceProperties);
    c.vkGetPhysicalDeviceProperties(physical_device, &properties);
    const device_name: [*:0]const u8 = @ptrCast(&properties.deviceName);
    const api = properties.apiVersion;
    std.log.info(
        "Vulkan effects context: device={s} api={d}.{d}.{d} queue-family={d} rgba16f(sampled={},color={}) bgra8(sampled={},color={}) linear={} sync(fence={},wlroots-timeline={}) physical-features(anisotropy={},timeline={},sync2={}) timestamps={} period-ns={d}",
        .{
            device_name,
            versionMajor(api),
            versionMinor(api),
            versionPatch(api),
            queue_family,
            capabilities.rgba16f_sampled,
            capabilities.rgba16f_color_attachment,
            capabilities.bgra8_sampled,
            capabilities.bgra8_color_attachment,
            capabilities.linear_filtering,
            capabilities.fence_submission,
            capabilities.renderer_timeline,
            capabilities.sampler_anisotropy_supported,
            capabilities.timeline_semaphore_supported,
            capabilities.synchronization2_supported,
            capabilities.timestamp_queries,
            capabilities.timestamp_period_ns,
        },
    );

    return .{
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = queue,
        .queue_family = queue_family,
        .pipeline_cache = pipeline_cache,
        .capabilities = capabilities,
        .render_probe = render_probe,
    };
}

pub fn deinit(context: *VulkanContext) void {
    if (comptime build_options.vulkan_render_probe) {
        context.render_probe.deinit();
    }
    if (context.deferred.items.len != 0) {
        const idle_result = c.vkDeviceWaitIdle(context.device);
        if (idle_result != c.VK_SUCCESS and idle_result != c.VK_ERROR_DEVICE_LOST) {
            std.log.warn("waiting for Vulkan device idle failed during effects teardown: {s}", .{resultName(idle_result)});
        }
    }

    for (context.deferred.items) |entry| {
        destroyResource(context.device, entry.resource);
        c.vkDestroyFence(context.device, entry.fence, null);
    }
    context.deferred.deinit(util.gpa);
    c.vkDestroyPipelineCache(context.device, context.pipeline_cache, null);
    std.log.info("destroyed Vulkan effects context", .{});
}

/// Retire a resource after the queue submission containing its final use.
pub fn deferDestroy(context: *VulkanContext, resource: DeferredResource) !void {
    try context.deferred.ensureUnusedCapacity(util.gpa, 1);

    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    var fence: c.VkFence = null;
    const create_result = c.vkCreateFence(context.device, &fence_info, null, &fence);
    if (create_result != c.VK_SUCCESS) {
        std.log.err("failed to create Vulkan retirement fence: {s}", .{resultName(create_result)});
        return error.VulkanFenceCreateFailed;
    }
    errdefer c.vkDestroyFence(context.device, fence, null);

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    const submit_result = c.vkQueueSubmit(context.queue, 1, &submit_info, fence);
    if (submit_result != c.VK_SUCCESS) {
        std.log.err("failed to submit Vulkan retirement fence: {s}", .{resultName(submit_result)});
        return error.VulkanFenceSubmitFailed;
    }

    context.deferred.appendAssumeCapacity(.{
        .fence = fence,
        .resource = resource,
    });
}

/// Destroy resources whose retirement fence has completed without blocking.
pub fn collectDeferred(context: *VulkanContext) void {
    var i: usize = 0;
    while (i < context.deferred.items.len) {
        const entry = context.deferred.items[i];
        const status = c.vkGetFenceStatus(context.device, entry.fence);
        if (status == c.VK_NOT_READY) {
            i += 1;
            continue;
        }
        if (status != c.VK_SUCCESS) {
            std.log.warn("checking Vulkan retirement fence failed: {s}", .{resultName(status)});
            i += 1;
            continue;
        }
        destroyResource(context.device, entry.resource);
        c.vkDestroyFence(context.device, entry.fence, null);
        _ = context.deferred.swapRemove(i);
    }
}

fn queryCapabilities(
    physical_device: c.VkPhysicalDevice,
    queue_family: u32,
    renderer: *wlr.Renderer,
) Capabilities {
    var properties = std.mem.zeroes(c.VkPhysicalDeviceProperties);
    c.vkGetPhysicalDeviceProperties(physical_device, &properties);

    var features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
    c.vkGetPhysicalDeviceFeatures(physical_device, &features);

    var queue_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, null);
    var queue_properties: [64]c.VkQueueFamilyProperties = undefined;
    const requested_count = @min(queue_count, queue_properties.len);
    var available_count: u32 = @intCast(requested_count);
    c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &available_count, &queue_properties);
    const timestamp_valid_bits = if (queue_family < available_count)
        queue_properties[queue_family].timestampValidBits
    else
        0;

    const rgba16f = formatFeatures(physical_device, c.VK_FORMAT_R16G16B16A16_SFLOAT);
    const bgra8 = formatFeatures(physical_device, c.VK_FORMAT_B8G8R8A8_UNORM);
    const api = properties.apiVersion;
    const modern_features = queryModernFeatures(physical_device, api);

    return .{
        .rgba16f_sampled = hasFormatFeature(rgba16f, c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT),
        .rgba16f_color_attachment = hasFormatFeature(rgba16f, c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT),
        .bgra8_sampled = hasFormatFeature(bgra8, c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT),
        .bgra8_color_attachment = hasFormatFeature(bgra8, c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT),
        .linear_filtering = hasFormatFeature(rgba16f, c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT),
        .sampler_anisotropy_supported = features.samplerAnisotropy != 0,
        .fence_submission = true,
        .renderer_timeline = renderer.features.timeline,
        .timeline_semaphore_supported = modern_features.timeline_semaphore,
        .synchronization2_supported = modern_features.synchronization2,
        .timestamp_queries = timestamp_valid_bits > 0 and properties.limits.timestampComputeAndGraphics != 0,
        .timestamp_period_ns = properties.limits.timestampPeriod,
    };
}

fn queryModernFeatures(physical_device: c.VkPhysicalDevice, api: u32) struct {
    timeline_semaphore: bool,
    synchronization2: bool,
} {
    if (!versionAtLeast(api, 1, 2)) {
        return .{ .timeline_semaphore = false, .synchronization2 = false };
    }

    var vulkan12 = std.mem.zeroes(c.VkPhysicalDeviceVulkan12Features);
    vulkan12.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;

    var features2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
    features2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features2.pNext = &vulkan12;

    var vulkan13 = std.mem.zeroes(c.VkPhysicalDeviceVulkan13Features);
    if (versionAtLeast(api, 1, 3)) {
        vulkan13.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
        vulkan12.pNext = &vulkan13;
    }

    c.vkGetPhysicalDeviceFeatures2(physical_device, &features2);
    return .{
        .timeline_semaphore = vulkan12.timelineSemaphore != 0,
        .synchronization2 = versionAtLeast(api, 1, 3) and vulkan13.synchronization2 != 0,
    };
}

fn formatFeatures(physical_device: c.VkPhysicalDevice, format: c.VkFormat) c.VkFormatFeatureFlags {
    var properties = std.mem.zeroes(c.VkFormatProperties);
    c.vkGetPhysicalDeviceFormatProperties(physical_device, format, &properties);
    return properties.optimalTilingFeatures;
}

fn hasFormatFeature(features: c.VkFormatFeatureFlags, required: c.VkFormatFeatureFlagBits) bool {
    return features & @as(c.VkFormatFeatureFlags, @intCast(required)) != 0;
}

fn destroyResource(device: c.VkDevice, resource: DeferredResource) void {
    switch (resource) {
        .pipeline => |handle| c.vkDestroyPipeline(device, handle, null),
        .pipeline_layout => |handle| c.vkDestroyPipelineLayout(device, handle, null),
        .descriptor_pool => |handle| c.vkDestroyDescriptorPool(device, handle, null),
        .image => |handle| c.vkDestroyImage(device, handle, null),
        .image_view => |handle| c.vkDestroyImageView(device, handle, null),
        .sampler => |handle| c.vkDestroySampler(device, handle, null),
        .memory => |handle| c.vkFreeMemory(device, handle, null),
    }
}

fn versionAtLeast(version: u32, major: u32, minor: u32) bool {
    return versionMajor(version) > major or
        (versionMajor(version) == major and versionMinor(version) >= minor);
}

fn versionMajor(version: u32) u32 {
    return version >> 22;
}

fn versionMinor(version: u32) u32 {
    return (version >> 12) & 0x3ff;
}

fn versionPatch(version: u32) u32 {
    return version & 0xfff;
}

fn resultName(result: c.VkResult) []const u8 {
    return switch (result) {
        c.VK_SUCCESS => "VK_SUCCESS",
        c.VK_NOT_READY => "VK_NOT_READY",
        c.VK_TIMEOUT => "VK_TIMEOUT",
        c.VK_ERROR_OUT_OF_HOST_MEMORY => "VK_ERROR_OUT_OF_HOST_MEMORY",
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        c.VK_ERROR_INITIALIZATION_FAILED => "VK_ERROR_INITIALIZATION_FAILED",
        c.VK_ERROR_DEVICE_LOST => "VK_ERROR_DEVICE_LOST",
        else => "unknown Vulkan result",
    };
}
