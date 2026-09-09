// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
// Real Wayland capture protocols and output sources with an in-memory renderer.
// This checks protocol/copy behavior without claiming GPU renderer coverage.
#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wlr/backend/interface.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/interfaces/wlr_output.h>
#include <wlr/render/allocator.h>
#include <wlr/render/interface.h>
#include <wlr/render/vulkan.h>
#include <wlr/types/wlr_ext_image_capture_source_v1.h>
#include <wlr/types/wlr_ext_image_copy_capture_v1.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_shm.h>
#include <drm_fourcc.h>
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"
#include "aqueous-capture-color-v1-client-protocol.h"
#include "wlr-screencopy-unstable-v1-client-protocol.h"

#ifndef CAPTURE_WIDTH
#define CAPTURE_WIDTH 1024
#define CAPTURE_HEIGHT 2
#endif
enum { WIDTH = CAPTURE_WIDTH, HEIGHT = CAPTURE_HEIGHT };
static double commit_ms;
static struct wl_display *server, *client;
static struct wlr_drm_format_set render_formats;
static struct wlr_output output;
static bool fail_import, fail_read, empty_damage_next;
static size_t live_buffers, live_textures, reads;
static struct wlr_renderer *gpu_renderer;
static struct wlr_allocator *gpu_allocator;

struct memory_buffer { struct wlr_buffer base; uint32_t format; uint8_t *pixels; };
struct memory_texture { struct wlr_texture base; struct memory_buffer *buffer; };

static void buffer_destroy(struct wlr_buffer *base) {
	struct memory_buffer *b = wl_container_of(base, b, base);
	free(b->pixels); free(b); live_buffers--;
}
static bool buffer_access(struct wlr_buffer *base, uint32_t flags, void **data,
        uint32_t *format, size_t *stride) {
	struct memory_buffer *b = wl_container_of(base, b, base);
	*data = b->pixels; *format = b->format; *stride = (size_t)base->width * 4;
	return true;
}
static void buffer_end_access(struct wlr_buffer *base) {}
static const struct wlr_buffer_impl buffer_impl = {
	.destroy = buffer_destroy, .begin_data_ptr_access = buffer_access, .end_data_ptr_access = buffer_end_access,
};
static struct wlr_buffer *allocate(struct wlr_allocator *allocator, int width, int height,
		const struct wlr_drm_format *format) {
	struct memory_buffer *b = calloc(1, sizeof(*b)); assert(b);
	wlr_buffer_init(&b->base, &buffer_impl, width, height);
	b->format = format->format;
	b->pixels = calloc((size_t)width * height, 4); assert(b->pixels);
	live_buffers++;
	return &b->base;
}
static void allocator_destroy(struct wlr_allocator *allocator) {}
static const struct wlr_allocator_interface allocator_impl = {
	.create_buffer = allocate, .destroy = allocator_destroy,
};
static const struct wlr_drm_format_set *texture_formats(struct wlr_renderer *renderer, uint32_t caps) {
	return &render_formats;
}
static const struct wlr_drm_format_set *get_render_formats(struct wlr_renderer *renderer) {
	return &render_formats;
}
static void texture_destroy(struct wlr_texture *base) { free(base); live_textures--; }
static uint32_t preferred_format(struct wlr_texture *base) {
	struct memory_texture *t = wl_container_of(base, t, base);
	return t->buffer->format;
}
static bool read_pixels(struct wlr_texture *base, const struct wlr_texture_read_pixels_options *o) {
	if (fail_read) return false;
	struct memory_texture *t = wl_container_of(base, t, base);
	assert(o->format == t->buffer->format); // Conversion must read native pixels.
	struct wlr_box box;
	wlr_texture_read_pixels_options_get_src_box(o, base, &box);
	uint8_t *data = wlr_texture_read_pixel_options_get_data(o);
	for (int y = 0; y < box.height; y++) {
		memcpy(data + (size_t)y * o->stride,
			t->buffer->pixels + ((size_t)(y + box.y) * base->width + box.x) * 4,
			(size_t)box.width * 4);
	}
	reads++;
	return true;
}
static const struct wlr_texture_impl texture_impl = {
	.destroy = texture_destroy, .preferred_read_format = preferred_format, .read_pixels = read_pixels,
};
static struct wlr_texture *import_texture(struct wlr_renderer *renderer, struct wlr_buffer *buffer) {
	if (fail_import) return NULL;
	assert(buffer->impl == &buffer_impl);
	struct memory_texture *t = calloc(1, sizeof(*t)); assert(t);
	wlr_texture_init(&t->base, renderer, &texture_impl, buffer->width, buffer->height);
	t->buffer = wl_container_of(buffer, t->buffer, base);
	live_textures++;
	return &t->base;
}
static struct wlr_render_pass *begin_pass(struct wlr_renderer *renderer, struct wlr_buffer *buffer,
		const struct wlr_buffer_pass_options *options) { return NULL; }
static void renderer_destroy(struct wlr_renderer *renderer) {}
static const struct wlr_renderer_impl renderer_impl = {
	.get_texture_formats = texture_formats, .get_render_formats = get_render_formats,
	.texture_from_buffer = import_texture, .begin_buffer_pass = begin_pass, .destroy = renderer_destroy,
};
static bool output_commit(struct wlr_output *o, const struct wlr_output_state *state) { return true; }
static const struct wlr_output_impl output_impl = {.commit = output_commit, .destroy = wlr_output_finish};
static const struct wlr_backend_impl backend_impl = {0};

static struct wl_shm *shm;
static struct wl_output *wl_output;
static struct ext_output_image_capture_source_manager_v1 *sources;
static struct ext_image_copy_capture_manager_v1 *captures;
static struct aqueous_capture_color_manager_v1 *colors;
static struct zwlr_screencopy_manager_v1 *legacy;
static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version) {
#define BIND(variable, iface, v) if (!strcmp(interface, #iface)) variable = wl_registry_bind(registry, name, &iface##_interface, v)
	BIND(shm, wl_shm, 1);
	BIND(wl_output, wl_output, 1);
	BIND(sources, ext_output_image_capture_source_manager_v1, 1);
	BIND(captures, ext_image_copy_capture_manager_v1, 1);
	BIND(colors, aqueous_capture_color_manager_v1, 1);
	BIND(legacy, zwlr_screencopy_manager_v1, 3);
#undef BIND
}
static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};
static void sync_done(void *data, struct wl_callback *cb, uint32_t serial) {
	*(bool *)data = true; wl_callback_destroy(cb);
}
static const struct wl_callback_listener sync_listener = {.done = sync_done};
static void roundtrip(void) {
	bool done = false;
	struct wl_callback *cb = wl_display_sync(client);
	wl_callback_add_listener(cb, &sync_listener, &done);
	assert(wl_display_flush(client) >= 0);
	assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
	wl_display_flush_clients(server);
	while (!done) assert(wl_display_dispatch(client) >= 0);
}

struct session {
	struct ext_image_capture_source_v1 *source;
	struct ext_image_copy_capture_session_v1 *proxy;
	uint32_t formats[16], width, height;
	size_t count;
	unsigned batches;
	bool batch, stopped;
};
static void session_size(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h) {
	struct session *v = data; if (!v->batch) v->count = 0; v->batch = true; v->width = w; v->height = h;
}
static void session_shm(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t format) {
	struct session *v = data; if (!v->batch) v->count = 0; v->batch = true;
	assert(v->count < 16); v->formats[v->count++] = format;
}
static void session_device(void *data, struct ext_image_copy_capture_session_v1 *s, struct wl_array *a) {}
static void session_dmabuf(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t f, struct wl_array *a) {}
static void session_done(void *data, struct ext_image_copy_capture_session_v1 *s) {
	struct session *v = data; v->batch = false; v->batches++;
}
static void session_stopped(void *data, struct ext_image_copy_capture_session_v1 *s) { ((struct session *)data)->stopped = true; }
static const struct ext_image_copy_capture_session_v1_listener session_listener = {
	.buffer_size = session_size, .shm_format = session_shm, .dmabuf_device = session_device,
	.dmabuf_format = session_dmabuf, .done = session_done, .stopped = session_stopped,
};
static void session_init(struct session *s) {
	*s = (struct session){0};
	s->source = ext_output_image_capture_source_manager_v1_create_source(sources, wl_output);
	s->proxy = ext_image_copy_capture_manager_v1_create_session(captures, s->source, 0);
	ext_image_copy_capture_session_v1_add_listener(s->proxy, &session_listener, s);
	roundtrip(); assert(s->batches == 1);
}
static bool has_format(struct session *s, uint32_t f) {
	for (size_t i = 0; i < s->count; i++) if (s->formats[i] == f) return true;
	return false;
}
struct frame {
	struct ext_image_copy_capture_frame_v1 *proxy;
	struct aqueous_capture_color_info_v1 *info;
	struct wl_buffer *buffer;
	uint8_t *pixels;
	size_t stride, size;
	bool ready, failed, color_done, unavailable;
	uint32_t reason, primaries, tf, reference, white, mastering_max, max_cll;
};
static void frame_transform(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t t) {}
static void frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y, int32_t w, int32_t h) {}
static void frame_time(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c) {}
static void frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *f) {
	struct frame *v = data; assert(v->color_done || v->unavailable); v->ready = true;
}
static void frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
	struct frame *v = data; v->failed = true; v->reason = reason;
}
static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
	.transform = frame_transform, .damage = frame_damage, .presentation_time = frame_time,
	.ready = frame_ready, .failed = frame_failed,
};
static void color_encoding(void *data, struct aqueous_capture_color_info_v1 *i, uint32_t p, uint32_t tf, uint32_t r, uint32_t w) {
	struct frame *v = data; v->primaries = p; v->tf = tf; v->reference = r; v->white = w;
}
static void color_mastering(void *data, struct aqueous_capture_color_info_v1 *i,
		uint32_t rx, uint32_t ry, uint32_t gx, uint32_t gy, uint32_t bx, uint32_t by,
		uint32_t wx, uint32_t wy, uint32_t min, uint32_t max) { ((struct frame *)data)->mastering_max = max; }
static void color_light(void *data, struct aqueous_capture_color_info_v1 *i, uint32_t cll, uint32_t fall) { ((struct frame *)data)->max_cll = cll; }
static void color_done(void *data, struct aqueous_capture_color_info_v1 *i) {
	struct frame *v = data; assert(!v->unavailable && !v->color_done); v->color_done = true;
}
static void color_unavailable(void *data, struct aqueous_capture_color_info_v1 *i) {
	struct frame *v = data; assert(!v->unavailable && !v->color_done); v->unavailable = true;
}
static const struct aqueous_capture_color_info_v1_listener color_listener = {
	.encoding = color_encoding, .mastering_display = color_mastering, .content_light = color_light,
	.done = color_done, .unavailable = color_unavailable,
};
static void frame_init(struct frame *f, struct session *s, uint32_t format, bool start) {
	*f = (struct frame){0};
	f->stride = WIDTH * 4 + 16; f->size = f->stride * HEIGHT;
	int fd = memfd_create("capture-fixture", MFD_CLOEXEC); assert(fd >= 0);
	assert(ftruncate(fd, (off_t)f->size) == 0);
	f->pixels = mmap(NULL, f->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	assert(f->pixels != MAP_FAILED); memset(f->pixels, 0xA5, f->size);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)f->size);
	f->buffer = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, (int32_t)f->stride, format);
	wl_shm_pool_destroy(pool); close(fd);
	f->proxy = ext_image_copy_capture_session_v1_create_frame(s->proxy);
	ext_image_copy_capture_frame_v1_add_listener(f->proxy, &frame_listener, f);
	f->info = aqueous_capture_color_manager_v1_get_frame_info(colors, f->proxy);
	aqueous_capture_color_info_v1_add_listener(f->info, &color_listener, f);
	ext_image_copy_capture_frame_v1_attach_buffer(f->proxy, f->buffer);
	ext_image_copy_capture_frame_v1_damage_buffer(f->proxy, 0, 0, WIDTH, HEIGHT);
	if (start) ext_image_copy_capture_frame_v1_capture(f->proxy);
	roundtrip();
}
static void frame_finish(struct frame *f) {
	ext_image_copy_capture_frame_v1_destroy(f->proxy);
	aqueous_capture_color_info_v1_destroy(f->info);
	wl_buffer_destroy(f->buffer); munmap(f->pixels, f->size); roundtrip();
}
static void padding_unchanged(struct frame *f) {
	for (int y = 0; y < HEIGHT; y++) for (size_t x = WIDTH * 4; x < f->stride; x++)
		assert(f->pixels[(size_t)y * f->stride + x] == 0xA5);
}

struct legacy_shot {
	struct zwlr_screencopy_frame_v1 *proxy;
	struct wl_buffer *buffer;
	uint8_t *pixels;
	size_t size;
	unsigned buffers;
	uint32_t expected_format;
	bool ready, failed;
};
static void legacy_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame,
		uint32_t format, uint32_t width, uint32_t height, uint32_t stride) {
	struct legacy_shot *s = data;
	assert(++s->buffers == 1 && format == s->expected_format);
	assert(width == 64 && height == 1 && stride == width * 4);
	s->size = (size_t)stride * height;
	int fd = memfd_create("legacy-capture-fixture", MFD_CLOEXEC); assert(fd >= 0);
	assert(ftruncate(fd, (off_t)s->size) == 0);
	s->pixels = mmap(NULL, s->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	assert(s->pixels != MAP_FAILED);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)s->size);
	s->buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, format);
	wl_shm_pool_destroy(pool); close(fd);
}
static void legacy_flags(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t flags) {}
static void legacy_ready(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t a, uint32_t b, uint32_t c) {
	((struct legacy_shot *)data)->ready = true;
}
static void legacy_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) { ((struct legacy_shot *)data)->failed = true; }
static void legacy_damage(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {}
static void legacy_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format, uint32_t w, uint32_t h) {}
static void legacy_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {
	struct legacy_shot *s = data; assert(s->buffer); zwlr_screencopy_frame_v1_copy(frame, s->buffer);
}
static const struct zwlr_screencopy_frame_v1_listener legacy_listener = {
	.buffer = legacy_buffer, .flags = legacy_flags, .ready = legacy_ready, .failed = legacy_failed,
	.damage = legacy_damage, .linux_dmabuf = legacy_dmabuf, .buffer_done = legacy_done,
};

static struct wlr_output_image_description hdr(double white) {
	struct wlr_output_image_description d = {
		.primaries = WLR_COLOR_NAMED_PRIMARIES_BT2020,
		.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ,
		.sdr_white_level = white, .mastering_luminance = {.min = 0.005, .max = 1000},
		.max_cll = 1000, .max_fall = 400,
	};
	wlr_color_primaries_from_named(&d.mastering_display_primaries, d.primaries);
	return d;
}
static void commit_buffer(struct memory_buffer *b, const struct wlr_output_image_description *desc, bool set_desc) {
	struct wlr_output_state state; wlr_output_state_init(&state);
	struct wlr_buffer *gpu_buffer = NULL;
	if (gpu_renderer) {
		const struct wlr_drm_format_set *set = gpu_renderer->WLR_PRIVATE.impl->get_render_formats(gpu_renderer);
		const struct wlr_drm_format *format = wlr_drm_format_set_get(set, b->format);
		assert(format);
		gpu_buffer = wlr_allocator_create_buffer(gpu_allocator, WIDTH, HEIGHT, format); assert(gpu_buffer);
		struct wlr_texture *upload = wlr_texture_from_pixels(gpu_renderer, b->format,
			WIDTH * 4, WIDTH, HEIGHT, b->pixels); assert(upload);
		struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(gpu_renderer, gpu_buffer, NULL); assert(pass);
		wlr_render_pass_add_texture(pass, &(struct wlr_render_texture_options) {
			.texture = upload, .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
		});
		assert(wlr_render_pass_submit(pass)); wlr_texture_destroy(upload);
		// Reference the actual committed GPU buffer. Native capture must match
		// it exactly; fixture rendering itself is not a bit-preserving upload.
		struct wlr_texture *reference = wlr_texture_from_buffer(gpu_renderer, gpu_buffer); assert(reference);
		assert(wlr_texture_read_pixels(reference, &(struct wlr_texture_read_pixels_options) {
			.data = b->pixels, .format = b->format, .stride = WIDTH * 4,
		}));
		wlr_texture_destroy(reference);
	}
	wlr_output_state_set_buffer(&state, gpu_buffer ? gpu_buffer : &b->base);
	wlr_output_state_set_render_format(&state, b->format);
	if (empty_damage_next) {
		pixman_region32_t damage; pixman_region32_init(&damage);
		wlr_output_state_set_damage(&state, &damage); pixman_region32_fini(&damage);
		empty_damage_next = false;
	}
	if (set_desc) assert(wlr_output_state_set_image_description(&state, desc));
	struct timespec start, end;
	assert(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
	assert(wlr_output_commit_state(&output, &state));
	assert(clock_gettime(CLOCK_MONOTONIC, &end) == 0);
	commit_ms = (end.tv_sec - start.tv_sec) * 1000.0 + (end.tv_nsec - start.tv_nsec) / 1000000.0;
	wlr_output_state_finish(&state); wlr_output_send_frame(&output);
	if (gpu_buffer) wlr_buffer_drop(gpu_buffer);
	roundtrip();
}
static void color_only(const struct wlr_output_image_description *desc) {
	struct wlr_output_state state; wlr_output_state_init(&state);
	assert(wlr_output_state_set_image_description(&state, desc));
	assert(wlr_output_commit_state(&output, &state));
	wlr_output_state_finish(&state); roundtrip();
}

static void fill_ramp(struct memory_buffer *b) {
	for (int y = 0; y < HEIGHT; y++) for (unsigned x = 0; x < WIDTH; x++) {
		uint32_t value = x % 1024;
		uint32_t pixel = value | value << 10 | value << 20 | 3u << 30;
		memcpy(b->pixels + ((size_t)y * WIDTH + x) * 4, &pixel, 4);
	}
}

static void save_capture(const struct frame *native, const struct frame *sdr) {
	const char *directory = getenv("AQUEOUS_CAPTURE_ARTIFACT_DIR");
	if (!directory) return;
	char path[4096];
	const struct frame *frames[] = {native, sdr};
	const char *names[] = {"native-xb30.raw", "sdr-xrgb8888.raw"};
	for (size_t i = 0; i < 2; i++) {
		int n = snprintf(path, sizeof(path), "%s/%s", directory, names[i]); assert(n > 0 && n < (int)sizeof(path));
		FILE *file = fopen(path, "wb"); assert(file);
		assert(fwrite(frames[i]->pixels, 1, frames[i]->size, file) == frames[i]->size);
		assert(fclose(file) == 0);
	}
	int n = snprintf(path, sizeof(path), "%s/capture.json", directory); assert(n > 0 && n < (int)sizeof(path));
	FILE *file = fopen(path, "w"); assert(file);
	fprintf(file, "{\"width\":%d,\"height\":%d,\"stride\":%zu,\"synthetic_output\":true,"
		"\"vulkan\":%s,\"native_tf\":%u,\"native_primaries\":%u,\"reference_white_1e4\":%u,"
		"\"sdr_white_1e4\":%u,\"sdr_tf\":%u,\"dual_capture_commit_ms\":%.3f}\n",
		WIDTH, HEIGHT, native->stride, gpu_renderer ? "true" : "false", native->tf,
		native->primaries, native->reference, native->white, sdr->tf, commit_ms);
	assert(fclose(file) == 0);
}

int main(int argc, char **argv) {
	alarm(60);
	setvbuf(stdout, NULL, _IOLBF, 0);
	server = wl_display_create(); assert(server);
	struct wlr_backend backend; wlr_backend_init(&backend, &backend_impl);
	backend.buffer_caps = WLR_BUFFER_CAP_DATA_PTR;
	uint32_t formats[] = {DRM_FORMAT_XRGB8888, DRM_FORMAT_ARGB8888,
		DRM_FORMAT_XBGR2101010, DRM_FORMAT_ABGR2101010, DRM_FORMAT_XRGB2101010, DRM_FORMAT_ARGB2101010};
	for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++)
		assert(wlr_drm_format_set_add(&render_formats, formats[i], DRM_FORMAT_MOD_LINEAR));
	struct wlr_renderer renderer;
	wlr_renderer_init(&renderer, &renderer_impl, WLR_BUFFER_CAP_DATA_PTR);
	struct wlr_allocator allocator;
	wlr_allocator_init(&allocator, &allocator_impl, WLR_BUFFER_CAP_DATA_PTR);
	int gpu_fd = -1;
	if (argc == 3 && !strcmp(argv[1], "--vulkan")) {
		gpu_fd = open(argv[2], O_RDWR | O_CLOEXEC); assert(gpu_fd >= 0);
		gpu_renderer = wlr_vk_renderer_create_with_drm_fd(gpu_fd); assert(gpu_renderer);
		backend.buffer_caps = WLR_BUFFER_CAP_DMABUF;
		gpu_allocator = wlr_allocator_autocreate(&backend, gpu_renderer); assert(gpu_allocator);
		printf("Vulkan capture fixture on %s (synthetic output, no desktop capture)\n", argv[2]);
	} else {
		assert(argc == 1);
	}
	struct wlr_output_state initial; wlr_output_state_init(&initial);
	wlr_output_state_set_enabled(&initial, true);
	wlr_output_state_set_custom_mode(&initial, WIDTH, HEIGHT, 60000);
	wlr_output_state_set_render_format(&initial, DRM_FORMAT_XBGR2101010);
	struct wlr_output_image_description description = hdr(200);
	assert(wlr_output_state_set_image_description(&initial, &description));
	wlr_output_init(&output, &backend, &output_impl, wl_display_get_event_loop(server), &initial);
	wlr_output_state_finish(&initial);
	output.supported_primaries = WLR_COLOR_NAMED_PRIMARIES_SRGB | WLR_COLOR_NAMED_PRIMARIES_BT2020;
	output.supported_transfer_functions = WLR_COLOR_TRANSFER_FUNCTION_GAMMA22 | WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ;
	wlr_output_set_name(&output, "CAPTURE-TEST");
	assert(wlr_output_init_render(&output, gpu_allocator ? gpu_allocator : &allocator,
		gpu_renderer ? gpu_renderer : &renderer));
	wlr_output_create_global(&output, server);
	assert(wlr_shm_create(server, 1, formats, sizeof(formats) / sizeof(formats[0])));
	assert(wlr_ext_output_image_capture_source_manager_v1_create(server, 1));
	assert(wlr_ext_image_copy_capture_manager_v1_create(server, 1));
	assert(wlr_aqueous_capture_color_manager_v1_create(server));
	assert(wlr_screencopy_manager_v1_create(server));
	int sockets[2]; assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == 0);
	assert(wl_client_create(server, sockets[0])); client = wl_display_connect_to_fd(sockets[1]); assert(client);
	struct wl_registry *registry = wl_display_get_registry(client);
	wl_registry_add_listener(registry, &registry_listener, NULL); roundtrip(); roundtrip();
	assert(shm && wl_output && sources && captures && colors && legacy);
	struct session native, sdr; session_init(&native); session_init(&sdr);
	assert(native.count == 2 && has_format(&native, WL_SHM_FORMAT_XRGB8888));
	assert(has_format(&native, WL_SHM_FORMAT_XBGR2101010));

	struct memory_buffer *b;
	struct wlr_drm_format fmt = {.format = DRM_FORMAT_XBGR2101010};
	struct wlr_buffer *base = allocate(&allocator, WIDTH, HEIGHT, &fmt);
	b = wl_container_of(base, b, base);
	fill_ramp(b);
	struct frame nf, sf;
	frame_init(&nf, &native, WL_SHM_FORMAT_XBGR2101010, true);
	frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true);
	commit_buffer(b, NULL, false);
	assert(nf.ready && sf.ready && !nf.failed && !sf.failed);
	bool codes[1024] = {false}; unsigned unique = 0;
	for (size_t x = 0; x < 1024; x++) {
		uint32_t pixel; memcpy(&pixel, nf.pixels + x * 4, 4); codes[pixel & 1023] = true;
	}
	for (size_t x = 0; x < 1024; x++) unique += codes[x];
	assert(unique > 256); // Neither fixture preparation nor native copy is reduced to 8-bit.
	for (int y = 0; y < HEIGHT; y++) assert(!memcmp(nf.pixels + (size_t)y * nf.stride,
		b->pixels + (size_t)y * WIDTH * 4, WIDTH * 4));
	assert(nf.tf == AQUEOUS_CAPTURE_COLOR_INFO_V1_TRANSFER_FUNCTION_PQ && nf.white == 2000000);
	assert(nf.reference == 2030000 && nf.mastering_max == 10000000 && nf.max_cll == 10000000);
	assert(sf.tf == AQUEOUS_CAPTURE_COLOR_INFO_V1_TRANSFER_FUNCTION_GAMMA22 && sf.white == 800000);
	assert(sf.mastering_max == 0 && sf.max_cll == 0);
	assert(sf.pixels[0] == 0 && sf.pixels[594 * 4] >= 253 && sf.pixels[1023 * 4] == 255);
	padding_unchanged(&nf); padding_unchanged(&sf); save_capture(&nf, &sf);
	frame_finish(&nf); frame_finish(&sf);
	puts("PASS: simultaneous native 10-bit and SDR capture, metadata ordering, padding");
	if (getenv("AQUEOUS_CAPTURE_BENCHMARK")) {
		double total = 0, max = 0;
		for (int i = 0; i < 3; i++) {
			frame_init(&nf, &native, WL_SHM_FORMAT_XBGR2101010, true);
			frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true); commit_buffer(b, NULL, false);
			assert(nf.ready && sf.ready); total += commit_ms; if (commit_ms > max) max = commit_ms;
			frame_finish(&nf); frame_finish(&sf);
		}
		printf("BENCH: %dx%d native+SDR synchronous capture, mean %.3f ms, max %.3f ms (3 samples); conversion temporary %zu bytes\n",
			WIDTH, HEIGHT, total / 3, max, (size_t)WIDTH * HEIGHT * 4);
	}

	size_t before = reads;
	frame_init(&sf, &sdr, WL_SHM_FORMAT_ARGB8888, true); // wl_shm supports it; this source doesn't.
	commit_buffer(b, NULL, false);
	assert(sf.failed && sf.reason == EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS);
	assert(reads == before && sf.unavailable); frame_finish(&sf);
	frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true); commit_buffer(b, NULL, false);
	assert(sf.ready); frame_finish(&sf);
	puts("PASS: unsupported format rejected without readback; client can retry");

	frame_init(&nf, &native, WL_SHM_FORMAT_XBGR2101010, true);
	description = hdr(400); description.mastering_luminance.max = 400;
	description.max_cll = 400; description.max_fall = 200; color_only(&description);
	empty_damage_next = true; commit_buffer(b, NULL, false);
	assert(nf.ready && nf.white == 4000000 && nf.mastering_max == 4000000 && nf.max_cll == 4000000);
	frame_finish(&nf);
	frame_init(&nf, &native, WL_SHM_FORMAT_XBGR2101010, false);
	b->format = DRM_FORMAT_XRGB8888; commit_buffer(b, NULL, true);
	assert(native.count == 1 && has_format(&native, WL_SHM_FORMAT_XRGB8888));
	ext_image_copy_capture_frame_v1_capture(nf.proxy); roundtrip(); commit_buffer(b, NULL, false);
	assert(nf.failed && nf.reason == EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS);
	frame_finish(&nf);
	frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true); commit_buffer(b, NULL, false);
	assert(sf.ready && sf.tf == AQUEOUS_CAPTURE_COLOR_INFO_V1_TRANSFER_FUNCTION_GAMMA22); frame_finish(&sf);
	puts("PASS: color-only updates use current frame metadata; HDR toggle rejects stale buffers");

	b->format = DRM_FORMAT_XBGR2101010; commit_buffer(b, NULL, true);
	frame_init(&nf, &native, WL_SHM_FORMAT_XBGR2101010, true); commit_buffer(b, NULL, false);
	assert(nf.ready && nf.tf == AQUEOUS_CAPTURE_COLOR_INFO_V1_TRANSFER_FUNCTION_GAMMA22); frame_finish(&nf);
	frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true); commit_buffer(b, NULL, false);
	uint32_t sdr_pixel; memcpy(&sdr_pixel, b->pixels + 512 * 4, 4);
	assert(sf.ready && sf.pixels[512 * 4] == (((sdr_pixel >> 20) & 1023) * 255 + 511) / 1023);
	frame_finish(&sf);
	puts("PASS: 10-bit SDR is not decoded as PQ");

	for (size_t i = 2; i < sizeof(formats) / sizeof(formats[0]); i++) {
		// Aqueous HDR outputs use opaque XB30/XR30. Alpha layouts are covered
		// by the deterministic renderer; not every GBM driver allocates them.
		if (gpu_renderer && (formats[i] == DRM_FORMAT_ABGR2101010 || formats[i] == DRM_FORMAT_ARGB2101010)) continue;
		if (gpu_renderer) {
			const struct wlr_drm_format_set *set = gpu_renderer->WLR_PRIVATE.impl->get_render_formats(gpu_renderer);
			const struct wlr_drm_format *f = wlr_drm_format_set_get(set, formats[i]);
			struct wlr_buffer *probe = f ? wlr_allocator_create_buffer(gpu_allocator, WIDTH, HEIGHT, f) : NULL;
			if (!probe) {
				printf("SKIP: GPU cannot allocate optional output format 0x%08x\n", formats[i]);
				continue;
			}
			wlr_buffer_drop(probe);
		}
		b->format = formats[i]; fill_ramp(b); commit_buffer(b, &description, true);
		assert(native.count == 2 && has_format(&native, formats[i]));
		frame_init(&nf, &native, formats[i], true);
		frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true); commit_buffer(b, NULL, false);
		assert(nf.ready && sf.ready);
		assert(!memcmp(nf.pixels, b->pixels, WIDTH * 4));
		assert(sf.pixels[0] == 0 && sf.pixels[1023 * 4] == 255);
		frame_finish(&nf); frame_finish(&sf);
	}
	puts(gpu_renderer ? "PASS: allocatable Aqueous HDR output formats retain native samples" :
		"PASS: all four advertised 10-bit layouts retain native samples");
	struct legacy_shot shot = {.expected_format = WL_SHM_FORMAT_XRGB8888};
	shot.proxy = zwlr_screencopy_manager_v1_capture_output_region(legacy, 0, wl_output, 512, 1, 64, 1);
	zwlr_screencopy_frame_v1_add_listener(shot.proxy, &legacy_listener, &shot);
	roundtrip(); roundtrip(); commit_buffer(b, NULL, false);
	assert(shot.ready && !shot.failed && shot.buffers == 1);
	assert(shot.pixels[0] > 0 && shot.pixels[63 * 4] > shot.pixels[0]);
	zwlr_screencopy_frame_v1_destroy(shot.proxy); wl_buffer_destroy(shot.buffer);
	munmap(shot.pixels, shot.size); roundtrip();
	puts("PASS: legacy screencopy advertises one 8-bit format and copies an HDR region");
	b->format = DRM_FORMAT_ARGB8888; commit_buffer(b, NULL, true);
	shot = (struct legacy_shot){.expected_format = WL_SHM_FORMAT_ARGB8888};
	shot.proxy = zwlr_screencopy_manager_v1_capture_output_region(legacy, 0, wl_output, 512, 1, 64, 1);
	zwlr_screencopy_frame_v1_add_listener(shot.proxy, &legacy_listener, &shot);
	roundtrip(); roundtrip();
	b->format = DRM_FORMAT_XBGR2101010; fill_ramp(b); commit_buffer(b, &description, true);
	assert(shot.failed && !shot.ready);
	zwlr_screencopy_frame_v1_destroy(shot.proxy); wl_buffer_destroy(shot.buffer);
	munmap(shot.pixels, shot.size); roundtrip();
	puts("PASS: legacy frame with obsolete 8-bit packing fails instead of leaking raw PQ");

	for (int failure = 0; !gpu_renderer && failure < 2; failure++) {
		frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true);
		fail_import = failure == 0; fail_read = failure == 1;
		commit_buffer(b, NULL, false); fail_import = fail_read = false;
		assert(sf.failed && sf.unavailable && live_textures == 0); frame_finish(&sf);
	}
	frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, false); frame_finish(&sf);
	frame_init(&sf, &sdr, WL_SHM_FORMAT_XRGB8888, true);
	wlr_output_destroy(&output); roundtrip();
	assert(sf.failed && sf.unavailable && sdr.stopped && native.stopped); frame_finish(&sf);
	puts(gpu_renderer ? "PASS: cancellation, output removal and metadata lifetime" :
		"PASS: import/read failure, cancellation, output removal and metadata lifetime");
	ext_image_copy_capture_session_v1_destroy(native.proxy); ext_image_capture_source_v1_destroy(native.source);
	ext_image_copy_capture_session_v1_destroy(sdr.proxy); ext_image_capture_source_v1_destroy(sdr.source);
	wl_display_disconnect(client); wl_display_destroy_clients(server); wl_display_destroy(server);
	wlr_buffer_drop(base); wlr_allocator_destroy(&allocator); wlr_renderer_destroy(&renderer);
	wlr_backend_finish(&backend); wlr_drm_format_set_finish(&render_formats);
	if (gpu_allocator) wlr_allocator_destroy(gpu_allocator);
	if (gpu_renderer) wlr_renderer_destroy(gpu_renderer);
	if (gpu_fd >= 0) close(gpu_fd);
	assert(live_buffers == 0 && live_textures == 0);
	return 0;
}
