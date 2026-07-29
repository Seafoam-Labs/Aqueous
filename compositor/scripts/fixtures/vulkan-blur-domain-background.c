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
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"

struct owned_buffer {
    struct wl_buffer *buffer;
    uint32_t *pixels;
    size_t size;
    int32_t width;
    int32_t height;
    bool released;
};

struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct wl_surface *surface;
    struct zwlr_layer_surface_v1 *layer_surface;
    struct owned_buffer buffer;
    struct wl_callback *frame_callback;
    const char *ready_path;
    const char *control_dir;
    uint64_t last_sequence;
    uint64_t pending_sequence;
    char pending_operation[32];
    int32_t pending_x;
    int32_t pending_y;
    int32_t pending_width;
    int32_t pending_height;
    int32_t edge_generation;
    bool configured;
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
        "%s/aqueous-blur-domain-XXXXXX",
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

static uint32_t argb(uint8_t red, uint8_t green, uint8_t blue) {
    return UINT32_C(0xff000000) |
        ((uint32_t)red << 16) |
        ((uint32_t)green << 8) |
        (uint32_t)blue;
}

static int32_t left_domain_end(int32_t width) {
    const int32_t outer_gap = 8;
    const int32_t inner_gap = 4;
    const int32_t usable = width - 2 * outer_gap;
    const int32_t available = usable - inner_gap;
    const int32_t primary = (available + 1) / 2;
    return outer_gap + primary;
}

static void paint_background(struct app *app) {
    const int32_t width = app->buffer.width;
    const int32_t height = app->buffer.height;
    const int32_t left_end = left_domain_end(width);
    const int32_t right_start = left_end + 4;
    const int32_t patch_x = left_end - 62;
    const int32_t patch_y = height / 3;

    for (int32_t y = 0; y < height; y++) {
        for (int32_t x = 0; x < width; x++) {
            uint32_t color;
            if (x >= left_end && x < right_start) {
                // Keep the true inter-window gap dark. Cross-window isolation
                // is tested separately by the opaque client witness on the
                // lower (left) sibling, not by gap pixels.
                color = argb(10, 12, 16);
            } else {
                const int32_t gradient =
                    width > 1 ? (x * 112) / (width - 1) : 0;
                const bool bright = ((x / 8) & 1) != 0;
                const uint8_t red = (uint8_t)(
                    (bright ? 104 : 24) + gradient);
                const uint8_t green = (uint8_t)(
                    (bright ? 164 : 52) + gradient / 2);
                const uint8_t blue = (uint8_t)(bright ? 76 : 20);
                color = argb(red, green, blue);
            }

            // The right blur domain starts at right_start. Its first two
            // source pixels are a narrow high-contrast ridge, followed by a
            // dark 4px pattern. Constant edge clamping repeats the ridge over
            // the whole out-of-domain kernel and creates a bright plateau;
            // reflection folds the alternating in-domain pattern instead.
            if (x >= right_start && x < right_start + 98) {
                if (x < right_start + 2) {
                    color = argb(255, 248, 224);
                } else {
                    const bool alternate = ((x - right_start - 2) / 4) % 2 == 0;
                    color = alternate
                        ? argb(8, 10, 14)
                        : argb(80, 34, 8);
                }
            }

            if (app->edge_generation > 0 &&
                x >= patch_x && x < patch_x + 36 &&
                y >= patch_y && y < patch_y + 160) {
                const bool alternate =
                    (((x - patch_x) / 6) + ((y - patch_y) / 6) +
                        app->edge_generation) % 2 == 0;
                color = alternate
                    ? argb(255, 244, 24)
                    : argb(20, 224, 255);
            }
            app->buffer.pixels[
                (size_t)y * (size_t)width + (size_t)x] = color;
        }
    }
}

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void)buffer;
    struct app *app = data;
    app->buffer.released = true;
}

static const struct wl_buffer_listener buffer_listener = {
    .release = buffer_release,
};

static bool allocate_buffer(
    struct app *app,
    int32_t width,
    int32_t height) {
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
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
        WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    if (buffer == NULL) {
        (void)munmap(pixels, size);
        return false;
    }

    app->buffer = (struct owned_buffer){
        .buffer = buffer,
        .pixels = pixels,
        .size = size,
        .width = width,
        .height = height,
    };
    wl_buffer_add_listener(buffer, &buffer_listener, app);
    paint_background(app);
    wl_surface_attach(app->surface, buffer, 0, 0);
    wl_surface_damage_buffer(app->surface, 0, 0, width, height);
    wl_surface_commit(app->surface);
    return true;
}

static bool publish_ready(struct app *app) {
    FILE *file = fopen(app->ready_path, "w");
    if (file == NULL) return false;
    const int written = fprintf(
        file,
        "domain-background %d %d\n",
        app->buffer.width,
        app->buffer.height);
    bool ok = written > 0;
    if (fclose(file) != 0) ok = false;
    return ok;
}

static bool publish_ack(struct app *app) {
    char temporary[PATH_MAX];
    char destination[PATH_MAX];
    if (snprintf(
            temporary,
            sizeof(temporary),
            "%s/ack.tmp",
            app->control_dir) < 0 ||
        snprintf(
            destination,
            sizeof(destination),
            "%s/ack",
            app->control_dir) < 0) {
        return false;
    }
    FILE *file = fopen(temporary, "w");
    if (file == NULL) return false;
    const int written = fprintf(
        file,
        "%llu %s %d %d %d %d\n",
        (unsigned long long)app->pending_sequence,
        app->pending_operation,
        app->pending_x,
        app->pending_y,
        app->pending_width,
        app->pending_height);
    bool ok = written > 0;
    if (fclose(file) != 0) ok = false;
    if (ok && rename(temporary, destination) != 0) ok = false;
    return ok;
}

static void frame_done(
    void *data,
    struct wl_callback *callback,
    uint32_t callback_data) {
    (void)callback_data;
    struct app *app = data;
    wl_callback_destroy(callback);
    app->frame_callback = NULL;
    app->last_sequence = app->pending_sequence;
    if (!publish_ack(app)) fail(app, "unable to publish control acknowledgement");
}

static const struct wl_callback_listener frame_listener = {
    .done = frame_done,
};

static bool submit_update(
    struct app *app,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height) {
    paint_background(app);
    app->buffer.released = false;
    wl_surface_attach(app->surface, app->buffer.buffer, 0, 0);
    wl_surface_damage_buffer(app->surface, x, y, width, height);
    app->frame_callback = wl_surface_frame(app->surface);
    if (app->frame_callback == NULL) return false;
    wl_callback_add_listener(app->frame_callback, &frame_listener, app);
    wl_surface_commit(app->surface);
    return true;
}

static bool process_control(struct app *app) {
    if (!app->configured || !app->buffer.released ||
        app->frame_callback != NULL) {
        return true;
    }

    char path[PATH_MAX];
    if (snprintf(
            path,
            sizeof(path),
            "%s/command",
            app->control_dir) < 0) {
        return false;
    }
    FILE *file = fopen(path, "r");
    if (file == NULL) return errno == ENOENT;

    unsigned long long sequence_value = 0;
    char operation[32];
    int32_t value = 0;
    const int fields = fscanf(
        file,
        "%llu %31s %d",
        &sequence_value,
        operation,
        &value);
    const int close_result = fclose(file);
    if (fields != 3 || close_result != 0) return false;
    const uint64_t sequence = (uint64_t)sequence_value;
    if (sequence <= app->last_sequence) return true;

    const int32_t left_end = left_domain_end(app->buffer.width);
    const int32_t patch_x = left_end - 62;
    const int32_t patch_y = app->buffer.height / 3;
    int32_t damage_x = 0;
    int32_t damage_y = 0;
    int32_t damage_width = app->buffer.width;
    int32_t damage_height = app->buffer.height;
    if (strcmp(operation, "edge") == 0 && value > 0) {
        app->edge_generation = value;
        damage_x = patch_x;
        damage_y = patch_y;
        damage_width = 36;
        damage_height = 160;
    } else if (strcmp(operation, "repaint") == 0 &&
        value == app->edge_generation) {
        // Re-submit identical pixels with full-surface damage. This is the
        // oracle for the preceding edge-localized cache update.
    } else if (strcmp(operation, "reset") == 0 && value == 0) {
        app->edge_generation = 0;
    } else {
        return false;
    }

    app->pending_sequence = sequence;
    app->pending_x = damage_x;
    app->pending_y = damage_y;
    app->pending_width = damage_width;
    app->pending_height = damage_height;
    if (snprintf(
            app->pending_operation,
            sizeof(app->pending_operation),
            "%s",
            operation) < 0) {
        return false;
    }
    return submit_update(
        app,
        damage_x,
        damage_y,
        damage_width,
        damage_height);
}

static void layer_surface_configure(
    void *data,
    struct zwlr_layer_surface_v1 *layer_surface,
    uint32_t serial,
    uint32_t width,
    uint32_t height) {
    struct app *app = data;
    zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    if (app->configured) return;
    if (width == 0 || height == 0 ||
        !allocate_buffer(app, (int32_t)width, (int32_t)height)) {
        fail(app, "unable to allocate the domain background");
        return;
    }
    app->configured = true;
    if (!publish_ready(app)) fail(app, "unable to publish readiness");
}

static void layer_surface_closed(
    void *data,
    struct zwlr_layer_surface_v1 *layer_surface) {
    (void)layer_surface;
    fail(data, "compositor closed the domain background");
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
    .configure = layer_surface_configure,
    .closed = layer_surface_closed,
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
        const uint32_t bind_version = version < 4 ? version : 4;
        app->layer_shell = wl_registry_bind(
            registry,
            name,
            &zwlr_layer_shell_v1_interface,
            bind_version);
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
    if (argc != 3) {
        fprintf(stderr, "usage: %s READY_FILE CONTROL_DIR\n", argv[0]);
        return 2;
    }

    struct app app = {
        .ready_path = argv[1],
        .control_dir = argv[2],
    };
    app.display = wl_display_connect(NULL);
    if (app.display == NULL) {
        fputs("failed to connect to Wayland display\n", stderr);
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    if (wl_display_roundtrip(app.display) < 0 || app.compositor == NULL ||
        app.shm == NULL || app.layer_shell == NULL) {
        fputs("required Wayland globals unavailable\n", stderr);
        return 1;
    }

    app.surface = wl_compositor_create_surface(app.compositor);
    app.layer_surface = zwlr_layer_shell_v1_get_layer_surface(
        app.layer_shell,
        app.surface,
        NULL,
        ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
        "aqueous-blur-domain-background");
    if (app.surface == NULL || app.layer_surface == NULL) return 1;
    zwlr_layer_surface_v1_add_listener(
        app.layer_surface,
        &layer_surface_listener,
        &app);
    zwlr_layer_surface_v1_set_size(app.layer_surface, 0, 0);
    zwlr_layer_surface_v1_set_anchor(
        app.layer_surface,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
            ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_set_exclusive_zone(app.layer_surface, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(app.layer_surface, 0);
    wl_surface_commit(app.surface);

    const int display_fd = wl_display_get_fd(app.display);
    while (!app.failed) {
        if (wl_display_dispatch_pending(app.display) < 0) break;
        if (wl_display_flush(app.display) < 0 && errno != EAGAIN) break;
        struct pollfd descriptor = {
            .fd = display_fd,
            .events = POLLIN,
        };
        const int result = poll(&descriptor, 1, 20);
        if (result < 0) {
            if (errno == EINTR) continue;
            fail(&app, "poll failed");
            break;
        }
        if (result > 0) {
            if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                break;
            }
            if ((descriptor.revents & POLLIN) != 0 &&
                wl_display_dispatch(app.display) < 0) {
                break;
            }
        }
        if (!process_control(&app)) {
            fail(&app, "unable to process control command");
        }
    }

    if (app.frame_callback != NULL) {
        wl_callback_destroy(app.frame_callback);
    }
    if (app.buffer.buffer != NULL) {
        wl_buffer_destroy(app.buffer.buffer);
        (void)munmap(app.buffer.pixels, app.buffer.size);
    }
    zwlr_layer_surface_v1_destroy(app.layer_surface);
    wl_surface_destroy(app.surface);
    zwlr_layer_shell_v1_destroy(app.layer_shell);
    wl_shm_destroy(app.shm);
    wl_compositor_destroy(app.compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(app.display);
    return app.failed ? 1 : 0;
}
