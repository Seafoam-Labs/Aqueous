// SPDX-License-Identifier: GPL-3.0-only
#define _POSIX_C_SOURCE 200809L
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "single-pixel-client-protocol.h"
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

struct pixels { struct wl_buffer *buffer; void *data; size_t size; };
struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_subcompositor *subcompositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm;
    struct wp_viewporter *viewporter;
    struct wp_single_pixel_buffer_manager_v1 *single_pixel;
    struct wp_viewport *child_viewport;
    struct wl_surface *surface, *child_surface;
    struct wl_subsurface *child;
    struct xdg_surface *xdg;
    struct xdg_toplevel *toplevel;
    int width, height, padding, transform, child_x, child_y;
    bool configured, running;
};
static void release(void *data, struct wl_buffer *buffer) {
    struct pixels *p = data;
    wl_buffer_destroy(buffer);
    munmap(p->data, p->size);
    free(p);
}
static const struct wl_buffer_listener buffer_listener = { .release = release };
static void single_release(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener single_listener = { .release = single_release };
static void attach(struct app *app, struct wl_surface *surface, int width, int height,
                   int padding, uint32_t color) {
    struct pixels *p = calloc(1, sizeof(*p));
    if (!p) abort();
    p->size = (size_t)width * height * 4;
    char name[] = "/tmp/aqueous-corner-buffer-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) abort();
    unlink(name);
    if (ftruncate(fd, (off_t)p->size) < 0) abort();
    p->data = mmap(NULL, p->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p->data == MAP_FAILED) abort();
    uint32_t *words = p->data;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x)
        words[y * width + x] = x >= padding && x < width - padding &&
            y >= padding && y < height - padding ? color : 0;
    struct wl_shm_pool *pool = wl_shm_create_pool(app->shm, fd, (int32_t)p->size);
    close(fd);
    p->buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    wl_buffer_add_listener(p->buffer, &buffer_listener, p);
    wl_surface_attach(surface, p->buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
}
static void draw(struct app *app) {
    int p = app->padding;
    int bw = app->width + 2 * p, bh = app->height + 2 * p;
    if (app->transform % 2) { int tmp = bw; bw = bh; bh = tmp; }
    wl_surface_set_buffer_transform(app->surface, app->transform);
    attach(app, app->surface, bw, bh, p, 0xffb03020);
    struct wl_region *opaque = wl_compositor_create_region(app->compositor);
    wl_region_add(opaque, p, p, app->width, app->height);
    wl_surface_set_opaque_region(app->surface, opaque);
    wl_region_destroy(opaque);
    xdg_surface_set_window_geometry(app->xdg, p, p, app->width, app->height);
    if (app->child) wl_subsurface_set_position(app->child, p + app->child_x, p + app->child_y);
    wl_surface_commit(app->surface);
}
static void configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    struct app *app = data;
    xdg_surface_ack_configure(surface, serial);
    draw(app);
    if (!app->configured) { app->configured = true; puts("READY"); fflush(stdout); }
}
static const struct xdg_surface_listener surface_listener = { .configure = configure };
static void top_configure(void *data, struct xdg_toplevel *top, int32_t width, int32_t height, struct wl_array *states) {
    (void)top; (void)states;
    struct app *app = data;
    if (width > 0) app->width = width;
    if (height > 0) app->height = height;
}
static void close_window(void *data, struct xdg_toplevel *top) { (void)top; ((struct app *)data)->running = false; }
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = close_window };
static void ping(void *data, struct xdg_wm_base *wm, uint32_t serial) { (void)data; xdg_wm_base_pong(wm, serial); }
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct app *app = data;
    (void)version;
    if (!strcmp(interface, "wl_compositor")) app->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_subcompositor")) app->subcompositor = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
    else if (!strcmp(interface, "wl_shm")) app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "wp_viewporter")) app->viewporter = wl_registry_bind(registry, name, &wp_viewporter_interface, 1);
    else if (!strcmp(interface, "wp_single_pixel_buffer_manager_v1")) app->single_pixel = wl_registry_bind(registry, name, &wp_single_pixel_buffer_manager_v1_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        app->wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(app->wm, &wm_listener, app);
    }
}
static void remove_global(void *data, struct wl_registry *registry, uint32_t name) { (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = remove_global };
int main(int argc, char **argv) {
    struct app app = { .width = 320, .height = 240, .padding = 20, .running = true };
    app.display = wl_display_connect(NULL);
    if (!app.display) return 1;
    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    if (wl_display_roundtrip(app.display) < 0 || !app.compositor || !app.subcompositor || !app.shm || !app.wm) return 1;
    app.surface = wl_compositor_create_surface(app.compositor);
    app.xdg = xdg_wm_base_get_xdg_surface(app.wm, app.surface);
    xdg_surface_add_listener(app.xdg, &surface_listener, &app);
    app.toplevel = xdg_surface_get_toplevel(app.xdg);
    xdg_toplevel_add_listener(app.toplevel, &top_listener, &app);
    xdg_toplevel_set_app_id(app.toplevel, argc > 1 ? argv[1] : "aqueous.corner-probe");
    xdg_toplevel_set_title(app.toplevel, "Rounded window geometry probe");
    wl_surface_commit(app.surface);
    setvbuf(stdin, NULL, _IONBF, 0);
    while (app.running) {
        if (wl_display_dispatch_pending(app.display) < 0 || wl_display_flush(app.display) < 0) break;
        struct pollfd fds[] = { { .fd = wl_display_get_fd(app.display), .events = POLLIN }, { .fd = STDIN_FILENO, .events = POLLIN } };
        if (poll(fds, 2, -1) < 0) break;
        if (fds[0].revents & POLLIN) if (wl_display_dispatch(app.display) < 0) break;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char command[128];
            if (!fgets(command, sizeof(command), stdin)) break;
            int a, b;
            if (sscanf(command, "padding %d", &a) == 1 && a >= 0 && a <= 64) { app.padding = a; draw(&app); }
            else if (sscanf(command, "transform %d", &a) == 1 && a >= 0 && a <= 7) { app.transform = a; draw(&app); }
            else if (sscanf(command, "child %d %d", &a, &b) == 2 ||
                     sscanf(command, "single-child %d %d", &a, &b) == 2) {
                app.child_x = a; app.child_y = b;
                if (!app.child) {
                    app.child_surface = wl_compositor_create_surface(app.compositor);
                    app.child = wl_subcompositor_get_subsurface(app.subcompositor, app.child_surface, app.surface);
                    if (!strncmp(command, "single-child", 12)) {
                        if (!app.single_pixel || !app.viewporter) return 2;
                        app.child_viewport = wp_viewporter_get_viewport(app.viewporter, app.child_surface);
                        wp_viewport_set_destination(app.child_viewport, 64, 64);
                        struct wl_buffer *buffer = wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(
                            app.single_pixel, 0x20202020, 0xc0c0c0c0, 0x40404040, UINT32_MAX);
                        wl_buffer_add_listener(buffer, &single_listener, NULL);
                        wl_surface_attach(app.child_surface, buffer, 0, 0);
                        wl_surface_damage(app.child_surface, 0, 0, 64, 64);
                        wl_surface_commit(app.child_surface);
                    } else attach(&app, app.child_surface, 64, 64, 0, 0xff20c040);
                    wl_surface_commit(app.child_surface);
                }
                draw(&app);
            } else if (!strncmp(command, "no-child", 8)) {
                if (app.child) {
                    if (app.child_viewport) { wp_viewport_destroy(app.child_viewport); app.child_viewport = NULL; }
                    wl_subsurface_destroy(app.child); wl_surface_destroy(app.child_surface); app.child = NULL;
                }
                draw(&app);
            } else if (!strncmp(command, "fullscreen", 10)) xdg_toplevel_set_fullscreen(app.toplevel, NULL);
            else if (!strncmp(command, "windowed", 8)) xdg_toplevel_unset_fullscreen(app.toplevel);
            else if (!strncmp(command, "quit", 4)) break;
            else return 2;
            if (wl_display_roundtrip(app.display) < 0) break;
            puts("OK"); fflush(stdout);
        }
    }
    wl_display_disconnect(app.display);
    return 0;
}
