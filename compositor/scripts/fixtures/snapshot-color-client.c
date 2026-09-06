// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
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
static bool mapped;

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
static void configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    (void)data;
    // Leave a transaction snapshot visible long enough for frame sampling.
    if (mapped) nanosleep(&(struct timespec){ .tv_nsec = 80000000 }, NULL);
    xdg_surface_ack_configure(xdg, serial);
    char path[4096];
    snprintf(path, sizeof(path), "%s/snapshot-pixels-XXXXXX", getenv("XDG_RUNTIME_DIR"));
    int fd = mkstemp(path);
    assert(fd >= 0);
    unlink(path);
    size_t size = (size_t)width * height * 4;
    assert(ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    const uint32_t patches[] = { 0xff404040, 0xff808080, 0xff306080, 0xff804030 };
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++)
            pixels[y * width + x] = patches[(y >= height / 2) * 2 + (x >= width / 2)];
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
        width * 4, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
    xdg_surface_set_window_geometry(xdg, 0, 0, width, height);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    mapped = true;
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
int main(void) {
    display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && wm && colors);
    wp_color_manager_v1_add_listener(colors, &color_listener, NULL);
    struct wp_image_description_creator_params_v1 *creator =
        wp_color_manager_v1_create_parametric_creator(colors);
    wp_image_description_creator_params_v1_set_tf_named(creator,
        WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22);
    wp_image_description_creator_params_v1_set_primaries_named(creator,
        WP_COLOR_MANAGER_V1_PRIMARIES_BT2020);
    struct wp_image_description_v1 *description = wp_image_description_creator_params_v1_create(creator);
    wp_image_description_v1_add_listener(description, &description_listener, NULL);
    while (!description_ready) assert(wl_display_dispatch(display) >= 0);
    surface = wl_compositor_create_surface(compositor);
    struct wp_color_management_surface_v1 *color_surface =
        wp_color_manager_v1_get_surface(colors, surface);
    wp_color_management_surface_v1_set_image_description(color_surface, description,
        WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(top, "aqueous.snapshot-color");
    xdg_toplevel_set_title(top, "Snapshot color regression");
    wl_surface_commit(surface);
    while (wl_display_dispatch(display) >= 0) {}
    return 1;
}
