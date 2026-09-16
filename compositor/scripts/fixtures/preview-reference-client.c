// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <math.h>
#include <poll.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "color-management-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_color_manager_v1 *colors;
static struct wl_surface *surface;
static int width = 400, height = 320;
static bool description_ready;
static bool mapped, hdr;
static unsigned frame;
static struct xdg_surface *xdg;
static uint32_t patch(double nits) {
    if (!hdr) {
        unsigned v = (unsigned)(fmin(nits / 1000.0, 1.0) * 255.0 + .5);
        return 0xff000000 | v * 0x010101;
    }
    // ST 2084 absolute PQ, neutral BT.2020 patches in a 10-bit buffer.
    double y = pow(nits / 10000.0, 2610.0 / 16384.0);
    double pq = pow((3424.0 / 4096.0 + 2413.0 / 128.0 * y) /
        (1.0 + 2392.0 / 128.0 * y), 2523.0 / 32.0);
    unsigned v = (unsigned)(pq * 1023.0 + .5);
    return 0xc0000000 | (v << 20) | (v << 10) | v;
}
static double seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void global(void *data, struct wl_registry *registry, uint32_t name,
        const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    } else if (!strcmp(interface, "wp_color_manager_v1"))
        colors = wl_registry_bind(registry, name, &wp_color_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = { global, removed };
static void supported(void *data, struct wp_color_manager_v1 *manager, uint32_t value) {
    (void)data; (void)manager; (void)value;
}
static void manager_done(void *data, struct wp_color_manager_v1 *manager) {
    (void)data; (void)manager;
}
static const struct wp_color_manager_v1_listener color_listener = {
    .supported_intent = supported, .supported_feature = supported,
    .supported_tf_named = supported, .supported_primaries_named = supported,
    .done = manager_done,
};
static void ready(void *data, struct wp_image_description_v1 *description, uint32_t identity) {
    (void)data; (void)description; (void)identity;
    description_ready = true;
}
static void failed(void *data, struct wp_image_description_v1 *description,
        uint32_t cause, const char *message) {
    (void)data; (void)description;
    fprintf(stderr, "image description failed (%u): %s\n", cause, message);
    exit(1);
}
static const struct wp_image_description_v1_listener description_listener = {
    .ready = ready, .failed = failed,
};
static void release(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = { .release = release };
static void render(void) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/preview-reference-XXXXXX", getenv("XDG_RUNTIME_DIR"));
    int fd = mkstemp(path);
    assert(fd >= 0);
    unlink(path);
    size_t size = (size_t)width * height * 4;
    assert(ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    const double levels[] = { 0, 80, 203, 400, 1000, 4000 };
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++) {
            double level = levels[(size_t)x * 6 / width];
            if (y > height * 3 / 4)
                level = (x / 24 == (int)(frame % ((unsigned)width / 24 + 1))) ? 1000 : 0;
            pixels[y * width + x] = patch(level);
        }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
        width * 4, hdr ? WL_SHM_FORMAT_ARGB2101010 : WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
    xdg_surface_set_window_geometry(xdg, 0, 0, width, height);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    mapped = true;
    frame++;
}
static void configure(void *data, struct xdg_surface *configured, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(configured, serial);
    render();
}
static const struct xdg_surface_listener surface_listener = { .configure = configure };
static void size_changed(void *data, struct xdg_toplevel *top, int32_t w, int32_t h,
        struct wl_array *states) {
    (void)data; (void)top; (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
}
static void closed(void *data, struct xdg_toplevel *top) {
    (void)data; (void)top;
    exit(0);
}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = size_changed, .close = closed,
};
int main(int argc, char **argv) {
    hdr = argc > 1 && !strcmp(argv[1], "hdr");
    if (argc > 1 && strcmp(argv[1], "hdr") && strcmp(argv[1], "sdr")) {
        fprintf(stderr, "usage: %s [hdr|sdr] [duration-seconds]\n", argv[0]);
        return 2;
    }
    double duration = argc > 2 ? atof(argv[2]) : 300;
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("{\"scene\":\"%s\",\"patch_nits\":[0,80,203,400,1000,4000],"
           "\"pacing_fps\":[40,60,90,48],\"panel_refresh_verified\":false}\n", hdr ? "pq-bt2020-10bit" : "sdr-highlight-ramp");
    display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && wm && (!hdr || colors));
    if (colors) {
        wp_color_manager_v1_add_listener(colors, &color_listener, NULL);
        struct wp_image_description_creator_params_v1 *creator =
            wp_color_manager_v1_create_parametric_creator(colors);
        wp_image_description_creator_params_v1_set_tf_named(creator,
            hdr ? WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ : WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_SRGB);
        wp_image_description_creator_params_v1_set_primaries_named(creator,
            hdr ? WP_COLOR_MANAGER_V1_PRIMARIES_BT2020 : WP_COLOR_MANAGER_V1_PRIMARIES_SRGB);
        struct wp_image_description_v1 *description = wp_image_description_creator_params_v1_create(creator);
        wp_image_description_v1_add_listener(description, &description_listener, NULL);
        while (!description_ready) assert(wl_display_dispatch(display) >= 0);
        surface = wl_compositor_create_surface(compositor);
        struct wp_color_management_surface_v1 *color_surface =
            wp_color_manager_v1_get_surface(colors, surface);
        wp_color_management_surface_v1_set_image_description(color_surface, description,
            WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
    } else surface = wl_compositor_create_surface(compositor);
    xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(top, "aqueous.preview-reference");
    xdg_toplevel_set_title(top, "Preview reference: neutral patches and paced moving bar");
    xdg_toplevel_set_fullscreen(top, NULL);
    wl_surface_commit(surface);
    while (!mapped) if (wl_display_dispatch(display) < 0) return 1;
    printf("{\"ready\":true}\n");
    const double rates[] = {40, 60, 90, 48};
    double start = seconds(), next = start;
    unsigned previous_phase = 4;
    while (seconds() - start < duration) {
        if (wl_display_dispatch_pending(display) < 0) return 1;
        double now = seconds();
        unsigned phase = (unsigned)((now - start) / 4) % 4;
        if (phase != previous_phase) {
            printf("{\"elapsed\":%.3f,\"requested_fps\":%.0f,\"frames_submitted\":%u}\n",
                now - start, rates[phase], frame);
            previous_phase = phase;
        }
        if (now >= next) { render(); next = now + 1.0 / rates[phase]; }
        if (wl_display_flush(display) < 0 && errno != EAGAIN) return 1;
        struct pollfd fd = { .fd = wl_display_get_fd(display), .events = POLLIN };
        int result = poll(&fd, 1, (int)fmax(1, (next - seconds()) * 1000));
        if (result < 0 && errno != EINTR) return 1;
        if (result > 0 && wl_display_dispatch(display) < 0) return 1;
    }
    wl_display_disconnect(display);
    return 0;
}
