// SPDX-FileCopyrightText: © 2026 The Aqueous Developers
// SPDX-License-Identifier: GPL-3.0-only

const RoundedPipeline = @This();

const std = @import("std");
const c = @import("c");

const EffectMetadata = @import("EffectMetadata.zig");
const util = @import("../util.zig");

const texture_vertex_shader align(4) =
    @embedFile("shaders/rounded_texture.vert.spv").*;
const texture_fragment_shader align(4) =
    @embedFile("shaders/rounded_texture.frag.spv").*;
const rect_vertex_shader align(4) =
    @embedFile("shaders/rounded_rect.vert.spv").*;
const rect_fragment_shader align(4) =
    @embedFile("shaders/rounded_rect.frag.spv").*;

const TextureVertexPush = extern struct {
    projection: [4][4]f32,
    uv_offset: [2]f32,
    uv_size: [2]f32,
};

const TextureFragmentPush = extern struct {
    color_matrix: [4][4]f32,
    alpha: f32,
    luminance_multiplier: f32,
};

const RectPush = extern struct {
    rect: [4]f32,
    color: [4]f32,
    outer_radii: [4]f32,
    inner_rect: [4]f32,
    inner_radii: [4]f32,
    output_data: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(TextureVertexPush) == 80);
    std.debug.assert(@sizeOf(TextureFragmentPush) == 72);
    std.debug.assert(@sizeOf(RectPush) == 96);
}

const TexturePipeline = struct {
    render_pass: c.VkRenderPass,
    subpass: u32,
    pipeline_layout: c.VkPipelineLayout,
    texture_transform: u32,
    pipeline: c.VkPipeline,
};

const RectPipeline = struct {
    render_pass: c.VkRenderPass,
    subpass: u32,
    pipeline: c.VkPipeline,
};

device: c.VkDevice,
pipeline_cache: c.VkPipelineCache,
rect_pipeline_layout: c.VkPipelineLayout,
texture_pipelines: std.ArrayList(TexturePipeline) = .empty,
rect_pipelines: std.ArrayList(RectPipeline) = .empty,
texture_draw_count: u64 = 0,
rect_draw_count: u64 = 0,
explicit_sync_draw_count: u64 = 0,
normal_draw_count: u64 = 0,
swapchain_draw_count: u64 = 0,

pub fn init(
    device: c.VkDevice,
    pipeline_cache: c.VkPipelineCache,
) !RoundedPipeline {
    var push_range = std.mem.zeroes(c.VkPushConstantRange);
    push_range.stageFlags =
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    push_range.size = @sizeOf(RectPush);

    var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.pushConstantRangeCount = 1;
    layout_info.pPushConstantRanges = &push_range;

    var rect_pipeline_layout: c.VkPipelineLayout = null;
    const result = c.vkCreatePipelineLayout(
        device,
        &layout_info,
        null,
        &rect_pipeline_layout,
    );
    if (result != c.VK_SUCCESS) {
        std.log.err(
            "failed to create Vulkan rounded-rect pipeline layout: {s}",
            .{resultName(result)},
        );
        return error.VulkanRoundedRectPipelineLayoutCreateFailed;
    }

    std.log.info("Vulkan rounded effects pipeline initialized", .{});
    return .{
        .device = device,
        .pipeline_cache = pipeline_cache,
        .rect_pipeline_layout = rect_pipeline_layout,
    };
}

pub fn deinit(pipeline: *RoundedPipeline) void {
    const texture_pipeline_count = pipeline.texture_pipelines.items.len;
    const rect_pipeline_count = pipeline.rect_pipelines.items.len;
    for (pipeline.texture_pipelines.items) |entry| {
        c.vkDestroyPipeline(pipeline.device, entry.pipeline, null);
    }
    for (pipeline.rect_pipelines.items) |entry| {
        c.vkDestroyPipeline(pipeline.device, entry.pipeline, null);
    }
    pipeline.texture_pipelines.deinit(util.gpa);
    pipeline.rect_pipelines.deinit(util.gpa);
    c.vkDestroyPipelineLayout(
        pipeline.device,
        pipeline.rect_pipeline_layout,
        null,
    );
    std.log.info(
        "destroyed Vulkan rounded effects after {d} texture and {d} rect draws ({d} normal, {d} swapchain, {d} explicit-sync)",
        .{
            pipeline.texture_draw_count,
            pipeline.rect_draw_count,
            pipeline.normal_draw_count,
            pipeline.swapchain_draw_count,
            pipeline.explicit_sync_draw_count,
        },
    );
    std.log.info(
        "Vulkan rounded resources created: {d} texture pipelines, {d} rect pipelines",
        .{ texture_pipeline_count, rect_pipeline_count },
    );
}

pub fn drawTexture(
    pipeline: *RoundedPipeline,
    attributes: *const c.struct_wlr_vk_render_texture_attribs,
    options: *const c.struct_wlr_render_texture_options,
    radii: EffectMetadata.CornerRadii,
    scale: f32,
    swapchain_path: bool,
) !bool {
    if (!validPass(&attributes.render_pass) or
        attributes.pipeline_layout == null or
        attributes.descriptor_set == null)
    {
        return error.VulkanRoundedTextureAttributesInvalid;
    }

    const box = options.dst_box;
    if (box.width <= 0 or box.height <= 0) return false;
    const physical_radii = EffectMetadata.clampedPhysicalRadii(
        radii,
        box.width,
        box.height,
        scale,
    );
    if (!hasRadius(physical_radii)) return false;

    const graphics_pipeline = try pipeline.texturePipelineFor(attributes);
    var vertex_push: TextureVertexPush = .{
        .projection = attributes.projection,
        .uv_offset = attributes.uv_offset,
        .uv_size = attributes.uv_size,
    };
    var fragment_push: TextureFragmentPush = .{
        .color_matrix = attributes.color_matrix,
        .alpha = attributes.alpha,
        .luminance_multiplier = attributes.luminance_multiplier,
    };
    fragment_push.color_matrix[0][3] = @floatFromInt(box.width);
    fragment_push.color_matrix[1][3] = @floatFromInt(box.height);
    fragment_push.color_matrix[3] = physical_radii;

    const command_buffer = attributes.render_pass.command_buffer;
    c.vkCmdBindPipeline(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        graphics_pipeline,
    );
    setViewport(command_buffer, attributes.render_pass.extent);
    c.vkCmdBindDescriptorSets(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        attributes.pipeline_layout,
        0,
        1,
        &attributes.descriptor_set,
        0,
        null,
    );
    c.vkCmdPushConstants(
        command_buffer,
        attributes.pipeline_layout,
        c.VK_SHADER_STAGE_VERTEX_BIT,
        0,
        @sizeOf(TextureVertexPush),
        &vertex_push,
    );
    c.vkCmdPushConstants(
        command_buffer,
        attributes.pipeline_layout,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        @sizeOf(TextureVertexPush),
        @sizeOf(TextureFragmentPush),
        &fragment_push,
    );
    _ = drawClipped(
        command_buffer,
        options.clip,
        box,
        attributes.render_pass.extent,
    );
    pipeline.recordDraw(true, swapchain_path, attributes.render_pass.has_signal_timeline);
    return true;
}

pub fn drawRect(
    pipeline: *RoundedPipeline,
    render_pass: *c.struct_wlr_render_pass,
    options: *const c.struct_wlr_render_rect_options,
    effect: EffectMetadata.RectRenderData,
    swapchain_path: bool,
) !bool {
    var attributes = std.mem.zeroes(c.struct_wlr_vk_render_pass_attribs);
    if (!c.wlr_vk_render_pass_get_attribs(render_pass, &attributes)) {
        return false;
    }
    if (!validPass(&attributes)) {
        return error.VulkanRoundedRectAttributesInvalid;
    }

    const box = options.box;
    if (box.width <= 0 or box.height <= 0) return false;
    const graphics_pipeline = try pipeline.rectPipelineFor(&attributes);
    const alpha = options.color.a;
    const push: RectPush = .{
        .rect = .{
            @floatFromInt(box.x),
            @floatFromInt(box.y),
            @floatFromInt(box.width),
            @floatFromInt(box.height),
        },
        .color = .{
            linearPremultiplied(options.color.r, alpha),
            linearPremultiplied(options.color.g, alpha),
            linearPremultiplied(options.color.b, alpha),
            alpha,
        },
        .outer_radii = effect.outer_radii,
        .inner_rect = effect.inner_rect,
        .inner_radii = effect.inner_radii,
        .output_data = .{
            @floatFromInt(attributes.extent.width),
            @floatFromInt(attributes.extent.height),
            if (effect.has_inner) 1 else 0,
            0,
        },
    };
    c.vkCmdBindPipeline(
        attributes.command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        graphics_pipeline,
    );
    setViewport(attributes.command_buffer, attributes.extent);
    c.vkCmdPushConstants(
        attributes.command_buffer,
        pipeline.rect_pipeline_layout,
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(RectPush),
        &push,
    );
    _ = drawClipped(
        attributes.command_buffer,
        options.clip,
        box,
        attributes.extent,
    );
    pipeline.recordDraw(false, swapchain_path, attributes.has_signal_timeline);
    return true;
}

fn recordDraw(
    pipeline: *RoundedPipeline,
    texture: bool,
    swapchain_path: bool,
    explicit_sync: bool,
) void {
    if (texture) {
        pipeline.texture_draw_count += 1;
    } else {
        pipeline.rect_draw_count += 1;
    }
    if (swapchain_path) {
        pipeline.swapchain_draw_count += 1;
    } else {
        pipeline.normal_draw_count += 1;
    }
    if (explicit_sync) pipeline.explicit_sync_draw_count += 1;

    const total = pipeline.texture_draw_count + pipeline.rect_draw_count;
    if (total == 1 or total % 1000 == 0) {
        std.log.info(
            "Vulkan rounded effects draw count={d} texture={d} rect={d} normal={d} swapchain={d} explicit-sync={d}",
            .{
                total,
                pipeline.texture_draw_count,
                pipeline.rect_draw_count,
                pipeline.normal_draw_count,
                pipeline.swapchain_draw_count,
                pipeline.explicit_sync_draw_count,
            },
        );
    }
}

fn texturePipelineFor(
    pipeline: *RoundedPipeline,
    attributes: *const c.struct_wlr_vk_render_texture_attribs,
) !c.VkPipeline {
    for (pipeline.texture_pipelines.items) |entry| {
        if (entry.render_pass == attributes.render_pass.render_pass and
            entry.subpass == attributes.render_pass.subpass and
            entry.pipeline_layout == attributes.pipeline_layout and
            entry.texture_transform == attributes.texture_transform)
        {
            return entry.pipeline;
        }
    }

    const graphics_pipeline = try pipeline.createGraphicsPipeline(
        attributes.render_pass.render_pass,
        attributes.render_pass.subpass,
        attributes.pipeline_layout,
        &texture_vertex_shader,
        &texture_fragment_shader,
        attributes.texture_transform,
    );
    errdefer c.vkDestroyPipeline(pipeline.device, graphics_pipeline, null);
    try pipeline.texture_pipelines.append(util.gpa, .{
        .render_pass = attributes.render_pass.render_pass,
        .subpass = attributes.render_pass.subpass,
        .pipeline_layout = attributes.pipeline_layout,
        .texture_transform = attributes.texture_transform,
        .pipeline = graphics_pipeline,
    });
    return graphics_pipeline;
}

fn rectPipelineFor(
    pipeline: *RoundedPipeline,
    attributes: *const c.struct_wlr_vk_render_pass_attribs,
) !c.VkPipeline {
    for (pipeline.rect_pipelines.items) |entry| {
        if (entry.render_pass == attributes.render_pass and
            entry.subpass == attributes.subpass)
        {
            return entry.pipeline;
        }
    }

    const graphics_pipeline = try pipeline.createGraphicsPipeline(
        attributes.render_pass,
        attributes.subpass,
        pipeline.rect_pipeline_layout,
        &rect_vertex_shader,
        &rect_fragment_shader,
        null,
    );
    errdefer c.vkDestroyPipeline(pipeline.device, graphics_pipeline, null);
    try pipeline.rect_pipelines.append(util.gpa, .{
        .render_pass = attributes.render_pass,
        .subpass = attributes.subpass,
        .pipeline = graphics_pipeline,
    });
    return graphics_pipeline;
}

fn createGraphicsPipeline(
    pipeline: *RoundedPipeline,
    render_pass: c.VkRenderPass,
    subpass: u32,
    pipeline_layout: c.VkPipelineLayout,
    vertex_code: []align(4) const u8,
    fragment_code: []align(4) const u8,
    texture_transform: ?u32,
) !c.VkPipeline {
    const vertex_module = try createShaderModule(pipeline.device, vertex_code);
    defer c.vkDestroyShaderModule(pipeline.device, vertex_module, null);
    const fragment_module = try createShaderModule(pipeline.device, fragment_code);
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

    var specialization_entry = std.mem.zeroes(c.VkSpecializationMapEntry);
    var specialization = std.mem.zeroes(c.VkSpecializationInfo);
    var transform_value: u32 = texture_transform orelse 0;
    if (texture_transform != null) {
        specialization_entry.constantID = 0;
        specialization_entry.offset = 0;
        specialization_entry.size = @sizeOf(u32);
        specialization.mapEntryCount = 1;
        specialization.pMapEntries = &specialization_entry;
        specialization.dataSize = @sizeOf(u32);
        specialization.pData = &transform_value;
        stages[1].pSpecializationInfo = &specialization;
    }

    var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
    input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN;

    var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    var rasterization = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    rasterization.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterization.polygonMode = c.VK_POLYGON_MODE_FILL;
    rasterization.cullMode = c.VK_CULL_MODE_NONE;
    rasterization.frontFace = c.VK_FRONT_FACE_CLOCKWISE;
    rasterization.lineWidth = 1;

    var multisample = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    multisample.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisample.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    attachment.blendEnable = c.VK_TRUE;
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
    color_blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
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
    create_info.layout = pipeline_layout;
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
            "failed to create Vulkan rounded-effects pipeline: {s}",
            .{resultName(result)},
        );
        return error.VulkanRoundedPipelineCreateFailed;
    }
    return graphics_pipeline;
}

fn setViewport(command_buffer: c.VkCommandBuffer, extent: c.VkExtent2D) void {
    const viewport: c.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
}

fn drawClipped(
    command_buffer: c.VkCommandBuffer,
    clip: ?*const c.pixman_region32_t,
    box: c.struct_wlr_box,
    extent: c.VkExtent2D,
) u32 {
    var draws: u32 = 0;
    if (clip) |region| {
        var count: c_int = 0;
        const rectangles = c.pixman_region32_rectangles(region, &count);
        var index: usize = 0;
        while (index < @as(usize, @intCast(@max(0, count)))) : (index += 1) {
            const rectangle = rectangles[index];
            if (drawIntersection(
                command_buffer,
                box,
                rectangle.x1,
                rectangle.y1,
                rectangle.x2,
                rectangle.y2,
                extent,
            )) draws += 1;
        }
    } else if (drawIntersection(
        command_buffer,
        box,
        box.x,
        box.y,
        box.x + box.width,
        box.y + box.height,
        extent,
    )) {
        draws = 1;
    }
    return draws;
}

fn drawIntersection(
    command_buffer: c.VkCommandBuffer,
    box: c.struct_wlr_box,
    clip_left: i32,
    clip_top: i32,
    clip_right: i32,
    clip_bottom: i32,
    extent: c.VkExtent2D,
) bool {
    const left = @max(0, @max(box.x, clip_left));
    const top = @max(0, @max(box.y, clip_top));
    const right = @min(
        @as(i32, @intCast(extent.width)),
        @min(box.x + box.width, clip_right),
    );
    const bottom = @min(
        @as(i32, @intCast(extent.height)),
        @min(box.y + box.height, clip_bottom),
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
    c.vkCmdDraw(command_buffer, 4, 1, 0, 0);
    return true;
}

fn validPass(attributes: *const c.struct_wlr_vk_render_pass_attribs) bool {
    return attributes.command_buffer != null and
        attributes.render_pass != null and
        attributes.extent.width != 0 and
        attributes.extent.height != 0;
}

fn hasRadius(radii: [4]f32) bool {
    for (radii) |radius| {
        if (radius > 0) return true;
    }
    return false;
}

fn linearPremultiplied(channel: f32, alpha: f32) f32 {
    if (alpha == 0) return 0;
    return std.math.pow(f32, channel / alpha, 2.2) * alpha;
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
    const result = c.vkCreateShaderModule(device, &create_info, null, &module);
    if (result != c.VK_SUCCESS) {
        std.log.err(
            "failed to create Vulkan rounded-effects shader module: {s}",
            .{resultName(result)},
        );
        return error.VulkanRoundedShaderModuleCreateFailed;
    }
    return module;
}

fn resultName(result: c.VkResult) []const u8 {
    return switch (result) {
        c.VK_SUCCESS => "VK_SUCCESS",
        c.VK_ERROR_OUT_OF_HOST_MEMORY => "VK_ERROR_OUT_OF_HOST_MEMORY",
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        c.VK_ERROR_INITIALIZATION_FAILED => "VK_ERROR_INITIALIZATION_FAILED",
        c.VK_ERROR_DEVICE_LOST => "VK_ERROR_DEVICE_LOST",
        else => "unknown Vulkan result",
    };
}
