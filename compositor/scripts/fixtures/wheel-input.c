// SPDX-License-Identifier: GPL-3.0-only
// Persistent virtual devices for the wheel binding integration test.
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-client-protocol.h"
#include "virtual-pointer-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *keyboards;
static struct zwlr_virtual_pointer_manager_v1 *pointers;

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_seat")) seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1")) keyboards = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1")) pointers = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener listener = { .global = global, .global_remove = removed };

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *display = wl_display_connect(NULL); assert(display);
    wl_registry_add_listener(wl_display_get_registry(display), &listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(seat && keyboards && pointers);
    struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboards, seat);
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointers, seat);
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS); assert(context);
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS); assert(keymap);
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1); assert(text);
    int fd = memfd_create("wheel-keymap", MFD_CLOEXEC); assert(fd >= 0);
    size_t length = strlen(text) + 1;
    assert(write(fd, text, length) == (ssize_t)length);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, length);
    close(fd); free(text); xkb_keymap_unref(keymap); xkb_context_unref(context);
    assert(wl_display_roundtrip(display) >= 0);
    puts("ready");
    char command[128];
    while (fgets(command, sizeof(command), stdin)) {
        struct timespec now; assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
        uint32_t time = (uint32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
        uint32_t mods, axis, source; int discrete; double delta;
        if (sscanf(command, "mods %u", &mods) == 1) {
            zwp_virtual_keyboard_v1_modifiers(keyboard, mods, 0, 0, 0);
        } else if (sscanf(command, "scroll %u %u %lf %d", &axis, &source, &delta, &discrete) == 4) {
            zwlr_virtual_pointer_v1_axis_source(pointer, source);
            if (source == WL_POINTER_AXIS_SOURCE_WHEEL) {
                zwlr_virtual_pointer_v1_axis_discrete(pointer, time, axis, wl_fixed_from_double(delta), discrete);
            } else {
                zwlr_virtual_pointer_v1_axis(pointer, time, axis, wl_fixed_from_double(delta));
            }
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (!strncmp(command, "move", 4)) {
            zwlr_virtual_pointer_v1_motion_absolute(pointer, time, 100, 100, 1000, 1000);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (!strncmp(command, "quit", 4)) break;
        else abort();
        assert(wl_display_roundtrip(display) >= 0);
        puts("done");
    }
    wl_display_disconnect(display);
    return 0;
}
