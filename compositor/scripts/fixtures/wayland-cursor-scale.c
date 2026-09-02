// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-shell-client-protocol.h"

enum { cursor_logical_size = 24 };

struct buffer {
	struct wl_buffer *wl_buffer;
	void *mapping;
	size_t size;
};

struct state {
	struct wl_display *display;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct wl_seat *seat;
	struct wl_pointer *pointer;
	struct xdg_wm_base *wm_base;
	struct wp_fractional_scale_manager_v1 *fractional_manager;
	struct wp_viewporter *viewporter;
	struct wl_surface *window_surface;
	struct wl_surface *cursor_surface;
	struct wp_viewport *cursor_viewport;
	struct wp_fractional_scale_v1 *cursor_fractional;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *toplevel;
	struct buffer *window_buffer;
	uint32_t preferred_scale;
	int configured;
	int cursor_entered;
	unsigned int buffer_serial;
};

static void buffer_release(void *data, struct wl_buffer *wl_buffer) {
	struct buffer *buffer = data;
	wl_buffer_destroy(wl_buffer);
	munmap(buffer->mapping, buffer->size);
	free(buffer);
}

static const struct wl_buffer_listener buffer_listener = {
	.release = buffer_release,
};

static struct buffer *create_buffer(struct state *state, int width, int height,
		uint32_t pixel) {
	struct buffer *buffer = calloc(1, sizeof(*buffer));
	if (buffer == NULL) return NULL;
	char name[96];
	snprintf(name, sizeof(name), "/aqueous-cursor-scale-%ld-%u",
		(long)getpid(), state->buffer_serial++);
	int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
	if (fd < 0) {
		perror("shm_open");
		free(buffer);
		return NULL;
	}
	shm_unlink(name);
	buffer->size = (size_t)width * (size_t)height * 4;
	if (ftruncate(fd, (off_t)buffer->size) < 0) {
		perror("ftruncate");
		close(fd);
		free(buffer);
		return NULL;
	}
	buffer->mapping = mmap(NULL, buffer->size, PROT_READ | PROT_WRITE,
		MAP_SHARED, fd, 0);
	if (buffer->mapping == MAP_FAILED) {
		perror("mmap");
		close(fd);
		free(buffer);
		return NULL;
	}
	uint32_t *pixels = buffer->mapping;
	for (size_t i = 0; i < buffer->size / 4; ++i) pixels[i] = pixel;
	struct wl_shm_pool *pool = wl_shm_create_pool(state->shm, fd,
		(int)buffer->size);
	buffer->wl_buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
		width * 4, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	wl_buffer_add_listener(buffer->wl_buffer, &buffer_listener, buffer);
	return buffer;
}

static int redraw_cursor(struct state *state, uint32_t scale) {
	const uint64_t scaled = (uint64_t)cursor_logical_size * scale;
	const int pixels = (int)((scaled + 119) / 120);
	struct buffer *buffer = create_buffer(state, pixels, pixels, 0xffffffffu);
	if (buffer == NULL) return -1;
	wp_viewport_set_destination(state->cursor_viewport,
		cursor_logical_size, cursor_logical_size);
	wl_surface_attach(state->cursor_surface, buffer->wl_buffer, 0, 0);
	wl_surface_damage_buffer(state->cursor_surface, 0, 0, INT32_MAX, INT32_MAX);
	wl_surface_commit(state->cursor_surface);
	state->preferred_scale = scale;
	printf("CURSOR preferred=%u buffer=%dx%d logical=%dx%d\n", scale,
		pixels, pixels, cursor_logical_size, cursor_logical_size);
	fflush(stdout);
	return 0;
}

static void preferred_scale(void *data,
		struct wp_fractional_scale_v1 *fractional, uint32_t scale) {
	(void)fractional;
	struct state *state = data;
	if (scale == 0 || scale == state->preferred_scale) return;
	if (redraw_cursor(state, scale) < 0) exit(1);
}

static const struct wp_fractional_scale_v1_listener fractional_listener = {
	.preferred_scale = preferred_scale,
};

static void pointer_enter(void *data, struct wl_pointer *pointer,
		uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
	(void)surface;
	(void)x;
	(void)y;
	struct state *state = data;
	wl_pointer_set_cursor(pointer, serial, state->cursor_surface, 0, 0);
	state->cursor_entered = 1;
	printf("ENTER serial=%u\n", serial);
	fflush(stdout);
}

static void pointer_leave(void *data, struct wl_pointer *pointer,
		uint32_t serial, struct wl_surface *surface) {
	(void)data;
	(void)pointer;
	(void)serial;
	(void)surface;
}

static void pointer_motion(void *data, struct wl_pointer *pointer,
		uint32_t time, wl_fixed_t x, wl_fixed_t y) {
	(void)data;
	(void)pointer;
	(void)time;
	(void)x;
	(void)y;
}

static void pointer_button(void *data, struct wl_pointer *pointer,
		uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
	(void)data;
	(void)pointer;
	(void)serial;
	(void)time;
	(void)button;
	(void)state;
}

static void pointer_axis(void *data, struct wl_pointer *pointer,
		uint32_t time, uint32_t axis, wl_fixed_t value) {
	(void)data;
	(void)pointer;
	(void)time;
	(void)axis;
	(void)value;
}

static void pointer_frame(void *data, struct wl_pointer *pointer) {
	(void)data;
	(void)pointer;
}

static void pointer_axis_source(void *data, struct wl_pointer *pointer,
		uint32_t source) {
	(void)data;
	(void)pointer;
	(void)source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *pointer,
		uint32_t time, uint32_t axis) {
	(void)data;
	(void)pointer;
	(void)time;
	(void)axis;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *pointer,
		uint32_t axis, int32_t discrete) {
	(void)data;
	(void)pointer;
	(void)axis;
	(void)discrete;
}

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
	.frame = pointer_frame,
	.axis_source = pointer_axis_source,
	.axis_stop = pointer_axis_stop,
	.axis_discrete = pointer_axis_discrete,
};

static void seat_capabilities(void *data, struct wl_seat *seat,
		uint32_t capabilities) {
	struct state *state = data;
	if ((capabilities & WL_SEAT_CAPABILITY_POINTER) != 0 &&
			state->pointer == NULL) {
		state->pointer = wl_seat_get_pointer(seat);
		wl_pointer_add_listener(state->pointer, &pointer_listener, state);
	}
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
	(void)data;
	(void)seat;
	(void)name;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void wm_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
	(void)data;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_listener = {
	.ping = wm_ping,
};

static void surface_configure(void *data, struct xdg_surface *surface,
		uint32_t serial) {
	struct state *state = data;
	xdg_surface_ack_configure(surface, serial);
	if (!state->configured) {
		state->window_buffer = create_buffer(state, 640, 480, 0xff101010u);
		if (state->window_buffer == NULL) exit(1);
		wl_surface_attach(state->window_surface,
			state->window_buffer->wl_buffer, 0, 0);
		wl_surface_damage_buffer(state->window_surface, 0, 0,
			INT32_MAX, INT32_MAX);
		wl_surface_commit(state->window_surface);
		state->configured = 1;
		printf("MAPPED\n");
		fflush(stdout);
	}
}

static const struct xdg_surface_listener surface_listener = {
	.configure = surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
		int32_t width, int32_t height, struct wl_array *states) {
	(void)data;
	(void)toplevel;
	(void)width;
	(void)height;
	(void)states;
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
	(void)data;
	(void)toplevel;
	exit(0);
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct state *state = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, version < 6 ? version : 6);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		state->seat = wl_registry_bind(registry, name, &wl_seat_interface,
			version < 5 ? version : 5);
		wl_seat_add_listener(state->seat, &seat_listener, state);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		state->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, 1);
	} else if (strcmp(interface,
			wp_fractional_scale_manager_v1_interface.name) == 0) {
		state->fractional_manager = wl_registry_bind(registry, name,
			&wp_fractional_scale_manager_v1_interface, 1);
	} else if (strcmp(interface, wp_viewporter_interface.name) == 0) {
		state->viewporter = wl_registry_bind(registry, name,
			&wp_viewporter_interface, 1);
	}
}

static void registry_remove(void *data, struct wl_registry *registry,
		uint32_t name) {
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_remove,
};

int main(void) {
	struct state state = {0};
	setvbuf(stdout, NULL, _IOLBF, 0);
	state.display = wl_display_connect(NULL);
	if (state.display == NULL) {
		fprintf(stderr, "unable to connect to Wayland display\n");
		return 1;
	}
	struct wl_registry *registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(state.display) < 0 || state.compositor == NULL ||
			state.shm == NULL || state.seat == NULL || state.wm_base == NULL ||
			state.fractional_manager == NULL || state.viewporter == NULL) {
		fprintf(stderr, "required Wayland globals are unavailable\n");
		return 1;
	}
	xdg_wm_base_add_listener(state.wm_base, &wm_listener, &state);

	state.cursor_surface = wl_compositor_create_surface(state.compositor);
	state.cursor_fractional =
		wp_fractional_scale_manager_v1_get_fractional_scale(
			state.fractional_manager, state.cursor_surface);
	wp_fractional_scale_v1_add_listener(state.cursor_fractional,
		&fractional_listener, &state);
	state.cursor_viewport = wp_viewporter_get_viewport(state.viewporter,
		state.cursor_surface);
	if (redraw_cursor(&state, 120) < 0) return 1;

	state.window_surface = wl_compositor_create_surface(state.compositor);
	state.xdg_surface = xdg_wm_base_get_xdg_surface(state.wm_base,
		state.window_surface);
	xdg_surface_add_listener(state.xdg_surface, &surface_listener, &state);
	state.toplevel = xdg_surface_get_toplevel(state.xdg_surface);
	xdg_toplevel_add_listener(state.toplevel, &toplevel_listener, &state);
	xdg_toplevel_set_app_id(state.toplevel, "aqueous.wayland-cursor-scale");
	xdg_toplevel_set_title(state.toplevel, "Aqueous Wayland cursor scale probe");
	wl_surface_commit(state.window_surface);

	while (wl_display_dispatch(state.display) >= 0) {}
	return errno == EPIPE ? 0 : 1;
}
