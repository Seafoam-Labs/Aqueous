// SPDX-License-Identifier: GPL-3.0-only
// Real submissions prove per-pass selection, color preservation and reclamation.
#include <assert.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <wayland-server-core.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/allocator.h>
#include <wlr/render/color.h>
#include <wlr/render/pass.h>
#include <wlr/render/swapchain.h>
#include <wlr/render/vulkan.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_presentation.h>
#include <wlr/util/log.h>

static bool fail_framebuffer;

VKAPI_ATTR VkResult VKAPI_CALL vkCreateFramebuffer(VkDevice device,
        const VkFramebufferCreateInfo *info, const VkAllocationCallbacks *allocator,
        VkFramebuffer *framebuffer) {
    if (fail_framebuffer) {
        fail_framebuffer = false;
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    PFN_vkCreateFramebuffer create = (PFN_vkCreateFramebuffer)dlsym(RTLD_NEXT, "vkCreateFramebuffer");
    assert(create);
    return create(device, info, allocator, framebuffer);
}

static bool backdrop(const struct wlr_vk_render_offscreen_attribs *attrs, void *data) {
    (void)data;
    assert(attrs->source_format == VK_FORMAT_R16G16B16A16_SFLOAT);
    return true;
}

static unsigned pixel(struct wlr_buffer *buffer) {
    void *data; uint32_t format; size_t stride;
    assert(wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ, &data, &format, &stride));
    unsigned value = ((unsigned char *)data)[0];
    wlr_buffer_end_data_ptr_access(buffer);
    return value;
}

int main(void) {
    wlr_log_init(WLR_INFO, NULL);
    struct wl_display *display = wl_display_create();
    assert(display);
    struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
    const char *node = getenv("AQUEOUS_TEST_RENDER_NODE");
    int fd = node ? open(node, O_RDWR | O_CLOEXEC) : -1;
    assert(!node || fd >= 0);
    struct wlr_renderer *renderer = wlr_vk_renderer_create_with_drm_fd(fd);
    if (fd >= 0) close(fd);
    if (!renderer) return 77;
    struct wlr_allocator *allocator = wlr_allocator_autocreate(backend, renderer);
    assert(allocator);
    struct wlr_output *output = wlr_headless_add_output(backend, 127, 65);
    assert(output && wlr_output_init_render(output, allocator, renderer));
    assert(wlr_output_allow_presentation_copy(output, true));
    assert(wlr_output_try_presentation_copy(output));
    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    assert(wlr_output_configure_primary_swapchain(output, &state, &output->swapchain));
    struct wlr_buffer *buffer = wlr_swapchain_acquire(output->swapchain);
    assert(buffer);
    struct wlr_color_transform *linear = wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR);
    struct wlr_color_transform *srgb = wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_SRGB);
    assert(linear && srgb);
    // Populate only the direct sRGB target, then fail each lazy setup once.
    // Retrying must recreate a complete framebuffer, not reuse a partial view.
    for (unsigned setup = 0; setup < 3; setup++) {
        struct wlr_buffer_pass_options options = {
            .color_transform = setup == 0 ? srgb : linear,
            .sampleable_backdrop = setup == 2,
        };
        if (setup != 0) {
            fail_framebuffer = true;
            wlr_log_init(WLR_SILENT, NULL);
            assert(!wlr_renderer_begin_buffer_pass(renderer, buffer, &options));
            wlr_log_init(WLR_INFO, NULL);
            assert(!fail_framebuffer);
        }
        struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, buffer, &options);
        assert(pass);
        struct wlr_vk_render_pass_attribs attrs;
        assert(wlr_vk_render_pass_get_attribs(pass, &attrs));
        assert(attrs.uses_fp16_intermediate == (setup == 2));
        if (setup < 2) assert(attrs.intermediate_allocation_bytes == 0);
        wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
            .box = {0, 0, 127, 65}, .color = {0, 0, 0, 1},
            .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
        });
        assert(wlr_render_pass_submit(pass));
        assert(pixel(buffer) == 0);
    }
    for (unsigned cycle = 0; cycle < 4; cycle++) {
        unsigned linear_reference = 0, srgb_reference = 0;
        for (unsigned frame = 0; frame < 22; frame++) {
            bool needs_backdrop = frame == 0 || frame == 20;
            bool is_srgb = frame == 0 || frame == 10;
            bool gamma22 = frame == 21;
            struct wlr_buffer_pass_options options = {
                .color_transform = gamma22 ? NULL : is_srgb ? srgb : linear,
                .sampleable_backdrop = needs_backdrop,
            };
            struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, buffer, &options);
            assert(pass);
            struct wlr_vk_render_pass_attribs attrs;
            assert(wlr_vk_render_pass_get_attribs(pass, &attrs));
            if (needs_backdrop || gamma22) assert(attrs.uses_fp16_intermediate);
            if (!is_srgb && !needs_backdrop && !gamma22) assert(!attrs.uses_fp16_intermediate);
            if (frame == 10) assert(!attrs.uses_fp16_intermediate);
            if (frame >= 9 && frame < 20) assert(attrs.intermediate_allocation_bytes == 0);
            wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
                .box = {0, 0, 127, 65}, .color = {0.2f, 0.2f, 0.2f, 1.0f},
                .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
            });
            if (needs_backdrop) assert(wlr_vk_render_pass_run_offscreen(pass, backdrop, NULL));
            // Exercise linear blending and alpha on direct and intermediate paths.
            wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
                .box = {0, 0, 127, 65}, .color = {0.25f, 0.25f, 0.25f, 0.5f},
            });
            assert(wlr_render_pass_submit(pass));
            unsigned value = pixel(buffer); // presentation copy also proves completion
            if (frame == 0) srgb_reference = value;
            if (frame == 1) linear_reference = value;
            if (frame == 10) assert(abs((int)value - (int)srgb_reference) <= 1);
            if (frame == 20) assert(abs((int)value - (int)linear_reference) <= 1);
        }
    }
    wlr_color_transform_unref(linear);
    wlr_color_transform_unref(srgb);
    wlr_buffer_unlock(buffer);
    wlr_output_state_finish(&state);
    wlr_backend_destroy(backend);
    wlr_renderer_destroy(renderer);
    wlr_allocator_destroy(allocator);
    wl_display_destroy(display);
    puts("PASS: direct/FP16 transitions, alpha, sRGB parity, gamma22 fallback, allocation retries and intermediate release");
}
