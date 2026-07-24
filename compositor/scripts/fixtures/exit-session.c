// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "river-window-management-v1-client-protocol.h"

static struct river_window_manager_v1 *manager;

static void registry_global(void *data, struct wl_registry *registry,
        uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, river_window_manager_v1_interface.name) == 0) {
        uint32_t bind_version = version < 4 ? version : 4;
        manager = wl_registry_bind(registry, name,
            &river_window_manager_v1_interface, bind_version);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry,
        uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) return EXIT_FAILURE;

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || manager == NULL ||
            river_window_manager_v1_get_version(manager) < 4) {
        wl_registry_destroy(registry);
        wl_display_disconnect(display);
        return EXIT_FAILURE;
    }

    river_window_manager_v1_exit_session(manager);
    if (wl_display_flush(display) < 0) {
        wl_registry_destroy(registry);
        wl_display_disconnect(display);
        return EXIT_FAILURE;
    }
    (void)wl_display_roundtrip(display);

    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return EXIT_SUCCESS;
}
