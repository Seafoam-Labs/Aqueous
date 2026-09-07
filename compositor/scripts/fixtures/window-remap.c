// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
// Persistent window controlled with single-byte commands: h(ide), s(how), q(uit).
// Compile with -DX11 for the XWayland variant. Neither variant recreates its
// window on show, matching an application's hide-to-tray lifecycle.
#define _POSIX_C_SOURCE 200809L
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    Display *display = XOpenDisplay(NULL);
    if (!display) return 1;
    Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
        0, 0, 320, 240, 0, 0, strtoul(argv[2], NULL, 16));
    XClassHint hint = {.res_name = argv[1], .res_class = argv[1]};
    XSetClassHint(display, window, &hint);
    XStoreName(display, window, argv[1]);
    XSelectInput(display, window, StructureNotifyMask | ExposureMask);
    XMapWindow(display, window);
    printf("WINDOW %lu\n", window);
    for (;;) {
        while (XPending(display)) {
            XEvent event;
            XNextEvent(display, &event);
            if (event.type == MapNotify) puts("MAPPED");
            if (event.type == UnmapNotify) puts("UNMAPPED");
            if (event.type == ConfigureNotify) {
                printf("CONFIGURE %d %d\n", event.xconfigure.width, event.xconfigure.height);
            }
            if (event.type == Expose || event.type == ConfigureNotify || event.type == MapNotify)
                XClearWindow(display, window);
        }
        XFlush(display);
        struct pollfd fds[] = {{ConnectionNumber(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) return 1;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char command;
            if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') break;
            if (command == 'h') XUnmapWindow(display, window);
            if (command == 's') XMapWindow(display, window);
        }
    }
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    return 0;
}
#else
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static bool showing = true;
static bool remapping;
static int width = 320, height = 240;
static uint32_t color;

static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
static void released(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {.release = released};
static void configured(void *data, struct xdg_surface *xdg, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xdg, serial);
    printf("CONFIGURE %u %d %d showing=%d\n", serial, width, height, showing);
    if (!showing) return;
    if (remapping && getenv("AQUEOUS_REMAP_WITHHOLD_BUFFER")) {
        puts("NEGATIVE_CONTROL: withholding remap buffer");
        return;
    }
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) exit(1);
    size_t size = (size_t)width * height * 4;
    char path[] = "/tmp/aqueous-remap-buffer.XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) exit(1);
    unlink(path);
    if (ftruncate(fd, (off_t)size)) exit(1);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) exit(1);
    for (size_t i = 0; i < size / 4; i++) pixels[i] = color;
    munmap(pixels, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_shm_pool_destroy(pool);
    close(fd);
    xdg_surface_set_window_geometry(xdg, 0, 0, width, height);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    puts("BUFFER_COMMITTED");
}
static const struct xdg_surface_listener surface_listener = {.configure = configured};
static void size_configured(void *data, struct xdg_toplevel *toplevel, int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)toplevel; (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
}
static void closed(void *data, struct xdg_toplevel *toplevel) {
    (void)data; (void)toplevel;
    exit(0);
}
static const struct xdg_toplevel_listener toplevel_listener = {.configure = size_configured, .close = closed};

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    color = (uint32_t)strtoul(argv[2], NULL, 16);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !shm || !wm) return 1;
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, argv[1]);
    xdg_toplevel_set_title(toplevel, argv[1]);
    wl_surface_commit(surface);
    printf("WINDOW %u\n", wl_proxy_get_id((struct wl_proxy *)surface));
    for (;;) {
        if (wl_display_dispatch_pending(display) < 0) return 1;
        wl_display_flush(display);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) return 1;
        if (fds[0].revents & (POLLERR | POLLHUP)) return 1;
        if ((fds[0].revents & POLLIN) && wl_display_dispatch(display) < 0) return 1;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char command;
            if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') break;
            if (command == 'h' && showing) {
                showing = false;
                wl_surface_attach(surface, NULL, 0, 0);
                wl_surface_commit(surface);
                puts("UNMAP_COMMITTED");
            }
            if (command == 's' && !showing) {
                showing = true;
                remapping = true;
                // xdg-shell resets toplevel attributes on unmap.
                xdg_toplevel_set_app_id(toplevel, argv[1]);
                xdg_toplevel_set_title(toplevel, argv[1]);
                wl_surface_commit(surface);
                puts("REMAP_REQUESTED");
            }
        }
    }
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdg);
    wl_surface_destroy(surface);
    wl_display_flush(display);
    wl_display_disconnect(display);
    return 0;
}
#endif
