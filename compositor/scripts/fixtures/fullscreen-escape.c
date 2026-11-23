// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

// Minimal fullscreen "game" fixture for the keyboard-seizure escape regression.
// It renders a solid color, can enter/exit fullscreen, can inhibit compositor
// shortcuts, and logs every key it receives so a test can distinguish keys the
// compositor forwards from escape chords it must intercept. Unlike the Xwayland
// grab fixture it does not drop its inhibitor when a key arrives.

#define _GNU_SOURCE

#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "xdg-shell-client-protocol.h"
#include "keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static struct xdg_wm_base *wm_base;
static struct zwp_keyboard_shortcuts_inhibit_manager_v1 *inhibit_manager;
static struct zwp_keyboard_shortcuts_inhibitor_v1 *inhibitor;
static struct zwp_virtual_keyboard_manager_v1 *virtual_manager;
static struct zwp_virtual_keyboard_v1 *virtual_keyboard;

static struct wl_surface *surface;
static struct xdg_surface *xdg_surface;
static struct xdg_toplevel *toplevel;
static struct wl_buffer *buffer;
static uint32_t color = 0xffff0000;
static int32_t pending_width, pending_height;
static bool pending_fullscreen;
static bool running = true;

static void wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void keyboard_keymap(void *data, struct wl_keyboard *kb, uint32_t format, int32_t fd, uint32_t size) {
    (void)data; (void)kb; (void)format; (void)size;
    close(fd);
}
static void keyboard_enter(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *s, struct wl_array *keys) {
    (void)data; (void)kb; (void)serial; (void)s; (void)keys;
    puts("keyboard enter");
}
static void keyboard_leave(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *s) {
    (void)data; (void)kb; (void)serial; (void)s;
    puts("keyboard leave");
}
static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)data; (void)kb; (void)serial; (void)time;
    printf("KEY keycode=%u state=%u\n", key, state);
}
static void keyboard_modifiers(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    (void)data; (void)kb; (void)serial; (void)depressed; (void)latched; (void)locked; (void)group;
}
static void keyboard_repeat_info(void *data, struct wl_keyboard *kb, int32_t rate, int32_t delay) {
    (void)data; (void)kb; (void)rate; (void)delay;
}
static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap, .enter = keyboard_enter, .leave = keyboard_leave,
    .key = keyboard_key, .modifiers = keyboard_modifiers, .repeat_info = keyboard_repeat_info,
};

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) {
        keyboard = wl_seat_get_keyboard(s);
        wl_keyboard_add_listener(keyboard, &keyboard_listener, NULL);
    }
}
static void seat_name(void *data, struct wl_seat *s, const char *name) { (void)data; (void)s; (void)name; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_capabilities, .name = seat_name };

static void inhibit_active(void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *i) { (void)data; (void)i; puts("inhibit active"); }
static void inhibit_inactive(void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *i) { (void)data; (void)i; puts("inhibit inactive"); }
static const struct zwp_keyboard_shortcuts_inhibitor_v1_listener inhibit_listener = {
    .active = inhibit_active, .inactive = inhibit_inactive,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        seat = wl_registry_bind(registry, name, &wl_seat_interface, version < 5 ? version : 5);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    } else if (strcmp(interface, zwp_keyboard_shortcuts_inhibit_manager_v1_interface.name) == 0) {
        inhibit_manager = wl_registry_bind(registry, name, &zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1);
    } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        virtual_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}
static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {
    .global = registry_global, .global_remove = registry_global_remove,
};

static bool attach_buffer(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return false;
    const size_t stride = (size_t)width * 4;
    const size_t size = stride * (size_t)height;
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    char path[256];
    snprintf(path, sizeof(path), "%s/aqueous-escape-XXXXXX", runtime ? runtime : "/tmp");
    int fd = mkstemp(path);
    if (fd < 0) return false;
    unlink(path);
    if (ftruncate(fd, (off_t)size) < 0) { close(fd); return false; }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { close(fd); return false; }
    for (size_t i = 0; i < size / 4; ++i) pixels[i] = color;
    munmap(pixels, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    buffer = wl_shm_pool_create_buffer(pool, 0, width, height, (int32_t)stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    if (!buffer) return false;
    xdg_surface_set_window_geometry(xdg_surface, 0, 0, width, height);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    return true;
}

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t width, int32_t height, struct wl_array *states) {
    (void)data; (void)t;
    pending_width = width;
    pending_height = height;
    pending_fullscreen = false;
    uint32_t *state;
    wl_array_for_each(state, states) {
        if (*state == XDG_TOPLEVEL_STATE_FULLSCREEN) pending_fullscreen = true;
    }
}
static void toplevel_close(void *data, struct xdg_toplevel *t) { (void)data; (void)t; running = false; }
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure, .close = toplevel_close,
};

static void surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(s, serial);
    int32_t width = pending_width > 0 ? pending_width : 320;
    int32_t height = pending_height > 0 ? pending_height : 200;
    if (!attach_buffer(width, height)) { fprintf(stderr, "FAIL: buffer attach\n"); running = false; return; }
    printf("CONFIGURE fullscreen=%d width=%d height=%d\n", pending_fullscreen ? 1 : 0, width, height);
}
static const struct xdg_surface_listener surface_listener = { .configure = surface_configure };

// Persistent virtual keyboard so key injection does not churn seat focus the way
// a create/destroy-per-key tool does. Mirrors the shell-client fixture.
static void make_keyboard(const char *layouts) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names names = { .layout = layouts };
    struct xkb_keymap *map = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("escape-keymap", MFD_CLOEXEC);
    if (fd >= 0 && write(fd, text, size) == (ssize_t)size) {
        if (!virtual_keyboard) virtual_keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(virtual_manager, seat);
        zwp_virtual_keyboard_v1_keymap(virtual_keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
        close(fd);
    }
    free(text); xkb_keymap_unref(map); xkb_context_unref(context);
    if (virtual_keyboard) zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, 0, 0, 0, 0);
}

static void inject_chord(unsigned code, unsigned mods, unsigned count, bool hold) {
    if (!virtual_keyboard) return;
    zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, mods, 0, 0, 0);
    for (unsigned i = 0; i < count; ++i) {
        zwp_virtual_keyboard_v1_key(virtual_keyboard, 2 * i + 1, code, WL_KEYBOARD_KEY_STATE_PRESSED);
        zwp_virtual_keyboard_v1_key(virtual_keyboard, 2 * i + 2, code, WL_KEYBOARD_KEY_STATE_RELEASED);
    }
    if (!hold) zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, 0, 0, 0, 0);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s APP_ID [COLOR_HEX]\n", argv[0]); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc >= 3) color = (uint32_t)strtoul(argv[2], NULL, 16);
    display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "failed to connect\n"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !seat || !wm_base || !inhibit_manager) {
        fprintf(stderr, "missing globals\n"); return 1;
    }
    surface = wl_compositor_create_surface(compositor);
    xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg_surface, &surface_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xdg_surface);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(toplevel, "Aqueous escape fixture");
    xdg_toplevel_set_app_id(toplevel, argv[1]);
    wl_surface_commit(surface);
    wl_display_roundtrip(display);
    if (virtual_manager) make_keyboard("us");
    puts("ready");

    while (running) {
        while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
        wl_display_flush(display);
        struct pollfd fds[2] = { { wl_display_get_fd(display), POLLIN, 0 }, { STDIN_FILENO, POLLIN, 0 } };
        if (poll(fds, 2, -1) < 0) break;
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(display) < 0) break;
        } else wl_display_cancel_read(display);
        if (wl_display_dispatch_pending(display) < 0) break;
        if (fds[0].revents & (POLLHUP | POLLERR)) break;
        if (fds[1].revents & POLLIN) {
            char line[256];
            if (!fgets(line, sizeof(line), stdin)) break;
            line[strcspn(line, "\n")] = 0;
            if (!strcmp(line, "quit")) break;
            else if (!strcmp(line, "fullscreen")) xdg_toplevel_set_fullscreen(toplevel, NULL);
            else if (!strcmp(line, "windowed")) xdg_toplevel_unset_fullscreen(toplevel);
            else if (!strcmp(line, "inhibit") && !inhibitor) {
                inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(inhibit_manager, surface, seat);
                zwp_keyboard_shortcuts_inhibitor_v1_add_listener(inhibitor, &inhibit_listener, NULL);
            } else if (!strcmp(line, "uninhibit") && inhibitor) {
                zwp_keyboard_shortcuts_inhibitor_v1_destroy(inhibitor);
                inhibitor = NULL;
            } else if (!strncmp(line, "chord-hold ", 11)) {
                unsigned code, mods, count = 1;
                if (sscanf(line + 11, "%u %u %u", &code, &mods, &count) >= 2) inject_chord(code, mods, count, true);
            } else if (!strncmp(line, "chord ", 6)) {
                unsigned code, mods, count = 1;
                if (sscanf(line + 6, "%u %u %u", &code, &mods, &count) >= 2) inject_chord(code, mods, count, false);
            } else if (!strncmp(line, "mods ", 5)) {
                unsigned mods;
                if (sscanf(line + 5, "%u", &mods) == 1 && virtual_keyboard)
                    zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, mods, 0, 0, 0);
            } else if (!strncmp(line, "key ", 4)) {
                unsigned code, count = 1;
                if (sscanf(line + 4, "%u %u", &code, &count) >= 1) inject_chord(code, 0, count, false);
            }
            wl_surface_commit(surface);
            wl_display_roundtrip(display);
            printf("COMMAND %s\n", line);
        }
    }
    wl_display_flush(display);
    wl_display_disconnect(display);
    return 0;
}