// SPDX-License-Identifier: GPL-3.0-only
// Real protocol commits and the production luminance helper, without a GPU.
#include <assert.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <wayland-client.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_single_pixel_buffer_v1.h>
#include "color-management-v1-client-protocol.h"
#include "single-pixel-buffer-v1-client-protocol.h"
#include "scene-luminance.h"

static struct wl_display *server, *client;
static struct wl_compositor *compositor;
static struct wp_color_manager_v1 *manager;
static struct wp_single_pixel_buffer_manager_v1 *pixels;
static struct wlr_scene *scene;
static struct wlr_scene_surface *live;
static struct wl_listener new_surface;

static void new_surface_notify(struct wl_listener *listener, void *data) {
	live = wlr_scene_surface_create(&scene->tree, data);
	assert(live);
}

static void manager_value(void *data, struct wp_color_manager_v1 *object, uint32_t value) {}
static void manager_done(void *data, struct wp_color_manager_v1 *object) {}
static const struct wp_color_manager_v1_listener manager_listener = {
	.supported_intent = manager_value,
	.supported_feature = manager_value,
	.supported_tf_named = manager_value,
	.supported_primaries_named = manager_value,
	.done = manager_done,
};

static void global(void *data, struct wl_registry *registry, uint32_t id,
		const char *name, uint32_t version) {
	if (!strcmp(name, "wl_compositor")) {
		compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
	} else if (!strcmp(name, "wp_color_manager_v1")) {
		manager = wl_registry_bind(registry, id, &wp_color_manager_v1_interface, 1);
		wp_color_manager_v1_add_listener(manager, &manager_listener, NULL);
	} else if (!strcmp(name, "wp_single_pixel_buffer_manager_v1")) {
		pixels = wl_registry_bind(registry, id, &wp_single_pixel_buffer_manager_v1_interface, 1);
	}
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t id) {}
static const struct wl_registry_listener registry_listener = {global, global_remove};

static void sync_done(void *data, struct wl_callback *callback, uint32_t serial) {
	*(bool *)data = true;
	wl_callback_destroy(callback);
}
static const struct wl_callback_listener sync_listener = {sync_done};
static void sync_client(void) {
	bool synced = false;
	struct wl_callback *callback = wl_display_sync(client);
	wl_callback_add_listener(callback, &sync_listener, &synced);
	for (unsigned i = 0; i < 100 && !synced; i++) {
		assert(wl_display_flush(client) >= 0);
		assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
		wl_display_flush_clients(server);
		struct pollfd fd = {wl_display_get_fd(client), POLLIN, 0};
		if (poll(&fd, 1, 10) > 0) assert(wl_display_dispatch(client) >= 0);
	}
	assert(synced);
}

static void description_ready(void *data, struct wp_image_description_v1 *description, uint32_t id) {
	*(bool *)data = true;
}
static void description_failed(void *data, struct wp_image_description_v1 *description,
		uint32_t cause, const char *message) {
	fprintf(stderr, "image description failed: %s\n", message);
	assert(false);
}
static const struct wp_image_description_v1_listener description_listener = {
	.ready = description_ready,
	.failed = description_failed,
};

static void expect_near(float actual, float expected) {
	if (fabsf(actual - expected) > 0.00001f * fmaxf(1, fabsf(expected))) {
		fprintf(stderr, "luminance: got %f, expected %f\n", actual, expected);
		assert(false);
	}
}

static void check_luminance(struct wlr_scene_buffer *snapshot) {
	struct wlr_scene_buffer *linear = wlr_scene_buffer_create(&scene->tree, NULL);
	struct wlr_scene_buffer *pq = wlr_scene_buffer_create(&scene->tree, NULL);
	assert(linear && pq);
	wlr_scene_buffer_set_transfer_function(linear, WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR);
	wlr_scene_buffer_set_transfer_function(pq, WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ);
	struct wlr_output_image_description out = {
		.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ,
	};
	const float whites[] = {80, 100, 200, 203, 400};
	for (size_t i = 0; i < sizeof(whites) / sizeof(whites[0]); i++) {
		out.sdr_white_level = whites[i];
		expect_near(scene_buffer_luminance(live->buffer, &out), 80.0f / 203);
		expect_near(scene_buffer_luminance(snapshot, &out), 80.0f / 203);
		expect_near(scene_buffer_luminance(linear, &out), whites[i] / 203);
		expect_near(scene_buffer_luminance(pq, &out), 10000.0f / 203);
	}
	out.sdr_white_level = 0;
	expect_near(scene_buffer_luminance(snapshot, &out), 80.0f / 203);
	expect_near(scene_buffer_luminance(linear, &out), 1);
	out.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_SRGB;
	for (size_t i = 0; i < sizeof(whites) / sizeof(whites[0]); i++) {
		out.sdr_white_level = whites[i];
		expect_near(scene_buffer_luminance(snapshot, &out), 1);
		expect_near(scene_buffer_luminance(linear, &out), 1);
		expect_near(scene_buffer_luminance(pq, &out), 10000.0f / 203);
	}
	expect_near(scene_buffer_luminance(snapshot, NULL), 1);
	wlr_scene_node_destroy(&linear->node);
	wlr_scene_node_destroy(&pq->node);
}

int main(void) {
	server = wl_display_create();
	assert(server);
	scene = wlr_scene_create();
	assert(scene);
	struct wlr_compositor *wc = wlr_compositor_create(server, 6, NULL);
	assert(wc);
	new_surface.notify = new_surface_notify;
	wl_signal_add(&wc->events.new_surface, &new_surface);
	assert(wlr_single_pixel_buffer_manager_v1_create(server));
	const enum wp_color_manager_v1_render_intent intents[] = {WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL};
	const enum wp_color_manager_v1_transfer_function tfs[] = {WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR};
	const enum wp_color_manager_v1_primaries primaries[] = {WP_COLOR_MANAGER_V1_PRIMARIES_SRGB};
	const struct wlr_color_manager_v1_options options = {
		.features = {.parametric = true, .windows_scrgb = true},
		.render_intents = intents, .render_intents_len = 1,
		.transfer_functions = tfs, .transfer_functions_len = 1,
		.primaries = primaries, .primaries_len = 1,
	};
	assert(wlr_color_manager_v1_create(server, 1, &options));
	int pair[2];
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
	assert(wl_client_create(server, pair[0]));
	client = wl_display_connect_to_fd(pair[1]);
	assert(client);
	struct wl_registry *registry = wl_display_get_registry(client);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	sync_client(); sync_client();
	assert(compositor && manager && pixels);
	struct wl_surface *surface = wl_compositor_create_surface(compositor);
	struct wp_color_management_surface_v1 *color = wp_color_manager_v1_get_surface(manager, surface);
	struct wl_buffer *buffer = wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(
		pixels, UINT32_MAX, UINT32_MAX, UINT32_MAX, UINT32_MAX);
	wl_surface_attach(surface, buffer, 0, 0);
	wl_surface_commit(surface);
	sync_client();
	assert(live && live->surface->current.width == 1);
	assert(!wlr_scene_buffer_get_windows_scrgb(live->buffer));

	bool scrgb_ready = false, linear_ready = false;
	struct wp_image_description_v1 *scrgb = wp_color_manager_v1_create_windows_scrgb(manager);
	wp_image_description_v1_add_listener(scrgb, &description_listener, &scrgb_ready);
	struct wp_image_description_creator_params_v1 *params = wp_color_manager_v1_create_parametric_creator(manager);
	wp_image_description_creator_params_v1_set_tf_named(params, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR);
	wp_image_description_creator_params_v1_set_primaries_named(params, WP_COLOR_MANAGER_V1_PRIMARIES_SRGB);
	struct wp_image_description_v1 *linear = wp_image_description_creator_params_v1_create(params);
	wp_image_description_v1_add_listener(linear, &description_listener, &linear_ready);
	sync_client();
	assert(scrgb_ready && linear_ready);
	wp_color_management_surface_v1_set_image_description(color, scrgb, WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
	sync_client();
	assert(!wlr_scene_buffer_get_windows_scrgb(live->buffer)); // Still pending.
	wl_surface_commit(surface); // No buffer attach or damage: metadata only.
	sync_client();
	assert(wlr_scene_buffer_get_windows_scrgb(live->buffer));
	assert(live->buffer->transfer_function == WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR);
	assert(live->buffer->primaries == WLR_COLOR_NAMED_PRIMARIES_SRGB);
	struct wlr_scene_buffer *snapshot = wlr_scene_buffer_create(&scene->tree, NULL);
	assert(snapshot);
	wlr_scene_buffer_set_transfer_function(snapshot, live->buffer->transfer_function);
	wlr_scene_buffer_set_windows_scrgb(snapshot, wlr_scene_buffer_get_windows_scrgb(live->buffer));
	assert(!wlr_scene_surface_try_from_buffer(snapshot));
	check_luminance(snapshot);

	// Same transfer function and primaries, but ordinary relative linear content.
	wp_color_management_surface_v1_set_image_description(color, linear, WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
	sync_client();
	assert(wlr_scene_buffer_get_windows_scrgb(live->buffer));
	wl_surface_commit(surface);
	sync_client();
	assert(!wlr_scene_buffer_get_windows_scrgb(live->buffer));
	assert(live->buffer->transfer_function == WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR);
	assert(wlr_scene_buffer_get_windows_scrgb(snapshot));
	wp_color_management_surface_v1_set_image_description(color, scrgb, WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
	wl_surface_commit(surface);
	sync_client();
	assert(wlr_scene_buffer_get_windows_scrgb(live->buffer));
	wp_color_management_surface_v1_unset_image_description(color);
	sync_client();
	assert(wlr_scene_buffer_get_windows_scrgb(live->buffer));
	wl_surface_commit(surface);
	sync_client();
	assert(!wlr_scene_buffer_get_windows_scrgb(live->buffer));
	assert(live->buffer->transfer_function == WLR_COLOR_TRANSFER_FUNCTION_GAMMA22);
	assert(wlr_scene_buffer_get_windows_scrgb(snapshot));

	wp_color_management_surface_v1_destroy(color);
	wp_image_description_v1_destroy(scrgb);
	wp_image_description_v1_destroy(linear);
	wl_surface_destroy(surface);
	wl_buffer_destroy(buffer);
	sync_client();
	assert(wlr_scene_buffer_get_windows_scrgb(snapshot));
	wp_single_pixel_buffer_manager_v1_destroy(pixels);
	wp_color_manager_v1_destroy(manager);
	wl_compositor_destroy(compositor);
	wl_registry_destroy(registry);
	wl_display_disconnect(client);
	wl_display_destroy_clients(server);
	wl_list_remove(&new_surface.link);
	wlr_scene_node_destroy(&scene->tree.node);
	wl_display_destroy(server);
	puts("PASS: scRGB snapshot luminance, SDR/PQ controls, committed color transitions and frozen state");
}
