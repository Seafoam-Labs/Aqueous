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
#include "xdg-dialog-client-protocol.h"
#include "security-context-client-protocol.h"
#include "aqueous-input-client-protocol.h"
#include "layer-shell-client-protocol.h"
#include "xdg-activation-client-protocol.h"
#include "virtual-pointer-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct xdg_wm_dialog_v1 *manager;
static struct zwlr_virtual_pointer_v1 *pointer;
static const char *label;
static struct wp_security_context_manager_v1 *security;
static struct aqueous_input_manager_v1 *input_manager;
static struct zwlr_layer_shell_v1 *layer_manager;
static struct zwlr_layer_surface_v1 *layer;
static struct xdg_activation_v1 *activation;
struct window {
    struct wl_surface *surface;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    struct xdg_dialog_v1 *dialog;
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
static struct window overlay;
static void layer_configured(void *data, struct zwlr_layer_surface_v1 *object, uint32_t serial, uint32_t width, uint32_t height) {
    (void)data; zwlr_layer_surface_v1_ack_configure(object, serial);
    overlay.width = (int)width; overlay.height = (int)height; draw(&overlay);
}
static void layer_closed(void *data, struct zwlr_layer_surface_v1 *object) { (void)data; (void)object; }
static const struct zwlr_layer_surface_v1_listener layer_listener = {.configure = layer_configured, .closed = layer_closed};
static void input_finished(void *data, struct aqueous_input_manager_v1 *object) { (void)data; aqueous_input_manager_v1_destroy(object); }
static void input_device(void *data, struct aqueous_input_manager_v1 *object, struct aqueous_input_device_v1 *device) {
    (void)data; (void)object; aqueous_input_device_v1_destroy(device);
}
static const struct aqueous_input_manager_v1_listener input_listener = {.finished = input_finished, .input_device = input_device};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, version < 7 ? version : 7);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    } else if (!strcmp(interface, "xdg_wm_dialog_v1")) {
        manager = wl_registry_bind(registry, name, &xdg_wm_dialog_v1_interface, 1);
        printf("{\"event\":\"global\",\"version\":%u}\n", version);
    } else if (!strcmp(interface, "aqueous_input_manager_v1")) {
        input_manager = wl_registry_bind(registry, name, &aqueous_input_manager_v1_interface, 1);
        aqueous_input_manager_v1_add_listener(input_manager, &input_listener, NULL);
    } else if (!strcmp(interface, "zwlr_layer_shell_v1")) {
        layer_manager = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, 4);
    } else if (!strcmp(interface, "xdg_activation_v1")) {
        activation = wl_registry_bind(registry, name, &xdg_activation_v1_interface, 1);
    } else if (!strcmp(interface, "wp_security_context_manager_v1")) {
        security = wl_registry_bind(registry, name, &wp_security_context_manager_v1_interface, 1);
    } else if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1")) {
        struct zwlr_virtual_pointer_manager_v1 *pm = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
        pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pm, NULL);
        zwlr_virtual_pointer_manager_v1_destroy(pm);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) { (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
static void create(int id, int parent, int mode) {
    struct window *w = &windows[id]; assert(!w->surface);
    *w = (struct window){.id = id, .width = id ? 240 : 640, .height = id ? 180 : 480};
    w->surface = wl_compositor_create_surface(compositor);
    w->xdg = xdg_wm_base_get_xdg_surface(wm, w->surface);
    xdg_surface_add_listener(w->xdg, &surface_listener, w);
    w->top = xdg_surface_get_toplevel(w->xdg);
    xdg_toplevel_add_listener(w->top, &top_listener, w);
    char name[128]; snprintf(name, sizeof(name), "%s-%d", label, id);
    xdg_toplevel_set_app_id(w->top, name); xdg_toplevel_set_title(w->top, name);
    if (parent >= 0) xdg_toplevel_set_parent(w->top, windows[parent].top);
    if (mode) {
        w->dialog = xdg_wm_dialog_v1_get_xdg_dialog(manager, w->top);
        if (mode == 2) xdg_dialog_v1_set_modal(w->dialog);
    }
    wl_surface_commit(w->surface);
}
static bool command(char *line) {
    char op[32]; int id = 0, value = 0, mode = 0;
    int fields = sscanf(line, "%31s %d %d %d", op, &id, &value, &mode);
    assert(fields >= 1 && id >= 0);
    assert(!strcmp(op, "click") || id < 16);
    struct window *w = &windows[id < 16 ? id : 0];
    if (!strcmp(op, "quit")) return false;
    if (!strcmp(op, "create")) { assert(fields == 4); create(id, value, mode); }
    else if (!strcmp(op, "sandbox")) {
        assert(security);
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0), lifetime[2];
        assert(fd >= 0 && socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, lifetime) == 0);
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        int len = snprintf(address.sun_path, sizeof(address.sun_path), "%s/dialog-sandbox", getenv("XDG_RUNTIME_DIR"));
        assert(len > 0 && (size_t)len < sizeof(address.sun_path));
        assert(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 8) == 0);
        struct wp_security_context_v1 *context = wp_security_context_manager_v1_create_listener(security, fd, lifetime[0]);
        wp_security_context_v1_set_sandbox_engine(context, "aqueous-test");
        wp_security_context_v1_set_app_id(context, "dialog-test");
        wp_security_context_v1_commit(context); wp_security_context_v1_destroy(context);
        close(fd); close(lifetime[0]); // Keep lifetime[1] open until process exit.
    }
    else if (!strcmp(op, "create-seat")) aqueous_input_manager_v1_create_seat(input_manager, "dialog-seat");
    else if (!strcmp(op, "destroy-seat")) aqueous_input_manager_v1_destroy_seat(input_manager, "dialog-seat");
    else if (!strcmp(op, "activate-bogus")) xdg_activation_v1_activate(activation, "invalid-dialog-token", w->surface);
    else if (!strcmp(op, "layer")) {
        assert(!layer);
        overlay = (struct window){.id = 14, .surface = wl_compositor_create_surface(compositor)};
        layer = zwlr_layer_shell_v1_get_layer_surface(layer_manager, overlay.surface, NULL, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "dialog-test");
        zwlr_layer_surface_v1_add_listener(layer, &layer_listener, NULL);
        zwlr_layer_surface_v1_set_size(layer, 120, 90);
        zwlr_layer_surface_v1_set_keyboard_interactivity(layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
        wl_surface_commit(overlay.surface);
    } else if (!strcmp(op, "destroy-layer")) {
        zwlr_layer_surface_v1_destroy(layer); wl_surface_destroy(overlay.surface); layer = NULL;
    }
    else if (!strcmp(op, "dialog")) { assert(!w->dialog); w->dialog = xdg_wm_dialog_v1_get_xdg_dialog(manager, w->top); }
    else if (!strcmp(op, "duplicate")) (void)xdg_wm_dialog_v1_get_xdg_dialog(manager, w->top);
    else if (!strcmp(op, "modal")) { if (value) xdg_dialog_v1_set_modal(w->dialog); else xdg_dialog_v1_unset_modal(w->dialog); }
    else if (!strcmp(op, "parent")) xdg_toplevel_set_parent(w->top, value < 0 ? NULL : windows[value].top);
    else if (!strcmp(op, "destroy-dialog")) { xdg_dialog_v1_destroy(w->dialog); w->dialog = NULL; }
    else if (!strcmp(op, "destroy-manager")) { xdg_wm_dialog_v1_destroy(manager); manager = NULL; }
    else if (!strcmp(op, "destroy-top")) {
        xdg_toplevel_destroy(w->top); xdg_surface_destroy(w->xdg); wl_surface_destroy(w->surface);
        w->surface = NULL; w->top = NULL; w->xdg = NULL;
    } else if (!strcmp(op, "fullscreen")) { if (value) xdg_toplevel_set_fullscreen(w->top, NULL); else xdg_toplevel_unset_fullscreen(w->top); }
    else if (!strcmp(op, "minimize")) xdg_toplevel_set_minimized(w->top);
    else if (!strcmp(op, "delay")) { w->delay = value; if (!value) acknowledge(w); }
    else if (!strcmp(op, "remap")) {
        wl_surface_attach(w->surface, NULL, 0, 0); wl_surface_commit(w->surface); w->mapped = false;
        char name[128]; snprintf(name, sizeof(name), "%s-%d", label, id);
        xdg_toplevel_set_app_id(w->top, name); xdg_toplevel_set_title(w->top, name);
        // xdg_toplevel state resets on unmap; explicitly restore the parent.
        if (value >= 0) xdg_toplevel_set_parent(w->top, windows[value].top);
        wl_surface_commit(w->surface);
    } else if (!strcmp(op, "click")) {
        // id/value are normalized coordinates in a 1280x720 headless output.
        assert(pointer);
        zwlr_virtual_pointer_v1_motion_absolute(pointer, 1, (uint32_t)id, (uint32_t)value, 1280, 720);
        zwlr_virtual_pointer_v1_button(pointer, 2, 0x110, WL_POINTER_BUTTON_STATE_PRESSED);
        zwlr_virtual_pointer_v1_button(pointer, 3, 0x110, WL_POINTER_BUTTON_STATE_RELEASED);
        zwlr_virtual_pointer_v1_frame(pointer);
    } else abort();
    return true;
}
int main(int argc, char **argv) {
    assert(argc == 2); label = argv[1]; setvbuf(stdout, NULL, _IOLBF, 0);
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && compositor && shm && wm && manager);
    puts("{\"event\":\"ready\"}");
    for (;;) {
        while (wl_display_prepare_read(display) != 0) if (wl_display_dispatch_pending(display) < 0) goto error;
        if (wl_display_flush(display) < 0) { wl_display_cancel_read(display); goto error; }
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        assert(poll(fds, 2, -1) >= 0);
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) { if (wl_display_read_events(display) < 0) goto error; }
        else wl_display_cancel_read(display);
        if (wl_display_dispatch_pending(display) < 0) goto error;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char line[128]; if (!fgets(line, sizeof(line), stdin) || !command(line)) break;
            if (wl_display_roundtrip(display) < 0) goto error;
            printf("{\"event\":\"command\",\"value\":\"%.*s\"}\n", (int)strcspn(line, "\n"), line);
        }
    }
    wl_display_disconnect(display); return 0;
error: {
    const struct wl_interface *interface = NULL; uint32_t id;
    uint32_t code = wl_display_get_protocol_error(display, &interface, &id);
    printf("{\"event\":\"error\",\"interface\":\"%s\",\"code\":%u}\n", interface ? interface->name : "", code);
    wl_display_disconnect(display); return 2;
}
}
