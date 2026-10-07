// SPDX-License-Identifier: GPL-3.0-only
// Exercise real Vulkan rendering, copy, buffer reuse and allocation lifetimes.
#include <assert.h>
#include <drm_fourcc.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/interfaces/wlr_output.h>
#include <wlr/render/allocator.h>
#include <wlr/render/pass.h>
#include <wlr/render/swapchain.h>
#include <wlr/render/vulkan.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_presentation.h>
#include <wlr/util/log.h>

static struct wlr_buffer *fail_allocate(struct wlr_allocator *allocator,
		int width, int height, const struct wlr_drm_format *format) {
	(void)allocator; (void)width; (void)height; (void)format;
	return NULL;
}

static void fail_destroy(struct wlr_allocator *allocator) { free(allocator); }

static const struct wlr_allocator_interface failing_allocator = {
	.create_buffer = fail_allocate, .destroy = fail_destroy,
};

static bool fail_commit(struct wlr_output *output, const struct wlr_output_state *state) {
	(void)output; (void)state;
	return false;
}

static void pixels(struct wlr_buffer *buffer, unsigned channel) {
	void *data;
	uint32_t format;
	size_t stride;
	assert(wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
		&data, &format, &stride));
	assert(format == DRM_FORMAT_XRGB8888 || format == DRM_FORMAT_ARGB8888);
	for (int y = 0; y < buffer->height; y++) {
		for (int x = 0; x < buffer->width; x++) {
			unsigned char *p = (unsigned char *)data + y * stride + x * 4;
			assert(p[channel] == 255);
			assert(p[(channel + 1) % 3] == 0);
			assert(p[(channel + 2) % 3] == 0);
		}
	}
	wlr_buffer_end_data_ptr_access(buffer);
}

int main(void) {
	wlr_log_init(WLR_DEBUG, NULL);
	struct wl_display *display = wl_display_create();
	assert(display);
	struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
	assert(backend);
	const char *node = getenv("AQUEOUS_TEST_RENDER_NODE");
	int fd = node ? open(node, O_RDWR | O_CLOEXEC) : -1;
	assert(!node || fd >= 0);
	struct wlr_renderer *renderer = wlr_vk_renderer_create_with_drm_fd(fd);
	if (fd >= 0) close(fd);
	if (!renderer) {
		wlr_backend_destroy(backend);
		wl_display_destroy(display);
		return 77;
	}
	assert(wlr_vk_renderer_enable_offscreen(renderer));
	struct wlr_allocator *allocator = wlr_allocator_autocreate(backend, renderer);
	assert(allocator);
	struct wlr_output *output = wlr_headless_add_output(backend, 127, 65);
	assert(output && wlr_output_init_render(output, allocator, renderer));
	assert(!wlr_output_try_presentation_copy(output)); // default is unchanged
	// A failed allocation switches only the affected output, and hot-unplug
	// drops its allocator and locks without changing another output's path.
	for (int plug = 0; plug < 2; plug++) {
		struct wlr_allocator *bad = calloc(1, sizeof(*bad));
		assert(bad);
		wlr_allocator_init(bad, &failing_allocator, allocator->buffer_caps);
		struct wlr_output *other = wlr_headless_add_output(backend, 127, 65);
		assert(other && wlr_output_init_render(other, bad, renderer));
		assert(wlr_output_allow_presentation_copy(other, true));
		struct wlr_output_state pending;
		wlr_output_state_init(&pending);
		wlr_output_state_set_enabled(&pending, true);
		wlr_log_init(WLR_SILENT, NULL); // expected allocation failure
		assert(wlr_output_configure_primary_swapchain(other, &pending, &other->swapchain));
		wlr_log_init(WLR_DEBUG, NULL);
		assert(wlr_output_uses_presentation_copy(other));
		assert(!wlr_output_presentation_copy_committed(other));
		assert(!wlr_output_uses_presentation_copy(output));
		assert(output->attach_render_locks == 0 && output->software_cursor_locks == 0);
		wlr_output_state_finish(&pending);
		wlr_output_destroy(other);
		wlr_allocator_destroy(bad);
	}
	assert(wlr_output_allow_presentation_copy(output, true));
	assert(wlr_output_try_presentation_copy(output));
	assert(output->attach_render_locks == 1 && output->software_cursor_locks == 1);
	assert(!wlr_output_try_presentation_copy(output)); // one transition, no lock leak
	for (int size = 0; size < 3; size++) {
		struct wlr_output_state state;
		wlr_output_state_init(&state);
		wlr_output_state_set_custom_mode(&state, 127 + size * 17, 65 + size * 9, 60000);
		wlr_output_state_set_enabled(&state, true);
		assert(wlr_output_configure_primary_swapchain(output, &state, &output->swapchain));
		for (unsigned frame = 0; frame < 24; frame++) {
			struct wlr_buffer *buffer = wlr_swapchain_acquire(output->swapchain);
			assert(buffer);
			struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, buffer, NULL);
			assert(pass);
			unsigned channel = frame % 3;
			struct wlr_render_rect_options rect = {
				.box = {0, 0, buffer->width, buffer->height},
				.color = {channel == 2, channel == 1, channel == 0, 1},
				.blend_mode = WLR_RENDER_BLEND_MODE_NONE,
			};
			wlr_render_pass_add_rect(pass, &rect);
			assert(wlr_render_pass_submit(pass));
			pixels(buffer, channel);
			// Capture/mirror imports must see the completed copied pixels.
			struct wlr_texture *texture = wlr_texture_from_buffer(renderer, buffer);
			assert(texture);
			pass = wlr_renderer_begin_buffer_pass(renderer, buffer, NULL);
			assert(pass);
			wlr_render_pass_add_texture(pass, &(struct wlr_render_texture_options){
				.texture = texture,
				.blend_mode = WLR_RENDER_BLEND_MODE_NONE,
			});
			assert(wlr_render_pass_submit(pass));
			wlr_texture_destroy(texture);
			pixels(buffer, channel);
			wlr_output_state_set_buffer(&state, buffer);
			if (size == 0 && frame == 0) {
				const struct wlr_output_impl *original = output->impl;
				struct wlr_output_impl rejected = *original;
				rejected.commit = fail_commit;
				output->impl = &rejected;
				assert(!wlr_output_commit_state(output, &state));
				assert(!wlr_output_presentation_copy_committed(output));
				output->impl = original;
			}
			assert(wlr_output_commit_state(output, &state));
			assert(wlr_output_presentation_copy_committed(output));
			wlr_buffer_unlock(buffer);
		}
		wlr_output_state_finish(&state);
	}
	assert(wlr_output_init_render(output, allocator, renderer));
	assert(!wlr_output_uses_presentation_copy(output));
	assert(output->attach_render_locks == 0 && output->software_cursor_locks == 0);
	wlr_backend_destroy(backend);
	wlr_renderer_destroy(renderer);
	wlr_allocator_destroy(allocator);
	wl_display_destroy(display);
	puts("PASS: Vulkan allocation fallback, output isolation, hotplug, pixels, reuse, resize, capture import, commit and reset");
}
