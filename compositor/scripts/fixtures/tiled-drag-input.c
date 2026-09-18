// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-client-protocol.h"
#include "virtual-pointer-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
static struct zwlr_virtual_pointer_manager_v1 *pointer_manager;

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_seat"))
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    else if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1"))
        keyboard_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    else if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1"))
        pointer_manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener listener = {.global = global, .global_remove = removed};

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(seat && keyboard_manager && pointer_manager);
    struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager, seat);
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointer_manager, seat);
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    assert(context);
    struct xkb_rule_names names = {.layout = "us"};
    struct xkb_keymap *map = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    assert(map);
    char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1);
    assert(text);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("tiled-drag-keymap", MFD_CLOEXEC);
    assert(fd >= 0 && write(fd, text, size) == (ssize_t)size);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    close(fd); free(text); xkb_keymap_unref(map); xkb_context_unref(context);
    assert(wl_display_roundtrip(display) >= 0);
    puts("ready");
    uint32_t tick = 1000;
    char line[256], op[32];
    while (fgets(line, sizeof(line), stdin)) {
        int a = 0, b = 0;
        assert(sscanf(line, "%31s %d %d", op, &a, &b) >= 1);
        if (!strcmp(op, "motion") || !strcmp(op, "drop")) {
            zwlr_virtual_pointer_v1_motion(pointer, ++tick, wl_fixed_from_int(a), wl_fixed_from_int(b));
            if (!strcmp(op, "drop"))
                zwlr_virtual_pointer_v1_button(pointer, ++tick, 0x110, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (!strcmp(op, "crossings")) {
            for (int i = 0; i < b; ++i) {
                zwlr_virtual_pointer_v1_motion(pointer, ++tick, wl_fixed_from_int(i % 2 ? -a : a), 0);
                zwlr_virtual_pointer_v1_frame(pointer);
            }
        } else if (!strcmp(op, "button")) {
            // Optional second argument selects the Linux button code (left by default).
            zwlr_virtual_pointer_v1_button(pointer, ++tick, b ? (uint32_t)b : 0x110, a ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (!strcmp(op, "modifiers")) {
            zwp_virtual_keyboard_v1_modifiers(keyboard, a, 0, 0, 0);
        } else if (!strcmp(op, "key")) {
            zwp_virtual_keyboard_v1_modifiers(keyboard, b, 0, 0, 0);
            zwp_virtual_keyboard_v1_key(keyboard, ++tick, a, WL_KEYBOARD_KEY_STATE_PRESSED);
            zwp_virtual_keyboard_v1_key(keyboard, ++tick, a, WL_KEYBOARD_KEY_STATE_RELEASED);
            zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
        } else if (!strcmp(op, "quit")) break;
        else assert(!"unknown command");
        assert(wl_display_roundtrip(display) >= 0);
        puts("done");
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    zwp_virtual_keyboard_v1_destroy(keyboard);
    wl_display_disconnect(display);
    return 0;
}
