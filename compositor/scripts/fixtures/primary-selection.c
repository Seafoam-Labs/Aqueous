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
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-dialog-client-protocol.h"
#include "primary-selection-client-protocol.h"
#include "virtual-keyboard-client-protocol.h"
#include "virtual-pointer-client-protocol.h"
#include "layer-shell-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm;
static struct xdg_wm_dialog_v1 *dialogs;
static struct zwlr_layer_shell_v1 *layers;
static struct zwp_virtual_keyboard_manager_v1 *keyboards;
static struct zwlr_virtual_pointer_v1 *pointer;
static struct zwp_primary_selection_device_manager_v1 *primary;
static struct zwp_primary_selection_device_v1 *device;
static struct zwp_primary_selection_source_v1 *source;
static struct zwp_primary_selection_offer_v1 *offer;
static uint32_t input_serial;
static int paste_fd = -1;
static char content[64] = "first-selection";
static const char *label;
struct window {
    struct wl_surface *surface;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    struct xdg_dialog_v1 *dialog;
    struct zwlr_layer_surface_v1 *layer;
    int width, height;
};
static struct window windows[2];

static uint32_t timestamp(void) {
    struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (uint32_t)((uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000);
}
static void release(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener buffer_listener = {.release = release};
static void draw(struct window *w) {
    size_t size = (size_t)w->width * w->height * 4;
    int fd = memfd_create("primary-selection", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    for (size_t i = 0; i < size / 4; i++) pixels[i] = 0x336699;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w->width, w->height, w->width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_surface_attach(w->surface, buffer, 0, 0);
    wl_surface_damage(w->surface, 0, 0, w->width, w->height);
    wl_surface_commit(w->surface);
    wl_shm_pool_destroy(pool); munmap(pixels, size); close(fd);
}
static void configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    xdg_surface_ack_configure(xdg, serial); draw(data);
}
static const struct xdg_surface_listener surface_listener = {.configure = configure};
static void top_configure(void *data, struct xdg_toplevel *top, int32_t width, int32_t height, struct wl_array *states) {
    (void)top; (void)states; struct window *w = data;
    if (width > 0) w->width = width;
    if (height > 0) w->height = height;
}
static void top_close(void *data, struct xdg_toplevel *top) { (void)data; (void)top; }
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = top_close};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) { (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void layer_ready(void *data, struct wl_callback *callback, uint32_t time) {
    (void)data; (void)time; wl_callback_destroy(callback); puts("{\"event\":\"layer-ready\"}");
}
static const struct wl_callback_listener layer_frame_listener = {.done = layer_ready};
static void layer_configure(void *data, struct zwlr_layer_surface_v1 *layer, uint32_t serial, uint32_t width, uint32_t height) {
    struct window *w = data; w->width = width; w->height = height;
    wl_callback_add_listener(wl_surface_frame(w->surface), &layer_frame_listener, NULL);
    zwlr_layer_surface_v1_ack_configure(layer, serial); draw(w);
}
static void layer_close(void *data, struct zwlr_layer_surface_v1 *layer) { (void)data; (void)layer; }
static const struct zwlr_layer_surface_v1_listener layer_listener = {.configure = layer_configure, .closed = layer_close};
static void mime(void *data, struct zwp_primary_selection_offer_v1 *o, const char *type) { (void)data; (void)o; (void)type; }
static const struct zwp_primary_selection_offer_v1_listener offer_listener = {.offer = mime};
static void data_offer(void *data, struct zwp_primary_selection_device_v1 *dev, struct zwp_primary_selection_offer_v1 *o) {
    (void)data; (void)dev; zwp_primary_selection_offer_v1_add_listener(o, &offer_listener, NULL);
}
static void selection(void *data, struct zwp_primary_selection_device_v1 *dev, struct zwp_primary_selection_offer_v1 *o) {
    (void)data; (void)dev;
    if (offer) zwp_primary_selection_offer_v1_destroy(offer);
    offer = o;
    printf("{\"event\":\"selection\",\"available\":%d}\n", offer != NULL);
}
static const struct zwp_primary_selection_device_v1_listener device_listener = {.data_offer = data_offer, .selection = selection};
static void send_selection(void *data, struct zwp_primary_selection_source_v1 *s, const char *type, int32_t fd) {
    (void)data; (void)s; (void)type;
    assert(write(fd, content, strlen(content)) == (ssize_t)strlen(content)); close(fd);
}
static void cancelled(void *data, struct zwp_primary_selection_source_v1 *s) { (void)data; (void)s; }
static const struct zwp_primary_selection_source_v1_listener source_listener = {.send = send_selection, .cancelled = cancelled};
static int surface_id(struct wl_surface *surface) {
    for (int i = 0; i < 2; i++) if (windows[i].surface == surface) return i;
    return -1;
}
static void enter(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p; (void)serial; (void)x; (void)y;
    printf("{\"event\":\"enter\",\"id\":%d}\n", surface_id(surface));
}
static void leave(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *surface) {
    (void)data; (void)p; (void)serial; (void)surface;
}
static void motion(void *data, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p; (void)time; (void)x; (void)y;
}
static void button(void *data, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t b, uint32_t state) {
    (void)data; (void)p; (void)time; input_serial = serial;
    printf("{\"event\":\"button\",\"button\":%u,\"state\":%u,\"offer\":%d}\n", b, state, offer != NULL);
    // Request data during press dispatch, before any later keyboard/selection events.
    if (b == 274 && state == WL_POINTER_BUTTON_STATE_PRESSED && offer) {
        int fds[2]; assert(paste_fd < 0 && pipe(fds) == 0); paste_fd = fds[0];
        zwp_primary_selection_offer_v1_receive(offer, "text/plain", fds[1]); close(fds[1]);
    }
}
static void axis(void *data, struct wl_pointer *p, uint32_t time, uint32_t a, wl_fixed_t value) {
    (void)data; (void)p; (void)time; (void)a; (void)value;
}
static const struct wl_pointer_listener pointer_listener = {.enter = enter, .leave = leave, .motion = motion, .button = button, .axis = axis};
static int keyboard_event(const void *impl, void *object, uint32_t opcode, const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)object; (void)opcode;
    if (!strcmp(message->name, "keymap")) close(args[1].h);
    if (!strcmp(message->name, "enter")) printf("{\"event\":\"keyboard\",\"id\":%d}\n", surface_id((struct wl_surface *)args[1].o));
    return 0;
}
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "wl_seat") && !seat) seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) { wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm, &wm_listener, NULL); }
    else if (!strcmp(interface, "xdg_wm_dialog_v1")) dialogs = wl_registry_bind(r, name, &xdg_wm_dialog_v1_interface, 1);
    else if (!strcmp(interface, "zwlr_layer_shell_v1")) layers = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, 4);
    else if (!strcmp(interface, "zwp_primary_selection_device_manager_v1")) primary = wl_registry_bind(r, name, &zwp_primary_selection_device_manager_v1_interface, 1);
    else if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1")) keyboards = wl_registry_bind(r, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    else if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1")) {
        struct zwlr_virtual_pointer_manager_v1 *pm = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
        pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pm, NULL); zwlr_virtual_pointer_manager_v1_destroy(pm);
    }
}
static void removed(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
static void setup(void) {
    struct zwp_virtual_keyboard_v1 *vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboards, seat);
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS); assert(ctx);
    struct xkb_keymap *map = xkb_keymap_new_from_names(ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS); assert(map);
    char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1); assert(text);
    int fd = memfd_create("primary-keymap", MFD_CLOEXEC); assert(fd >= 0);
    size_t size = strlen(text) + 1; assert(write(fd, text, size) == (ssize_t)size);
    zwp_virtual_keyboard_v1_keymap(vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    close(fd); free(text); xkb_keymap_unref(map); xkb_context_unref(ctx);
    struct wl_keyboard *keyboard = wl_seat_get_keyboard(seat);
    wl_proxy_add_dispatcher((struct wl_proxy *)keyboard, keyboard_event, NULL, NULL);
    wl_pointer_add_listener(wl_seat_get_pointer(seat), &pointer_listener, NULL);
    device = zwp_primary_selection_device_manager_v1_get_device(primary, seat);
    zwp_primary_selection_device_v1_add_listener(device, &device_listener, NULL);
}
static bool command(char *line) {
    char op[32]; int a = 0, b = 0;
    assert(sscanf(line, "%31s %d %d", op, &a, &b) >= 1);
    if (!strcmp(op, "quit")) return false;
    if (!strcmp(op, "create") || !strcmp(op, "layer")) {
        assert(a >= 0 && a < 2); struct window *w = &windows[a]; assert(!w->surface);
        *w = (struct window){.width = 320, .height = 240}; w->surface = wl_compositor_create_surface(compositor);
        if (!strcmp(op, "layer")) {
            w->layer = zwlr_layer_shell_v1_get_layer_surface(layers, w->surface, NULL, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, label);
            zwlr_layer_surface_v1_add_listener(w->layer, &layer_listener, w);
            zwlr_layer_surface_v1_set_anchor(w->layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
            zwlr_layer_surface_v1_set_size(w->layer, 200, 100);
            zwlr_layer_surface_v1_set_keyboard_interactivity(w->layer, b);
        } else {
            w->xdg = xdg_wm_base_get_xdg_surface(wm, w->surface);
            xdg_surface_add_listener(w->xdg, &surface_listener, w);
            w->top = xdg_surface_get_toplevel(w->xdg); xdg_toplevel_add_listener(w->top, &top_listener, w);
            char app[100]; snprintf(app, sizeof(app), "%s-%d", label, a);
            xdg_toplevel_set_app_id(w->top, app); xdg_toplevel_set_title(w->top, app);
            if (a == 1) { xdg_toplevel_set_parent(w->top, windows[0].top); w->dialog = xdg_wm_dialog_v1_get_xdg_dialog(dialogs, w->top); xdg_dialog_v1_set_modal(w->dialog); }
        }
        wl_surface_commit(w->surface);
    } else if (!strcmp(op, "vanish") && !b) {
        assert(a >= 0 && a < 2);
        zwlr_virtual_pointer_v1_button(pointer, timestamp(), 274, 1);
        wl_surface_attach(windows[a].surface, NULL, 0, 0);
        wl_surface_commit(windows[a].surface);
        zwlr_virtual_pointer_v1_button(pointer, timestamp(), 274, 0);
        zwlr_virtual_pointer_v1_frame(pointer);
    } else if (!strcmp(op, "destroy") || !strcmp(op, "vanish")) {
        assert(a >= 0 && a < 2); struct window *w = &windows[a];
        if (!strcmp(op, "vanish")) zwlr_virtual_pointer_v1_button(pointer, timestamp(), 274, 1);
        if (w->dialog) xdg_dialog_v1_destroy(w->dialog);
        if (w->layer) zwlr_layer_surface_v1_destroy(w->layer);
        if (w->top) xdg_toplevel_destroy(w->top);
        if (w->xdg) xdg_surface_destroy(w->xdg);
        wl_surface_destroy(w->surface); *w = (struct window){0};
        if (!strcmp(op, "vanish")) {
            zwlr_virtual_pointer_v1_button(pointer, timestamp(), 274, 0);
            zwlr_virtual_pointer_v1_frame(pointer);
        }
    } else if (!strcmp(op, "primary")) {
        assert(sscanf(line, "%*s %63s", content) == 1);
        if (source) zwp_primary_selection_source_v1_destroy(source);
        source = zwp_primary_selection_device_manager_v1_create_source(primary);
        zwp_primary_selection_source_v1_add_listener(source, &source_listener, NULL);
        zwp_primary_selection_source_v1_offer(source, "text/plain");
        zwp_primary_selection_device_v1_set_selection(device, source, input_serial);
    } else if (!strcmp(op, "read-paste")) {
        char text[128] = {0}; int count = -1;
        if (paste_fd >= 0) {
            struct pollfd fd = {paste_fd, POLLIN, 0};
            if (poll(&fd, 1, 1000) > 0) count = read(paste_fd, text, sizeof(text) - 1);
            close(paste_fd); paste_fd = -1;
        }
        printf("{\"event\":\"paste\",\"bytes\":%d,\"text\":\"%s\"}\n", count, text);
    } else if (!strcmp(op, "move")) {
        zwlr_virtual_pointer_v1_motion_absolute(pointer, timestamp(), a, b, 1280, 720);
        zwlr_virtual_pointer_v1_frame(pointer);
    } else if (!strcmp(op, "button")) {
        zwlr_virtual_pointer_v1_button(pointer, timestamp(), a, b);
        zwlr_virtual_pointer_v1_frame(pointer);
    } else if (!strcmp(op, "click-at")) {
        // One request batch keeps the click inside the hover delay.
        zwlr_virtual_pointer_v1_motion_absolute(pointer, timestamp(), a, b, 1280, 720);
        zwlr_virtual_pointer_v1_button(pointer, timestamp(), 274, 1);
        zwlr_virtual_pointer_v1_frame(pointer);
        zwlr_virtual_pointer_v1_button(pointer, timestamp(), 274, 0);
        zwlr_virtual_pointer_v1_frame(pointer);
    } else assert(!"unknown command");
    return true;
}
int main(int argc, char **argv) {
    assert(argc == 2); label = argv[1]; setvbuf(stdout, NULL, _IOLBF, 0);
    display = wl_display_connect(NULL); assert(display);
    wl_registry_add_listener(wl_display_get_registry(display), &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && seat && wm && primary && keyboards && pointer && layers && dialogs);
    setup(); assert(wl_display_roundtrip(display) >= 0); puts("{\"event\":\"ready\"}");
    for (;;) {
        while (wl_display_prepare_read(display) != 0) assert(wl_display_dispatch_pending(display) >= 0);
        assert(wl_display_flush(display) >= 0);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        assert(poll(fds, 2, -1) >= 0);
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) assert(wl_display_read_events(display) >= 0);
        else wl_display_cancel_read(display);
        assert(wl_display_dispatch_pending(display) >= 0);
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char line[128]; if (!fgets(line, sizeof(line), stdin) || !command(line)) break;
            assert(wl_display_roundtrip(display) >= 0);
            printf("{\"event\":\"command\",\"value\":\"%.*s\"}\n", (int)strcspn(line, "\n"), line);
        }
    }
    if (paste_fd >= 0) close(paste_fd);
    wl_display_disconnect(display); return 0;
}
