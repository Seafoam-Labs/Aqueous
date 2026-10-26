// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
// Stateful GPU mock: real production Zig functions own these handles. A tiny
// descriptor pool makes leaks fail quickly without requiring a physical GPU.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <vulkan/vulkan.h>

enum kind { FREE, SAMPLER, LAYOUT, POOL, PIPELINE_LAYOUT, PASS, SHADER,
    PIPELINE, IMAGE, MEMORY, VIEW, FRAMEBUFFER, DESCRIPTOR };
static enum kind handles[128];
static uintptr_t descriptor_pool[128];
static unsigned live, descriptors, attempts, fail_at;
static void (*callbacks[32])(void *);
static void *callback_data[32];
static unsigned callback_count;
static bool fail_completion;

unsigned aqueous_blur_test_live(void) { return live; }
unsigned aqueous_blur_test_descriptors(void) { return descriptors; }
unsigned aqueous_blur_test_attempts(void) { return attempts; }
void aqueous_blur_test_fail(unsigned at) { attempts = 0; fail_at = at; }
void aqueous_blur_test_reset(void) {
    assert(live == 0 && descriptors == 0 && callback_count == 0);
    attempts = fail_at = 0;
    fail_completion = false;
}
void aqueous_blur_test_reject_completion(bool reject) { fail_completion = reject; }

static uintptr_t make(enum kind kind) {
    if (++attempts == fail_at) return 0;
    if (kind == DESCRIPTOR && descriptors == 8) return 0;
    for (uintptr_t i = 1; i < 128; ++i) {
        if (handles[i] != FREE) continue;
        handles[i] = kind;
        ++live;
        if (kind == DESCRIPTOR) ++descriptors;
        return i;
    }
    assert(!"mock handle limit exceeded");
    return 0;
}
static void drop(uintptr_t handle, enum kind kind) {
    if (!handle) return;
    assert(handle < 128 && handles[handle] == kind);
    handles[handle] = FREE;
    --live;
    if (kind == DESCRIPTOR) --descriptors;
}

#define CREATE(name, kind) \
VkResult vkCreate##name(VkDevice device, const Vk##name##CreateInfo *info, \
        const VkAllocationCallbacks *allocator, Vk##name *out) { \
    (void)device; (void)info; (void)allocator; \
    *out = (Vk##name)make(kind); \
    return *out ? VK_SUCCESS : VK_ERROR_OUT_OF_HOST_MEMORY; \
}
#define DESTROY(name, kind) \
void vkDestroy##name(VkDevice device, Vk##name handle, const VkAllocationCallbacks *allocator) { \
    (void)device; (void)allocator; drop((uintptr_t)handle, kind); \
}
CREATE(Sampler, SAMPLER)
DESTROY(Sampler, SAMPLER)
CREATE(DescriptorSetLayout, LAYOUT)
DESTROY(DescriptorSetLayout, LAYOUT)
CREATE(DescriptorPool, POOL)
CREATE(PipelineLayout, PIPELINE_LAYOUT)
DESTROY(PipelineLayout, PIPELINE_LAYOUT)
CREATE(RenderPass, PASS)
DESTROY(RenderPass, PASS)
CREATE(ShaderModule, SHADER)
DESTROY(ShaderModule, SHADER)
DESTROY(Pipeline, PIPELINE)
CREATE(Image, IMAGE)
DESTROY(Image, IMAGE)
CREATE(ImageView, VIEW)
DESTROY(ImageView, VIEW)
CREATE(Framebuffer, FRAMEBUFFER)
DESTROY(Framebuffer, FRAMEBUFFER)

void vkDestroyDescriptorPool(VkDevice device, VkDescriptorPool pool, const VkAllocationCallbacks *allocator) {
    (void)device; (void)allocator;
    for (uintptr_t i = 1; i < 128; ++i)
        if (handles[i] == DESCRIPTOR && descriptor_pool[i] == (uintptr_t)pool) drop(i, DESCRIPTOR);
    drop((uintptr_t)pool, POOL);
}
VkResult vkCreateGraphicsPipelines(VkDevice device, VkPipelineCache cache, uint32_t count,
        const VkGraphicsPipelineCreateInfo *info, const VkAllocationCallbacks *allocator, VkPipeline *out) {
    (void)device; (void)cache; (void)info; (void)allocator;
    assert(count == 1);
    *out = (VkPipeline)make(PIPELINE);
    return *out ? VK_SUCCESS : VK_ERROR_OUT_OF_HOST_MEMORY;
}
void vkGetImageMemoryRequirements(VkDevice device, VkImage image, VkMemoryRequirements *out) {
    (void)device; (void)image;
    *out = (VkMemoryRequirements){ .size = 4096, .alignment = 256, .memoryTypeBits = 1 };
}
void vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice device, VkPhysicalDeviceMemoryProperties *out) {
    (void)device;
    memset(out, 0, sizeof(*out));
    out->memoryTypeCount = 1;
    out->memoryTypes[0].propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
}
VkResult vkAllocateMemory(VkDevice device, const VkMemoryAllocateInfo *info,
        const VkAllocationCallbacks *allocator, VkDeviceMemory *out) {
    (void)device; (void)info; (void)allocator;
    *out = (VkDeviceMemory)make(MEMORY);
    return *out ? VK_SUCCESS : VK_ERROR_OUT_OF_HOST_MEMORY;
}
void vkFreeMemory(VkDevice device, VkDeviceMemory memory, const VkAllocationCallbacks *allocator) {
    (void)device; (void)allocator; drop((uintptr_t)memory, MEMORY);
}
VkResult vkBindImageMemory(VkDevice device, VkImage image, VkDeviceMemory memory, VkDeviceSize offset) {
    (void)device; (void)image; (void)memory; (void)offset;
    return ++attempts == fail_at ? VK_ERROR_OUT_OF_HOST_MEMORY : VK_SUCCESS;
}
VkResult vkAllocateDescriptorSets(VkDevice device, const VkDescriptorSetAllocateInfo *info, VkDescriptorSet *out) {
    (void)device;
    assert(info->descriptorSetCount == 1 && handles[(uintptr_t)info->descriptorPool] == POOL);
    *out = (VkDescriptorSet)make(DESCRIPTOR);
    if (*out) descriptor_pool[(uintptr_t)*out] = (uintptr_t)info->descriptorPool;
    return *out ? VK_SUCCESS : VK_ERROR_OUT_OF_POOL_MEMORY;
}
void vkUpdateDescriptorSets(VkDevice device, uint32_t count, const VkWriteDescriptorSet *writes,
        uint32_t copies, const VkCopyDescriptorSet *copy) {
    (void)device; (void)count; (void)writes; (void)copies; (void)copy;
}
VkResult vkFreeDescriptorSets(VkDevice device, VkDescriptorPool pool, uint32_t count, const VkDescriptorSet *sets) {
    (void)device;
    assert(handles[(uintptr_t)pool] == POOL);
    for (unsigned i = 0; i < count; ++i) {
        assert(descriptor_pool[(uintptr_t)sets[i]] == (uintptr_t)pool);
        drop((uintptr_t)sets[i], DESCRIPTOR);
    }
    return VK_SUCCESS;
}

struct wlr_render_pass;
bool wlr_vk_render_pass_add_completion(struct wlr_render_pass *pass, void (*callback)(void *), void *data) {
    (void)pass;
    if (fail_completion) return false;
    assert(callback_count < 32);
    callbacks[callback_count] = callback;
    callback_data[callback_count++] = data;
    return true;
}
void aqueous_blur_test_complete(void) {
    for (unsigned i = 0; i < callback_count; ++i) callbacks[i](callback_data[i]);
    callback_count = 0;
}
