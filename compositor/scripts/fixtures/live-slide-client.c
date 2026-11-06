// SPDX-License-Identifier: GPL-3.0-only
// Callback-paced color counter, optionally on a desynchronized child only.
#define _GNU_SOURCE
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *root, *animated;
static bool child_only, static_only;
static int width = 400, height = 320;
static uint32_t frame;
static struct wl_callback *pending;

struct allocation { void *pixels; size_t size; };
static void release(void *data, struct wl_buffer *buffer) {
    struct allocation *a = data;
    wl_buffer_destroy(buffer);
    munmap(a->pixels, a->size);
    free(a);
}
static const struct wl_buffer_listener buffer_listener = {.release = release};

static void paint(struct wl_surface *surface, int w, int h, uint32_t color) {
    struct allocation *a = calloc(1, sizeof(*a));
    assert(a);
    a->size = (size_t)w * h * 4;
    int fd = memfd_create("live-slide", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, a->size) == 0);
    a->pixels = mmap(NULL, a->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(a->pixels != MAP_FAILED);
    for (size_t i = 0; i < a->size / 4; i++) ((uint32_t *)a->pixels)[i] = color;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, a->size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_buffer_add_listener(buffer, &buffer_listener, a);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, w, h);
}

static void draw(void);
static void done(void *data, struct wl_callback *callback, uint32_t time) {
    (void)data; (void)time;
    wl_callback_destroy(callback);
    pending = NULL;
    draw();
}
static const struct wl_callback_listener frame_listener = {.done = done};
static void draw(void) {
    if (static_only) {
        paint(root, width, height, 0xff303030);
        wl_surface_commit(root);
        return;
    }
    // Large uniform color is measurable even when cropped/moving. Adjacent
    // frames differ enough to survive output encoding and screenshot rounding.
    uint32_t red = 32 + (frame++ * 13) % 192;
    paint(animated, child_only ? 240 : width, child_only ? 180 : height,
        0xff000000 | red << 16 | 0x50a0);
    if (!pending) {
        pending = wl_surface_frame(animated);
        wl_callback_add_listener(pending, &frame_listener, NULL);
    }
    wl_surface_commit(animated);
    printf("frame %u\n", frame);
    fflush(stdout);
}
static void configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(surface, serial);
    if (child_only) {
        paint(root, width, height, 0xff303030);
        wl_surface_commit(root);
    }
    if (!pending) draw();
}
static const struct xdg_surface_listener surface_listener = {.configure = configure};
static void size(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)t; (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
}
static void close_window(void *data, struct xdg_toplevel *t) { (void)data; (void)t; exit(0); }
static const struct xdg_toplevel_listener toplevel_listener = {.configure = size, .close = close_window};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) { (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, version < 4 ? version : 4);
    if (!strcmp(interface, "wl_subcompositor")) subcompositor = wl_registry_bind(r, name, &wl_subcompositor_interface, 1);
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
}
static void removed(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};

int main(int argc, char **argv) {
    child_only = argc > 1 && !strcmp(argv[1], "--child-only");
    static_only = argc > 1 && !strcmp(argv[1], "--static");
    struct wl_display *display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && compositor && subcompositor && shm && wm);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    root = wl_compositor_create_surface(compositor);
    animated = root;
    struct xdg_surface *surface = xdg_wm_base_get_xdg_surface(wm, root);
    xdg_surface_add_listener(surface, &surface_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(surface);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, child_only ? "aqueous.live-slide-child" : "aqueous.live-slide-root");
    xdg_toplevel_set_title(toplevel, static_only ? "Static slide peer" : "Live slide counter");
    if (child_only) {
        animated = wl_compositor_create_surface(compositor);
        struct wl_subsurface *child = wl_subcompositor_get_subsurface(subcompositor, animated, root);
        wl_subsurface_set_position(child, 40, 40);
        wl_subsurface_set_desync(child);
    }
    wl_surface_commit(root);
    while (wl_display_dispatch(display) >= 0) {}
    return 0;
}
