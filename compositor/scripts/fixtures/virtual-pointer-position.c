// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

struct state {
	struct wl_seat *seat;
	struct zwlr_virtual_pointer_manager_v1 *manager;
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct state *state = data;
	if (strcmp(interface, wl_seat_interface.name) == 0 && state->seat == NULL) {
		state->seat = wl_registry_bind(registry, name, &wl_seat_interface,
			version < 7 ? version : 7);
	} else if (strcmp(interface,
			zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
		state->manager = wl_registry_bind(registry, name,
			&zwlr_virtual_pointer_manager_v1_interface, 1);
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

static uint32_t parse(const char *text) {
	char *end = NULL;
	errno = 0;
	unsigned long value = strtoul(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || value > UINT32_MAX) {
		fprintf(stderr, "invalid coordinate: %s\n", text);
		exit(2);
	}
	return (uint32_t)value;
}

static uint32_t monotonic_milliseconds(void) {
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
		perror("clock_gettime");
		exit(1);
	}
	return (uint32_t)
		((uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000);
}

static int send_position(struct wl_display *display,
		struct zwlr_virtual_pointer_v1 *pointer, uint32_t x, uint32_t y,
		uint32_t x_extent, uint32_t y_extent) {
	zwlr_virtual_pointer_v1_motion_absolute(pointer, monotonic_milliseconds(),
		x, y, x_extent, y_extent);
	zwlr_virtual_pointer_v1_frame(pointer);
	return wl_display_roundtrip(display);
}

int main(int argc, char **argv) {
	if (argc != 4 && argc != 5) {
		fprintf(stderr,
			"usage: %s X Y X_EXTENT Y_EXTENT | FIFO X_EXTENT Y_EXTENT\n",
			argv[0]);
		return 2;
	}
	struct state state = {0};
	struct wl_display *display = wl_display_connect(NULL);
	if (display == NULL) return 1;
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.seat == NULL ||
			state.manager == NULL) {
		fprintf(stderr, "virtual pointer globals are unavailable\n");
		return 1;
	}
	struct zwlr_virtual_pointer_v1 *pointer =
		zwlr_virtual_pointer_manager_v1_create_virtual_pointer(
			state.manager, state.seat);
	if (argc == 5) {
		if (send_position(display, pointer, parse(argv[1]), parse(argv[2]),
				parse(argv[3]), parse(argv[4])) < 0) return 1;
	} else {
		const uint32_t x_extent = parse(argv[2]);
		const uint32_t y_extent = parse(argv[3]);
		int fd = open(argv[1], O_RDWR);
		if (fd < 0) {
			perror("open command fifo");
			return 1;
		}
		FILE *commands = fdopen(fd, "r");
		if (commands == NULL) return 1;
		printf("READY\n");
		fflush(stdout);
		uint32_t x;
		uint32_t y;
		while (fscanf(commands, "%u %u", &x, &y) == 2) {
			if (send_position(display, pointer, x, y, x_extent, y_extent) < 0) {
				return 1;
			}
			printf("POSITION %u %u\n", x, y);
			fflush(stdout);
		}
		fclose(commands);
	}
	zwlr_virtual_pointer_v1_destroy(pointer);
	zwlr_virtual_pointer_manager_v1_destroy(state.manager);
	wl_seat_destroy(state.seat);
	wl_registry_destroy(registry);
	wl_display_disconnect(display);
	return 0;
}
