// SPDX-License-Identifier: GPL-3.0-only
// Exercise real Wayland resources and the shipped wlroots refresh API.
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <wayland-client.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_output.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include "xdg-output.h"

static struct wl_display *server;
static struct wl_client *projected_client;
static struct wlr_output *outputs[2];
static struct wlr_output_client_projection projections[2];
static unsigned xdg_version;
static unsigned failed_commits;

static bool fail_commit(struct wlr_output *output, const struct wlr_output_state *state) {
	failed_commits++;
	return false;
}

struct observation {
	struct wl_output *output;
	struct zxdg_output_v1 *xdg;
	char name[32];
	uint32_t global_id;
	bool active;
	unsigned positions, sizes, xdg_done, output_done;
	int32_t x, y, width, height;
};

struct connection {
	struct wl_display *display;
	struct wl_registry *registry;
	struct zxdg_output_manager_v1 *manager;
	struct observation heads[16];
	unsigned count;
	bool observing;
};

static bool project(struct wlr_output *output, struct wl_client *client,
		struct wlr_output_client_projection *projection, void *data) {
	if (client != projected_client) {
		return false;
	}
	for (unsigned i = 0; i < 2; i++) {
		if (outputs[i] == output) {
			*projection = projections[i];
			return true;
		}
	}
	return false;
}

static void geometry(void *data, struct wl_output *output, int32_t x, int32_t y,
		int32_t pw, int32_t ph, int32_t subpixel, const char *make,
		const char *model, int32_t transform) {}
static void mode(void *data, struct wl_output *output, uint32_t flags,
		int32_t width, int32_t height, int32_t refresh) {}
static void scale(void *data, struct wl_output *output, int32_t factor) {}
static void output_done(void *data, struct wl_output *output) {
	((struct observation *)data)->output_done++;
}
static void output_name(void *data, struct wl_output *output, const char *name) {
	snprintf(((struct observation *)data)->name, 32, "%s", name);
}
static void output_description(void *data, struct wl_output *output, const char *value) {}
static const struct wl_output_listener output_listener = {
	.geometry = geometry, .mode = mode, .done = output_done, .scale = scale,
	.name = output_name, .description = output_description,
};

static void position(void *data, struct zxdg_output_v1 *output, int32_t x, int32_t y) {
	struct observation *o = data;
	o->positions++;
	o->x = x;
	o->y = y;
}
static void size(void *data, struct zxdg_output_v1 *output, int32_t width, int32_t height) {
	struct observation *o = data;
	o->sizes++;
	o->width = width;
	o->height = height;
}
static void xdg_done(void *data, struct zxdg_output_v1 *output) {
	((struct observation *)data)->xdg_done++;
}
static void xdg_name(void *data, struct zxdg_output_v1 *output, const char *name) {}
static void xdg_description(void *data, struct zxdg_output_v1 *output, const char *value) {}
static const struct zxdg_output_v1_listener xdg_listener = {
	.logical_position = position, .logical_size = size, .done = xdg_done,
	.name = xdg_name, .description = xdg_description,
};

static void global(void *data, struct wl_registry *registry, uint32_t id,
		const char *interface, uint32_t version) {
	struct connection *c = data;
	if (strcmp(interface, "wl_output") == 0) {
		assert(c->count < 16 && version >= 4);
		struct observation *o = &c->heads[c->count++];
		o->global_id = id;
		o->active = true;
		o->output = wl_registry_bind(registry, id, &wl_output_interface, 4);
		wl_output_add_listener(o->output, &output_listener, o);
		if (c->observing) {
			o->xdg = zxdg_output_manager_v1_get_xdg_output(c->manager, o->output);
			zxdg_output_v1_add_listener(o->xdg, &xdg_listener, o);
		}
	} else if (strcmp(interface, "zxdg_output_manager_v1") == 0) {
		assert(version >= xdg_version);
		c->manager = wl_registry_bind(registry, id,
			&zxdg_output_manager_v1_interface, xdg_version);
	}
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {
	struct connection *c = data;
	for (unsigned i = 0; i < c->count; i++) {
		if (c->heads[i].global_id == id) {
			c->heads[i].active = false;
		}
	}
}
static const struct wl_registry_listener registry_listener = {global, removed};

static void synced(void *data, struct wl_callback *callback, uint32_t serial) {
	*(bool *)data = true;
	wl_callback_destroy(callback);
}
static const struct wl_callback_listener sync_listener = {synced};

static void sync_client(struct connection *c) {
	if (!server) {
		assert(wl_display_roundtrip(c->display) >= 0);
		return;
	}
	bool done = false;
	struct wl_callback *callback = wl_display_sync(c->display);
	wl_callback_add_listener(callback, &sync_listener, &done);
	for (unsigned i = 0; i < 100 && !done; i++) {
		assert(wl_display_flush(c->display) >= 0);
		assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
		wl_display_flush_clients(server);
		struct pollfd fd = {wl_display_get_fd(c->display), POLLIN, 0};
		if (poll(&fd, 1, 10) > 0) {
			assert(wl_display_dispatch(c->display) >= 0);
		}
	}
	assert(done);
}

static void connect_client(struct connection *c, bool projected) {
	int pair[2];
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
	struct wl_client *client = wl_client_create(server, pair[0]);
	assert(client);
	if (projected) {
		projected_client = client;
	}
	c->display = wl_display_connect_to_fd(pair[1]);
	assert(c->display);
	c->registry = wl_display_get_registry(c->display);
	wl_registry_add_listener(c->registry, &registry_listener, c);
	sync_client(c);
	sync_client(c);
	assert(c->count == 2 && c->manager);
	for (unsigned i = 0; i < 2; i++) {
		struct observation *o = &c->heads[i];
		o->xdg = zxdg_output_manager_v1_get_xdg_output(c->manager, o->output);
		zxdg_output_v1_add_listener(o->xdg, &xdg_listener, o);
	}
	sync_client(c);
	for (unsigned i = 0; i < 2; i++) {
		assert(c->heads[i].positions == 1 && c->heads[i].sizes == 1);
		assert(c->heads[i].xdg_done == (xdg_version < 3 ? 1u : 0u));
	}
}

static struct observation *head(struct connection *c, const char *name) {
	for (unsigned i = 0; i < 2; i++) {
		if (strcmp(c->heads[i].name, name) == 0) {
			return &c->heads[i];
		}
	}
	abort();
}

static void reset(struct connection *c) {
	for (unsigned i = 0; i < c->count; i++) {
		struct observation *o = &c->heads[i];
		o->positions = o->sizes = o->xdg_done = o->output_done = 0;
	}
}

static void expect_quiet(struct connection *c) {
	for (unsigned i = 0; i < 2; i++) {
		struct observation *o = &c->heads[i];
		assert(o->positions == 0 && o->sizes == 0 &&
			o->xdg_done == 0 && o->output_done == 0);
	}
}

static void expect_completion(struct observation *o) {
	assert(o->xdg_done == (xdg_version < 3 ? 1u : 0u));
	assert(o->output_done == (xdg_version >= 3 ? 1u : 0u));
}

static void disconnect_client(struct connection *c) {
	for (unsigned i = 0; i < 2; i++) {
		zxdg_output_v1_destroy(c->heads[i].xdg);
		wl_output_release(c->heads[i].output);
	}
	zxdg_output_manager_v1_destroy(c->manager);
	wl_registry_destroy(c->registry);
	sync_client(c);
	wl_display_disconnect(c->display);
	assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
}

static int observe(void) {
	struct connection c = {0};
	c.display = wl_display_connect(NULL);
	assert(c.display);
	c.registry = wl_display_get_registry(c.display);
	wl_registry_add_listener(c.registry, &registry_listener, &c);
	sync_client(&c);
	sync_client(&c);
	assert(c.count == 2 && c.manager);
	for (unsigned i = 0; i < 2; i++) {
		struct observation *o = &c.heads[i];
		o->xdg = zxdg_output_manager_v1_get_xdg_output(c.manager, o->output);
		zxdg_output_v1_add_listener(o->xdg, &xdg_listener, o);
	}
	sync_client(&c);
	c.observing = true;
	setvbuf(stdout, NULL, _IOLBF, 0);
	puts("ready");
	char command[32];
	while (fgets(command, sizeof(command), stdin)) {
		sync_client(&c);
		if (command[0] == 'r') {
			reset(&c);
			puts("reset");
		} else if (command[0] == 's') {
			printf("[");
			bool first = true;
			for (unsigned i = 0; i < c.count; i++) {
				struct observation *o = &c.heads[i];
				if (!o->active) {
					continue;
				}
				printf("%s{\"name\":\"%s\",\"positions\":%u,\"sizes\":%u,"
					"\"xdg_done\":%u,\"output_done\":%u,\"x\":%d,\"y\":%d,"
					"\"width\":%d,\"height\":%d}", first ? "" : ",", o->name,
					o->positions, o->sizes, o->xdg_done, o->output_done,
					o->x, o->y, o->width, o->height);
				first = false;
			}
			puts("]");
		} else {
			break;
		}
	}
	wl_display_disconnect(c.display);
	return 0;
}

int main(int argc, char **argv) {
	assert(argc == 2 || argc == 3);
	if (argc == 3) {
		assert(strcmp(argv[1], "observe") == 0);
		xdg_version = strtoul(argv[2], NULL, 10);
		assert(xdg_version >= 1 && xdg_version <= 3);
		return observe();
	}
	xdg_version = strtoul(argv[1], NULL, 10);
	assert(xdg_version >= 1 && xdg_version <= 3);
	server = wl_display_create();
	assert(server);
	struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(server));
	assert(backend);
	struct wlr_output_layout *layout = wlr_output_layout_create(server);
	assert(layout);
	struct wlr_xdg_output_manager_v1 *manager = wlr_xdg_output_manager_v1_create(server, layout);
	assert(manager);
	for (unsigned i = 0; i < 2; i++) {
		outputs[i] = wlr_headless_add_output(backend, 1280, 720);
		assert(outputs[i]);
		outputs[i]->enabled = true;
		assert(wlr_output_layout_add(layout, outputs[i], 1280 * i, 0));
		projections[i] = (struct wlr_output_client_projection){
			.x = 1600 * i, .y = 0, .width = 1600, .height = 900, .scale = 1,
		};
	}
	wlr_output_set_client_projection_handler(project, NULL);
	struct connection native = {0}, projected = {0};
	connect_client(&native, false);
	connect_client(&projected, true);
	assert(head(&native, "HEADLESS-1")->width == 1280);
	assert(head(&projected, "HEADLESS-1")->width == 1600);
	reset(&native);
	reset(&projected);
	for (unsigned i = 0; i < 1000; i++) {
		assert(wlr_output_layout_add(layout, outputs[0], 0, 0));
		wlr_xdg_output_manager_v1_update(manager);
	}
	sync_client(&native);
	sync_client(&projected);
	expect_quiet(&native);
	expect_quiet(&projected);

	// A backend failure must not advance the advertised geometry cache.
	const struct wlr_output_impl *original_impl = outputs[0]->impl;
	struct wlr_output_impl failing_impl = *original_impl;
	failing_impl.commit = fail_commit;
	outputs[0]->impl = &failing_impl;
	struct wlr_output_state candidate;
	wlr_output_state_init(&candidate);
	wlr_output_state_set_scale(&candidate, 2.0f);
	assert(!wlr_output_commit_state(outputs[0], &candidate));
	assert(failed_commits == 1 && outputs[0]->scale == 1.0f);
	wlr_output_state_finish(&candidate);
	outputs[0]->impl = original_impl;
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&native);
	sync_client(&projected);
	expect_quiet(&native);
	expect_quiet(&projected);

	// Another head can change the X11 origin while logical geometry stays put.
	projections[0].x += 400;
	projections[1].x += 400;
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&native);
	sync_client(&projected);
	expect_quiet(&native);
	for (unsigned i = 0; i < 2; i++) {
		assert(projected.heads[i].positions == 1 && projected.heads[i].sizes == 0);
		expect_completion(&projected.heads[i]);
	}
	reset(&projected);
	projections[0].width = 1920;
	projections[0].height = 1080;
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&native);
	sync_client(&projected);
	expect_quiet(&native);
	struct observation *p = head(&projected, "HEADLESS-1");
	assert(p->positions == 0 && p->sizes == 1 && p->width == 1920 && p->height == 1080);
	expect_completion(p);
	assert(head(&projected, "HEADLESS-2")->positions == 0 &&
		head(&projected, "HEADLESS-2")->output_done == 0);

	// Real logical changes use the same per-resource cache as the refresh.
	reset(&projected);
	assert(wlr_output_layout_add(layout, outputs[0], -640, -200));
	projections[0].x = 0;
	projections[0].y = 0;
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&native);
	sync_client(&projected);
	struct observation *n = head(&native, "HEADLESS-1");
	assert(n->positions == 1 && n->sizes == 0 && n->x == -640 && n->y == -200);
	assert(p->positions == 1 && p->sizes == 0 && p->x == 0 && p->y == 0);
	reset(&native);
	reset(&projected);
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&native);
	sync_client(&projected);
	expect_quiet(&native);
	expect_quiet(&projected);

	// Every new resource gets initial geometry, independent of other bindings.
	struct observation duplicate = {0};
	duplicate.xdg = zxdg_output_manager_v1_get_xdg_output(projected.manager, p->output);
	zxdg_output_v1_add_listener(duplicate.xdg, &xdg_listener, &duplicate);
	sync_client(&projected);
	assert(duplicate.positions == 1 && duplicate.sizes == 1 && duplicate.width == 1920);
	reset(&projected);
	duplicate.positions = duplicate.sizes = duplicate.xdg_done = 0;
	projections[0].y = 100;
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&native);
	sync_client(&projected);
	expect_quiet(&native);
	assert(p->positions == 1 && duplicate.positions == 1 && duplicate.sizes == 0);
	expect_completion(p);
	assert(duplicate.xdg_done == (xdg_version < 3 ? 1u : 0u));
	zxdg_output_v1_destroy(duplicate.xdg);
	sync_client(&projected);

	disconnect_client(&projected);
	projected_client = NULL;
	projected = (struct connection){0};
	connect_client(&projected, true);
	assert(head(&projected, "HEADLESS-1")->y == 100);
	reset(&projected);
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&projected);
	expect_quiet(&projected);

	// Output removal leaves inert resources that can safely be destroyed later.
	wlr_output_layout_remove(layout, outputs[0]);
	wlr_xdg_output_manager_v1_update(manager);
	sync_client(&native);
	sync_client(&projected);
	disconnect_client(&projected);
	disconnect_client(&native);
	wlr_output_set_client_projection_handler(NULL, NULL);
	wlr_backend_destroy(backend);
	wl_display_destroy(server);
	printf("PASS: xdg-output v%u change detection, client isolation, completion and lifetime\n", xdg_version);
	return 0;
}
