// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const RenderProbe = @This();

const std = @import("std");
const c = @import("c");

const util = @import("../util.zig");

const vertex_shader align(4) =
    @embedFile("shaders/render_probe.vert.spv").*;
const fragment_shader align(4) =
    @embedFile("shaders/render_probe.frag.spv").*;

const Pipeline = struct {
    render_pass: c.VkRenderPass,
    subpass: u32,
    pipeline: c.VkPipeline,
};

const PushConstants = extern struct {
    rect: [4]f32,
    color: [4]f32,
    output_radius: [4]f32,
};

device: c.VkDevice,
pipeline_cache: c.VkPipelineCache,
pipeline_layout: c.VkPipelineLayout,
pipelines: std.ArrayList(Pipeline) = .empty,
draw_count: u64 = 0,
explicit_sync_draw_count: u64 = 0,
normal_draw_count: u64 = 0,
swapchain_draw_count: u64 = 0,

pub fn init(
    device: c.VkDevice,
    pipeline_cache: c.VkPipelineCache,
) !RenderProbe {
    var push_range = std.mem.zeroes(c.VkPushConstantRange);
    push_range.stageFlags =
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    push_range.size = @sizeOf(PushConstants);

    var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.pushConstantRangeCount = 1;
    layout_info.pPushConstantRanges = &push_range;

    var pipeline_layout: c.VkPipelineLayout = null;
    const result =
        c.vkCreatePipelineLayout(device, &layout_info, null, &pipeline_layout);
    if (result != c.VK_SUCCESS) {
        std.log.err(
            "failed to create Vulkan render-probe pipeline layout: {s}",
            .{resultName(result)},
        );
        return error.VulkanRenderProbePipelineLayoutCreateFailed;
    }

    std.log.info("Vulkan render probe initialized", .{});
    return .{
        .device = device,
        .pipeline_cache = pipeline_cache,
        .pipeline_layout = pipeline_layout,
    };
}

pub fn deinit(probe: *RenderProbe) void {
    if (probe.pipelines.items.len != 0) {
        const result = c.vkDeviceWaitIdle(probe.device);
        if (result != c.VK_SUCCESS and result != c.VK_ERROR_DEVICE_LOST) {
            std.log.warn(
                "waiting for Vulkan render-probe teardown failed: {s}",
                .{resultName(result)},
            );
        }
    }
    for (probe.pipelines.items) |entry| {
        c.vkDestroyPipeline(probe.device, entry.pipeline, null);
    }
    probe.pipelines.deinit(util.gpa);
    c.vkDestroyPipelineLayout(probe.device, probe.pipeline_layout, null);
    std.log.info(
        "destroyed Vulkan render probe after {d} draws ({d} normal, {d} swapchain, {d} explicit-sync)",
        .{
            probe.draw_count,
            probe.normal_draw_count,
            probe.swapchain_draw_count,
            probe.explicit_sync_draw_count,
        },
    );
}

pub fn draw(
    probe: *RenderProbe,
    render_pass: *c.struct_wlr_render_pass,
    options: *const c.struct_wlr_render_texture_options,
    swapchain_path: bool,
) !void {
    var attributes = std.mem.zeroes(c.struct_wlr_vk_render_pass_attribs);
    if (!c.wlr_vk_render_pass_get_attribs(render_pass, &attributes)) {
        return error.VulkanRenderPassAttributesUnavailable;
    }
    if (attributes.command_buffer == null or attributes.render_pass == null or
        attributes.extent.width == 0 or attributes.extent.height == 0)
    {
        return error.VulkanRenderPassAttributesInvalid;
    }

    const box = options.dst_box;
    if (box.width <= 0 or box.height <= 0) return;
    const pipeline = try probe.pipelineFor(
        attributes.render_pass,
        attributes.subpass,
    );

    const radius = @min(
        @as(f32, @floatFromInt(@min(box.width, box.height))) * 0.12,
        64.0,
    );
    const push: PushConstants = .{
        .rect = .{
            @floatFromInt(box.x),
            @floatFromInt(box.y),
            @floatFromInt(box.width),
            @floatFromInt(box.height),
        },
        .color = .{ 0.04, 0.78, 0.24, 0.92 },
        .output_radius = .{
            @floatFromInt(attributes.extent.width),
            @floatFromInt(attributes.extent.height),
            radius,
            0,
        },
    };

    c.vkCmdBindPipeline(
        attributes.command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        pipeline,
    );
    const viewport: c.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(attributes.extent.width),
        .height = @floatFromInt(attributes.extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(attributes.command_buffer, 0, 1, &viewport);
    c.vkCmdPushConstants(
        attributes.command_buffer,
        probe.pipeline_layout,
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(PushConstants),
        &push,
    );

    if (options.clip) |clip| {
        var count: c_int = 0;
        const rectangles = c.pixman_region32_rectangles(clip, &count);
        var index: usize = 0;
        while (index < @as(usize, @intCast(count))) : (index += 1) {
            const rectangle = rectangles[index];
            const left = @max(rectangle.x1, box.x);
            const top = @max(rectangle.y1, box.y);
            const right = @min(rectangle.x2, box.x + box.width);
            const bottom = @min(rectangle.y2, box.y + box.height);
            if (right <= left or bottom <= top) continue;
            drawScissored(
                attributes.command_buffer,
                left,
                top,
                right - left,
                bottom - top,
            );
        }
    } else {
        drawScissored(
            attributes.command_buffer,
            box.x,
            box.y,
            box.width,
            box.height,
        );
    }

    probe.draw_count += 1;
    if (swapchain_path) {
        probe.swapchain_draw_count += 1;
    } else {
        probe.normal_draw_count += 1;
    }
    if (attributes.has_signal_timeline) {
        probe.explicit_sync_draw_count += 1;
    }
    if (probe.draw_count == 1 or probe.draw_count % 1000 == 0) {
        std.log.info(
            "Vulkan render probe draw count={d} normal={d} swapchain={d} explicit-sync={d} extent={d}x{d}",
            .{
                probe.draw_count,
                probe.normal_draw_count,
                probe.swapchain_draw_count,
                probe.explicit_sync_draw_count,
                attributes.extent.width,
                attributes.extent.height,
            },
        );
    }
}

fn drawScissored(
    command_buffer: c.VkCommandBuffer,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) void {
    const scissor: c.VkRect2D = .{
        .offset = .{ .x = x, .y = y },
        .extent = .{
            .width = @intCast(width),
            .height = @intCast(height),
        },
    };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
    c.vkCmdDraw(command_buffer, 4, 1, 0, 0);
}

fn pipelineFor(
    probe: *RenderProbe,
    render_pass: c.VkRenderPass,
    subpass: u32,
) !c.VkPipeline {
    for (probe.pipelines.items) |entry| {
        if (entry.render_pass == render_pass and entry.subpass == subpass) {
            return entry.pipeline;
        }
    }

    const pipeline = try probe.createPipeline(render_pass, subpass);
    errdefer c.vkDestroyPipeline(probe.device, pipeline, null);
    try probe.pipelines.append(util.gpa, .{
        .render_pass = render_pass,
        .subpass = subpass,
        .pipeline = pipeline,
    });
    return pipeline;
}

fn createPipeline(
    probe: *RenderProbe,
    render_pass: c.VkRenderPass,
    subpass: u32,
) !c.VkPipeline {
    const vertex_module = try createShaderModule(probe.device, &vertex_shader);
    defer c.vkDestroyShaderModule(probe.device, vertex_module, null);
    const fragment_module =
        try createShaderModule(probe.device, &fragment_shader);
    defer c.vkDestroyShaderModule(probe.device, fragment_module, null);

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
    input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;

    var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
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
    create_info.layout = probe.pipeline_layout;
    create_info.renderPass = render_pass;
    create_info.subpass = subpass;
    create_info.basePipelineIndex = -1;

    var pipeline: c.VkPipeline = null;
    const result = c.vkCreateGraphicsPipelines(
        probe.device,
        probe.pipeline_cache,
        1,
        &create_info,
        null,
        &pipeline,
    );
    if (result != c.VK_SUCCESS) {
        std.log.err(
            "failed to create Vulkan render-probe pipeline: {s}",
            .{resultName(result)},
        );
        return error.VulkanRenderProbePipelineCreateFailed;
    }
    return pipeline;
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
        std.log.err(
            "failed to create Vulkan render-probe shader module: {s}",
            .{resultName(result)},
        );
        return error.VulkanRenderProbeShaderModuleCreateFailed;
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
