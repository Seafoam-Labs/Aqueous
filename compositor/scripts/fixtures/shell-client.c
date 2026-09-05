// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "xdg-shell-client-protocol.h"
#include "virtual-keyboard-client-protocol.h"
#include "shortcuts-client-protocol.h"
#include "layer-shell-client-protocol.h"
#include "session-lock-client-protocol.h"
#include "aqueous-shell-client-protocol.h"
#include "ext-workspace-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static struct wl_output *outputs[16];
static size_t noutputs;
static struct xdg_wm_base *wm;
static struct zwp_virtual_keyboard_manager_v1 *virtual_manager;
static struct zwp_virtual_keyboard_v1 *virtual_keyboard;
static struct zwp_keyboard_shortcuts_inhibit_manager_v1 *inhibit_manager;
static struct zwp_keyboard_shortcuts_inhibitor_v1 *inhibitor;
static struct zwlr_layer_shell_v1 *layer_manager;
static struct ext_session_lock_manager_v1 *lock_manager;
static struct ext_session_lock_v1 *lock;
static struct aqueous_shell_manager_v1 *shell;
static struct ext_workspace_manager_v1 *workspaces;
static int want_workspaces;
static struct wl_surface *window;
static uint32_t batch_serial;
static int width = 400, height = 300;
static int running = 1;

struct buffer { struct wl_buffer *object; void *map; size_t size; };
static void release(void *data, struct wl_buffer *object) {
    struct buffer *b = data; wl_buffer_destroy(object); munmap(b->map, b->size); free(b);
}
static const struct wl_buffer_listener buffer_listener = { .release = release };
static void draw(struct wl_surface *surface, int w, int h) {
    assert(w > 0 && h > 0 && w < 16384 && h < 16384);
    struct buffer *b = calloc(1, sizeof(*b)); assert(b);
    b->size = (size_t)w * h * 4;
    int fd = memfd_create("aqueous-shell-test", MFD_CLOEXEC); assert(fd >= 0);
    assert(ftruncate(fd, b->size) == 0);
    b->map = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); assert(b->map != MAP_FAILED);
    uint32_t *pixels = b->map;
    for (size_t i = 0; i < b->size / 4; ++i) pixels[i] = 0xff287858;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, b->size);
    b->object = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool); close(fd);
    wl_buffer_add_listener(b->object, &buffer_listener, b);
    wl_surface_attach(surface, b->object, 0, 0);
    wl_surface_damage(surface, 0, 0, w, h);
    wl_surface_commit(surface);
}
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) { (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void configure(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(s, serial); draw(window, width, height); puts("configured");
}
static const struct xdg_surface_listener surface_listener = { .configure = configure };
static void top_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)t; (void)states; if (w > 0) width = w; if (h > 0) height = h;
}
static void close_window(void *data, struct xdg_toplevel *t) { (void)data; (void)t; puts("closed"); running = 0; }
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = close_window };
static void keymap(void *data, struct wl_keyboard *k, uint32_t format, int32_t fd, uint32_t size) { (void)data; (void)k; (void)format; (void)size; close(fd); }
static void enter(void *data, struct wl_keyboard *k, uint32_t serial, struct wl_surface *surface, struct wl_array *keys) { (void)data; (void)k; (void)serial; (void)surface; (void)keys; puts("enter"); }
static void leave(void *data, struct wl_keyboard *k, uint32_t serial, struct wl_surface *surface) { (void)data; (void)k; (void)serial; (void)surface; puts("leave"); }
static void key(void *data, struct wl_keyboard *k, uint32_t serial, uint32_t time, uint32_t code, uint32_t state) { (void)data; (void)k; (void)serial; (void)time; printf("key %u %u\n", code, state); }
static void modifiers(void *data, struct wl_keyboard *k, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) { (void)data; (void)k; (void)serial; (void)depressed; (void)latched; (void)locked; printf("layout %u\n", group); }
static void repeat(void *data, struct wl_keyboard *k, int32_t rate, int32_t delay) { (void)data; (void)k; (void)rate; (void)delay; }
static const struct wl_keyboard_listener key_listener = { .keymap = keymap, .enter = enter, .leave = leave, .key = key, .modifiers = modifiers, .repeat_info = repeat };
static void seat_caps(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) { keyboard = wl_seat_get_keyboard(s); wl_keyboard_add_listener(keyboard, &key_listener, NULL); }
}
static void seat_name(void *data, struct wl_seat *s, const char *name) { (void)data; (void)s; (void)name; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_caps, .name = seat_name };
static void active(void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *i) { (void)data; (void)i; puts("inhibit active"); }
static void inactive(void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *i) { (void)data; (void)i; puts("inhibit inactive"); }
static const struct zwp_keyboard_shortcuts_inhibitor_v1_listener inhibit_listener = { .active = active, .inactive = inactive };
static void layer_configure(void *data, struct zwlr_layer_surface_v1 *s, uint32_t serial, uint32_t w, uint32_t h) {
    zwlr_layer_surface_v1_ack_configure(s, serial); draw(data, w, h); puts("frame configured");
}
static void layer_close(void *data, struct zwlr_layer_surface_v1 *s) { (void)data; (void)s; }
static const struct zwlr_layer_surface_v1_listener layer_listener = { .configure = layer_configure, .closed = layer_close };
static void locked(void *data, struct ext_session_lock_v1 *l) { (void)data; (void)l; puts("locked"); }
static void lock_finished(void *data, struct ext_session_lock_v1 *l) { (void)data; (void)l; puts("lock finished"); }
static const struct ext_session_lock_v1_listener lock_listener = { .locked = locked, .finished = lock_finished };
static void lock_configure(void *data, struct ext_session_lock_surface_v1 *s, uint32_t serial, uint32_t w, uint32_t h) { ext_session_lock_surface_v1_ack_configure(s, serial); draw(data, w, h); }
static const struct ext_session_lock_surface_v1_listener lock_surface_listener = { .configure = lock_configure };
static void capabilities(void *data, struct aqueous_shell_manager_v1 *s, const char *json) { (void)data; (void)s; (void)json; }
static void begin(void *data, struct aqueous_shell_manager_v1 *s, uint32_t serial) { (void)data; (void)s; batch_serial = serial; }
static void bytes(void *data, struct aqueous_shell_manager_v1 *s, struct wl_array *array) { (void)data; (void)s; (void)array; }
static void done(void *data, struct aqueous_shell_manager_v1 *s, uint32_t serial) { (void)data; (void)s; assert(serial == batch_serial); puts("batch"); }
static void result(void *data, struct aqueous_shell_manager_v1 *s, uint32_t id, uint32_t status, const char *sequence) { (void)data; (void)s; (void)id; (void)status; (void)sequence; }
static void workspace_id(void *data, struct aqueous_shell_manager_v1 *s, uint32_t id, const char *value) { (void)data; (void)s; printf("workspace %u %s\n", id, value); }
static const struct aqueous_shell_manager_v1_listener shell_listener = { .capabilities = capabilities, .begin = begin, .data = bytes, .done = done, .result = result, .workspace_id = workspace_id };
static void ws_string(void *d, struct ext_workspace_handle_v1 *w, const char *v) { (void)d; (void)w; (void)v; }
static void ws_uint(void *d, struct ext_workspace_handle_v1 *w, uint32_t v) { (void)d; (void)w; (void)v; }
static void ws_array(void *d, struct ext_workspace_handle_v1 *w, struct wl_array *v) { (void)d; (void)w; (void)v; }
static void ws_removed(void *d, struct ext_workspace_handle_v1 *w) { (void)d; ext_workspace_handle_v1_destroy(w); }
static const struct ext_workspace_handle_v1_listener ws_listener = { .id = ws_string, .name = ws_string, .coordinates = ws_array, .state = ws_uint, .capabilities = ws_uint, .removed = ws_removed };
static void group_uint(void *d, struct ext_workspace_group_handle_v1 *g, uint32_t v) { (void)d; (void)g; (void)v; }
static void group_output(void *d, struct ext_workspace_group_handle_v1 *g, struct wl_output *v) { (void)d; (void)g; (void)v; }
static void group_ws(void *d, struct ext_workspace_group_handle_v1 *g, struct ext_workspace_handle_v1 *v) { (void)d; (void)g; (void)v; }
static void group_removed(void *d, struct ext_workspace_group_handle_v1 *g) { (void)d; ext_workspace_group_handle_v1_destroy(g); }
static const struct ext_workspace_group_handle_v1_listener group_listener = { .capabilities = group_uint, .output_enter = group_output, .output_leave = group_output, .workspace_enter = group_ws, .workspace_leave = group_ws, .removed = group_removed };
static void workspace_group(void *d, struct ext_workspace_manager_v1 *m, struct ext_workspace_group_handle_v1 *g) { (void)d; (void)m; ext_workspace_group_handle_v1_add_listener(g, &group_listener, NULL); }
static void workspace_created(void *d, struct ext_workspace_manager_v1 *m, struct ext_workspace_handle_v1 *w) {
    (void)d; (void)m; static uint32_t id;
    ext_workspace_handle_v1_add_listener(w, &ws_listener, NULL);
    aqueous_shell_manager_v1_identify_workspace(shell, ++id, w);
}
static void workspace_done(void *d, struct ext_workspace_manager_v1 *m) { (void)d; (void)m; }
static const struct ext_workspace_manager_v1_listener workspace_listener = { .workspace_group = workspace_group, .workspace = workspace_created, .done = workspace_done, .finished = workspace_done };
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
#define BIND(iface, dest, v) if (!strcmp(interface, iface##_interface.name)) dest = wl_registry_bind(r, name, &iface##_interface, v)
    BIND(wl_compositor, compositor, 4);
    else BIND(wl_shm, shm, 1);
    else BIND(wl_seat, seat, 5);
    else BIND(xdg_wm_base, wm, 1);
    else BIND(zwp_virtual_keyboard_manager_v1, virtual_manager, 1);
    else BIND(zwp_keyboard_shortcuts_inhibit_manager_v1, inhibit_manager, 1);
    else BIND(zwlr_layer_shell_v1, layer_manager, 1);
    else BIND(ext_session_lock_manager_v1, lock_manager, 1);
    else BIND(aqueous_shell_manager_v1, shell, 1);
    else if (want_workspaces && !strcmp(interface, ext_workspace_manager_v1_interface.name)) workspaces = wl_registry_bind(r, name, &ext_workspace_manager_v1_interface, 1);
    else if (!strcmp(interface, wl_output_interface.name) && noutputs < 16) outputs[noutputs++] = wl_registry_bind(r, name, &wl_output_interface, 1);
#undef BIND
}
static void global_remove(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = global_remove };
static void make_keyboard(const char *layouts) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS); assert(context);
    struct xkb_rule_names names = { .layout = layouts };
    struct xkb_keymap *map = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS); assert(map);
    char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1); assert(text);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("shell-keymap", MFD_CLOEXEC); assert(fd >= 0);
    assert(write(fd, text, size) == (ssize_t)size);
    if (!virtual_keyboard) virtual_keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(virtual_manager, seat);
    zwp_virtual_keyboard_v1_keymap(virtual_keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    close(fd); free(text); xkb_keymap_unref(map); xkb_context_unref(context);
    zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, 0, 0, 0, 0);
}
int main(int argc, char **argv) {
    assert(argc == 2); setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stdin, NULL, _IONBF, 0);
    want_workspaces = !strcmp(argv[1], "workspaces");
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && seat && wm && virtual_manager && inhibit_manager && layer_manager && lock_manager && shell);
    wl_seat_add_listener(seat, &seat_listener, NULL);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    aqueous_shell_manager_v1_add_listener(shell, &shell_listener, NULL);
    if (workspaces) ext_workspace_manager_v1_add_listener(workspaces, &workspace_listener, NULL);
    struct xdg_toplevel *toplevel = NULL;
    if (!strcmp(argv[1], "window")) {
        make_keyboard("us,de");
        window = wl_compositor_create_surface(compositor);
        struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, window);
        xdg_surface_add_listener(xdg, &surface_listener, NULL);
        toplevel = xdg_surface_get_toplevel(xdg);
        xdg_toplevel_add_listener(toplevel, &top_listener, NULL);
        xdg_toplevel_set_title(toplevel, "same title");
        xdg_toplevel_set_app_id(toplevel, "aq-shell-test");
        wl_surface_commit(window);
    } else if (!strcmp(argv[1], "frame")) {
        assert(noutputs);
        const uint32_t anchors[] = { 1|4|8, 2|4|8, 4|1|2, 8|1|2 };
        for (size_t i = 0; i < 4; ++i) {
            struct wl_surface *surface = wl_compositor_create_surface(compositor);
            struct zwlr_layer_surface_v1 *layer = zwlr_layer_shell_v1_get_layer_surface(layer_manager, surface, outputs[0], ZWLR_LAYER_SHELL_V1_LAYER_TOP, "dms:frame-exclusion");
            zwlr_layer_surface_v1_add_listener(layer, &layer_listener, surface);
            zwlr_layer_surface_v1_set_anchor(layer, anchors[i]);
            zwlr_layer_surface_v1_set_size(layer, i < 2 ? 0 : 1, i < 2 ? 1 : 0);
            zwlr_layer_surface_v1_set_exclusive_zone(layer, 20);
            struct wl_region *empty = wl_compositor_create_region(compositor);
            wl_surface_set_input_region(surface, empty); wl_region_destroy(empty);
            wl_surface_commit(surface);
        }
    } else if (!strcmp(argv[1], "lock")) {
        lock = ext_session_lock_manager_v1_lock(lock_manager);
        ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
        for (size_t i = 0; i < noutputs; ++i) {
            struct wl_surface *surface = wl_compositor_create_surface(compositor);
            struct ext_session_lock_surface_v1 *s = ext_session_lock_v1_get_lock_surface(lock, surface, outputs[i]);
            ext_session_lock_surface_v1_add_listener(s, &lock_surface_listener, surface);
        }
    } else if (!strcmp(argv[1], "watch")) aqueous_shell_manager_v1_subscribe(shell);
    else if (!want_workspaces) abort();
    assert(wl_display_roundtrip(display) >= 0);
    if (want_workspaces) assert(wl_display_roundtrip(display) >= 0);
    puts("ready");
    while (running) {
        assert(wl_display_dispatch_pending(display) >= 0);
        assert(wl_display_flush(display) >= 0);
        struct pollfd fds[2] = { {wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0} };
        if (poll(fds, 2, -1) < 0) break;
        if (fds[0].revents & POLLIN) { if (wl_display_dispatch(display) < 0) break; }
        if (fds[0].revents & (POLLHUP | POLLERR)) break;
        if (fds[1].revents & POLLIN) {
            char command[1024]; if (!fgets(command, sizeof(command), stdin)) break;
            if (!strncmp(command, "quit", 4)) running = 0;
            else if (!strncmp(command, "inhibit", 7) && !inhibitor && window) {
                inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(inhibit_manager, window, seat);
                zwp_keyboard_shortcuts_inhibitor_v1_add_listener(inhibitor, &inhibit_listener, NULL);
            } else if (!strncmp(command, "uninhibit", 9) && inhibitor) { zwp_keyboard_shortcuts_inhibitor_v1_destroy(inhibitor); inhibitor = NULL; }
            else if (!strncmp(command, "press", 5)) {
                zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, 1 << 6, 0, 0, 0);
                zwp_virtual_keyboard_v1_key(virtual_keyboard, 1, 17, WL_KEYBOARD_KEY_STATE_PRESSED);
            } else if (!strncmp(command, "release", 7)) {
                zwp_virtual_keyboard_v1_key(virtual_keyboard, 2, 17, WL_KEYBOARD_KEY_STATE_RELEASED);
                zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, 0, 0, 0, 0);
            } else if (!strncmp(command, "layout", 6)) zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, 0, 0, 0, 1);
            else if (!strncmp(command, "reload", 6)) make_keyboard("us,fr,de");
            else if (!strncmp(command, "title ", 6) && toplevel) { command[strcspn(command, "\n")] = 0; xdg_toplevel_set_title(toplevel, command + 6); }
            else if (!strncmp(command, "ack", 3)) aqueous_shell_manager_v1_ack(shell, batch_serial);
            else if (!strncmp(command, "unlock", 6) && lock) { ext_session_lock_v1_unlock_and_destroy(lock); lock = NULL; assert(wl_display_roundtrip(display) >= 0); running = 0; }
        }
    }
    wl_display_flush(display); wl_display_disconnect(display);
    return 0;
}
