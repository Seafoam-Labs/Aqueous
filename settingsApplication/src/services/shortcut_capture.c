/* Record through the application's existing Wayland keyboard connection. */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include "shortcuts-client.h"

static struct zwp_keyboard_shortcuts_inhibit_manager_v1 *manager;
static struct zwp_keyboard_shortcuts_inhibitor_v1 *inhibitor;
static bool active, lost, ready, pressed;
static uint32_t captured_key, captured_sym, captured_mods;

static void activated(void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *obj) {
    (void)data; (void)obj; active = true;
}
static void deactivated(void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *obj) {
    (void)data; (void)obj; active = false; lost = true;
}
static const struct zwp_keyboard_shortcuts_inhibitor_v1_listener listener = {activated, deactivated};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "zwp_keyboard_shortcuts_inhibit_manager_v1"))
        manager = wl_registry_bind(registry, name, &zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {global, removed};

void aq_shortcut_end(void) {
    if (inhibitor) zwp_keyboard_shortcuts_inhibitor_v1_destroy(inhibitor);
    if (manager) zwp_keyboard_shortcuts_inhibit_manager_v1_destroy(manager);
    inhibitor = NULL; manager = NULL;
    active = lost = ready = pressed = false;
}
int aq_shortcut_begin(struct wl_display *display, struct wl_surface *surface, struct wl_seat *seat) {
    aq_shortcut_end();
    if (!display || !surface || !seat) return 0;
    struct wl_registry *registry = wl_display_get_registry(display);
    if (!registry) return 0;
    wl_registry_add_listener(registry, &registry_listener, NULL);
    int result = wl_display_roundtrip(display);
    wl_registry_destroy(registry);
    if (result < 0 || !manager) { aq_shortcut_end(); return 0; }
    inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(manager, surface, seat);
    if (!inhibitor) { aq_shortcut_end(); return 0; }
    zwp_keyboard_shortcuts_inhibitor_v1_add_listener(inhibitor, &listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !active) { aq_shortcut_end(); return 0; }
    return 1;
}

/* Called before Quark's ordinary keyboard handling, including text/search. */
int aq_shortcut_key(struct xkb_state *state, uint32_t key, bool down) {
    if (!inhibitor) return 0;
    if (!active || !state) return 1;
    if (!down) {
        if (pressed && key == captured_key) ready = true;
        return 1;
    }
    if (pressed) return 1;
    const xkb_keysym_t *syms = NULL;
    struct xkb_keymap *map = xkb_state_get_keymap(state);
    xkb_layout_index_t layout = xkb_state_key_get_layout(state, key + 8);
    int count = xkb_keymap_key_get_syms_by_level(map, key + 8, layout, 0, &syms);
    xkb_keysym_t sym = count > 0 ? syms[0] : xkb_state_key_get_one_sym(state, key + 8);
    switch (sym) {
        case XKB_KEY_Shift_L: case XKB_KEY_Shift_R:
        case XKB_KEY_Control_L: case XKB_KEY_Control_R:
        case XKB_KEY_Alt_L: case XKB_KEY_Alt_R:
        case XKB_KEY_Meta_L: case XKB_KEY_Meta_R:
        case XKB_KEY_Super_L: case XKB_KEY_Super_R:
        case XKB_KEY_Hyper_L: case XKB_KEY_Hyper_R:
        case XKB_KEY_ISO_Level3_Shift: case XKB_KEY_ISO_Level5_Shift:
            return 1;
    }
    captured_mods = 0;
    const char *names[] = {XKB_MOD_NAME_SHIFT, XKB_MOD_NAME_CTRL, XKB_MOD_NAME_ALT, XKB_MOD_NAME_LOGO};
    const uint32_t masks[] = {1, 4, 8, 64};
    for (unsigned i = 0; i < 4; ++i)
        if (xkb_state_mod_name_is_active(state, names[i], XKB_STATE_MODS_EFFECTIVE) > 0)
            captured_mods |= masks[i];
    captured_sym = xkb_keysym_to_lower(sym);
    captured_key = key;
    pressed = true;
    return 1;
}
int aq_shortcut_take(uint32_t *sym, uint32_t *mods) {
    if (lost) return -1;
    if (!ready) return 0;
    *sym = captured_sym; *mods = captured_mods;
    ready = false;
    return 1;
}
