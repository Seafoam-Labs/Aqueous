// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _GNU_SOURCE
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "aqueous-window-management-v1-client-protocol.h"
#include "aqueous-input-management-v1-client-protocol.h"
#include "aqueous-xkb-bindings-v1-client-protocol.h"
#include "aqueous-xkb-config-v1-client-protocol.h"
#include "aqueous-libinput-config-v1-client-protocol.h"
#include "aqueous-layer-shell-v1-client-protocol.h"
#include "security-context-client-protocol.h"
#include "virtual-keyboard-client-protocol.h"

static const struct wl_interface *interfaces[] = {
    &aqueous_window_manager_v1_interface, &aqueous_input_manager_v1_interface,
    &aqueous_xkb_bindings_v1_interface, &aqueous_xkb_config_v1_interface,
    &aqueous_libinput_config_v1_interface, &aqueous_layer_shell_v1_interface,
};
static const uint32_t versions[] = {10, 2, 3, 2, 2, 1};
struct connection {
    struct wl_display *display;
    struct wl_registry *registry;
    uint32_t globals[6];
    bool unavailable;
};
static struct aqueous_xkb_bindings_v1 *bindings;
static struct aqueous_layer_shell_v1 *layer;
static struct wp_security_context_manager_v1 *security;
static struct zwp_virtual_keyboard_manager_v1 *virtual_manager;
static struct wl_seat *wl_seat;
static struct wl_compositor *compositor;
static unsigned seats, outputs, devices, keyboards, keymap_success, accel_success;
static unsigned manage_cycles, render_cycles;

static void watch(void *proxy, struct connection *connection);

/* Use the generated event metadata so even events irrelevant to this smoke test
 * are dispatched, and every server-created child gets checked and watched. */
static int event(const void *implementation, void *object, uint32_t opcode,
                 const struct wl_message *message, union wl_argument *args) {
    (void)implementation; (void)opcode;
    struct connection *connection = wl_proxy_get_user_data(object);
    const char *type = wl_proxy_get_class(object);
    unsigned argument = 0;
    for (const char *signature = message->signature; *signature; signature++) {
        if ((*signature >= '0' && *signature <= '9') || *signature == '?') continue;
        if (*signature == 'n') {
            struct wl_proxy *child = (struct wl_proxy *)args[argument].o;
            assert(child && message->types[argument]);
            assert(!strcmp(wl_proxy_get_class(child), message->types[argument]->name));
            assert(!strncmp(wl_proxy_get_class(child), "aqueous_", 8));
            watch(child, connection);
        }
        argument++;
    }
    if (!strcmp(type, "aqueous_window_manager_v1")) {
        if (!strcmp(message->name, "unavailable")) connection->unavailable = true;
        else if (!strcmp(message->name, "manage_start")) {
            manage_cycles++;
            aqueous_window_manager_v1_manage_finish(object);
        } else if (!strcmp(message->name, "render_start")) {
            render_cycles++;
            aqueous_window_manager_v1_render_finish(object);
        } else if (!strcmp(message->name, "seat")) {
            struct aqueous_seat_v1 *seat = (void *)args[0].o;
            seats++;
            watch(aqueous_xkb_bindings_v1_get_seat(bindings, seat), connection);
            watch(aqueous_xkb_bindings_v1_get_xkb_binding(bindings, seat, XKB_KEY_F12, 0), connection);
            watch(aqueous_seat_v1_get_pointer_binding(seat, 0x110, 0), connection);
            watch(aqueous_layer_shell_v1_get_seat(layer, seat), connection);
        } else if (!strcmp(message->name, "output")) {
            outputs++;
            watch(aqueous_layer_shell_v1_get_output(layer, (void *)args[0].o), connection);
        }
    } else if (!strcmp(type, "aqueous_input_manager_v1") && !strcmp(message->name, "input_device")) {
        devices++;
    } else if (!strcmp(type, "aqueous_xkb_config_v1") && !strcmp(message->name, "xkb_keyboard")) {
        keyboards++;
    } else if (!strcmp(type, "aqueous_xkb_keyboard_v1") && !strcmp(message->name, "input_device")) {
        assert(args[0].o && !strcmp(wl_proxy_get_class((void *)args[0].o), "aqueous_input_device_v1"));
    } else if (!strcmp(type, "aqueous_xkb_keymap_v1")) {
        assert(!strcmp(message->name, "success"));
        keymap_success++;
    } else if (!strcmp(type, "aqueous_libinput_result_v1")) {
        assert(!strcmp(message->name, "success"));
        accel_success++;
        wl_proxy_destroy(object);
    }
    return 0;
}

static void watch(void *proxy, struct connection *connection) {
    assert(proxy);
    assert(wl_proxy_add_dispatcher(proxy, event, NULL, connection) == 0);
}

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    struct connection *connection = data;
    assert(strncmp(interface, "river_", 6) != 0);
    for (unsigned i = 0; i < 6; i++) {
        if (strcmp(interface, interfaces[i]->name)) continue;
        assert(!connection->globals[i] && version == versions[i]);
        connection->globals[i] = name;
    }
    /* Only the primary connection needs the standard helper interfaces. */
    if (!security && !strcmp(interface, wp_security_context_manager_v1_interface.name))
        security = wl_registry_bind(registry, name, &wp_security_context_manager_v1_interface, 1);
    if (!virtual_manager && !strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name))
        virtual_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    if (!wl_seat && !strcmp(interface, wl_seat_interface.name))
        wl_seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    if (!compositor && !strcmp(interface, wl_compositor_interface.name))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};

static void connect_client(struct connection *connection, const char *name, bool restricted) {
    connection->display = wl_display_connect(name);
    assert(connection->display);
    connection->registry = wl_display_get_registry(connection->display);
    assert(wl_registry_add_listener(connection->registry, &registry_listener, connection) == 0);
    assert(wl_display_roundtrip(connection->display) >= 0);
    for (unsigned i = 0; i < 6; i++) assert((connection->globals[i] != 0) == !restricted);
}
static void roundtrips(struct connection *connection) {
    for (unsigned i = 0; i < 8; i++) assert(wl_display_roundtrip(connection->display) >= 0);
}
static void *bind_global(struct connection *connection, unsigned index) {
    void *proxy = wl_registry_bind(connection->registry, connection->globals[index], interfaces[index], versions[index]);
    watch(proxy, connection);
    return proxy;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    bool external = !strcmp(argv[1], "external") || !strcmp(argv[1], "compare");
    struct connection primary = {0};
    connect_client(&primary, NULL, false);
    assert(security && virtual_manager && wl_seat && compositor);
    struct aqueous_input_manager_v1 *input = bind_global(&primary, 1);
    bindings = bind_global(&primary, 2);
    struct aqueous_xkb_config_v1 *xkb = bind_global(&primary, 3);
    struct aqueous_libinput_config_v1 *libinput = bind_global(&primary, 4);
    layer = bind_global(&primary, 5);
    struct aqueous_window_manager_v1 *manager = bind_global(&primary, 0);
    roundtrips(&primary);
    assert(primary.unavailable == !external);

    /* The second connection must not acquire ownership even in external mode. */
    struct connection second = {0};
    connect_client(&second, NULL, false);
    struct aqueous_window_manager_v1 *rejected = bind_global(&second, 0);
    roundtrips(&second);
    assert(second.unavailable);
    aqueous_window_manager_v1_destroy(rejected);
    roundtrips(&second);
    wl_display_disconnect(second.display);

    aqueous_input_manager_v1_create_seat(input, "protocol-test");
    roundtrips(&primary);
    if (external) assert(seats >= 2 && outputs >= 1 && manage_cycles && render_cycles);

    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    assert(context);
    struct xkb_rule_names names = {.layout = "us"};
    struct xkb_keymap *map = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    assert(map);
    char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1);
    assert(text);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("protocol-keymap", MFD_CLOEXEC);
    assert(fd >= 0 && write(fd, text, size) == (ssize_t)size);
    struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(virtual_manager, wl_seat);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    struct aqueous_xkb_keymap_v1 *keymap = aqueous_xkb_config_v1_create_keymap(xkb, fd, AQUEOUS_XKB_CONFIG_V1_KEYMAP_FORMAT_TEXT_V1);
    watch(keymap, &primary);
    close(fd); free(text); xkb_keymap_unref(map); xkb_context_unref(context);
    roundtrips(&primary);
    assert(keymap_success == 1);
    /* Virtual keyboards intentionally stay out of the physical-device APIs. */
    assert(devices == 0 && keyboards == 0);

    struct aqueous_libinput_accel_config_v1 *accel = aqueous_libinput_config_v1_create_accel_config(libinput, AQUEOUS_LIBINPUT_DEVICE_V1_ACCEL_PROFILE_CUSTOM);
    double step_value = 1.0, point_values[] = {0.0, 1.0};
    struct wl_array step = {.size = sizeof(step_value), .data = &step_value};
    struct wl_array points = {.size = sizeof(point_values), .data = point_values};
    watch(aqueous_libinput_accel_config_v1_set_points(accel, AQUEOUS_LIBINPUT_ACCEL_CONFIG_V1_ACCEL_TYPE_MOTION, &step, &points), &primary);
    roundtrips(&primary);
    assert(accel_success == 1);

    if (external) {
        struct wl_surface *surface = wl_compositor_create_surface(compositor);
        struct aqueous_shell_surface_v1 *shell = aqueous_window_manager_v1_get_shell_surface(manager, surface);
        watch(shell, &primary);
        struct aqueous_node_v1 *node = aqueous_shell_surface_v1_get_node(shell);
        roundtrips(&primary);
        aqueous_node_v1_destroy(node);
        aqueous_shell_surface_v1_destroy(shell);
        wl_surface_destroy(surface);
    }

    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0), lifetime[2];
    assert(listener >= 0 && socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, lifetime) == 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    int length = snprintf(address.sun_path, sizeof(address.sun_path), "%s/protocol-sandbox", getenv("XDG_RUNTIME_DIR"));
    assert(length > 0 && (size_t)length < sizeof(address.sun_path));
    assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(listener, 8) == 0);
    struct wp_security_context_v1 *sandbox = wp_security_context_manager_v1_create_listener(security, listener, lifetime[0]);
    wp_security_context_v1_set_sandbox_engine(sandbox, "aqueous-test");
    wp_security_context_v1_set_app_id(sandbox, "protocol-test");
    wp_security_context_v1_commit(sandbox);
    wp_security_context_v1_destroy(sandbox);
    close(listener); close(lifetime[0]);
    roundtrips(&primary);
    struct connection restricted = {0};
    connect_client(&restricted, "protocol-sandbox", true);
    wl_display_disconnect(restricted.display);
    close(lifetime[1]);

    aqueous_input_manager_v1_destroy_seat(input, "protocol-test");
    aqueous_libinput_accel_config_v1_destroy(accel);
    aqueous_xkb_keymap_v1_destroy(keymap);
    zwp_virtual_keyboard_v1_destroy(keyboard);
    roundtrips(&primary);
    aqueous_window_manager_v1_destroy(manager);
    roundtrips(&primary);
    /* Disconnect with the remaining child objects alive to exercise cleanup. */
    wl_display_disconnect(primary.display);
    puts("PASS Aqueous globals/versions, bindings, input/XKB/libinput children, policy ownership, restricted visibility, cleanup");
    return 0;
}
