// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

struct owned_buffer {
    struct wl_buffer *buffer;
    void *pixels;
    size_t size;
};

struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct xdg_wm_base *wm_base;

    struct wl_surface *layer_surface;
    struct zwlr_layer_surface_v1 *layer_role;

    struct wl_surface *popup_surface;
    struct xdg_surface *popup_xdg_surface;
    struct xdg_popup *popup;

    struct wl_surface *nested_surface;
    struct xdg_surface *nested_xdg_surface;
    struct xdg_popup *nested_popup;

    struct owned_buffer buffers[3];
    size_t buffer_count;
    const char *ready_path;
    bool layer_configured;
    bool popup_configured;
    bool nested_configured;
    bool failed;
};

static void fail(struct app *app, const char *message) {
    fprintf(stderr, "FAIL: %s\n", message);
    app->failed = true;
}

static int create_shm_file(size_t size) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (runtime == NULL) return -1;

    char path[PATH_MAX];
    const int written = snprintf(
        path,
        sizeof(path),
        "%s/aqueous-layer-popup-XXXXXX",
        runtime);
    if (written < 0 || (size_t)written >= sizeof(path)) return -1;
    const int fd = mkstemp(path);
    if (fd < 0) return -1;
    (void)unlink(path);
    if (ftruncate(fd, (off_t)size) < 0) {
        (void)close(fd);
        return -1;
    }
    return fd;
}

static uint32_t argb(
    uint8_t alpha,
    uint8_t red,
    uint8_t green,
    uint8_t blue) {
    const uint32_t r = ((uint32_t)red * alpha + 127u) / 255u;
    const uint32_t g = ((uint32_t)green * alpha + 127u) / 255u;
    const uint32_t b = ((uint32_t)blue * alpha + 127u) / 255u;
    return ((uint32_t)alpha << 24) | (r << 16) | (g << 8) | b;
}

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void)data;
    (void)buffer;
}

static const struct wl_buffer_listener buffer_listener = {
    .release = buffer_release,
};

static bool attach_buffer(
    struct app *app,
    struct wl_surface *surface,
    int32_t width,
    int32_t height,
    uint32_t first,
    uint32_t second) {
    if (app->buffer_count >=
        sizeof(app->buffers) / sizeof(app->buffers[0])) {
        return false;
    }

    const size_t stride = (size_t)width * 4u;
    const size_t size = stride * (size_t)height;
    const int fd = create_shm_file(size);
    if (fd < 0) return false;
    void *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        (void)close(fd);
        return false;
    }
    struct wl_shm_pool *pool =
        wl_shm_create_pool(app->shm, fd, (int32_t)size);
    (void)close(fd);
    if (pool == NULL) {
        (void)munmap(pixels, size);
        return false;
    }
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool,
        0,
        width,
        height,
        (int32_t)stride,
        WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    if (buffer == NULL) {
        (void)munmap(pixels, size);
        return false;
    }

    uint32_t *words = pixels;
    for (int32_t y = 0; y < height; y++) {
        for (int32_t x = 0; x < width; x++) {
            const bool alternate = (((x / 14) + (y / 14)) & 1) == 0;
            words[(size_t)y * (size_t)width + (size_t)x] =
                alternate ? first : second;
        }
    }

    app->buffers[app->buffer_count++] = (struct owned_buffer){
        .buffer = buffer,
        .pixels = pixels,
        .size = size,
    };
    wl_buffer_add_listener(buffer, &buffer_listener, app);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    return true;
}

static void publish_ready(struct app *app) {
    if (!app->layer_configured || !app->popup_configured ||
        !app->nested_configured) {
        return;
    }
    FILE *file = fopen(app->ready_path, "w");
    if (file == NULL) {
        fail(app, "unable to create readiness file");
        return;
    }
    if (fprintf(file, "aqueous-popup-test popups=2\n") <= 0 ||
        fclose(file) != 0) {
        fail(app, "unable to publish readiness");
    }
}

static void popup_configure(
    void *data,
    struct xdg_popup *popup,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height) {
    (void)data;
    (void)popup;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
}

static void popup_done(void *data, struct xdg_popup *popup) {
    (void)popup;
    fail(data, "compositor dismissed a reference popup");
}

static void popup_repositioned(
    void *data,
    struct xdg_popup *popup,
    uint32_t token) {
    (void)data;
    (void)popup;
    (void)token;
}

static const struct xdg_popup_listener popup_listener = {
    .configure = popup_configure,
    .popup_done = popup_done,
    .repositioned = popup_repositioned,
};

static bool create_nested_popup(struct app *app);

static void nested_surface_configure(
    void *data,
    struct xdg_surface *xdg_surface,
    uint32_t serial) {
    struct app *app = data;
    xdg_surface_ack_configure(xdg_surface, serial);
    if (app->nested_configured) return;
    xdg_surface_set_window_geometry(xdg_surface, 0, 0, 120, 80);
    if (!attach_buffer(
            app,
            app->nested_surface,
            120,
            80,
            argb(224, 255, 208, 36),
            argb(176, 48, 220, 255))) {
        fail(app, "unable to attach nested popup buffer");
        return;
    }
    app->nested_configured = true;
    publish_ready(app);
}

static const struct xdg_surface_listener nested_surface_listener = {
    .configure = nested_surface_configure,
};

static void popup_surface_configure(
    void *data,
    struct xdg_surface *xdg_surface,
    uint32_t serial) {
    struct app *app = data;
    xdg_surface_ack_configure(xdg_surface, serial);
    if (app->popup_configured) return;
    xdg_surface_set_window_geometry(xdg_surface, 0, 0, 220, 140);
    if (!attach_buffer(
            app,
            app->popup_surface,
            220,
            140,
            argb(208, 240, 56, 188),
            argb(160, 40, 224, 248))) {
        fail(app, "unable to attach popup buffer");
        return;
    }
    app->popup_configured = true;
    if (!create_nested_popup(app)) {
        fail(app, "unable to create nested popup");
    }
}

static const struct xdg_surface_listener popup_surface_listener = {
    .configure = popup_surface_configure,
};

static bool create_nested_popup(struct app *app) {
    app->nested_surface = wl_compositor_create_surface(app->compositor);
    if (app->nested_surface == NULL) return false;
    app->nested_xdg_surface = xdg_wm_base_get_xdg_surface(
        app->wm_base,
        app->nested_surface);
    if (app->nested_xdg_surface == NULL) return false;
    xdg_surface_add_listener(
        app->nested_xdg_surface,
        &nested_surface_listener,
        app);

    struct xdg_positioner *positioner =
        xdg_wm_base_create_positioner(app->wm_base);
    if (positioner == NULL) return false;
    xdg_positioner_set_size(positioner, 120, 80);
    xdg_positioner_set_anchor_rect(positioner, 150, 84, 1, 1);
    xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
    xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
    app->nested_popup = xdg_surface_get_popup(
        app->nested_xdg_surface,
        app->popup_xdg_surface,
        positioner);
    xdg_positioner_destroy(positioner);
    if (app->nested_popup == NULL) return false;
    xdg_popup_add_listener(app->nested_popup, &popup_listener, app);
    wl_surface_commit(app->nested_surface);
    return true;
}

static bool create_popup(struct app *app) {
    app->popup_surface = wl_compositor_create_surface(app->compositor);
    if (app->popup_surface == NULL) return false;
    app->popup_xdg_surface = xdg_wm_base_get_xdg_surface(
        app->wm_base,
        app->popup_surface);
    if (app->popup_xdg_surface == NULL) return false;
    xdg_surface_add_listener(
        app->popup_xdg_surface,
        &popup_surface_listener,
        app);

    struct xdg_positioner *positioner =
        xdg_wm_base_create_positioner(app->wm_base);
    if (positioner == NULL) return false;
    xdg_positioner_set_size(positioner, 220, 140);
    xdg_positioner_set_anchor_rect(positioner, 250, 160, 1, 1);
    xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
    xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
    app->popup = xdg_surface_get_popup(
        app->popup_xdg_surface,
        NULL,
        positioner);
    xdg_positioner_destroy(positioner);
    if (app->popup == NULL) return false;
    xdg_popup_add_listener(app->popup, &popup_listener, app);
    zwlr_layer_surface_v1_get_popup(app->layer_role, app->popup);
    wl_surface_commit(app->popup_surface);
    return true;
}

static void layer_surface_configure(
    void *data,
    struct zwlr_layer_surface_v1 *layer_surface,
    uint32_t serial,
    uint32_t width,
    uint32_t height) {
    struct app *app = data;
    zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    if (app->layer_configured) return;
    if (width == 0) width = 640;
    if (height == 0) height = 420;
    if (!attach_buffer(
            app,
            app->layer_surface,
            (int32_t)width,
            (int32_t)height,
            argb(88, 245, 245, 255),
            argb(48, 38, 80, 132))) {
        fail(app, "unable to attach layer buffer");
        return;
    }
    app->layer_configured = true;
    if (!create_popup(app)) fail(app, "unable to create layer popup");
}

static void layer_surface_closed(
    void *data,
    struct zwlr_layer_surface_v1 *layer_surface) {
    (void)layer_surface;
    fail(data, "compositor closed the reference layer surface");
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
    .configure = layer_surface_configure,
    .closed = layer_surface_closed,
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
    struct app *app = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        const uint32_t bind_version = version < 4 ? version : 4;
        app->compositor = wl_registry_bind(
            registry,
            name,
            &wl_compositor_interface,
            bind_version);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
        app->layer_shell = wl_registry_bind(
            registry,
            name,
            &zwlr_layer_shell_v1_interface,
            version < 4 ? version : 4);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        app->wm_base = wl_registry_bind(
            registry,
            name,
            &xdg_wm_base_interface,
            1);
        xdg_wm_base_add_listener(app->wm_base, &wm_base_listener, NULL);
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

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s READY_FILE\n", argv[0]);
        return 2;
    }

    struct app app = {
        .ready_path = argv[1],
    };
    app.display = wl_display_connect(NULL);
    if (app.display == NULL) {
        fputs("failed to connect to Wayland display\n", stderr);
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    if (wl_display_roundtrip(app.display) < 0 || app.compositor == NULL ||
        app.shm == NULL || app.layer_shell == NULL || app.wm_base == NULL) {
        fputs("required Wayland globals unavailable\n", stderr);
        return 1;
    }

    app.layer_surface = wl_compositor_create_surface(app.compositor);
    app.layer_role = zwlr_layer_shell_v1_get_layer_surface(
        app.layer_shell,
        app.layer_surface,
        NULL,
        ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        "aqueous-popup-test");
    if (app.layer_surface == NULL || app.layer_role == NULL) return 1;
    zwlr_layer_surface_v1_add_listener(
        app.layer_role,
        &layer_surface_listener,
        &app);
    zwlr_layer_surface_v1_set_size(app.layer_role, 640, 420);
    zwlr_layer_surface_v1_set_anchor(
        app.layer_role,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_set_margin(app.layer_role, 80, 0, 0, 100);
    zwlr_layer_surface_v1_set_keyboard_interactivity(app.layer_role, 0);
    wl_surface_commit(app.layer_surface);

    while (!app.failed && wl_display_dispatch(app.display) >= 0) {}

    for (size_t index = 0; index < app.buffer_count; index++) {
        wl_buffer_destroy(app.buffers[index].buffer);
        (void)munmap(app.buffers[index].pixels, app.buffers[index].size);
    }
    if (app.nested_popup != NULL) xdg_popup_destroy(app.nested_popup);
    if (app.nested_xdg_surface != NULL) {
        xdg_surface_destroy(app.nested_xdg_surface);
    }
    if (app.nested_surface != NULL) wl_surface_destroy(app.nested_surface);
    if (app.popup != NULL) xdg_popup_destroy(app.popup);
    if (app.popup_xdg_surface != NULL) {
        xdg_surface_destroy(app.popup_xdg_surface);
    }
    if (app.popup_surface != NULL) wl_surface_destroy(app.popup_surface);
    zwlr_layer_surface_v1_destroy(app.layer_role);
    wl_surface_destroy(app.layer_surface);
    xdg_wm_base_destroy(app.wm_base);
    zwlr_layer_shell_v1_destroy(app.layer_shell);
    wl_shm_destroy(app.shm);
    wl_compositor_destroy(app.compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(app.display);
    return app.failed ? 1 : 0;
}
