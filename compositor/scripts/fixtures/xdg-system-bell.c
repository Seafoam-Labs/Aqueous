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
#include "security-context-client-protocol.h"
#include "xdg-system-bell-client-protocol.h"
#include "session-lock-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_subcompositor *subcompositor;
static struct xdg_wm_base *wm;
static const char *label;
static struct wp_security_context_manager_v1 *security;
struct window {
    struct wl_surface *surface;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    int id, width, height;
    bool delay, mapped;
    uint32_t serial, states;
};
static struct window windows[16];
static void release(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener buffer_listener = {.release = release};
static void draw(struct window *w) {
    int fd = memfd_create("xdg-dialog", MFD_CLOEXEC);
    size_t size = (size_t)w->width * w->height * 4;
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    // Primary colors make scene-layer assertions independent of color transforms.
    const uint32_t colors[] = {0xff0000, 0x00ff00, 0x0000ff, 0xffff00};
    for (size_t i = 0; i < size / 4; i++) pixels[i] = colors[w->id % 4];
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w->width, w->height, w->width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_surface_attach(w->surface, buffer, 0, 0);
    wl_surface_damage(w->surface, 0, 0, w->width, w->height);
    wl_surface_commit(w->surface);
    wl_shm_pool_destroy(pool); munmap(pixels, size); close(fd);
    w->mapped = true;
}
static void acknowledge(struct window *w) {
    xdg_surface_ack_configure(w->xdg, w->serial);
    draw(w);
}
static void configured(void *data, struct xdg_surface *surface, uint32_t serial) {
    (void)surface; struct window *w = data; w->serial = serial;
    printf("{\"event\":\"configure\",\"id\":%d,\"states\":%u,\"width\":%d,\"height\":%d}\n", w->id, w->states, w->width, w->height);
    if (!w->delay) acknowledge(w);
}
static const struct xdg_surface_listener surface_listener = {.configure = configured};
static void top_configured(void *data, struct xdg_toplevel *top, int32_t width, int32_t height, struct wl_array *states) {
    (void)top; struct window *w = data;
    if (width > 0) w->width = width;
    if (height > 0) w->height = height;
    w->states = 0; uint32_t *state;
    wl_array_for_each(state, states) if (*state < 32) w->states |= 1u << *state;
}
static void closed(void *data, struct xdg_toplevel *top) { (void)data; (void)top; }
static void bounds(void *data, struct xdg_toplevel *top, int32_t w, int32_t h) { (void)data; (void)top; (void)w; (void)h; }
static void capabilities(void *data, struct xdg_toplevel *top, struct wl_array *caps) { (void)data; (void)top; (void)caps; }
static const struct xdg_toplevel_listener top_listener = {.configure = top_configured, .close = closed, .configure_bounds = bounds, .wm_capabilities = capabilities};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) { (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static struct wl_registry *registry;
static uint32_t bell_name;
static struct xdg_system_bell_v1 *bells[2];
static struct ext_session_lock_manager_v1 *locks;
static struct ext_session_lock_v1 *lock;
static void locked(void *data, struct ext_session_lock_v1 *object) {
    (void)data; (void)object; puts("{\"event\":\"locked\"}");
}
static void lock_finished(void *data, struct ext_session_lock_v1 *object) { (void)data; (void)object; }
static const struct ext_session_lock_v1_listener lock_listener = {.locked = locked, .finished = lock_finished};
static void global(void *data, struct wl_registry *reg, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_subcompositor")) subcompositor = wl_registry_bind(reg, name, &wl_subcompositor_interface, 1);
    else if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(reg, name, &xdg_wm_base_interface, version < 7 ? version : 7);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    } else if (!strcmp(interface, "xdg_system_bell_v1")) {
        bell_name = name;
        for (int i = 0; i < 2; ++i) bells[i] = wl_registry_bind(reg, name, &xdg_system_bell_v1_interface, 1);
        printf("{\"event\":\"global\",\"version\":%u}\n", version);
    } else if (!strcmp(interface, "wp_security_context_manager_v1")) {
        security = wl_registry_bind(reg, name, &wp_security_context_manager_v1_interface, 1);
    } else if (!strcmp(interface, "ext_session_lock_manager_v1")) {
        locks = wl_registry_bind(reg, name, &ext_session_lock_manager_v1_interface, 1);
    }
}
static void removed(void *data, struct wl_registry *reg, uint32_t name) { (void)data; (void)reg; (void)name; }
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
static void create(int id, bool commit) {
    struct window *w = &windows[id]; assert(!w->surface);
    *w = (struct window){.id = id, .width = 320, .height = 240};
    w->surface = wl_compositor_create_surface(compositor);
    w->xdg = xdg_wm_base_get_xdg_surface(wm, w->surface);
    xdg_surface_add_listener(w->xdg, &surface_listener, w);
    w->top = xdg_surface_get_toplevel(w->xdg);
    xdg_toplevel_add_listener(w->top, &top_listener, w);
    char name[128]; snprintf(name, sizeof(name), "%s-%d", label, id);
    xdg_toplevel_set_app_id(w->top, name); xdg_toplevel_set_title(w->top, name);
    if (commit) wl_surface_commit(w->surface);
}
static void destroy_window(struct window *w) {
    if (w->top) xdg_toplevel_destroy(w->top);
    if (w->xdg) xdg_surface_destroy(w->xdg);
    if (w->surface) wl_surface_destroy(w->surface);
    *w = (struct window){0};
}
static bool command(char *line) {
    char op[32]; int id = 0, count = 1;
    if (sscanf(line, "%31s %d %d", op, &id, &count) < 1) return true;
    assert(id >= 0 && id < 16);
    struct window *w = &windows[id];
    if (!strcmp(op, "quit")) return false;
    else if (!strcmp(op, "create")) create(id, true);
    else if (!strcmp(op, "premap")) create(id, false);
    else if (!strcmp(op, "map")) wl_surface_commit(w->surface);
    else if (!strcmp(op, "unmap")) { w->delay = true; wl_surface_attach(w->surface, NULL, 0, 0); wl_surface_commit(w->surface); }
    else if (!strcmp(op, "destroy")) destroy_window(w);
    else if (!strcmp(op, "ring")) for (int i = 0; i < count; ++i) xdg_system_bell_v1_ring(bells[i % 2], w->surface);
    else if (!strcmp(op, "null")) xdg_system_bell_v1_ring(bells[0], NULL);
    else if (!strcmp(op, "roleless")) {
        struct wl_surface *surface = wl_compositor_create_surface(compositor);
        xdg_system_bell_v1_ring(bells[0], surface); wl_surface_destroy(surface);
    } else if (!strcmp(op, "subsurface")) {
        struct wl_surface *surface = wl_compositor_create_surface(compositor);
        struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, surface, w->surface);
        xdg_system_bell_v1_ring(bells[0], surface);
        wl_subsurface_destroy(sub); wl_surface_destroy(surface);
    } else if (!strcmp(op, "popup")) {
        struct wl_surface *surface = wl_compositor_create_surface(compositor);
        struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
        struct xdg_positioner *positioner = xdg_wm_base_create_positioner(wm);
        xdg_positioner_set_size(positioner, 50, 50);
        xdg_positioner_set_anchor_rect(positioner, 0, 0, 1, 1);
        struct xdg_popup *popup = xdg_surface_get_popup(xdg, w->xdg, positioner);
        xdg_system_bell_v1_ring(bells[0], surface);
        xdg_popup_destroy(popup); xdg_positioner_destroy(positioner);
        xdg_surface_destroy(xdg); wl_surface_destroy(surface);
    } else if (!strcmp(op, "rebind")) {
        for (int i = 0; i < 2; ++i) {
            xdg_system_bell_v1_destroy(bells[i]);
            bells[i] = wl_registry_bind(registry, bell_name, &xdg_system_bell_v1_interface, 1);
        }
    } else if (!strcmp(op, "fullscreen")) xdg_toplevel_set_fullscreen(w->top, NULL);
    else if (!strcmp(op, "lock")) {
        assert(locks && !lock); lock = ext_session_lock_manager_v1_lock(locks);
        ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    } else if (!strcmp(op, "unlock")) { ext_session_lock_v1_unlock_and_destroy(lock); lock = NULL; }
    else if (!strcmp(op, "sandbox")) {
        assert(security);
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0), lifetime[2];
        assert(fd >= 0 && socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, lifetime) == 0);
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        int n = snprintf(address.sun_path, sizeof(address.sun_path), "%s/bell-sandbox", getenv("XDG_RUNTIME_DIR"));
        assert(n > 0 && (size_t)n < sizeof(address.sun_path));
        assert(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 8) == 0);
        struct wp_security_context_v1 *context = wp_security_context_manager_v1_create_listener(security, fd, lifetime[0]);
        wp_security_context_v1_set_sandbox_engine(context, "aqueous-test");
        wp_security_context_v1_set_app_id(context, "bell-test");
        wp_security_context_v1_commit(context); wp_security_context_v1_destroy(context);
        close(fd); close(lifetime[0]);
    } else assert(!"unknown command");
    assert(wl_display_roundtrip(display) >= 0);
    puts("{\"event\":\"command\"}");
    return true;
}
int main(int argc, char **argv) {
    setbuf(stdout, NULL); setbuf(stdin, NULL);
    label = argc > 1 ? argv[1] : "bell";
    display = wl_display_connect(NULL); assert(display);
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && bells[0] && compositor && shm && wm);
    puts("{\"event\":\"ready\"}");
    for (;;) {
        assert(wl_display_dispatch_pending(display) >= 0); wl_display_flush(display);
        struct pollfd fds[] = {{.fd = 0, .events = POLLIN}, {.fd = wl_display_get_fd(display), .events = POLLIN}};
        assert(poll(fds, 2, -1) >= 0);
        if (fds[1].revents) assert(wl_display_dispatch(display) >= 0);
        if (fds[0].revents & (POLLIN | POLLHUP)) {
            char line[256]; if (!fgets(line, sizeof(line), stdin) || !command(line)) break;
        }
    }
    for (int i = 0; i < 16; ++i) destroy_window(&windows[i]);
    for (int i = 0; i < 2; ++i) xdg_system_bell_v1_destroy(bells[i]);
    wl_display_roundtrip(display); wl_display_disconnect(display); return 0;
}
