// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "kde-server-decoration-client-protocol.h"

struct probe {
    struct wl_display *display;
    struct org_kde_kwin_server_decoration_manager *manager;
    uint32_t expected[16];
    size_t expected_count;
    size_t received_count;
    int failed;
};

static void default_mode(void *data,
                         struct org_kde_kwin_server_decoration_manager *manager,
                         uint32_t mode) {
    (void)manager;
    struct probe *probe = data;
    if (probe->received_count >= probe->expected_count ||
        mode != probe->expected[probe->received_count]) {
        fprintf(stderr, "unexpected default mode %u at event %zu\n",
                mode, probe->received_count + 1);
        probe->failed = 1;
        return;
    }
    printf("%u\n", mode);
    fflush(stdout);
    probe->received_count++;
}

static const struct org_kde_kwin_server_decoration_manager_listener manager_listener = {
    .default_mode = default_mode,
};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    struct probe *probe = data;
    if (strcmp(interface, org_kde_kwin_server_decoration_manager_interface.name) != 0)
        return;
    probe->manager = wl_registry_bind(
        registry, name, &org_kde_kwin_server_decoration_manager_interface,
        version < 1 ? version : 1);
    org_kde_kwin_server_decoration_manager_add_listener(
        probe->manager, &manager_listener, probe);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global,
    .global_remove = global_remove,
};

int main(int argc, char **argv) {
    if (argc < 2 || argc > 17) {
        fprintf(stderr, "usage: %s MODE [MODE ...]\n", argv[0]);
        return 2;
    }

    struct probe probe = {0};
    probe.expected_count = (size_t)argc - 1;
    for (int i = 1; i < argc; i++) {
        char *end = NULL;
        errno = 0;
        unsigned long mode = strtoul(argv[i], &end, 10);
        if (errno != 0 || end == argv[i] || *end != '\0' || mode > UINT32_MAX) {
            fprintf(stderr, "invalid mode: %s\n", argv[i]);
            return 2;
        }
        probe.expected[i - 1] = (uint32_t)mode;
    }

    probe.display = wl_display_connect(NULL);
    if (probe.display == NULL) {
        fprintf(stderr, "unable to connect to Wayland display\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(probe.display);
    wl_registry_add_listener(registry, &registry_listener, &probe);

    while (!probe.failed && probe.received_count < probe.expected_count) {
        if (wl_display_dispatch(probe.display) < 0) {
            fprintf(stderr, "Wayland display disconnected\n");
            probe.failed = 1;
        }
    }

    if (probe.manager != NULL)
        org_kde_kwin_server_decoration_manager_destroy(probe.manager);
    wl_registry_destroy(registry);
    wl_display_disconnect(probe.display);
    return probe.failed ? 1 : 0;
}
