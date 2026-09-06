// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "background-effect-client-protocol.h"
#include "layer-shell-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct zwlr_layer_shell_v1 *layer_shell;
static struct ext_background_effect_manager_v1 *manager, *second_manager;
static uint32_t caps;
static bool caps_received;
static bool inverted;
struct view { struct wl_surface *surface; struct zwlr_layer_surface_v1 *layer; struct wl_buffer *buffer; bool configured; bool geometry_offset; struct xdg_surface *xdg; struct xdg_toplevel *toplevel; struct xdg_popup *popup; };
static void capabilities(void *data, struct ext_background_effect_manager_v1 *m, uint32_t flags) {
    (void)data; (void)m; caps = flags; caps_received = true;
}
static const struct ext_background_effect_manager_v1_listener effect_listener = { .capabilities = capabilities };
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) { (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    if (!strcmp(interface, "wl_subcompositor")) subcompositor = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) { wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 2); xdg_wm_base_add_listener(wm_base, &wm_listener, NULL); }
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    if (!strcmp(interface, "zwlr_layer_shell_v1")) layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, 4);
    if (!strcmp(interface, "ext_background_effect_manager_v1")) {
        manager = wl_registry_bind(registry, name, &ext_background_effect_manager_v1_interface, 1);
        second_manager = wl_registry_bind(registry, name, &ext_background_effect_manager_v1_interface, 1);
        ext_background_effect_manager_v1_add_listener(manager, &effect_listener, NULL);
        ext_background_effect_manager_v1_add_listener(second_manager, &effect_listener, NULL);
    }
}
static void removed(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };
static struct wl_buffer *buffer(int width, int height, bool background) {
    char path[] = "/tmp/aqueous-blur-buffer-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0); unlink(path);
    size_t size = (size_t)width * height * 4;
    assert(ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    for (int y = 0; y < height; y++) for (int x = 0; x < width; x++)
        pixels[y * width + x] = background ? (((((x / 8) + (y / 8)) % 2) != inverted) ? 0xffeeeeee : 0xff111111) : 0x00000000;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *result = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool); munmap(pixels, size); close(fd);
    return result;
}
static void configure(void *data, struct zwlr_layer_surface_v1 *layer, uint32_t serial, uint32_t width, uint32_t height) {
    (void)width; (void)height;
    struct view *v = data;
    zwlr_layer_surface_v1_ack_configure(layer, serial);
    wl_surface_attach(v->surface, v->buffer, 0, 0);
    wl_surface_damage_buffer(v->surface, 0, 0, INT32_MAX, INT32_MAX);
    wl_surface_commit(v->surface);
    v->configured = true;
}
static void closed(void *data, struct zwlr_layer_surface_v1 *layer) { (void)data; (void)layer; }
static const struct zwlr_layer_surface_v1_listener layer_listener = { .configure = configure, .closed = closed };
static void view_init(struct view *v, bool background) {
    v->surface = wl_compositor_create_surface(compositor);
    v->buffer = buffer(background ? 1280 : 320, background ? 720 : 240, background);
    v->layer = zwlr_layer_shell_v1_get_layer_surface(layer_shell, v->surface, NULL,
        background ? ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND : ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        background ? "aqueous.blur.background" : "aqueous.blur.client");
    zwlr_layer_surface_v1_set_size(v->layer, background ? 1280 : 320, background ? 720 : 240);
    zwlr_layer_surface_v1_set_anchor(v->layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_set_exclusive_zone(v->layer, -1);
    zwlr_layer_surface_v1_add_listener(v->layer, &layer_listener, v);
    wl_surface_commit(v->surface);
    while (!v->configured) assert(wl_display_dispatch(display) >= 0);
}
static void xdg_configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    struct view *v = data;
    xdg_surface_ack_configure(xdg, serial);
    wl_surface_attach(v->surface, v->buffer, 0, 0);
    wl_surface_damage_buffer(v->surface, 0, 0, INT32_MAX, INT32_MAX);
    wl_surface_commit(v->surface);
    v->configured = true;
}
static const struct xdg_surface_listener xdg_listener = { .configure = xdg_configure };
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) { (void)d; (void)t; (void)w; (void)h; (void)s; }
static void top_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; }
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = top_close };
static void popup_configure(void *d, struct xdg_popup *p, int32_t x, int32_t y, int32_t w, int32_t h) { (void)d; (void)p; (void)x; (void)y; (void)w; (void)h; }
static void popup_done(void *d, struct xdg_popup *p) { (void)d; (void)p; }
static const struct xdg_popup_listener popup_listener = { .configure = popup_configure, .popup_done = popup_done };
static void xdg_init(struct view *v, struct view *parent) {
    v->surface = wl_compositor_create_surface(compositor);
    v->buffer = buffer(320, 240, false);
    v->xdg = xdg_wm_base_get_xdg_surface(wm_base, v->surface);
    xdg_surface_add_listener(v->xdg, &xdg_listener, v);
    if (parent) {
        struct xdg_positioner *positioner = xdg_wm_base_create_positioner(wm_base);
        xdg_positioner_set_size(positioner, 320, 240);
        xdg_positioner_set_anchor_rect(positioner, 0, 0, 1, 1);
        xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_TOP_LEFT);
        xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
        v->popup = xdg_surface_get_popup(v->xdg, parent->xdg, positioner);
        if (parent->layer) zwlr_layer_surface_v1_get_popup(parent->layer, v->popup);
        xdg_popup_add_listener(v->popup, &popup_listener, v);
        xdg_positioner_destroy(positioner);
    } else {
        v->toplevel = xdg_surface_get_toplevel(v->xdg);
        xdg_toplevel_set_app_id(v->toplevel, "aqueous.blur.client");
        xdg_toplevel_add_listener(v->toplevel, &top_listener, v);
    }
    if (v->geometry_offset) xdg_surface_set_window_geometry(v->xdg, 10, 15, 300, 210);
    wl_surface_commit(v->surface);
    while (!v->configured) assert(wl_display_dispatch(display) >= 0);
}
static void set_region(struct ext_background_effect_surface_v1 *effect, const char *shape) {
    struct wl_region *region = wl_compositor_create_region(compositor);
    if (!strcmp(shape, "hole") || !strcmp(shape, "shift")) {
        wl_region_add(region, 20, 20, 240, 160);
        wl_region_subtract(region, !strcmp(shape, "hole") ? 80 : 160, 60, 60, 60);
    } else if (!strcmp(shape, "split")) {
        wl_region_add(region, 20, 20, 70, 160);
        wl_region_add(region, 190, 20, 70, 160);
    } else if (!strcmp(shape, "rounded")) {
        for (int y = 20; y < 180; y++) {
            int inset = y < 40 ? 40-y : y >= 160 ? y-159 : 0;
            wl_region_add(region, 20+inset, y, 240-2*inset, 1);
        }
    } else if (!strcmp(shape, "outside")) {
        wl_region_add(region, -100, -100, 1000, 1000);
    }
    ext_background_effect_surface_v1_set_blur_region(effect, region);
    // Prove copy semantics, including destruction before the surface commits.
    wl_region_add(region, 0, 0, 320, 240);
    wl_region_destroy(region);
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(wl_display_roundtrip(display) >= 0);
    if (argc > 1 && !strcmp(argv[1], "probe")) {
        printf("%s %u\n", manager ? "supported" : "unsupported", caps);
        wl_display_disconnect(display); return 0;
    }
    assert(manager && caps_received && compositor && subcompositor && shm && layer_shell);
    struct view background = {0}, view = {0}, popup = {0}, nested = {0};
    view_init(&background, true);
    const char *mode = argc > 1 ? argv[1] : "layer";
    view.geometry_offset = !strcmp(mode, "geometry");
    if (!strcmp(mode, "toplevel") || !strcmp(mode, "geometry") || !strcmp(mode, "app-popup")) xdg_init(&view, NULL);
    else view_init(&view, false);
    struct wl_surface *target = view.surface;
    if (!strcmp(mode, "popup") || !strcmp(mode, "app-popup") || !strcmp(mode, "nested-popup")) {
        xdg_init(&popup, &view);
        target = popup.surface;
        if (!strcmp(mode, "nested-popup")) { xdg_init(&nested, &popup); target = nested.surface; }
    }
    struct wl_surface *child = NULL;
    struct wl_subsurface *sub = NULL;
    if (argc > 1 && !strcmp(argv[1], "subsurface")) {
        child = wl_compositor_create_surface(compositor);
        sub = wl_subcompositor_get_subsurface(subcompositor, child, view.surface);
        wl_subsurface_set_position(sub, 0, 0);
        wl_subsurface_place_below(sub, view.surface);
        wl_surface_attach(child, buffer(320, 240, false), 0, 0);
        wl_surface_commit(child); wl_surface_commit(view.surface);
        target = child;
    }
    if (view.xdg && target != view.surface) {
        (void)ext_background_effect_manager_v1_get_background_effect(manager, view.surface);
        wl_surface_commit(view.surface);
    }
    struct ext_background_effect_surface_v1 *effect = ext_background_effect_manager_v1_get_background_effect(manager, target);
    wl_surface_commit(target);
    wl_surface_commit(view.surface);
    assert(wl_display_roundtrip(display) >= 0);
    puts("READY");
    char line[128];
    while (true) {
        assert(wl_display_flush(display) >= 0);
        struct pollfd fds[2] = {{STDIN_FILENO, POLLIN, 0}, {wl_display_get_fd(display), POLLIN, 0}};
        assert(poll(fds, 2, -1) >= 0);
        if (fds[1].revents & POLLIN) assert(wl_display_dispatch(display) >= 0);
        if (!(fds[0].revents & POLLIN)) continue;
        if (!fgets(line, sizeof(line), stdin)) break;
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "set ", 4)) set_region(effect, line + 4);
        else if (!strcmp(line, "commit")) wl_surface_commit(target);
        else if (!strcmp(line, "parent")) wl_surface_commit(view.surface);
        else if (!strcmp(line, "desync")) { assert(sub); wl_subsurface_set_desync(sub); }
        else if (!strcmp(line, "above")) { assert(sub); wl_subsurface_place_above(sub, view.surface); wl_surface_commit(view.surface); }
        else if (!strcmp(line, "clear")) ext_background_effect_surface_v1_set_blur_region(effect, NULL);
        else if (!strcmp(line, "destroy")) { ext_background_effect_surface_v1_destroy(effect); effect = NULL; }
        else if (!strcmp(line, "create")) effect = ext_background_effect_manager_v1_get_background_effect(second_manager, target);
        else if (!strcmp(line, "manager-destroy")) { ext_background_effect_manager_v1_destroy(manager); manager = NULL; }
        else if (!strcmp(line, "unmap")) { wl_surface_attach(target, NULL, 0, 0); wl_surface_commit(target); }
        else if (!strcmp(line, "remap")) {
            if (child) { wl_surface_attach(target, buffer(320, 240, false), 0, 0); wl_surface_commit(target); wl_surface_commit(view.surface); }
            else { view.configured = false; wl_surface_commit(target); while (!view.configured) assert(wl_display_dispatch(display) >= 0); }
        }
        else if (!strcmp(line, "duplicate") || !strcmp(line, "dead-surface")) {
            if (!strcmp(line, "duplicate")) (void)ext_background_effect_manager_v1_get_background_effect(second_manager, target);
            else { if (sub) wl_subsurface_destroy(sub); else zwlr_layer_surface_v1_destroy(view.layer); wl_surface_destroy(target); ext_background_effect_surface_v1_set_blur_region(effect, NULL); }
            assert(wl_display_roundtrip(display) < 0);
            const struct wl_interface *interface = NULL;
            uint32_t code = wl_display_get_protocol_error(display, &interface, NULL);
            assert(interface && code == 0);
            assert(!strcmp(interface->name, !strcmp(line, "duplicate") ? "ext_background_effect_manager_v1" : "ext_background_effect_surface_v1"));
            puts("EXPECTED_ERROR"); wl_display_disconnect(display); return 0;
        }
        else if (!strcmp(line, "background")) {
            inverted = !inverted;
            background.buffer = buffer(1280, 720, true);
            wl_surface_attach(background.surface, background.buffer, 0, 0);
            wl_surface_damage_buffer(background.surface, 0, 0, INT32_MAX, INT32_MAX);
            wl_surface_commit(background.surface);
        }
        else if (!strcmp(line, "caps")) { }
        else if (!strcmp(line, "quit")) break;
        else abort();
        assert(wl_display_roundtrip(display) >= 0);
        printf("OK %u\n", caps);
    }
    wl_display_disconnect(display);
    return 0;
}
