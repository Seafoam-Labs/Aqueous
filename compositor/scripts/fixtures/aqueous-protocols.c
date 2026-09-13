// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _GNU_SOURCE
#include <assert.h>
#include <linux/input-event-codes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
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
#include "virtual-pointer-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "screencopy-client-protocol.h"

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
    bool toplevel_tag;
};
static struct aqueous_xkb_bindings_v1 *bindings;
static struct aqueous_layer_shell_v1 *layer;
static struct wp_security_context_manager_v1 *security;
static struct zwp_virtual_keyboard_manager_v1 *virtual_manager;
static struct wl_seat *wl_seat;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_output *wl_output;
static struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
static struct zwlr_screencopy_manager_v1 *capture_manager;
static uint32_t default_seat_name;
static unsigned seats, outputs, devices, keyboards, keymap_success, accel_success;
static unsigned manage_cycles, render_cycles;

static struct {
    struct aqueous_seat_v1 *object;
    struct aqueous_xkb_binding_v1 *key;
    struct aqueous_pointer_binding_v1 *button;
    uint32_t name;
    bool enabled;
} policy_seats[4];
static bool enable_bindings;
static unsigned key_pressed, key_released, button_pressed, button_released;
static bool key_down, button_down;

static struct {
    struct connection connection;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct wl_keyboard *keyboard;
    struct wl_pointer *pointer;
    struct xdg_wm_base *wm;
    struct wl_surface *surface;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    int width, height;
    unsigned draws, closes, keyboard_enters, pointer_enters;
    unsigned key_pressed, key_released, button_pressed, button_released;
    bool key_down, button_down;
} application;

static struct {
    struct aqueous_window_v1 *object;
    struct aqueous_node_v1 *node;
    struct aqueous_decoration_v1 *above, *below;
    struct wl_surface *above_surface, *below_surface;
    char app_id[128], title[128];
    int width, height, requested_width, requested_height;
    bool live, close_requested;
} window;
static unsigned windows_announced, windows_closed;
static int target_width = 320, target_height = 240, target_x = 100, target_y = 100;

static struct {
    struct wl_buffer *buffer;
    void *pixels;
    uint32_t format, width, height, stride, flags;
    size_t size;
    bool ready;
} capture;

static void watch(void *proxy, struct connection *connection);
static void manage_window(void);
static void render_window(void);

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {.release = buffer_release};

static void draw(struct wl_shm *pool_manager, struct wl_surface *surface,
                 int width, int height, uint32_t color) {
    size_t size = (size_t)width * height * 4;
    int fd = memfd_create("protocol-pixels", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    for (size_t i = 0; i < size / 4; i++) pixels[i] = color;
    struct wl_shm_pool *pool = wl_shm_create_pool(pool_manager, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
}

static void app_configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(surface, serial);
    draw(application.shm, application.surface, application.width, application.height, 0xff0000ff);
    application.draws++;
}
static const struct xdg_surface_listener app_surface_listener = {.configure = app_configure};
static void app_dimensions(void *data, struct xdg_toplevel *top, int32_t width, int32_t height, struct wl_array *states) {
    (void)data; (void)top; (void)states;
    if (width > 0) application.width = width;
    if (height > 0) application.height = height;
}
static void app_close(void *data, struct xdg_toplevel *top) {
    (void)data;
    application.closes++;
    xdg_toplevel_destroy(top);
    xdg_surface_destroy(application.xdg);
    wl_surface_destroy(application.surface);
    application.top = NULL;
    application.xdg = NULL;
    application.surface = NULL;
}
/* Bind xdg_wm_base at v1 so these are all possible toplevel events. */
static const struct xdg_toplevel_listener app_top_listener = {
    .configure = app_dimensions, .close = app_close,
};
static void app_ping(void *data, struct xdg_wm_base *wm, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm, serial);
}
static const struct xdg_wm_base_listener app_wm_listener = {.ping = app_ping};

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
            for (unsigned i = 0; i < seats; i++) {
                if (policy_seats[i].enabled == enable_bindings) continue;
                if (enable_bindings) {
                    aqueous_xkb_binding_v1_enable(policy_seats[i].key);
                    aqueous_pointer_binding_v1_enable(policy_seats[i].button);
                } else {
                    aqueous_xkb_binding_v1_disable(policy_seats[i].key);
                    aqueous_pointer_binding_v1_disable(policy_seats[i].button);
                }
                policy_seats[i].enabled = enable_bindings;
            }
            manage_window();
            aqueous_window_manager_v1_manage_finish(object);
        } else if (!strcmp(message->name, "render_start")) {
            render_cycles++;
            render_window();
            aqueous_window_manager_v1_render_finish(object);
        } else if (!strcmp(message->name, "window")) {
            assert(!window.object);
            window.object = (void *)args[0].o;
            window.live = true;
            windows_announced++;
        } else if (!strcmp(message->name, "seat")) {
            struct aqueous_seat_v1 *seat = (void *)args[0].o;
            assert(seats < 4);
            policy_seats[seats].object = seat;
            policy_seats[seats].key = aqueous_xkb_bindings_v1_get_xkb_binding(bindings, seat, XKB_KEY_F12, 0);
            policy_seats[seats].button = aqueous_seat_v1_get_pointer_binding(seat, BTN_LEFT, 0);
            watch(policy_seats[seats].key, connection);
            watch(policy_seats[seats].button, connection);
            seats++;
            watch(aqueous_xkb_bindings_v1_get_seat(bindings, seat), connection);
            watch(aqueous_layer_shell_v1_get_seat(layer, seat), connection);
        } else if (!strcmp(message->name, "output")) {
            outputs++;
            watch(aqueous_layer_shell_v1_get_output(layer, (void *)args[0].o), connection);
        }
    } else if (!strcmp(type, "aqueous_seat_v1") && !strcmp(message->name, "wl_seat")) {
        for (unsigned i = 0; i < seats; i++) {
            if (policy_seats[i].object == object) policy_seats[i].name = args[0].u;
        }
    } else if (!strcmp(type, "aqueous_window_v1")) {
        assert(object == window.object);
        if (!strcmp(message->name, "app_id")) snprintf(window.app_id, sizeof(window.app_id), "%s", args[0].s ? args[0].s : "");
        else if (!strcmp(message->name, "title")) snprintf(window.title, sizeof(window.title), "%s", args[0].s ? args[0].s : "");
        else if (!strcmp(message->name, "dimensions")) {
            window.width = args[0].i;
            window.height = args[1].i;
        } else if (!strcmp(message->name, "closed")) {
            assert(window.live);
            window.live = false;
            windows_closed++;
        }
    } else if (!strcmp(type, "aqueous_xkb_binding_v1")) {
        if (!strcmp(message->name, "pressed")) {
            assert(!key_down);
            key_down = true;
            key_pressed++;
        } else if (!strcmp(message->name, "released")) {
            assert(key_down);
            key_down = false;
            key_released++;
        }
    } else if (!strcmp(type, "aqueous_pointer_binding_v1")) {
        if (!strcmp(message->name, "pressed")) {
            assert(!button_down);
            button_down = true;
            button_pressed++;
        } else if (!strcmp(message->name, "released")) {
            assert(button_down);
            button_down = false;
            button_released++;
        }
    } else if (!strcmp(type, "wl_seat") && !strcmp(message->name, "capabilities")) {
        assert(object == application.seat);
        if ((args[0].u & WL_SEAT_CAPABILITY_KEYBOARD) && !application.keyboard) {
            application.keyboard = wl_seat_get_keyboard(application.seat);
            watch(application.keyboard, connection);
        }
        if ((args[0].u & WL_SEAT_CAPABILITY_POINTER) && !application.pointer) {
            application.pointer = wl_seat_get_pointer(application.seat);
            watch(application.pointer, connection);
        }
    } else if (!strcmp(type, "wl_keyboard")) {
        if (!strcmp(message->name, "keymap")) close(args[1].h);
        else if (!strcmp(message->name, "enter")) application.keyboard_enters++;
        else if (!strcmp(message->name, "key")) {
            assert(args[2].u == KEY_F12);
            bool pressed = args[3].u == WL_KEYBOARD_KEY_STATE_PRESSED;
            assert(application.key_down != pressed);
            application.key_down = pressed;
            if (pressed) application.key_pressed++;
            else application.key_released++;
        }
    } else if (!strcmp(type, "wl_pointer")) {
        if (!strcmp(message->name, "enter")) application.pointer_enters++;
        else if (!strcmp(message->name, "button")) {
            assert(args[2].u == BTN_LEFT);
            bool pressed = args[3].u == WL_POINTER_BUTTON_STATE_PRESSED;
            assert(application.button_down != pressed);
            application.button_down = pressed;
            if (pressed) application.button_pressed++;
            else application.button_released++;
        }
    } else if (!strcmp(type, "zwlr_screencopy_frame_v1")) {
        if (!strcmp(message->name, "buffer")) {
            capture.format = args[0].u;
            capture.width = args[1].u;
            capture.height = args[2].u;
            capture.stride = args[3].u;
            capture.size = (size_t)capture.stride * capture.height;
            int fd = memfd_create("protocol-capture", MFD_CLOEXEC);
            assert(fd >= 0 && ftruncate(fd, (off_t)capture.size) == 0);
            capture.pixels = mmap(NULL, capture.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            assert(capture.pixels != MAP_FAILED);
            struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)capture.size);
            capture.buffer = wl_shm_pool_create_buffer(pool, 0, capture.width, capture.height, capture.stride, capture.format);
            wl_shm_pool_destroy(pool);
            close(fd);
            zwlr_screencopy_frame_v1_copy(object, capture.buffer);
        } else if (!strcmp(message->name, "flags")) capture.flags = args[0].u;
        else if (!strcmp(message->name, "ready")) capture.ready = true;
        else if (!strcmp(message->name, "failed")) assert(!"screencopy failed");
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

static void manage_window(void) {
    if (!window.live) return;
    if (!window.node) window.node = aqueous_window_v1_get_node(window.object);
    if (window.requested_width != target_width || window.requested_height != target_height) {
        aqueous_window_v1_propose_dimensions(window.object, target_width, target_height);
        window.requested_width = target_width;
        window.requested_height = target_height;
        aqueous_window_v1_use_ssd(window.object);
    }
    for (unsigned i = 0; i < seats; i++) {
        if (policy_seats[i].name == default_seat_name)
            aqueous_seat_v1_focus_window(policy_seats[i].object, window.object);
    }
    if (window.close_requested) {
        aqueous_window_v1_close(window.object);
        window.close_requested = false;
    }
}

static void render_window(void) {
    if (!window.live || !window.node || !window.width) return;
    aqueous_node_v1_set_position(window.node, target_x, target_y);
    aqueous_node_v1_place_top(window.node);
    if (window.above) return;
    window.above_surface = wl_compositor_create_surface(compositor);
    window.below_surface = wl_compositor_create_surface(compositor);
    window.above = aqueous_window_v1_get_decoration_above(window.object, window.above_surface);
    window.below = aqueous_window_v1_get_decoration_below(window.object, window.below_surface);
    aqueous_decoration_v1_set_offset(window.above, 20, 20);
    aqueous_decoration_v1_set_offset(window.below, -10, -10);
    aqueous_decoration_v1_sync_next_commit(window.above);
    aqueous_decoration_v1_sync_next_commit(window.below);
    draw(shm, window.above_surface, 40, 40, 0xff00ff00);
    draw(shm, window.below_surface, 340, 260, 0xffff0000);
}

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    struct connection *connection = data;
    assert(strncmp(interface, "river_", 6) != 0);
    if (!strcmp(interface, "xdg_toplevel_tag_manager_v1")) {
        assert(version == 1 && !connection->toplevel_tag);
        connection->toplevel_tag = true;
    }
    for (unsigned i = 0; i < 6; i++) {
        if (strcmp(interface, interfaces[i]->name)) continue;
        assert(!connection->globals[i] && version == versions[i]);
        connection->globals[i] = name;
    }
    if (connection == &application.connection) {
        if (!strcmp(interface, wl_compositor_interface.name))
            application.compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
        else if (!strcmp(interface, wl_shm_interface.name))
            application.shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
        else if (!strcmp(interface, xdg_wm_base_interface.name)) {
            application.wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
            xdg_wm_base_add_listener(application.wm, &app_wm_listener, NULL);
        } else if (!strcmp(interface, wl_seat_interface.name) && name == default_seat_name) {
            application.seat = wl_registry_bind(registry, name, &wl_seat_interface, 5);
            watch(application.seat, connection);
        }
        return;
    }
    /* Only the primary connection needs the standard helper interfaces. */
    if (!security && !strcmp(interface, wp_security_context_manager_v1_interface.name))
        security = wl_registry_bind(registry, name, &wp_security_context_manager_v1_interface, 1);
    if (!virtual_manager && !strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name))
        virtual_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    if (!wl_seat && !strcmp(interface, wl_seat_interface.name)) {
        wl_seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        default_seat_name = name;
    }
    if (!compositor && !strcmp(interface, wl_compositor_interface.name))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    if (!shm && !strcmp(interface, wl_shm_interface.name))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    if (!wl_output && !strcmp(interface, wl_output_interface.name))
        wl_output = wl_registry_bind(registry, name, &wl_output_interface, 1);
    if (!pointer_manager && !strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name))
        pointer_manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    if (!capture_manager && !strcmp(interface, zwlr_screencopy_manager_v1_interface.name))
        capture_manager = wl_registry_bind(registry, name, &zwlr_screencopy_manager_v1_interface, 1);
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
    assert(connection->toplevel_tag);
}
static void roundtrips(struct connection *connection) {
    for (unsigned i = 0; i < 8; i++) {
        assert(wl_display_roundtrip(connection->display) >= 0);
        /* The application uses a separate connection and must acknowledge its
         * configures while the external window manager handles transactions. */
        if (application.connection.display && connection != &application.connection)
            assert(wl_display_roundtrip(application.connection.display) >= 0);
    }
}
static void *bind_global(struct connection *connection, unsigned index) {
    void *proxy = wl_registry_bind(connection->registry, connection->globals[index], interfaces[index], versions[index]);
    watch(proxy, connection);
    return proxy;
}

static double monotonic_seconds(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return now.tv_sec + now.tv_nsec / 1e9;
}

#define WAIT(connection, condition) do { \
    double deadline = monotonic_seconds() + 5.0; \
    while (!(condition)) { \
        roundtrips(connection); \
        if (monotonic_seconds() >= deadline) { \
            fprintf(stderr, "timed out waiting for %s\n", #condition); \
            abort(); \
        } \
        struct timespec delay = {.tv_nsec = 1000000}; \
        nanosleep(&delay, NULL); \
    } \
} while (0)

static void cycle(struct connection *connection, struct aqueous_window_manager_v1 *manager) {
    unsigned before = manage_cycles;
    aqueous_window_manager_v1_manage_dirty(manager);
    WAIT(connection, manage_cycles > before);
    roundtrips(connection);
}

static void screenshot(struct connection *connection) {
    memset(&capture, 0, sizeof(capture));
    struct zwlr_screencopy_frame_v1 *frame = zwlr_screencopy_manager_v1_capture_output(capture_manager, 0, wl_output);
    watch(frame, connection);
    WAIT(connection, capture.ready);
    zwlr_screencopy_frame_v1_destroy(frame);
}

static uint32_t pixel(unsigned x, unsigned y) {
    assert(x < capture.width && y < capture.height);
    if (capture.flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) y = capture.height - y - 1;
    const uint32_t *row = (const uint32_t *)((const char *)capture.pixels + y * capture.stride);
    uint32_t value = row[x] & 0xffffff;
    switch (capture.format) {
    case WL_SHM_FORMAT_ARGB8888: case WL_SHM_FORMAT_XRGB8888: return value;
    case WL_SHM_FORMAT_ABGR8888: case WL_SHM_FORMAT_XBGR8888:
        return ((value & 0xff) << 16) | (value & 0xff00) | ((value >> 16) & 0xff);
    default: assert(!"unsupported capture format"); return 0;
    }
}

static void release_capture(void) {
    wl_buffer_destroy(capture.buffer);
    munmap(capture.pixels, capture.size);
}

static void expect_pixel(unsigned x, unsigned y, uint32_t expected) {
    uint32_t actual = pixel(x, y);
    if (actual != expected) {
        fprintf(stderr, "pixel (%u,%u): expected #%06x, got #%06x\n", x, y, expected, actual);
        abort();
    }
}

struct sample { unsigned x, y; uint32_t color; };

static void expect_scene(struct connection *connection, const struct sample *samples, size_t count) {
    /* Protocol acknowledgement can precede presentation and the end of a
     * cosmetic transition. Poll captured frames, with a bounded deadline. */
    double deadline = monotonic_seconds() + 5.0;
    for (;;) {
        screenshot(connection);
        bool matches = true;
        for (size_t i = 0; i < count; i++)
            matches &= pixel(samples[i].x, samples[i].y) == samples[i].color;
        if (!matches && monotonic_seconds() >= deadline) {
            for (size_t i = 0; i < count; i++)
                expect_pixel(samples[i].x, samples[i].y, samples[i].color);
        }
        release_capture();
        if (matches) return;
    }
}

static void test_window_and_bindings(struct connection *connection,
                                    struct aqueous_window_manager_v1 *manager,
                                    struct zwp_virtual_keyboard_v1 *keyboard) {
    assert(shm && wl_output && pointer_manager && capture_manager);
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointer_manager, wl_seat);
    roundtrips(connection);
    screenshot(connection);
    uint32_t background = pixel(600, 600);
    uint32_t output_width = capture.width, output_height = capture.height;
    release_capture();
    connect_client(&application.connection, NULL, false);
    assert(application.compositor && application.shm && application.wm && application.seat);
    application.width = target_width;
    application.height = target_height;
    application.surface = wl_compositor_create_surface(application.compositor);
    application.xdg = xdg_wm_base_get_xdg_surface(application.wm, application.surface);
    xdg_surface_add_listener(application.xdg, &app_surface_listener, NULL);
    application.top = xdg_surface_get_toplevel(application.xdg);
    xdg_toplevel_add_listener(application.top, &app_top_listener, NULL);
    xdg_toplevel_set_app_id(application.top, "org.aqueous.protocol-test");
    xdg_toplevel_set_title(application.top, "Protocol window");
    wl_surface_commit(application.surface);
    WAIT(connection, windows_announced == 1 && application.draws > 0 &&
         window.width == target_width && window.height == target_height &&
         application.keyboard_enters > 0 && window.above && window.below);
    assert(!strcmp(window.app_id, "org.aqueous.protocol-test"));
    assert(!strcmp(window.title, "Protocol window"));

    const struct sample mapped[] = {
        {95, 95, 0xff0000},   /* Below decoration extends past the window. */
        {200, 200, 0x0000ff}, /* Interior content obscures the below decoration. */
        {125, 125, 0x00ff00}, /* Above decoration obscures window content. */
    };
    expect_scene(connection, mapped, sizeof(mapped) / sizeof(mapped[0]));
    puts("PASS external window announcement, metadata, configure, node position, above/below decoration pixels");

    uint32_t timestamp = 1;
    zwlr_virtual_pointer_v1_motion_absolute(pointer, timestamp++, 200, 200, output_width, output_height);
    zwlr_virtual_pointer_v1_frame(pointer);
    WAIT(connection, application.pointer_enters > 0);
    zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);

    /* Alternate disabled/enabled twice. Events must arrive in order, once, at
     * exactly the intended recipient, and a disabled binding must pass input
     * through to the real application's wl_keyboard/wl_pointer. */
    for (unsigned phase = 0; phase < 4; phase++) {
        enable_bindings = phase % 2 != 0;
        cycle(connection, manager);
        unsigned kp = key_pressed, kr = key_released, bp = button_pressed, br = button_released;
        unsigned akp = application.key_pressed, akr = application.key_released;
        unsigned abp = application.button_pressed, abr = application.button_released;
        zwp_virtual_keyboard_v1_key(keyboard, timestamp++, KEY_F12, WL_KEYBOARD_KEY_STATE_PRESSED);
        WAIT(connection, enable_bindings ? key_pressed == kp + 1 : application.key_pressed == akp + 1);
        zwp_virtual_keyboard_v1_key(keyboard, timestamp++, KEY_F12, WL_KEYBOARD_KEY_STATE_RELEASED);
        WAIT(connection, enable_bindings ? key_released == kr + 1 : application.key_released == akr + 1);
        zwlr_virtual_pointer_v1_button(pointer, timestamp++, BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
        zwlr_virtual_pointer_v1_frame(pointer);
        WAIT(connection, enable_bindings ? button_pressed == bp + 1 : application.button_pressed == abp + 1);
        zwlr_virtual_pointer_v1_button(pointer, timestamp++, BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
        zwlr_virtual_pointer_v1_frame(pointer);
        WAIT(connection, enable_bindings ? button_released == br + 1 : application.button_released == abr + 1);
        roundtrips(connection);
        assert(key_pressed == kp + enable_bindings && key_released == kr + enable_bindings);
        assert(button_pressed == bp + enable_bindings && button_released == br + enable_bindings);
        assert(application.key_pressed == akp + !enable_bindings && application.key_released == akr + !enable_bindings);
        assert(application.button_pressed == abp + !enable_bindings && application.button_released == abr + !enable_bindings);
        assert(!key_down && !button_down);
        assert(!application.key_down && !application.button_down);
    }
    puts("PASS keyboard/pointer binding press-release order, single delivery, disable passthrough, re-enable");

    target_width = 400;
    target_height = 260;
    target_x = 160;
    target_y = 140;
    unsigned previous_draws = application.draws;
    xdg_toplevel_set_title(application.top, "Updated protocol window");
    xdg_toplevel_set_app_id(application.top, "org.aqueous.protocol-test.updated");
    cycle(connection, manager);
    WAIT(connection, application.draws > previous_draws && window.width == target_width &&
         window.height == target_height && !strcmp(window.title, "Updated protocol window") &&
         !strcmp(window.app_id, "org.aqueous.protocol-test.updated"));
    assert(application.width == target_width && application.height == target_height);
    const struct sample resized[] = {
        {155, 135, 0xff0000}, {260, 240, 0x0000ff}, {185, 165, 0x00ff00},
        {530, 370, 0x0000ff}, /* Newly resized content is visible. */
        {95, 95, background}, /* No decoration remains at its old position. */
    };
    expect_scene(connection, resized, sizeof(resized) / sizeof(resized[0]));
    puts("PASS window metadata updates, resize acknowledgement, move, decoration tracking");

    window.close_requested = true;
    cycle(connection, manager);
    WAIT(connection, application.closes == 1 && windows_closed == 1);
    assert(!application.top && !window.live);
    const struct sample closed[] = {
        {155, 135, background}, {260, 240, background}, {185, 165, background},
        {530, 370, background},
    };
    expect_scene(connection, closed, sizeof(closed) / sizeof(closed[0]));
    /* Closing makes the policy objects inert; their destruction must remain
     * valid after the application's surfaces have already been destroyed. */
    aqueous_decoration_v1_destroy(window.above);
    aqueous_decoration_v1_destroy(window.below);
    wl_surface_destroy(window.above_surface);
    wl_surface_destroy(window.below_surface);
    aqueous_node_v1_destroy(window.node);
    aqueous_window_v1_destroy(window.object);
    window.object = NULL;
    roundtrips(connection);
    wl_display_disconnect(application.connection.display);
    application.connection.display = NULL;
    zwlr_virtual_pointer_v1_destroy(pointer);
    puts("PASS policy close reaches application, closed event, decoration removal, inert-object cleanup");
}

int main(int argc, char **argv) {
    assert(argc == 2);
    setvbuf(stdout, NULL, _IOLBF, 0);
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
        test_window_and_bindings(&primary, manager, keyboard);
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
