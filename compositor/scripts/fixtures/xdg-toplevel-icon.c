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
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-toplevel-icon-client-protocol.h"
#include "single-pixel-buffer-client-protocol.h"
#include "security-context-client-protocol.h"

static struct wp_security_context_manager_v1 *security;
static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct xdg_toplevel_icon_manager_v1 *manager;
static struct wp_single_pixel_buffer_manager_v1 *single;
static struct xdg_toplevel_icon_v1 *icons[32];
static struct wl_buffer *buffers[32];
static uint32_t *maps[32];
static size_t lengths[32];
struct window { struct wl_surface *surface; struct xdg_surface *xdg; struct xdg_toplevel *top; int width, height; bool mapped; };
static struct window windows[16];
static unsigned releases;
static void release(void *data, struct wl_buffer *buffer) { (void)data; (void)buffer; releases++; }
static void draw_release(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener buffer_listener = { .release = release };
static const struct wl_buffer_listener draw_listener = { .release = draw_release };
static struct wl_buffer *make_buffer(int width, int height, uint32_t color, uint32_t format, uint32_t **mapping, size_t *length) {
    int fd = memfd_create("toplevel-icon-test", MFD_CLOEXEC);
    int stride = width * 4 + 16;
    *length = (size_t)stride * height;
    assert(fd >= 0 && ftruncate(fd, *length) == 0);
    *mapping = mmap(NULL, *length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(*mapping != MAP_FAILED);
    for (size_t i = 0; i < *length / 4; i++) (*mapping)[i] = color;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, *length);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, format);
    wl_shm_pool_destroy(pool); close(fd);
    return buffer;
}
static void draw(struct window *w) {
    uint32_t *pixels; size_t len;
    struct wl_buffer *buffer = make_buffer(w->width, w->height, 0xff202020, WL_SHM_FORMAT_XRGB8888, &pixels, &len);
    wl_buffer_add_listener(buffer, &draw_listener, NULL);
    wl_surface_attach(w->surface, buffer, 0, 0);
    wl_surface_damage(w->surface, 0, 0, w->width, w->height);
    wl_surface_commit(w->surface);
    munmap(pixels, len);
    w->mapped = true;
}
static void configured(void *data, struct xdg_surface *xdg, uint32_t serial) {
    struct window *w = data; xdg_surface_ack_configure(xdg, serial); draw(w);
}
static const struct xdg_surface_listener surface_listener = { .configure = configured };
static void top_configure(void *data, struct xdg_toplevel *top, int32_t width, int32_t height, struct wl_array *states) {
    (void)top; (void)states; struct window *w = data;
    if (width > 0) w->width = width;
    if (height > 0) w->height = height;
}
static void closed(void *data, struct xdg_toplevel *top) { (void)data; (void)top; }
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = closed };
static void ping(void *data, struct xdg_wm_base *object, uint32_t serial) { (void)data; xdg_wm_base_pong(object, serial); }
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void size_event(void *data, struct xdg_toplevel_icon_manager_v1 *object, int32_t size) {
    (void)data; (void)object; printf("{\"size\":%d}\n", size);
}
static void done_event(void *data, struct xdg_toplevel_icon_manager_v1 *object) { (void)data; (void)object; puts("{\"done\":true}"); }
static const struct xdg_toplevel_icon_manager_v1_listener manager_listener = { .icon_size = size_event, .done = done_event };
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wp_security_context_manager_v1")) security = wl_registry_bind(registry, id, &wp_security_context_manager_v1_interface, 1);
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) { wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm, &wm_listener, NULL); }
    if (!strcmp(interface, "wp_single_pixel_buffer_manager_v1")) single = wl_registry_bind(registry, id, &wp_single_pixel_buffer_manager_v1_interface, 1);
    if (!strcmp(interface, "xdg_toplevel_icon_manager_v1")) { manager = wl_registry_bind(registry, id, &xdg_toplevel_icon_manager_v1_interface, 1); xdg_toplevel_icon_manager_v1_add_listener(manager, &manager_listener, NULL); }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) { (void)data; (void)registry; (void)id; }
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };
static bool dispatch_ok(int rc) {
    if (rc >= 0) return true;
    const struct wl_interface *interface; uint32_t id;
    uint32_t code = wl_display_get_protocol_error(display, &interface, &id);
    printf("{\"error\":%u,\"interface\":\"%s\"}\n", code, interface ? interface->name : "unknown");
    return false;
}
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && manager && compositor && shm && wm);
    assert(wl_display_roundtrip(display) >= 0); puts("{\"ready\":true}");
    char line[256], op[32], name[128]; unsigned color; int a, b, d, e;
    while (true) {
        assert(wl_display_flush(display) >= 0);
        struct pollfd fds[] = { { .fd = STDIN_FILENO, .events = POLLIN }, { .fd = wl_display_get_fd(display), .events = POLLIN } };
        assert(poll(fds, 2, -1) >= 0);
        if (fds[1].revents && !dispatch_ok(wl_display_dispatch(display))) break;
        if (!(fds[0].revents & POLLIN)) continue;
        if (!fgets(line, sizeof(line), stdin)) break;
        a = b = d = e = 0; name[0] = 0; color = 0;
        sscanf(line, "%31s %d %d %d %d", op, &a, &b, &d, &e);
        assert(a >= 0 && a < 32);
        if (!strcmp(op, "sandbox")) {
            assert(security);
            int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0), lifetime[2];
            assert(fd >= 0 && socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, lifetime) == 0);
            struct sockaddr_un address = {.sun_family = AF_UNIX};
            int len = snprintf(address.sun_path, sizeof(address.sun_path), "%s/icon-sandbox", getenv("XDG_RUNTIME_DIR"));
            assert(len > 0 && (size_t)len < sizeof(address.sun_path));
            assert(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 8) == 0);
            struct wp_security_context_v1 *context = wp_security_context_manager_v1_create_listener(security, fd, lifetime[0]);
            wp_security_context_v1_set_sandbox_engine(context, "aqueous-test");
            wp_security_context_v1_set_app_id(context, "icon-test");
            wp_security_context_v1_commit(context); wp_security_context_v1_destroy(context);
            close(fd); close(lifetime[0]);
        }
        else if (!strcmp(op, "icon")) { icons[a] = xdg_toplevel_icon_manager_v1_create_icon(manager); }
        else if (!strcmp(op, "name")) { sscanf(line, "%*s %d %127s", &a, name); xdg_toplevel_icon_v1_set_name(icons[a], name); }
        else if (!strcmp(op, "buffer")) {
            sscanf(line, "%*s %d %d %d %x %d", &a, &b, &d, &color, &e);
            buffers[a] = make_buffer(b, d, color, e, &maps[a], &lengths[a]); wl_buffer_add_listener(buffers[a], &buffer_listener, NULL);
        } else if (!strcmp(op, "nonshm")) { assert(single); buffers[a] = wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(single, 0, 0, 0, UINT32_MAX); }
        else if (!strcmp(op, "add")) xdg_toplevel_icon_v1_add_buffer(icons[a], buffers[b], d);
        else if (!strcmp(op, "window")) {
            assert(a < 16); struct window *w = &windows[a]; w->width = 300; w->height = 220;
            w->surface = wl_compositor_create_surface(compositor); w->xdg = xdg_wm_base_get_xdg_surface(wm, w->surface);
            xdg_surface_add_listener(w->xdg, &surface_listener, w); w->top = xdg_surface_get_toplevel(w->xdg);
            xdg_toplevel_add_listener(w->top, &top_listener, w); xdg_toplevel_set_app_id(w->top, "aqueous-icon-test");
            snprintf(name, sizeof(name), "icon-window-%d", a); xdg_toplevel_set_title(w->top, name);
            if (b >= 0) xdg_toplevel_icon_manager_v1_set_icon(manager, w->top, icons[b]);
            if (d) wl_surface_commit(w->surface);
        } else if (!strcmp(op, "set")) xdg_toplevel_icon_manager_v1_set_icon(manager, windows[a].top, b < 0 ? NULL : icons[b]);
        else if (!strcmp(op, "commit")) wl_surface_commit(windows[a].surface);
        else if (!strcmp(op, "unmap")) { wl_surface_attach(windows[a].surface, NULL, 0, 0); wl_surface_commit(windows[a].surface); windows[a].mapped = false; }
        else if (!strcmp(op, "remap")) { xdg_toplevel_set_app_id(windows[a].top, "aqueous-icon-test"); snprintf(name, sizeof(name), "icon-window-%d", a); xdg_toplevel_set_title(windows[a].top, name); wl_surface_commit(windows[a].surface); }
        else if (!strcmp(op, "destroy-window")) { xdg_toplevel_destroy(windows[a].top); xdg_surface_destroy(windows[a].xdg); wl_surface_destroy(windows[a].surface); }
        else if (!strcmp(op, "destroy-icon")) { xdg_toplevel_icon_v1_destroy(icons[a]); icons[a] = NULL; }
        else if (!strcmp(op, "destroy-buffer")) { wl_buffer_destroy(buffers[a]); buffers[a] = NULL; }
        else if (!strcmp(op, "overwrite")) { for (size_t i = 0; i < lengths[a] / 4; i++) maps[a][i] = 0xff000000; }
        else if (!strcmp(op, "destroy-manager")) { xdg_toplevel_icon_manager_v1_destroy(manager); manager = NULL; }
        else if (!strcmp(op, "quit")) break;
        else assert(!"unknown command");
        if (!dispatch_ok(wl_display_roundtrip(display))) break;
        printf("{\"command\":\"%s\",\"releases\":%u}\n", op, releases);
    }
    wl_display_disconnect(display);
    return 0;
}
