#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "fractional-scale-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

struct state {
	struct wl_display *display;
	struct wl_compositor *compositor;
	struct wl_subcompositor *subcompositor;
	struct wl_shm *shm;
	struct xdg_wm_base *wm_base;
	struct wp_fractional_scale_manager_v1 *fractional_manager;
	uint32_t sequence;
	uint32_t preferred_scale;
	uint32_t preferred_order;
	uint32_t root_configure_order;
	uint32_t popup_preferred_scale;
	uint32_t popup_preferred_order;
	uint32_t popup_configure_order;
	uint32_t subsurface_preferred_scale;
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct state *state = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, version < 6 ? version : 6);
	} else if (strcmp(interface, wl_subcompositor_interface.name) == 0) {
		state->subcompositor = wl_registry_bind(registry, name,
			&wl_subcompositor_interface, 1);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		state->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, 1);
	} else if (strcmp(interface,
			wp_fractional_scale_manager_v1_interface.name) == 0) {
		state->fractional_manager = wl_registry_bind(registry, name,
			&wp_fractional_scale_manager_v1_interface, 1);
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

static void wm_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
	(void)data;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_listener = {
	.ping = wm_ping,
};

static void root_preferred_scale(void *data,
		struct wp_fractional_scale_v1 *fractional, uint32_t scale) {
	(void)fractional;
	struct state *state = data;
	state->preferred_scale = scale;
	state->preferred_order = ++state->sequence;
}

static void popup_preferred_scale(void *data,
		struct wp_fractional_scale_v1 *fractional, uint32_t scale) {
	(void)fractional;
	struct state *state = data;
	state->popup_preferred_scale = scale;
	state->popup_preferred_order = ++state->sequence;
}

static void subsurface_preferred_scale(void *data,
		struct wp_fractional_scale_v1 *fractional, uint32_t scale) {
	(void)fractional;
	struct state *state = data;
	state->subsurface_preferred_scale = scale;
}

static const struct wp_fractional_scale_v1_listener root_fractional_listener = {
	.preferred_scale = root_preferred_scale,
};

static const struct wp_fractional_scale_v1_listener popup_fractional_listener = {
	.preferred_scale = popup_preferred_scale,
};

static const struct wp_fractional_scale_v1_listener subsurface_fractional_listener = {
	.preferred_scale = subsurface_preferred_scale,
};

static void root_surface_configure(void *data, struct xdg_surface *surface,
		uint32_t serial) {
	struct state *state = data;
	xdg_surface_ack_configure(surface, serial);
	if (state->root_configure_order == 0) {
		state->root_configure_order = ++state->sequence;
	}
}

static void popup_surface_configure(void *data, struct xdg_surface *surface,
		uint32_t serial) {
	(void)data;
	xdg_surface_ack_configure(surface, serial);
}

static const struct xdg_surface_listener root_surface_listener = {
	.configure = root_surface_configure,
};

static const struct xdg_surface_listener popup_surface_listener = {
	.configure = popup_surface_configure,
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
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

static void popup_configure(void *data, struct xdg_popup *popup,
		int32_t x, int32_t y, int32_t width, int32_t height) {
	(void)popup;
	(void)x;
	(void)y;
	(void)width;
	(void)height;
	struct state *state = data;
	if (state->popup_configure_order == 0) {
		state->popup_configure_order = ++state->sequence;
	}
}

static void popup_done(void *data, struct xdg_popup *popup) {
	(void)data;
	(void)popup;
}

static const struct xdg_popup_listener popup_listener = {
	.configure = popup_configure,
	.popup_done = popup_done,
};

static struct wl_buffer *create_buffer(struct state *state, int width,
		int height, void **mapping, size_t *mapping_size) {
	char name[64];
	snprintf(name, sizeof(name), "/aqueous-scale-%ld", (long)getpid());
	int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
	if (fd < 0) {
		perror("shm_open");
		return NULL;
	}
	shm_unlink(name);
	const size_t size = (size_t)width * (size_t)height * 4;
	if (ftruncate(fd, (off_t)size) < 0) {
		perror("ftruncate");
		close(fd);
		return NULL;
	}
	void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return NULL;
	}
	memset(data, 0x40, size);
	struct wl_shm_pool *pool = wl_shm_create_pool(state->shm, fd, (int)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
		width * 4, WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	*mapping = data;
	*mapping_size = size;
	return buffer;
}

static int dispatch_until(struct state *state, uint32_t *value) {
	for (int i = 0; i < 100 && *value == 0; ++i) {
		if (wl_display_dispatch(state->display) < 0) return -1;
	}
	return *value == 0 ? -1 : 0;
}

int main(int argc, char **argv) {
	if (argc != 3 && argc != 5) {
		fprintf(stderr,
			"usage: %s APP_ID EXPECTED_SCALE_120THS [NEXT_SCALE_120THS READY_FILE]\n",
			argv[0]);
		return 2;
	}
	char *end = NULL;
	const unsigned long expected_raw = strtoul(argv[2], &end, 10);
	if (end == argv[2] || *end != '\0' || expected_raw == 0 ||
			expected_raw > UINT32_MAX) {
		fprintf(stderr, "invalid expected scale: %s\n", argv[2]);
		return 2;
	}
	const uint32_t expected = (uint32_t)expected_raw;
	struct state state = {0};
	state.display = wl_display_connect(NULL);
	if (state.display == NULL) {
		fprintf(stderr, "unable to connect to Wayland display\n");
		return 1;
	}
	struct wl_registry *registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(state.display) < 0 || state.compositor == NULL ||
			state.subcompositor == NULL || state.shm == NULL || state.wm_base == NULL ||
			state.fractional_manager == NULL) {
		fprintf(stderr, "required Wayland globals are unavailable\n");
		return 1;
	}
	xdg_wm_base_add_listener(state.wm_base, &wm_listener, &state);

	struct wl_surface *root_wl = wl_compositor_create_surface(state.compositor);
	struct wp_fractional_scale_v1 *root_fractional =
		wp_fractional_scale_manager_v1_get_fractional_scale(
			state.fractional_manager, root_wl);
	wp_fractional_scale_v1_add_listener(root_fractional,
		&root_fractional_listener, &state);
	struct xdg_surface *root_xdg = xdg_wm_base_get_xdg_surface(
		state.wm_base, root_wl);
	xdg_surface_add_listener(root_xdg, &root_surface_listener, &state);
	struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(root_xdg);
	xdg_toplevel_add_listener(toplevel, &toplevel_listener, &state);
	xdg_toplevel_set_app_id(toplevel, argv[1]);
	xdg_toplevel_set_title(toplevel, "Aqueous buffer scale probe");
	wl_surface_commit(root_wl);
	if (dispatch_until(&state, &state.root_configure_order) < 0) {
		fprintf(stderr, "root surface did not receive an initial configure\n");
		return 1;
	}
	if (state.preferred_scale != expected || state.preferred_order == 0 ||
			state.preferred_order >= state.root_configure_order) {
		fprintf(stderr,
			"root scale ordering mismatch: scale=%u scale_order=%u configure_order=%u expected=%u\n",
			state.preferred_scale, state.preferred_order,
			state.root_configure_order, expected);
		return 1;
	}

	void *root_mapping = NULL;
	size_t root_mapping_size = 0;
	struct wl_buffer *root_buffer = create_buffer(&state, 160, 100,
		&root_mapping, &root_mapping_size);
	if (root_buffer == NULL) return 1;
	wl_surface_attach(root_wl, root_buffer, 0, 0);
	wl_surface_damage_buffer(root_wl, 0, 0, INT32_MAX, INT32_MAX);
	wl_surface_commit(root_wl);
	if (wl_display_roundtrip(state.display) < 0) return 1;

	struct wl_surface *child_wl = wl_compositor_create_surface(state.compositor);
	struct wp_fractional_scale_v1 *child_fractional =
		wp_fractional_scale_manager_v1_get_fractional_scale(
			state.fractional_manager, child_wl);
	wp_fractional_scale_v1_add_listener(child_fractional,
		&subsurface_fractional_listener, &state);
	struct wl_subsurface *subsurface = wl_subcompositor_get_subsurface(
		state.subcompositor, child_wl, root_wl);
	wl_subsurface_set_position(subsurface, 8, 8);
	wl_surface_attach(child_wl, root_buffer, 0, 0);
	wl_surface_damage_buffer(child_wl, 0, 0, INT32_MAX, INT32_MAX);
	wl_surface_commit(child_wl);
	wl_surface_commit(root_wl);
	if (dispatch_until(&state, &state.subsurface_preferred_scale) < 0 ||
			state.subsurface_preferred_scale != expected) {
		fprintf(stderr,
			"subsurface scale mismatch: scale=%u expected=%u\n",
			state.subsurface_preferred_scale, expected);
		return 1;
	}

	struct wl_surface *popup_wl = wl_compositor_create_surface(state.compositor);
	struct wp_fractional_scale_v1 *popup_fractional =
		wp_fractional_scale_manager_v1_get_fractional_scale(
			state.fractional_manager, popup_wl);
	wp_fractional_scale_v1_add_listener(popup_fractional,
		&popup_fractional_listener, &state);
	struct xdg_surface *popup_xdg = xdg_wm_base_get_xdg_surface(
		state.wm_base, popup_wl);
	xdg_surface_add_listener(popup_xdg, &popup_surface_listener, &state);
	struct xdg_positioner *positioner = xdg_wm_base_create_positioner(state.wm_base);
	xdg_positioner_set_size(positioner, 64, 40);
	/*
	 * Qt may anchor a bottom-edge menu just beyond the parent's/output's
	 * logical bounds. A compositor must still send the popup's initial
	 * configure when no output overlaps that anchor rectangle.
	 */
	xdg_positioner_set_anchor_rect(positioner, 0, 100000, 32, 24);
	struct xdg_popup *popup = xdg_surface_get_popup(popup_xdg, root_xdg,
		positioner);
	xdg_popup_add_listener(popup, &popup_listener, &state);
	wl_surface_commit(popup_wl);
	if (dispatch_until(&state, &state.popup_configure_order) < 0) {
		fprintf(stderr, "popup did not receive an initial configure\n");
		return 1;
	}
	if (state.popup_preferred_scale != expected ||
			state.popup_preferred_order == 0 ||
			state.popup_preferred_order >= state.popup_configure_order) {
		fprintf(stderr,
			"popup scale ordering mismatch: scale=%u scale_order=%u configure_order=%u expected=%u\n",
			state.popup_preferred_scale, state.popup_preferred_order,
			state.popup_configure_order, expected);
		return 1;
	}
	if (argc == 5) {
		end = NULL;
		const unsigned long next_raw = strtoul(argv[3], &end, 10);
		if (end == argv[3] || *end != '\0' || next_raw == 0 ||
				next_raw > UINT32_MAX) {
			fprintf(stderr, "invalid next scale: %s\n", argv[3]);
			return 2;
		}
		int ready_fd = open(argv[4], O_WRONLY | O_CREAT | O_EXCL, 0600);
		if (ready_fd < 0) {
			perror("create ready marker");
			return 1;
		}
		close(ready_fd);
		const uint32_t next = (uint32_t)next_raw;
		for (int i = 0; i < 100 &&
				(state.preferred_scale != next ||
				 state.popup_preferred_scale != next ||
				 state.subsurface_preferred_scale != next); ++i) {
			if (wl_display_dispatch(state.display) < 0) {
				fprintf(stderr, "display disconnected during scale transition\n");
				return 1;
			}
		}
		if (state.preferred_scale != next ||
				state.popup_preferred_scale != next ||
				state.subsurface_preferred_scale != next) {
			fprintf(stderr,
				"scale transition mismatch: root=%u popup=%u subsurface=%u expected=%u\n",
				state.preferred_scale, state.popup_preferred_scale,
				state.subsurface_preferred_scale, next);
			return 1;
		}
		printf("PASS: %s transitioned root, popup, and subsurface to preferred_scale(%u)\n",
			argv[1], next);
	}

	printf("PASS: %s preferred_scale(%u) preceded root and popup configures and reached its subsurface\n",
		argv[1], expected);
	xdg_popup_destroy(popup);
	xdg_positioner_destroy(positioner);
	xdg_surface_destroy(popup_xdg);
	wp_fractional_scale_v1_destroy(popup_fractional);
	wl_surface_destroy(popup_wl);
	xdg_toplevel_destroy(toplevel);
	xdg_surface_destroy(root_xdg);
	wl_subsurface_destroy(subsurface);
	wp_fractional_scale_v1_destroy(child_fractional);
	wl_surface_destroy(child_wl);
	wp_fractional_scale_v1_destroy(root_fractional);
	wl_buffer_destroy(root_buffer);
	munmap(root_mapping, root_mapping_size);
	wl_surface_destroy(root_wl);
	wp_fractional_scale_manager_v1_destroy(state.fractional_manager);
	xdg_wm_base_destroy(state.wm_base);
	wl_shm_destroy(state.shm);
	wl_subcompositor_destroy(state.subcompositor);
	wl_compositor_destroy(state.compositor);
	wl_registry_destroy(registry);
	wl_display_disconnect(state.display);
	return 0;
}
