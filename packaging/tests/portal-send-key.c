/* Test-only keyboard injection on the isolated compositor's Wayland socket. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-client.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;
static void global(void *data, struct wl_registry *registry, uint32_t name,
        const char *interface, uint32_t version) {
    (void)data;
    (void)version;
    if (!strcmp(interface, "wl_seat"))
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1"))
        manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
int main(int argc, char **argv) {
    assert(argc > 1);
    struct wl_display *display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    const struct wl_registry_listener listener = {global, removed};
    wl_registry_add_listener(registry, &listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && seat && manager);
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
    assert(keymap);
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("portal-test-keymap", MFD_CLOEXEC);
    assert(fd >= 0 && write(fd, text, size) == (ssize_t)size);
    struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    close(fd);
    assert(wl_display_roundtrip(display) >= 0);
    for (int i = 1; i < argc; ++i) {
        uint32_t key = (uint32_t)strtoul(argv[i], NULL, 10);
        zwp_virtual_keyboard_v1_key(keyboard, i * 200, key, WL_KEYBOARD_KEY_STATE_PRESSED);
        zwp_virtual_keyboard_v1_key(keyboard, i * 200 + 50, key, WL_KEYBOARD_KEY_STATE_RELEASED);
        assert(wl_display_roundtrip(display) >= 0);
        usleep(150000);
    }
    zwp_virtual_keyboard_v1_destroy(keyboard);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    free(text);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    return 0;
}
