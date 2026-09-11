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

#include "xdg-shell-client-protocol.h"

enum phase {
    PHASE_INITIAL,
    PHASE_ENTER,
    PHASE_REDUNDANT_ENTER,
    PHASE_EXIT,
    PHASE_DONE,
    PHASE_COMMAND,
};

struct output {
    struct wl_output *object;
    char name[128];
};

struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct wl_shm_pool *pool;
    struct wl_buffer *buffers[128];
    struct output outputs[8];
    size_t output_count;
    size_t buffer_count;
    enum phase phase;
    bool pending_fullscreen;
    bool failed;
    int32_t pending_width;
    int32_t pending_height;
    int32_t last_width;
    int32_t last_height;
    int32_t fullscreen_width;
    int32_t fullscreen_height;
    unsigned int cycle;
    const char *sync_dir;
};

static void fail(struct app *app, const char *message) {
    fprintf(stderr, "FAIL: %s\n", message);
    app->failed = true;
    app->phase = PHASE_DONE;
}

static bool sync_path(char *path, size_t size, const struct app *app, const char *name) {
    const int written = snprintf(path, size, "%s/%s", app->sync_dir, name);
    return written >= 0 && (size_t)written < size;
}

static bool publish_marker(const struct app *app, const char *name, const char *content) {
    char path[PATH_MAX];
    if (!sync_path(path, sizeof(path), app, name)) return false;
    FILE *file = fopen(path, "w");
    if (file == NULL) return false;
    bool ok = fputs(content, file) >= 0;
    if (fclose(file) != 0) ok = false;
    return ok;
}

static bool wait_for_marker(const struct app *app, const char *name) {
    char path[PATH_MAX];
    if (!sync_path(path, sizeof(path), app, name)) return false;
    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
    for (unsigned int attempt = 0; attempt < 1000; attempt++) {
        if (access(path, F_OK) == 0) return true;
        if (errno != ENOENT) return false;
        (void)nanosleep(&delay, NULL);
    }
    return false;
}

static int create_shm_file(size_t size) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (runtime == NULL) return -1;

    char path[PATH_MAX];
    const int written = snprintf(path, sizeof(path), "%s/aqueous-fullscreen-XXXXXX", runtime);
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
        app->pool,
        0,
        width,
        height,
        stride,
        WL_SHM_FORMAT_ARGB8888);
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

static void request_fullscreen(struct app *app) {
    app->phase = PHASE_ENTER;
    xdg_toplevel_set_fullscreen(app->toplevel, NULL);
    wl_surface_commit(app->surface);
}

static void request_redundant_fullscreen(struct app *app) {
    app->phase = PHASE_REDUNDANT_ENTER;
    xdg_toplevel_set_fullscreen(app->toplevel, NULL);
    wl_surface_commit(app->surface);
}

static void request_windowed(struct app *app) {
    app->phase = PHASE_EXIT;
    xdg_toplevel_unset_fullscreen(app->toplevel);
    wl_surface_commit(app->surface);
}

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = wm_base_ping,
};

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y,
    int32_t width, int32_t height, int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)output; (void)x; (void)y; (void)width; (void)height;
    (void)subpixel; (void)make; (void)model; (void)transform;
}
static void output_mode(void *data, struct wl_output *output, uint32_t flags,
    int32_t width, int32_t height, int32_t refresh) {
    (void)data; (void)output; (void)flags; (void)width; (void)height; (void)refresh;
}
static void output_done(void *data, struct wl_output *output) { (void)data; (void)output; }
static void output_scale(void *data, struct wl_output *output, int32_t scale) { (void)data; (void)output; (void)scale; }
static void output_name(void *data, struct wl_output *output, const char *name) {
    (void)output;
    struct output *entry = data;
    snprintf(entry->name, sizeof(entry->name), "%s", name);
}
static void output_description(void *data, struct wl_output *output, const char *description) {
    (void)data; (void)output; (void)description;
}
static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done,
    .scale = output_scale, .name = output_name, .description = output_description,
};

static struct wl_output *find_output(struct app *app, const char *name) {
    if (strcmp(name, "none") == 0) return NULL;
    for (size_t i = 0; i < app->output_count; i++) {
        if (strcmp(app->outputs[i].name, name) == 0) return app->outputs[i].object;
    }
    fail(app, "requested output not found");
    return NULL;
}

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version) {
    struct app *app = data;
    if (strcmp(interface, wl_output_interface.name) == 0 && app->phase == PHASE_COMMAND) {
        if (version < 4 || app->output_count == sizeof(app->outputs) / sizeof(app->outputs[0])) {
            fail(app, "output globals unavailable or exhausted");
            return;
        }
        struct output *output = &app->outputs[app->output_count++];
        output->object = wl_registry_bind(registry, name, &wl_output_interface, 4);
        wl_output_add_listener(output->object, &output_listener, output);
    } else if (strcmp(interface, wl_compositor_interface.name) == 0) {
        const uint32_t bind_version = version < 4 ? version : 4;
        app->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, bind_version);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        app->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
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
    void *data,
    struct xdg_toplevel *toplevel,
    int32_t width,
    int32_t height,
    struct wl_array *states) {
    (void)toplevel;
    struct app *app = data;
    app->pending_width = width;
    app->pending_height = height;
    app->pending_fullscreen = false;
    uint32_t *state;
    wl_array_for_each(state, states) {
        if (*state == XDG_TOPLEVEL_STATE_FULLSCREEN) app->pending_fullscreen = true;
    }
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
        fail(app, "unable to attach a buffer matching the configure");
        return;
    }

    switch (app->phase) {
        case PHASE_INITIAL:
            request_fullscreen(app);
            break;
        case PHASE_ENTER:
            if (!app->pending_fullscreen || app->pending_width <= 0 || app->pending_height <= 0) {
                fail(app, "fullscreen request was not acknowledged with fullscreen dimensions");
                return;
            }
            app->fullscreen_width = app->pending_width;
            app->fullscreen_height = app->pending_height;
            request_redundant_fullscreen(app);
            break;
        case PHASE_REDUNDANT_ENTER:
            if (!app->pending_fullscreen || app->pending_width != app->fullscreen_width ||
                app->pending_height != app->fullscreen_height) {
                fail(app, "repeated fullscreen request did not receive an equivalent configure");
                return;
            }
            if (app->cycle == 0) {
                char dimensions[64];
                const int written = snprintf(
                    dimensions,
                    sizeof(dimensions),
                    "%d %d\n",
                    app->fullscreen_width,
                    app->fullscreen_height);
                if (written < 0 || (size_t)written >= sizeof(dimensions) ||
                    !publish_marker(app, "fullscreen-ready", dimensions) ||
                    !wait_for_marker(app, "fullscreen-continue")) {
                    fail(app, "fullscreen inspection synchronization failed");
                    return;
                }
            }
            request_windowed(app);
            break;
        case PHASE_EXIT:
            if (app->pending_fullscreen) {
                fail(app, "unset_fullscreen was acknowledged as still fullscreen");
                return;
            }
            app->cycle += 1;
            if (app->cycle < 3) {
                request_fullscreen(app);
            } else {
                if (!publish_marker(app, "windowed-ready", "ready\n") ||
                    !wait_for_marker(app, "windowed-continue")) {
                    fail(app, "windowed inspection synchronization failed");
                    return;
                }
                app->phase = PHASE_DONE;
            }
            break;
        case PHASE_COMMAND:
            printf("{\"event\":\"configure\",\"fullscreen\":%s,\"width\":%d,\"height\":%d}\n",
                app->pending_fullscreen ? "true" : "false", width, height);
            break;
        case PHASE_DONE:
            break;
    }
}

static const struct xdg_surface_listener surface_listener = {
    .configure = surface_configure,
};

// Commands let placement tests inspect a settled window, reload its rules, or
// move it manually before sending another real xdg_toplevel fullscreen hint.
static void dispatch_commands(struct app *app) {
    while (!app->failed && app->phase != PHASE_DONE) {
        while (wl_display_prepare_read(app->display) != 0) {
            if (wl_display_dispatch_pending(app->display) < 0) goto disconnected;
        }
        if (wl_display_flush(app->display) < 0) {
            wl_display_cancel_read(app->display);
            goto disconnected;
        }
        struct pollfd fds[] = {
            { .fd = wl_display_get_fd(app->display), .events = POLLIN },
            { .fd = STDIN_FILENO, .events = POLLIN },
        };
        int ready = poll(fds, 2, -1);
        if (ready < 0) {
            wl_display_cancel_read(app->display);
            if (errno == EINTR) continue;
            goto disconnected;
        }
        if (fds[0].revents) {
            if (wl_display_read_events(app->display) < 0) goto disconnected;
        } else wl_display_cancel_read(app->display);
        if (wl_display_dispatch_pending(app->display) < 0) goto disconnected;
        if (fds[1].revents) {
            char line[384], op[32], value[128], hint[128];
            if (!fgets(line, sizeof(line), stdin)) break;
            int fields = sscanf(line, "%31s %127s %127s", op, value, hint);
            if (fields == 1 && strcmp(op, "quit") == 0) break;
            if (fields == 2 && strcmp(op, "fullscreen") == 0) {
                struct wl_output *output = find_output(app, value);
                if (app->failed) break;
                xdg_toplevel_set_fullscreen(app->toplevel, output);
            } else if (fields == 1 && strcmp(op, "windowed") == 0) {
                xdg_toplevel_unset_fullscreen(app->toplevel);
            } else if ((fields == 2 || fields == 3) && strcmp(op, "identity") == 0) {
                xdg_toplevel_set_app_id(app->toplevel, value);
                if (fields == 3) {
                    struct wl_output *output = find_output(app, hint);
                    if (app->failed) break;
                    xdg_toplevel_set_fullscreen(app->toplevel, output);
                }
            } else { fail(app, "invalid command"); break; }
            wl_surface_commit(app->surface);
            if (wl_display_roundtrip(app->display) < 0) goto disconnected;
            printf("{\"event\":\"command\",\"value\":\"%.*s\"}\n", (int)strcspn(line, "\n"), line);
        }
    }
    app->phase = PHASE_DONE;
    return;
disconnected:
    fail(app, "Wayland display disconnected");
}

int main(int argc, char **argv) {
    const bool commands = argc >= 3 && strcmp(argv[1], "--commands") == 0;
    if ((!commands && argc != 2) || (commands && argc > 4)) {
        fprintf(stderr, "usage: %s SYNC_DIR | --commands APP_ID [INITIAL_OUTPUT]\n", argv[0]);
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    struct app app = { .phase = commands ? PHASE_COMMAND : PHASE_INITIAL, .sync_dir = argv[1] };
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

    if (commands && (wl_display_roundtrip(app.display) < 0 || app.failed)) return 1;

    const size_t pool_size = 4096u * 4096u * 4u;
    const int pool_fd = create_shm_file(pool_size);
    if (pool_fd < 0) {
        fputs("failed to allocate shared-memory pool\n", stderr);
        return 1;
    }
    app.pool = wl_shm_create_pool(app.shm, pool_fd, (int32_t)pool_size);
    (void)close(pool_fd);
    if (app.pool == NULL) return 1;

    app.surface = wl_compositor_create_surface(app.compositor);
    app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
    xdg_surface_add_listener(app.xdg_surface, &surface_listener, &app);
    app.toplevel = xdg_surface_get_toplevel(app.xdg_surface);
    xdg_toplevel_add_listener(app.toplevel, &toplevel_listener, &app);
    xdg_toplevel_set_title(app.toplevel, "Aqueous fullscreen request fixture");
    xdg_toplevel_set_app_id(app.toplevel, commands ? argv[2] : "aqueous.fullscreen-request");
    if (commands && argc == 4) {
        struct wl_output *output = find_output(&app, argv[3]);
        if (app.failed) return 1;
        xdg_toplevel_set_fullscreen(app.toplevel, output);
    }
    wl_surface_commit(app.surface);

    if (commands) dispatch_commands(&app);
    else while (app.phase != PHASE_DONE && wl_display_dispatch(app.display) >= 0) {}
    if (!app.failed && app.phase != PHASE_DONE) fail(&app, "Wayland display disconnected");

    for (size_t index = 0; index < app.buffer_count; index++) wl_buffer_destroy(app.buffers[index]);
    xdg_toplevel_destroy(app.toplevel);
    xdg_surface_destroy(app.xdg_surface);
    wl_surface_destroy(app.surface);
    wl_shm_pool_destroy(app.pool);
    xdg_wm_base_destroy(app.wm_base);
    wl_shm_destroy(app.shm);
    wl_compositor_destroy(app.compositor);
    for (size_t i = 0; i < app.output_count; i++) wl_output_release(app.outputs[i].object);
    wl_registry_destroy(registry);
    wl_display_disconnect(app.display);

    if (app.failed) return 1;
    puts("PASS: client fullscreen requests and repeated configures");
    return 0;
}
