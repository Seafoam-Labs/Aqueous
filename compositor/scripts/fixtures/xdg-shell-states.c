// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
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
#include "xdg-shell-client-protocol.h"
#include "ext-foreign-toplevel-list-client-protocol.h"
#include "ext-image-capture-source-client-protocol.h"
#include "ext-image-copy-capture-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static struct xdg_surface *xdg;
static struct xdg_toplevel *top;
static unsigned bind_version, states, serial, draws;
static int width = 400, height = 300;
static bool mapped, ack_only, delay_ack;
static const char *app_id;
static struct ext_foreign_toplevel_handle_v1 *foreign;
static struct ext_foreign_toplevel_image_capture_source_manager_v1 *capture_manager;
static struct ext_image_copy_capture_manager_v1 *copy_manager;
static struct ext_image_capture_source_v1 *capture_source;
static struct ext_image_copy_capture_session_v1 *capture_session;

static void foreign_closed(void *data, struct ext_foreign_toplevel_handle_v1 *object) {
    (void)data; if (foreign == object) foreign = NULL; ext_foreign_toplevel_handle_v1_destroy(object);
}
static void foreign_done(void *data, struct ext_foreign_toplevel_handle_v1 *object) { (void)data; (void)object; }
static void foreign_string(void *data, struct ext_foreign_toplevel_handle_v1 *object, const char *value) { (void)data; (void)object; (void)value; }
static void foreign_app_id(void *data, struct ext_foreign_toplevel_handle_v1 *object, const char *value) {
    (void)data; if (!strcmp(value, app_id)) foreign = object;
}
static const struct ext_foreign_toplevel_handle_v1_listener foreign_listener = {
    .closed = foreign_closed, .done = foreign_done, .title = foreign_string,
    .app_id = foreign_app_id, .identifier = foreign_string,
};
static void foreign_top(void *data, struct ext_foreign_toplevel_list_v1 *object, struct ext_foreign_toplevel_handle_v1 *handle) {
    (void)data; (void)object; ext_foreign_toplevel_handle_v1_add_listener(handle, &foreign_listener, NULL);
}
static void foreign_finished(void *data, struct ext_foreign_toplevel_list_v1 *object) { (void)data; (void)object; }
static const struct ext_foreign_toplevel_list_v1_listener list_listener = {.toplevel = foreign_top, .finished = foreign_finished};
static void capture_size(void *data, struct ext_image_copy_capture_session_v1 *object, uint32_t w, uint32_t h) { (void)data; (void)object; (void)w; (void)h; }
static void capture_format(void *data, struct ext_image_copy_capture_session_v1 *object, uint32_t format) { (void)data; (void)object; (void)format; }
static void capture_device(void *data, struct ext_image_copy_capture_session_v1 *object, struct wl_array *device) { (void)data; (void)object; (void)device; }
static void capture_dmabuf(void *data, struct ext_image_copy_capture_session_v1 *object, uint32_t format, struct wl_array *mods) { (void)data; (void)object; (void)format; (void)mods; }
static void capture_done(void *data, struct ext_image_copy_capture_session_v1 *object) { (void)data; (void)object; }
static const struct ext_image_copy_capture_session_v1_listener capture_listener = {
    .buffer_size = capture_size, .shm_format = capture_format, .dmabuf_device = capture_device,
    .dmabuf_format = capture_dmabuf, .done = capture_done, .stopped = capture_done,
};

static void release(void *data, struct wl_buffer *buffer) {
    (void)data; wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {.release = release};
static void draw(void) {
    int fd = memfd_create("xdg-shell-states", MFD_CLOEXEC);
    size_t size = (size_t)width * height * 4;
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    for (size_t i = 0; i < size / 4; ++i) pixels[i] = 0xff204060;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    wl_shm_pool_destroy(pool); munmap(pixels, size); close(fd);
    mapped = true;
    printf("{\"event\":\"draw\",\"count\":%u}\n", ++draws);
}
static void acknowledge(void) {
    xdg_surface_ack_configure(xdg, serial);
    printf("{\"event\":\"ack\",\"serial\":%u}\n", serial);
    if ((!mapped || !(states & (1u << XDG_TOPLEVEL_STATE_SUSPENDED))) && !ack_only) draw();
}
static void configured(void *data, struct xdg_surface *object, uint32_t value) {
    (void)data; (void)object; serial = value;
    printf("{\"event\":\"configure\",\"serial\":%u,\"states\":%u,\"width\":%d,\"height\":%d}\n", serial, states, width, height);
    if (!delay_ack) acknowledge();
}
static const struct xdg_surface_listener surface_listener = {.configure = configured};
static void top_configure(void *data, struct xdg_toplevel *object, int32_t w, int32_t h, struct wl_array *values) {
    (void)data; (void)object;
    if (w > 0) width = w;
    if (h > 0) height = h;
    states = 0;
    uint32_t *value;
    wl_array_for_each(value, values) { assert(*value < 32); states |= 1u << *value; }
}
static void close_top(void *data, struct xdg_toplevel *object) { (void)data; (void)object; exit(0); }
static void bounds(void *data, struct xdg_toplevel *object, int32_t w, int32_t h) { (void)data; (void)object; (void)w; (void)h; }
static void caps(void *data, struct xdg_toplevel *object, struct wl_array *values) { (void)data; (void)object; (void)values; }
static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure, .close = close_top, .configure_bounds = bounds, .wm_capabilities = caps,
};
static void ping(void *data, struct xdg_wm_base *object, uint32_t value) { (void)data; xdg_wm_base_pong(object, value); }
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
    if (!strcmp(interface, "ext_foreign_toplevel_list_v1")) {
        struct ext_foreign_toplevel_list_v1 *list = wl_registry_bind(registry, id, &ext_foreign_toplevel_list_v1_interface, 1);
        ext_foreign_toplevel_list_v1_add_listener(list, &list_listener, NULL);
    }
    if (!strcmp(interface, "ext_foreign_toplevel_image_capture_source_manager_v1"))
        capture_manager = wl_registry_bind(registry, id, &ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1);
    if (!strcmp(interface, "ext_image_copy_capture_manager_v1"))
        copy_manager = wl_registry_bind(registry, id, &ext_image_copy_capture_manager_v1_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) {
        printf("{\"event\":\"global\",\"version\":%u}\n", version);
        assert(version >= bind_version);
        wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, bind_version);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) { (void)data; (void)registry; (void)id; }
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
int main(int argc, char **argv) {
    assert(argc == 3); bind_version = (unsigned)atoi(argv[1]);
    app_id = argv[2];
    setvbuf(stdout, NULL, _IOLBF, 0);
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && compositor && shm && wm);
    surface = wl_compositor_create_surface(compositor);
    xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_app_id(top, argv[2]);
    xdg_toplevel_set_title(top, argv[2]);
    wl_surface_commit(surface);
    for (;;) {
        while (wl_display_prepare_read(display) != 0) assert(wl_display_dispatch_pending(display) >= 0);
        wl_display_flush(display);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        assert(poll(fds, 2, -1) >= 0);
        if (fds[0].revents & POLLIN) assert(wl_display_read_events(display) >= 0);
        else wl_display_cancel_read(display);
        assert(wl_display_dispatch_pending(display) >= 0);
        if (fds[1].revents & POLLIN) {
            char command; if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') break;
            switch (command) {
            case 'f': xdg_toplevel_set_fullscreen(top, NULL); break;
            case 'F': xdg_toplevel_unset_fullscreen(top); break;
            case 'x': xdg_toplevel_set_maximized(top); break;
            case 'X': xdg_toplevel_unset_maximized(top); break;
            case 'n': xdg_toplevel_set_minimized(top); break;
            case 'a': ack_only = !ack_only; break;
            case 'l': delay_ack = true; break;
            case 'L': delay_ack = false; acknowledge(); break;
            case 'r':
                wl_surface_attach(surface, NULL, 0, 0); wl_surface_commit(surface);
                mapped = false; states = 0;
                xdg_toplevel_set_app_id(top, argv[2]); xdg_toplevel_set_title(top, argv[2]);
                wl_surface_commit(surface); break;
            case 'd': draw(); break;
            case 'c':
                assert(foreign && capture_manager && !capture_source);
                capture_source = ext_foreign_toplevel_image_capture_source_manager_v1_create_source(capture_manager, foreign);
                break;
            case 'C':
                assert(capture_source && copy_manager && !capture_session);
                capture_session = ext_image_copy_capture_manager_v1_create_session(copy_manager, capture_source, 0);
                ext_image_copy_capture_session_v1_add_listener(capture_session, &capture_listener, NULL);
                break;
            case 'e':
                assert(capture_session); ext_image_copy_capture_session_v1_destroy(capture_session); capture_session = NULL; break;
            case 's': assert(wl_display_roundtrip(display) >= 0); break;
            default: abort();
            }
            printf("{\"event\":\"command\",\"value\":\"%c\"}\n", command);
        }
    }
    xdg_toplevel_destroy(top); xdg_surface_destroy(xdg); wl_surface_destroy(surface);
    xdg_wm_base_destroy(wm); wl_registry_destroy(registry); wl_shm_destroy(shm); wl_compositor_destroy(compositor);
    wl_display_flush(display); wl_display_disconnect(display);
    return 0;
}
