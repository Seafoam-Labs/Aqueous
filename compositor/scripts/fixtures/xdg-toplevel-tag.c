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
#include "xdg-toplevel-tag-client-protocol.h"
#include "security-context-client-protocol.h"
#include "aqueous-window-info-client-protocol.h"
#include "ext-foreign-toplevel-list-client-protocol.h"

static struct wp_security_context_manager_v1 *security;
static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct xdg_toplevel_tag_manager_v1 *manager;
static uint32_t manager_name, info_name, list_name;
static unsigned info_version, info_done, info_tags;
static struct aqueous_window_info_manager_v1 *info_manager;
// Bind each historical manager version and reject new events or enum values
// below version 8. This also checks that existing event opcodes still dispatch.
static int info_dispatch(const void *impl, void *object, uint32_t opcode,
                         const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)opcode;
    if (!strcmp(message->name, "tag") || !strcmp(message->name, "description")) {
        assert(info_version >= 8 && args[0].s); info_tags++;
    }
    if (!strcmp(message->name, "rule_matcher") && args[0].u == 4) assert(info_version >= 8);
    if (!strcmp(message->name, "done")) { info_done++; aqueous_window_info_v1_destroy(object); }
    return 0;
}
static int handle_dispatch(const void *impl, void *object, uint32_t opcode,
                           const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)opcode; (void)args;
    if (!strcmp(message->name, "done")) {
        struct aqueous_window_info_v1 *info = aqueous_window_info_manager_v1_get_window_info(info_manager, object);
        assert(wl_proxy_add_dispatcher((struct wl_proxy *)info, info_dispatch, NULL, NULL) == 0);
        ext_foreign_toplevel_handle_v1_destroy(object);
    }
    return 0;
}
static int list_dispatch(const void *impl, void *object, uint32_t opcode,
                         const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)object; (void)opcode;
    if (!strcmp(message->name, "toplevel"))
        assert(wl_proxy_add_dispatcher((struct wl_proxy *)args[0].o, handle_dispatch, NULL, NULL) == 0);
    return 0;
}
struct window { struct wl_surface *surface; struct xdg_surface *xdg; struct xdg_toplevel *top; int width, height; bool mapped; };
static struct window windows[16];
static void draw_release(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener draw_listener = { .release = draw_release };
static struct wl_buffer *make_buffer(int width, int height, uint32_t color, uint32_t format, uint32_t **mapping, size_t *length) {
    int fd = memfd_create("toplevel-tag-test", MFD_CLOEXEC);
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
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wp_security_context_manager_v1")) security = wl_registry_bind(registry, id, &wp_security_context_manager_v1_interface, 1);
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(interface, "aqueous_window_info_manager_v1")) info_name = id;
    if (!strcmp(interface, "ext_foreign_toplevel_list_v1")) list_name = id;
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) { wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm, &wm_listener, NULL); }
    if (!strcmp(interface, "xdg_toplevel_tag_manager_v1")) { manager = wl_registry_bind(registry, id, &xdg_toplevel_tag_manager_v1_interface, 1); manager_name = id; assert(version == 1); }
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
    char line[8192], op[32], name[128]; int a, b;
    while (true) {
        assert(wl_display_flush(display) >= 0);
        struct pollfd fds[] = { { .fd = STDIN_FILENO, .events = POLLIN }, { .fd = wl_display_get_fd(display), .events = POLLIN } };
        assert(poll(fds, 2, -1) >= 0);
        if (fds[1].revents && !dispatch_ok(wl_display_dispatch(display))) break;
        if (!(fds[0].revents & POLLIN)) continue;
        if (!fgets(line, sizeof(line), stdin)) break;
        a = b = 0; name[0] = 0;
        sscanf(line, "%31s %d %d", op, &a, &b);
        assert(a >= 0 && a < 32);
        if (!strcmp(op, "sandbox")) {
            assert(security);
            int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0), lifetime[2];
            assert(fd >= 0 && socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, lifetime) == 0);
            struct sockaddr_un address = {.sun_family = AF_UNIX};
            int len = snprintf(address.sun_path, sizeof(address.sun_path), "%s/tag-sandbox", getenv("XDG_RUNTIME_DIR"));
            assert(len > 0 && (size_t)len < sizeof(address.sun_path));
            assert(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 8) == 0);
            struct wp_security_context_v1 *context = wp_security_context_manager_v1_create_listener(security, fd, lifetime[0]);
            wp_security_context_v1_set_sandbox_engine(context, "aqueous-test");
            wp_security_context_v1_set_app_id(context, "tag-test");
            wp_security_context_v1_commit(context); wp_security_context_v1_destroy(context);
            close(fd); close(lifetime[0]);
        }
        else if (!strcmp(op, "window")) {
            assert(a < 16); struct window *w = &windows[a]; w->width = 300; w->height = 220;
            w->surface = wl_compositor_create_surface(compositor); w->xdg = xdg_wm_base_get_xdg_surface(wm, w->surface);
            xdg_surface_add_listener(w->xdg, &surface_listener, w); w->top = xdg_surface_get_toplevel(w->xdg);
            xdg_toplevel_add_listener(w->top, &top_listener, w); xdg_toplevel_set_app_id(w->top, "aqueous-tag-test");
            snprintf(name, sizeof(name), "tag-window-%d", a); xdg_toplevel_set_title(w->top, name);
            if (b) {
                xdg_toplevel_tag_manager_v1_set_toplevel_tag(manager, w->top, "settings");
                xdg_toplevel_tag_manager_v1_set_toplevel_description(manager, w->top, "Paramètres");
            }
            // Keep creation separate from commit to exercise pre-map requests.
        } else if (!strcmp(op, "tag") || !strcmp(op, "description")) {
            int offset = 0;
            sscanf(line, "%*s %*d %n", &offset);
            char *value = line + offset;
            value[strcspn(value, "\n")] = 0;
            if (!strcmp(op, "tag")) xdg_toplevel_tag_manager_v1_set_toplevel_tag(manager, windows[a].top, value);
            else xdg_toplevel_tag_manager_v1_set_toplevel_description(manager, windows[a].top, value);
        }
        else if (!strcmp(op, "commit")) wl_surface_commit(windows[a].surface);
        else if (!strcmp(op, "unmap")) { wl_surface_attach(windows[a].surface, NULL, 0, 0); wl_surface_commit(windows[a].surface); windows[a].mapped = false; }
        else if (!strcmp(op, "remap")) { xdg_toplevel_set_app_id(windows[a].top, "aqueous-tag-test"); snprintf(name, sizeof(name), "tag-window-%d", a); xdg_toplevel_set_title(windows[a].top, name); wl_surface_commit(windows[a].surface); }
        else if (!strcmp(op, "destroy-window")) { xdg_toplevel_destroy(windows[a].top); xdg_surface_destroy(windows[a].xdg); wl_surface_destroy(windows[a].surface); }
        else if (!strcmp(op, "destroy-manager")) { xdg_toplevel_tag_manager_v1_destroy(manager); manager = NULL; }
        else if (!strcmp(op, "bind-manager")) { assert(!manager); manager = wl_registry_bind(registry, manager_name, &xdg_toplevel_tag_manager_v1_interface, 1); }
        else if (!strcmp(op, "inspect")) {
            assert(info_name && list_name && a > 0 && a <= 8);
            info_version = a; info_done = info_tags = 0;
            info_manager = wl_registry_bind(registry, info_name, &aqueous_window_info_manager_v1_interface, a);
            struct ext_foreign_toplevel_list_v1 *list = wl_registry_bind(registry, list_name, &ext_foreign_toplevel_list_v1_interface, 1);
            assert(wl_proxy_add_dispatcher((struct wl_proxy *)list, list_dispatch, NULL, NULL) == 0);
            assert(wl_display_roundtrip(display) >= 0);
            assert(wl_display_roundtrip(display) >= 0);
            assert(info_done > 0 && (a < 8 ? info_tags == 0 : info_tags > 0));
            ext_foreign_toplevel_list_v1_destroy(list);
            aqueous_window_info_manager_v1_destroy(info_manager);
        }
        else if (!strcmp(op, "quit")) break;
        else assert(!"unknown command");
        if (!dispatch_ok(wl_display_roundtrip(display))) break;
        printf("{\"command\":\"%s\"}\n", op);
    }
    wl_display_disconnect(display);
    return 0;
}
