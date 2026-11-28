// SPDX-License-Identifier: GPL-3.0-only
// Static solid-color xdg toplevel for the issue #135 empty-workspace
// scrolling regression. Paints once per configure; no frame callback needed.
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
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *root;
static uint32_t color = 0xff303030;
static const char *app_id = "empty-scrolling";
static const char *title = "empty-scrolling";
static int width = 400, height = 320;

struct allocation { void *pixels; size_t size; };
static void release(void *data, struct wl_buffer *buffer) {
    struct allocation *a = data;
    wl_buffer_destroy(buffer);
    munmap(a->pixels, a->size);
    free(a);
}
static const struct wl_buffer_listener buffer_listener = {.release = release};

static void paint(struct wl_surface *surface, int w, int h, uint32_t c) {
    struct allocation *a = calloc(1, sizeof(*a));
    assert(a);
    a->size = (size_t)w * h * 4;
    int fd = memfd_create("empty-scrolling", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, a->size) == 0);
    a->pixels = mmap(NULL, a->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(a->pixels != MAP_FAILED);
    for (size_t i = 0; i < a->size / 4; i++) ((uint32_t *)a->pixels)[i] = c;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, a->size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_buffer_add_listener(buffer, &buffer_listener, a);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, w, h);
}

static void configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(surface, serial);
    paint(root, width, height, color);
    wl_surface_commit(root);
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
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
}
static void removed(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--color") && i + 1 < argc) color = (uint32_t)strtoul(argv[++i], NULL, 16);
        else if (!strcmp(argv[i], "--app-id") && i + 1 < argc) app_id = argv[++i];
        else if (!strcmp(argv[i], "--title") && i + 1 < argc) title = argv[++i];
    }
    struct wl_display *display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && compositor && shm && wm);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    root = wl_compositor_create_surface(compositor);
    struct xdg_surface *surface = xdg_wm_base_get_xdg_surface(wm, root);
    xdg_surface_add_listener(surface, &surface_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(surface);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, app_id);
    xdg_toplevel_set_title(toplevel, title);
    wl_surface_commit(root);
    while (wl_display_dispatch(display) >= 0) {}
    return 0;
}