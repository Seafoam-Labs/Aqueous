// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#define BTN_LEFT 0x110u
#define POINTER_WIDTH 1280u
#define POINTER_HEIGHT 720u

enum operation {
    OP_NONE,
    OP_MOVE,
    OP_RESIZE_TOP_LEFT,
};

struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct xdg_wm_base *wm_base;
    struct zwlr_virtual_pointer_manager_v1 *virtual_pointer_manager;
    struct zwlr_virtual_pointer_v1 *virtual_pointer;
    struct wl_pointer *pointer;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct wl_shm_pool *pool;
    struct wl_buffer *buffers[32];
    size_t buffer_count;
    const char *sync_dir;
    const char *app_id;
    enum operation operation;
    bool configured;
    bool failed;
    int32_t pending_width;
    int32_t pending_height;
    int32_t last_width;
    int32_t last_height;
    uint32_t time_msec;
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
        struct pollfd pfd = {
            .fd = wl_display_get_fd(app->display),
            .events = POLLIN,
        };
        const int ready = poll(&pfd, 1, 10);
        if (ready < 0 && errno != EINTR) return false;
        if (ready > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) return false;
        if (ready > 0 && (pfd.revents & POLLIN) != 0 &&
            wl_display_dispatch(app->display) < 0) {
            return false;
        }
        if (ready == 0) (void)nanosleep(&delay, NULL);
    }
    return false;
}

static bool read_pointer_command(
    const struct app *app,
    const char *name,
    uint32_t *start_x,
    uint32_t *start_y,
    uint32_t *end_x,
    uint32_t *end_y) {
    char path[PATH_MAX];
    if (!sync_path(path, sizeof(path), app, name)) return false;
    FILE *file = fopen(path, "r");
    if (file == NULL) return false;
    const int scanned = fscanf(file, "%u %u %u %u", start_x, start_y, end_x, end_y);
    const bool closed = fclose(file) == 0;
    return scanned == 4 && closed;
}

static int create_shm_file(size_t size) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (runtime == NULL) return -1;
    char path[PATH_MAX];
    const int written = snprintf(path, sizeof(path), "%s/aqueous-floating-XXXXXX", runtime);
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

static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = wm_base_ping,
};

static void pointer_enter(
    void *data,
    struct wl_pointer *pointer,
    uint32_t serial,
    struct wl_surface *surface,
    wl_fixed_t surface_x,
    wl_fixed_t surface_y) {
    (void)data;
    (void)pointer;
    (void)serial;
    (void)surface;
    (void)surface_x;
    (void)surface_y;
}

static void pointer_leave(
    void *data,
    struct wl_pointer *pointer,
    uint32_t serial,
    struct wl_surface *surface) {
    (void)data;
    (void)pointer;
    (void)serial;
    (void)surface;
}

static void pointer_motion(
    void *data,
    struct wl_pointer *pointer,
    uint32_t time,
    wl_fixed_t surface_x,
    wl_fixed_t surface_y) {
    (void)data;
    (void)pointer;
    (void)time;
    (void)surface_x;
    (void)surface_y;
}

static void pointer_button(
    void *data,
    struct wl_pointer *pointer,
    uint32_t serial,
    uint32_t time,
    uint32_t button,
    uint32_t state) {
    (void)pointer;
    (void)time;
    struct app *app = data;
    if (button != BTN_LEFT || state != WL_POINTER_BUTTON_STATE_PRESSED) return;
    switch (app->operation) {
        case OP_MOVE:
            xdg_toplevel_move(app->toplevel, app->seat, serial);
            break;
        case OP_RESIZE_TOP_LEFT:
            xdg_toplevel_resize(
                app->toplevel,
                app->seat,
                serial,
                XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT);
            break;
        case OP_NONE:
            break;
    }
}

static void pointer_axis(
    void *data,
    struct wl_pointer *pointer,
    uint32_t time,
    uint32_t axis,
    wl_fixed_t value) {
    (void)data;
    (void)pointer;
    (void)time;
    (void)axis;
    (void)value;
}

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
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
            registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        app->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        app->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(app->wm_base, &wm_base_listener, NULL);
    } else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        app->virtual_pointer_manager = wl_registry_bind(
            registry, name, &zwlr_virtual_pointer_manager_v1_interface, 2);
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
    if (!attach_buffer(app, width, height)) {
        fail(app, "unable to attach configured buffer");
        return;
    }
    app->configured = true;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = surface_configure,
};

static bool roundtrip(struct app *app) {
    return wl_display_roundtrip(app->display) >= 0 && !app->failed;
}

static bool run_pointer_operation(struct app *app, const char *command, enum operation operation) {
    uint32_t start_x;
    uint32_t start_y;
    uint32_t end_x;
    uint32_t end_y;
    if (!wait_for_marker(app, command) ||
        !read_pointer_command(app, command, &start_x, &start_y, &end_x, &end_y)) {
        return false;
    }

    app->operation = operation;
    zwlr_virtual_pointer_v1_motion_absolute(
        app->virtual_pointer,
        ++app->time_msec,
        start_x,
        start_y,
        POINTER_WIDTH,
        POINTER_HEIGHT);
    zwlr_virtual_pointer_v1_frame(app->virtual_pointer);
    if (!roundtrip(app)) return false;

    zwlr_virtual_pointer_v1_button(
        app->virtual_pointer,
        ++app->time_msec,
        BTN_LEFT,
        WL_POINTER_BUTTON_STATE_PRESSED);
    zwlr_virtual_pointer_v1_frame(app->virtual_pointer);
    if (!roundtrip(app) || !roundtrip(app)) return false;

    zwlr_virtual_pointer_v1_motion_absolute(
        app->virtual_pointer,
        ++app->time_msec,
        end_x,
        end_y,
        POINTER_WIDTH,
        POINTER_HEIGHT);
    zwlr_virtual_pointer_v1_frame(app->virtual_pointer);
    if (!roundtrip(app)) return false;

    zwlr_virtual_pointer_v1_button(
        app->virtual_pointer,
        ++app->time_msec,
        BTN_LEFT,
        WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(app->virtual_pointer);
    app->operation = OP_NONE;
    return roundtrip(app);
}

static bool request_state(struct app *app, const char *command) {
    if (!wait_for_marker(app, command)) return false;
    if (strcmp(command, "maximize") == 0) {
        xdg_toplevel_set_maximized(app->toplevel);
    } else if (strcmp(command, "unmaximize") == 0) {
        xdg_toplevel_unset_maximized(app->toplevel);
    } else if (strcmp(command, "minimize") == 0) {
        xdg_toplevel_set_minimized(app->toplevel);
    } else {
        return false;
    }
    wl_surface_commit(app->surface);
    return roundtrip(app) && roundtrip(app);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s SYNC_DIR APP_ID\n", argv[0]);
        return 2;
    }
    struct app app = {
        .sync_dir = argv[1],
        .app_id = argv[2],
    };
    app.display = wl_display_connect(NULL);
    if (app.display == NULL) {
        fprintf(stderr, "FAIL: unable to connect to Wayland display\n");
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    if (!roundtrip(&app) || app.compositor == NULL || app.shm == NULL ||
        app.seat == NULL || app.wm_base == NULL || app.virtual_pointer_manager == NULL) {
        fail(&app, "required Wayland globals are unavailable");
        goto cleanup;
    }

    app.virtual_pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(
        app.virtual_pointer_manager, app.seat);
    if (!roundtrip(&app)) {
        fail(&app, "virtual pointer was not admitted");
        goto cleanup;
    }
    app.pointer = wl_seat_get_pointer(app.seat);
    wl_pointer_add_listener(app.pointer, &pointer_listener, &app);
    app.surface = wl_compositor_create_surface(app.compositor);
    app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
    xdg_surface_add_listener(app.xdg_surface, &xdg_surface_listener, &app);
    app.toplevel = xdg_surface_get_toplevel(app.xdg_surface);
    xdg_toplevel_add_listener(app.toplevel, &toplevel_listener, &app);
    xdg_toplevel_set_app_id(app.toplevel, app.app_id);
    xdg_toplevel_set_title(app.toplevel, app.app_id);

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

    if (!run_pointer_operation(&app, "move", OP_MOVE) ||
        !publish_marker(&app, "move-done") ||
        !run_pointer_operation(&app, "resize", OP_RESIZE_TOP_LEFT) ||
        !publish_marker(&app, "resize-done") ||
        !request_state(&app, "maximize") ||
        !publish_marker(&app, "maximize-done") ||
        !request_state(&app, "unmaximize") ||
        !publish_marker(&app, "unmaximize-done") ||
        !request_state(&app, "minimize") ||
        !publish_marker(&app, "minimize-done") ||
        !wait_for_marker(&app, "finish")) {
        fail(&app, "operation command failed");
    }

cleanup:
    for (size_t i = 0; i < app.buffer_count; i++) wl_buffer_destroy(app.buffers[i]);
    if (app.pool != NULL) wl_shm_pool_destroy(app.pool);
    if (app.toplevel != NULL) xdg_toplevel_destroy(app.toplevel);
    if (app.xdg_surface != NULL) xdg_surface_destroy(app.xdg_surface);
    if (app.surface != NULL) wl_surface_destroy(app.surface);
    if (app.pointer != NULL) wl_pointer_destroy(app.pointer);
    if (app.virtual_pointer != NULL) zwlr_virtual_pointer_v1_destroy(app.virtual_pointer);
    if (app.virtual_pointer_manager != NULL) {
        zwlr_virtual_pointer_manager_v1_destroy(app.virtual_pointer_manager);
    }
    if (app.seat != NULL) wl_seat_destroy(app.seat);
    if (app.wm_base != NULL) xdg_wm_base_destroy(app.wm_base);
    if (app.shm != NULL) wl_shm_destroy(app.shm);
    if (app.compositor != NULL) wl_compositor_destroy(app.compositor);
    if (registry != NULL) wl_registry_destroy(registry);
    wl_display_disconnect(app.display);
    if (app.failed) return 1;
    printf("PASS: %s client request sequence\n", app.app_id);
    return 0;
}
