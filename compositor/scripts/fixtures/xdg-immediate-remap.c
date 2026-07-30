// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

struct globals {
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
};

struct configure_state {
    unsigned int count;
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
        globals->compositor = wl_registry_bind(
            registry,
            name,
            &wl_compositor_interface,
            version < 4 ? version : 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        globals->shm = wl_registry_bind(
            registry,
            name,
            &wl_shm_interface,
            1);
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
    state->count++;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static struct wl_buffer *create_buffer(struct wl_shm *shm) {
    const int width = 64;
    const int height = 64;
    const int stride = width * 4;
    const size_t size = (size_t)stride * height;
    char path[] = "/tmp/aqueous-immediate-remap.XXXXXX";
    const int fd = mkstemp(path);
    if (fd < 0) return NULL;
    unlink(path);
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return NULL;
    }

    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    for (size_t i = 0; i < size / sizeof(*pixels); i++) {
        pixels[i] = 0xff336699;
    }
    munmap(pixels, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    close(fd);
    if (pool == NULL) return NULL;
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool,
        0,
        width,
        height,
        stride,
        WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    return buffer;
}

static bool wait_for_configure(
    struct wl_display *display,
    const struct configure_state *state,
    unsigned int count) {
    for (unsigned int roundtrip = 0; roundtrip < 8 && state->count < count; roundtrip++) {
        if (wl_display_roundtrip(display) < 0) return false;
    }
    return state->count >= count;
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
        globals.compositor == NULL ||
        globals.shm == NULL ||
        globals.wm_base == NULL) {
        fputs("required Wayland globals unavailable\n", stderr);
        return 1;
    }

    struct wl_surface *surface =
        wl_compositor_create_surface(globals.compositor);
    if (surface == NULL) {
        fputs("failed to create Wayland surface\n", stderr);
        return 1;
    }
    struct xdg_surface *xdg_surface =
        xdg_wm_base_get_xdg_surface(globals.wm_base, surface);
    if (xdg_surface == NULL) {
        fputs("failed to create XDG surface\n", stderr);
        return 1;
    }
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg_surface);
    if (toplevel == NULL) {
        fputs("failed to create XDG toplevel\n", stderr);
        return 1;
    }
    struct wl_buffer *buffer = create_buffer(globals.shm);
    if (buffer == NULL) {
        fputs("failed to create SHM buffer\n", stderr);
        return 1;
    }

    struct configure_state state = {0};
    xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, &state);
    xdg_toplevel_set_title(toplevel, "immediate-remap");
    xdg_toplevel_set_app_id(toplevel, "aqueous.immediate-remap");

    wl_surface_commit(surface);
    if (!wait_for_configure(display, &state, 1)) {
        fputs("initial configure was not received\n", stderr);
        return 1;
    }
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, 64, 64);
    wl_surface_commit(surface);
    if (wl_display_roundtrip(display) < 0) return 1;

    // Queue the unmap and the next bufferless initial commit together. The
    // compositor must reset the old window lifecycle before admitting the
    // remap even though its idle manage callback has not run between commits.
    wl_surface_attach(surface, NULL, 0, 0);
    wl_surface_commit(surface);
    wl_surface_commit(surface);
    if (!wait_for_configure(display, &state, 2)) {
        fputs("immediate remap configure was not received\n", stderr);
        return 1;
    }

    wl_buffer_destroy(buffer);
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdg_surface);
    wl_surface_destroy(surface);
    xdg_wm_base_destroy(globals.wm_base);
    wl_shm_destroy(globals.shm);
    wl_compositor_destroy(globals.compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    puts("PASS: immediate XDG remap received a fresh configure");
    return 0;
}
