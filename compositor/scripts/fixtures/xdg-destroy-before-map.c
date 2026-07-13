// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

struct globals {
    struct wl_compositor *compositor;
    struct xdg_wm_base *wm_base;
};

struct configure_state {
    bool configured;
};

static void wm_base_ping(
    void *data,
    struct xdg_wm_base *wm_base,
    uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = wm_base_ping,
};

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version) {
    struct globals *globals = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        const uint32_t bind_version = version < 4 ? version : 4;
        globals->compositor = wl_registry_bind(
            registry,
            name,
            &wl_compositor_interface,
            bind_version);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        globals->wm_base = wl_registry_bind(
            registry,
            name,
            &xdg_wm_base_interface,
            1);
        xdg_wm_base_add_listener(globals->wm_base, &wm_base_listener, NULL);
    }
}

static void registry_global_remove(
    void *data,
    struct wl_registry *registry,
    uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void xdg_surface_configure(
    void *data,
    struct xdg_surface *xdg_surface,
    uint32_t serial) {
    struct configure_state *state = data;
    xdg_surface_ack_configure(xdg_surface, serial);
    state->configured = true;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static bool destroy_configured_toplevel_before_map(
    struct wl_display *display,
    const struct globals *globals,
    unsigned int iteration) {
    struct wl_surface *surface = wl_compositor_create_surface(globals->compositor);
    if (surface == NULL) return false;

    struct xdg_surface *xdg_surface = xdg_wm_base_get_xdg_surface(globals->wm_base, surface);
    if (xdg_surface == NULL) {
        wl_surface_destroy(surface);
        return false;
    }

    struct configure_state state = {0};
    xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, &state);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg_surface);
    if (toplevel == NULL) {
        xdg_surface_destroy(xdg_surface);
        wl_surface_destroy(surface);
        return false;
    }

    char title[64];
    snprintf(title, sizeof(title), "destroy-before-map-%u", iteration);
    xdg_toplevel_set_title(toplevel, title);
    xdg_toplevel_set_app_id(toplevel, "aqueous.destroy-before-map");

    // A bufferless initial commit requests the first configure but never maps
    // the surface. Aqueous policy may assign a workspace before replying.
    wl_surface_commit(surface);
    for (unsigned int roundtrip = 0; roundtrip < 4 && !state.configured; roundtrip++) {
        if (wl_display_roundtrip(display) < 0) return false;
    }
    if (!state.configured) return false;

    // Commit the acknowledged configure without attaching a buffer. This lets
    // the compositor finish its configure transaction while the surface stays
    // initialized but unmapped.
    wl_surface_commit(surface);
    if (wl_display_roundtrip(display) < 0) return false;

    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdg_surface);
    wl_surface_destroy(surface);
    return wl_display_roundtrip(display) >= 0;
}

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        fputs("failed to connect to Wayland display\n", stderr);
        return 1;
    }

    struct globals globals = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &globals);
    if (wl_display_roundtrip(display) < 0 ||
        globals.compositor == NULL || globals.wm_base == NULL) {
        fputs("required Wayland globals unavailable\n", stderr);
        return 1;
    }

    // Repetition ensures each destroyed link is followed by another workspace
    // insertion, the operation that exposed the original dangling-list bug.
    for (unsigned int iteration = 0; iteration < 32; iteration++) {
        if (!destroy_configured_toplevel_before_map(display, &globals, iteration)) {
            fprintf(stderr, "iteration %u failed\n", iteration);
            return 1;
        }
    }

    xdg_wm_base_destroy(globals.wm_base);
    wl_compositor_destroy(globals.compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    puts("PASS: configured XDG toplevels destroyed before map");
    return 0;
}
