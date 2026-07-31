// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    int32_t pending_width;
    int32_t pending_height;
    int32_t minimum_height;
    uint32_t color;
    bool running;
};

struct buffer {
    struct wl_buffer *proxy;
    void *mapping;
    size_t size;
};

static void buffer_release(void *data, struct wl_buffer *proxy) {
    struct buffer *buffer = data;
    wl_buffer_destroy(proxy);
    munmap(buffer->mapping, buffer->size);
    free(buffer);
}

static const struct wl_buffer_listener buffer_listener = {
    .release = buffer_release,
};

static struct buffer *create_buffer(
    struct wl_shm *shm,
    int32_t width,
    int32_t height,
    uint32_t color) {
    const int32_t stride = width * 4;
    const size_t size = (size_t)stride * (size_t)height;
    char path[] = "/tmp/aqueous-scrolling-vertical.XXXXXX";
    const int fd = mkstemp(path);
    if (fd < 0) return NULL;
    unlink(path);
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return NULL;
    }

    void *mapping = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    uint32_t *pixels = mapping;
    for (size_t index = 0; index < size / sizeof(*pixels); index++) {
        pixels[index] = color;
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    close(fd);
    if (pool == NULL) {
        munmap(mapping, size);
        return NULL;
    }
    struct buffer *buffer = calloc(1, sizeof(*buffer));
    if (buffer == NULL) {
        wl_shm_pool_destroy(pool);
        munmap(mapping, size);
        return NULL;
    }
    buffer->proxy = wl_shm_pool_create_buffer(
        pool,
        0,
        width,
        height,
        stride,
        WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    if (buffer->proxy == NULL) {
        munmap(mapping, size);
        free(buffer);
        return NULL;
    }
    buffer->mapping = mapping;
    buffer->size = size;
    wl_buffer_add_listener(buffer->proxy, &buffer_listener, buffer);
    return buffer;
}

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
    struct app *app = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        app->compositor = wl_registry_bind(
            registry,
            name,
            &wl_compositor_interface,
            version < 4 ? version : 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        app->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(app->wm_base, &wm_base_listener, app);
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

static void toplevel_configure(
    void *data,
    struct xdg_toplevel *toplevel,
    int32_t width,
    int32_t height,
    struct wl_array *states) {
    (void)toplevel;
    (void)states;
    struct app *app = data;
    app->pending_width = width;
    app->pending_height = height;
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)toplevel;
    struct app *app = data;
    app->running = false;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
};

static void surface_configure(
    void *data,
    struct xdg_surface *xdg_surface,
    uint32_t serial) {
    struct app *app = data;
    xdg_surface_ack_configure(xdg_surface, serial);
    const int32_t width = app->pending_width > 0 ? app->pending_width : 320;
    const int32_t height = app->pending_height > 0
        ? app->pending_height
        : app->minimum_height;
    struct buffer *buffer = create_buffer(app->shm, width, height, app->color);
    if (buffer == NULL) {
        fprintf(stderr, "unable to allocate %dx%d buffer: %s\n", width, height, strerror(errno));
        app->running = false;
        return;
    }
    wl_surface_attach(app->surface, buffer->proxy, 0, 0);
    wl_surface_damage_buffer(app->surface, 0, 0, width, height);
    wl_surface_commit(app->surface);
}

static const struct xdg_surface_listener surface_listener = {
    .configure = surface_configure,
};

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s APP_ID ARGB MIN_HEIGHT\n", argv[0]);
        return 2;
    }
    char *color_end = NULL;
    char *height_end = NULL;
    const unsigned long color = strtoul(argv[2], &color_end, 16);
    const long minimum_height = strtol(argv[3], &height_end, 10);
    if (color_end == argv[2] || *color_end != '\0' || color > UINT32_MAX ||
        height_end == argv[3] || *height_end != '\0' ||
        minimum_height < 1 || minimum_height > INT32_MAX) {
        fputs("invalid color or minimum height\n", stderr);
        return 2;
    }

    struct app app = {
        .minimum_height = (int32_t)minimum_height,
        .color = (uint32_t)color,
        .running = true,
    };
    app.display = wl_display_connect(NULL);
    if (app.display == NULL) {
        fputs("failed to connect to Wayland display\n", stderr);
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    if (wl_display_roundtrip(app.display) < 0 || app.compositor == NULL ||
        app.shm == NULL || app.wm_base == NULL) {
        fputs("required Wayland globals unavailable\n", stderr);
        return 1;
    }

    app.surface = wl_compositor_create_surface(app.compositor);
    app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
    xdg_surface_add_listener(app.xdg_surface, &surface_listener, &app);
    app.toplevel = xdg_surface_get_toplevel(app.xdg_surface);
    xdg_toplevel_add_listener(app.toplevel, &toplevel_listener, &app);
    xdg_toplevel_set_app_id(app.toplevel, argv[1]);
    xdg_toplevel_set_title(app.toplevel, argv[1]);
    xdg_toplevel_set_min_size(app.toplevel, 100, app.minimum_height);
    wl_surface_commit(app.surface);

    while (app.running && wl_display_dispatch(app.display) >= 0) {}
    return app.running ? 1 : 0;
}
