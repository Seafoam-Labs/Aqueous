// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

// Minimal xdg-toplevel fixture for picture-in-picture stacking regressions.
// Unlike xdg-floating-request.c the window title is independent of the app id,
// so a fixture can pose as a browser PiP pop-out ("Picture-in-Picture") while
// keeping a distinct app id for aqueousctl lookups. Supports idling and a
// client-originated fullscreen request.

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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
    struct wl_shm_pool *pool;
    struct wl_buffer *buffers[32];
    size_t buffer_count;
    const char *sync_dir;
    bool configured;
    bool failed;
    int32_t pending_width;
    int32_t pending_height;
    int32_t last_width;
    int32_t last_height;
};

static void fail(struct app *app, const char *message) {
    fprintf(stderr, "FAIL: %s\n", message);
    app->failed = true;
}

static bool sync_path(char *path, size_t size, const struct app *app, const char *name) {
    const int written = snprintf(path, size, "%s/%s", app->sync_dir, name);
    return written >= 0 && (size_t)written < size;
}

static bool publish_marker(const struct app *app, const char *name) {
    char path[PATH_MAX];
    if (!sync_path(path, sizeof(path), app, name)) return false;
    FILE *file = fopen(path, "w");
    if (file == NULL) return false;
    return fclose(file) == 0;
}

static bool wait_for_marker(struct app *app, const char *name) {
    char path[PATH_MAX];
    if (!sync_path(path, sizeof(path), app, name)) return false;
    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
    for (unsigned int attempt = 0; attempt < 1000; attempt++) {
        if (access(path, F_OK) == 0) return true;
        if (errno != ENOENT) return false;
        (void)wl_display_flush(app->display);
        struct pollfd pfd = { .fd = wl_display_get_fd(app->display), .events = POLLIN };
        const int ready = poll(&pfd, 1, 10);
        if (ready < 0 && errno != EINTR) return false;
        if (ready > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) return false;
        if (ready > 0 && (pfd.revents & POLLIN) != 0 && wl_display_dispatch(app->display) < 0) {
            return false;
        }
        if (ready == 0) (void)nanosleep(&delay, NULL);
    }
    return false;
}

static int create_shm_file(size_t size) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (runtime == NULL) return -1;
    char path[PATH_MAX];
    const int written = snprintf(path, sizeof(path), "%s/aqueous-pip-XXXXXX", runtime);
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

static bool attach_buffer(struct app *app, int32_t width, int32_t height) {
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
        app->buffer_count >= sizeof(app->buffers) / sizeof(app->buffers[0])) {
        return false;
    }
    const int32_t stride = width * 4;
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        app->pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    if (buffer == NULL) return false;
    app->buffers[app->buffer_count++] = buffer;
    xdg_surface_set_window_geometry(app->xdg_surface, 0, 0, width, height);
    wl_surface_attach(app->surface, buffer, 0, 0);
    wl_surface_damage(app->surface, 0, 0, width, height);
    wl_surface_commit(app->surface);
    app->last_width = width;
    app->last_height = height;
    return true;
}

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void registry_global(
    void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct app *app = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        app->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        app->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, version < 2 ? version : 2);
        xdg_wm_base_add_listener(app->wm_base, &wm_base_listener, NULL);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void toplevel_configure(
    void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height, struct wl_array *states) {
    (void)toplevel;
    (void)states;
    struct app *app = data;
    app->pending_width = width;
    app->pending_height = height;
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)toplevel;
    fail(data, "compositor closed the fixture toplevel");
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
};

static void surface_configure(void *data, struct xdg_surface *xdg_surface, uint32_t serial) {
    struct app *app = data;
    xdg_surface_ack_configure(xdg_surface, serial);
    int32_t width = app->pending_width;
    int32_t height = app->pending_height;
    if (width <= 0) width = app->last_width > 0 ? app->last_width : 320;
    if (height <= 0) height = app->last_height > 0 ? app->last_height : 200;
    if (app->configured && width == app->last_width && height == app->last_height) {
        wl_surface_commit(app->surface);
        return;
    }
    if (!attach_buffer(app, width, height)) {
        fail(app, "unable to attach configured buffer");
        return;
    }
    app->configured = true;
}

static const struct xdg_surface_listener xdg_surface_listener = { .configure = surface_configure };

static bool roundtrip(struct app *app) {
    return wl_display_roundtrip(app->display) >= 0 && !app->failed;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s SYNC_DIR APP_ID TITLE [idle|fullscreen]\n", argv[0]);
        return 2;
    }
    const char *mode = argv[4];
    if (strcmp(mode, "idle") != 0 && strcmp(mode, "fullscreen") != 0) {
        fprintf(stderr, "FAIL: unknown mode %s\n", mode);
        return 2;
    }
    struct app app = { .sync_dir = argv[1] };
    app.display = wl_display_connect(NULL);
    if (app.display == NULL) {
        fprintf(stderr, "FAIL: unable to connect to Wayland display\n");
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    if (!roundtrip(&app) || app.compositor == NULL || app.shm == NULL || app.wm_base == NULL) {
        fail(&app, "required Wayland globals are unavailable");
        goto cleanup;
    }

    app.surface = wl_compositor_create_surface(app.compositor);
    app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
    xdg_surface_add_listener(app.xdg_surface, &xdg_surface_listener, &app);
    app.toplevel = xdg_surface_get_toplevel(app.xdg_surface);
    xdg_toplevel_add_listener(app.toplevel, &toplevel_listener, &app);
    xdg_toplevel_set_app_id(app.toplevel, argv[2]);
    xdg_toplevel_set_title(app.toplevel, argv[3]);

    const size_t pool_size = 4096u * 4096u * 4u;
    const int fd = create_shm_file(pool_size);
    if (fd < 0) {
        fail(&app, "unable to create shared-memory file");
        goto cleanup;
    }
    app.pool = wl_shm_create_pool(app.shm, fd, (int32_t)pool_size);
    (void)close(fd);
    wl_surface_commit(app.surface);
    while (!app.configured && !app.failed) {
        if (wl_display_dispatch(app.display) < 0) {
            fail(&app, "display disconnected before initial configure");
        }
    }
    if (app.failed || !publish_marker(&app, "ready")) goto cleanup;

    if (strcmp(mode, "fullscreen") == 0) {
        if (!wait_for_marker(&app, "fullscreen")) {
            fail(&app, "fullscreen command failed");
        } else {
            xdg_toplevel_set_fullscreen(app.toplevel, NULL);
            wl_surface_commit(app.surface);
            if (!roundtrip(&app) || !roundtrip(&app) || !publish_marker(&app, "fullscreen-done")) {
                fail(&app, "fullscreen request failed");
            }
        }
    }
    if (!app.failed && !wait_for_marker(&app, "finish")) fail(&app, "finish command failed");

cleanup:
    for (size_t i = 0; i < app.buffer_count; i++) wl_buffer_destroy(app.buffers[i]);
    if (app.pool != NULL) wl_shm_pool_destroy(app.pool);
    if (app.toplevel != NULL) xdg_toplevel_destroy(app.toplevel);
    if (app.xdg_surface != NULL) xdg_surface_destroy(app.xdg_surface);
    if (app.surface != NULL) wl_surface_destroy(app.surface);
    if (app.wm_base != NULL) xdg_wm_base_destroy(app.wm_base);
    if (app.shm != NULL) wl_shm_destroy(app.shm);
    if (app.compositor != NULL) wl_compositor_destroy(app.compositor);
    if (registry != NULL) wl_registry_destroy(registry);
    wl_display_disconnect(app.display);
    if (app.failed) return 1;
    printf("PASS: %s pip stacking fixture\n", argv[2]);
    return 0;
}