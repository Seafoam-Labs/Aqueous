// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
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

#include "xdg-shell-client-protocol.h"

enum role {
    ROLE_BACKGROUND,
    ROLE_BLUR,
    ROLE_ALPHA,
};

struct owned_buffer {
    struct wl_buffer *buffer;
    void *pixels;
    size_t size;
};

struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct owned_buffer buffers[16];
    size_t buffer_count;
    enum role role;
    const char *ready_path;
    int32_t pending_width;
    int32_t pending_height;
    int32_t width;
    int32_t height;
    bool configured;
    bool failed;
};

static const char *role_name(enum role role) {
    switch (role) {
        case ROLE_BACKGROUND:
            return "background";
        case ROLE_BLUR:
            return "blur";
        case ROLE_ALPHA:
            return "alpha";
    }
    return "unknown";
}

static const char *app_id(enum role role) {
    switch (role) {
        case ROLE_BACKGROUND:
            return "aqueous.effects.background";
        case ROLE_BLUR:
            return "aqueous.effects.blur";
        case ROLE_ALPHA:
            return "aqueous.effects.alpha";
    }
    return "aqueous.effects.unknown";
}

static void default_size(enum role role, int32_t *width, int32_t *height) {
    switch (role) {
        case ROLE_BACKGROUND:
            *width = 1760;
            *height = 920;
            break;
        case ROLE_BLUR:
            *width = 760;
            *height = 520;
            break;
        case ROLE_ALPHA:
            *width = 560;
            *height = 360;
            break;
    }
}

static bool parse_role(const char *text, enum role *role) {
    if (strcmp(text, "background") == 0) {
        *role = ROLE_BACKGROUND;
        return true;
    }
    if (strcmp(text, "blur") == 0) {
        *role = ROLE_BLUR;
        return true;
    }
    if (strcmp(text, "alpha") == 0) {
        *role = ROLE_ALPHA;
        return true;
    }
    return false;
}

static void fail(struct app *app, const char *message) {
    fprintf(stderr, "FAIL: %s\n", message);
    app->failed = true;
}

static int create_shm_file(size_t size) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (runtime == NULL) return -1;

    char path[PATH_MAX];
    const int written = snprintf(path, sizeof(path), "%s/aqueous-effects-XXXXXX", runtime);
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

static uint32_t argb(uint8_t alpha, uint8_t red, uint8_t green, uint8_t blue) {
    const uint32_t r = ((uint32_t)red * alpha + 127u) / 255u;
    const uint32_t g = ((uint32_t)green * alpha + 127u) / 255u;
    const uint32_t b = ((uint32_t)blue * alpha + 127u) / 255u;
    return ((uint32_t)alpha << 24) | (r << 16) | (g << 8) | b;
}

static void paint_background(uint32_t *pixels, int32_t width, int32_t height) {
    for (int32_t y = 0; y < height; y++) {
        for (int32_t x = 0; x < width; x++) {
            const int checker = ((x / 32) + (y / 32)) & 1;
            const int stripe = ((x + y * 2) / 18) & 3;
            uint8_t red = checker ? 28 : 220;
            uint8_t green = checker ? 170 : 38;
            uint8_t blue = stripe < 2 ? 235 : 52;
            if (x < width / 5) {
                red = (uint8_t)((x * 255) / (width / 5));
                green = 48;
            }
            if (y > height * 4 / 5) {
                green = (uint8_t)(((height - y) * 255) / (height / 5));
                blue = (uint8_t)((x * 255) / width);
            }
            pixels[(size_t)y * (size_t)width + (size_t)x] =
                argb(255, red, green, blue);
        }
    }
}

static void paint_blur(uint32_t *pixels, int32_t width, int32_t height) {
    for (int32_t y = 0; y < height; y++) {
        for (int32_t x = 0; x < width; x++) {
            const int32_t edge = 28;
            const bool frame = x < edge || y < edge ||
                x >= width - edge || y >= height - edge;
            const bool grid = (x % 96) < 3 || (y % 96) < 3;
            uint8_t alpha = frame ? 224 : (grid ? 150 : 44);
            uint8_t red = frame ? 245 : 230;
            uint8_t green = frame ? 245 : 248;
            uint8_t blue = 255;
            pixels[(size_t)y * (size_t)width + (size_t)x] =
                argb(alpha, red, green, blue);
        }
    }
}

static void paint_alpha(uint32_t *pixels, int32_t width, int32_t height) {
    for (int32_t y = 0; y < height; y++) {
        for (int32_t x = 0; x < width; x++) {
            uint8_t alpha = (uint8_t)((x * 255) / (width > 1 ? width - 1 : 1));
            uint8_t red = 250;
            uint8_t green = (uint8_t)((y * 220) / (height > 1 ? height - 1 : 1));
            uint8_t blue = (uint8_t)(245 - green / 2);
            if (((x / 24) + (y / 24)) % 5 == 0) {
                alpha = 0;
            }
            pixels[(size_t)y * (size_t)width + (size_t)x] =
                argb(alpha, red, green, blue);
        }
    }
}

static bool attach_buffer(struct app *app, int32_t width, int32_t height) {
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
        app->buffer_count >= sizeof(app->buffers) / sizeof(app->buffers[0])) {
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

    struct wl_shm_pool *pool = wl_shm_create_pool(app->shm, fd, (int32_t)size);
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

    switch (app->role) {
        case ROLE_BACKGROUND:
            paint_background(pixels, width, height);
            break;
        case ROLE_BLUR:
            paint_blur(pixels, width, height);
            break;
        case ROLE_ALPHA:
            paint_alpha(pixels, width, height);
            break;
    }

    app->buffers[app->buffer_count++] = (struct owned_buffer){
        .buffer = buffer,
        .pixels = pixels,
        .size = size,
    };
    xdg_surface_set_window_geometry(app->xdg_surface, 0, 0, width, height);
    wl_surface_attach(app->surface, buffer, 0, 0);
    wl_surface_damage_buffer(app->surface, 0, 0, width, height);
    wl_surface_commit(app->surface);
    app->width = width;
    app->height = height;
    return true;
}

static bool publish_ready(const struct app *app) {
    FILE *file = fopen(app->ready_path, "w");
    if (file == NULL) return false;
    const int written = fprintf(
        file,
        "%s %d %d\n",
        app_id(app->role),
        app->width,
        app->height);
    bool ok = written > 0;
    if (fclose(file) != 0) ok = false;
    return ok;
}

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
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
    fail(data, "compositor closed the reference surface");
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

    int32_t width = app->pending_width;
    int32_t height = app->pending_height;
    if (width <= 0 || height <= 0) default_size(app->role, &width, &height);
    if (width == app->width && height == app->height) return;
    if (!attach_buffer(app, width, height)) {
        fail(app, "unable to allocate a configured buffer");
        return;
    }
    if (!app->configured) {
        app->configured = true;
        if (!publish_ready(app)) fail(app, "unable to publish readiness");
    }
}

static const struct xdg_surface_listener surface_listener = {
    .configure = surface_configure,
};

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s ROLE READY_FILE\n", argv[0]);
        return 2;
    }

    struct app app = { .ready_path = argv[2] };
    if (!parse_role(argv[1], &app.role)) {
        fprintf(stderr, "unknown role: %s\n", argv[1]);
        return 2;
    }

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

    char title[96];
    const int title_length = snprintf(
        title,
        sizeof(title),
        "Aqueous effects reference: %s",
        role_name(app.role));
    if (title_length < 0 || (size_t)title_length >= sizeof(title)) return 1;
    xdg_toplevel_set_title(app.toplevel, title);
    xdg_toplevel_set_app_id(app.toplevel, app_id(app.role));
    wl_surface_commit(app.surface);

    while (!app.failed && wl_display_dispatch(app.display) >= 0) {}

    for (size_t index = 0; index < app.buffer_count; index++) {
        wl_buffer_destroy(app.buffers[index].buffer);
        (void)munmap(app.buffers[index].pixels, app.buffers[index].size);
    }
    xdg_toplevel_destroy(app.toplevel);
    xdg_surface_destroy(app.xdg_surface);
    wl_surface_destroy(app.surface);
    xdg_wm_base_destroy(app.wm_base);
    wl_shm_destroy(app.shm);
    wl_compositor_destroy(app.compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(app.display);
    return app.failed ? 1 : 0;
}
