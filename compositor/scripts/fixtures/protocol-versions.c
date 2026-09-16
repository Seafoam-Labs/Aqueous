// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell.h"
#include "decoration.h"
#include "text-input.h"
#include "tablet.h"
#include "dmabuf.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm;
static struct zxdg_decoration_manager_v1 *decorations;
static struct zwp_text_input_manager_v3 *text_manager;
static struct zwp_tablet_manager_v2 *tablet_manager;
static struct zwp_linux_dmabuf_v1 *dmabuf;
static uint32_t version;
static unsigned configures, decoration_configures;
static uint32_t decoration_mode;
static bool feedback_done, sampling_seen, failed;
static dev_t main_device;

static void global(void *data, struct wl_registry *registry, uint32_t id,
                   const char *interface, uint32_t advertised) {
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
    if (!strcmp(interface, "wl_seat")) seat = wl_registry_bind(registry, id, &wl_seat_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1);
    if (!strcmp(interface, "zxdg_decoration_manager_v1")) {
        assert(advertised == 2);
        decorations = wl_registry_bind(registry, id, &zxdg_decoration_manager_v1_interface, version);
    }
    if (!strcmp(interface, "zwp_text_input_manager_v3")) {
        assert(advertised == 2);
        text_manager = wl_registry_bind(registry, id, &zwp_text_input_manager_v3_interface, version);
    }
    if (!strcmp(interface, "zwp_tablet_manager_v2")) {
        assert(advertised == 2);
        tablet_manager = wl_registry_bind(registry, id, &zwp_tablet_manager_v2_interface, version);
    }
    if (!strcmp(interface, "zwp_linux_dmabuf_v1")) {
        assert(advertised == 6);
        dmabuf = wl_registry_bind(registry, id, &zwp_linux_dmabuf_v1_interface, version == 1 ? 5 : 6);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {global, removed};
static void configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    xdg_surface_ack_configure(surface, serial); configures++;
}
static const struct xdg_surface_listener surface_listener = {configure};
static void decoration_configure(void *data, struct zxdg_toplevel_decoration_v1 *object, uint32_t mode) {
    decoration_configures++; decoration_mode = mode;
}
static const struct zxdg_toplevel_decoration_v1_listener decoration_listener = {decoration_configure};
static void done(void *data, struct zwp_linux_dmabuf_feedback_v1 *object) { feedback_done = true; }
static void table(void *data, struct zwp_linux_dmabuf_feedback_v1 *object, int32_t fd, uint32_t size) { close(fd); }
static void device(void *data, struct zwp_linux_dmabuf_feedback_v1 *object, struct wl_array *array) {
    assert(array->size == sizeof(main_device)); memcpy(&main_device, array->data, sizeof(main_device));
}
static void tranche_done(void *data, struct zwp_linux_dmabuf_feedback_v1 *object) {}
static void target(void *data, struct zwp_linux_dmabuf_feedback_v1 *object, struct wl_array *array) {}
static void formats(void *data, struct zwp_linux_dmabuf_feedback_v1 *object, struct wl_array *array) {}
static void flags(void *data, struct zwp_linux_dmabuf_feedback_v1 *object, uint32_t value) {
    if (version == 2) assert(value != 0);
    else assert(!(value & ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SAMPLING));
    sampling_seen |= (value & ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SAMPLING) != 0;
}
static const struct zwp_linux_dmabuf_feedback_v1_listener feedback_listener = {
    done, table, device, tranche_done, target, formats, flags,
};
static void created(void *data, struct zwp_linux_buffer_params_v1 *params, struct wl_buffer *buffer) { assert(false); }
static void import_failed(void *data, struct zwp_linux_buffer_params_v1 *params) { failed = true; }
static const struct zwp_linux_buffer_params_v1_listener params_listener = {created, import_failed};

static void roundtrip(void) { assert(wl_display_roundtrip(display) >= 0); }
static void expect_error(const struct wl_interface *expected, uint32_t code) {
    assert(wl_display_roundtrip(display) == -1 && wl_display_get_error(display) == EPROTO);
    const struct wl_interface *interface;
    assert(wl_display_get_protocol_error(display, &interface, NULL) == code);
    assert(interface && !strcmp(interface->name, expected->name));
}
static void draw(struct wl_surface *surface) {
    int fd = memfd_create("version-test", MFD_CLOEXEC); assert(fd >= 0 && ftruncate(fd, 64 * 64 * 4) == 0);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, 64 * 64 * 4);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, 64, 64, 64 * 4, WL_SHM_FORMAT_XRGB8888);
    wl_surface_attach(surface, buffer, 0, 0); wl_surface_damage(surface, 0, 0, 64, 64);
    wl_surface_commit(surface); wl_shm_pool_destroy(pool); close(fd);
}
static struct zxdg_toplevel_decoration_v1 *decorate(struct xdg_toplevel *top) {
    struct zxdg_toplevel_decoration_v1 *decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decorations, top);
    zxdg_toplevel_decoration_v1_add_listener(decoration, &decoration_listener, NULL);
    zxdg_toplevel_decoration_v1_set_mode(decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    return decoration;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    bool legacy = !strcmp(argv[1], "legacy"), mapped_error = !strcmp(argv[1], "mapped-v1-error");
    version = legacy || mapped_error ? 1 : 2;
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL); roundtrip();
    assert(compositor && shm && seat && wm && decorations && text_manager && tablet_manager);
    if (!strcmp(argv[2], "vulkan")) assert(dmabuf);
    struct zwp_tablet_seat_v2 *tablet_seat = zwp_tablet_manager_v2_get_tablet_seat(tablet_manager, seat);
    roundtrip(); zwp_tablet_seat_v2_destroy(tablet_seat);
    struct zwp_text_input_v3 *input = zwp_text_input_manager_v3_get_text_input(text_manager, seat);
    zwp_text_input_v3_enable(input);
    if (version == 2) {
        uint32_t actions[] = {ZWP_TEXT_INPUT_V3_ACTION_SUBMIT, ZWP_TEXT_INPUT_V3_ACTION_SUBMIT};
        bool invalid = !strcmp(argv[1], "invalid-action");
        struct wl_array array = {.size = invalid ? sizeof(actions) : sizeof(actions[0]), .data = actions};
        zwp_text_input_v3_set_available_actions(input, &array);
        if (invalid) {
            expect_error(&zwp_text_input_v3_interface, ZWP_TEXT_INPUT_V3_ERROR_INVALID_ACTION);
            goto success;
        }
        zwp_text_input_v3_set_content_type(input, ZWP_TEXT_INPUT_V3_CONTENT_HINT_PREEDIT_SHOWN, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
        zwp_text_input_v3_commit(input);
        zwp_text_input_v3_show_input_panel(input); zwp_text_input_v3_hide_input_panel(input);
    }
    zwp_text_input_v3_commit(input); roundtrip(); zwp_text_input_v3_destroy(input);
    if (dmabuf) {
        struct zwp_linux_dmabuf_feedback_v1 *feedback = zwp_linux_dmabuf_v1_get_default_feedback(dmabuf);
        zwp_linux_dmabuf_feedback_v1_add_listener(feedback, &feedback_listener, NULL); roundtrip();
        assert(feedback_done && (version == 1 || sampling_seen));
        zwp_linux_dmabuf_feedback_v1_destroy(feedback);
        if (version == 2) {
            struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(dmabuf);
            zwp_linux_buffer_params_v1_add_listener(params, &params_listener, NULL);
            struct wl_array array = {.size = sizeof(main_device), .data = &main_device};
            if (!strcmp(argv[1], "invalid-device")) {
                array.size--;
                zwp_linux_buffer_params_v1_set_sampling_device(params, &array);
                expect_error(&zwp_linux_buffer_params_v1_interface, ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_INVALID_DEV_T_SIZE);
                goto success;
            }
            zwp_linux_buffer_params_v1_set_sampling_device(params, &array);
            dev_t absent = 0; array.data = &absent;
            zwp_linux_buffer_params_v1_set_sampling_device(params, &array);
            int fd = memfd_create("invalid-dmabuf", MFD_CLOEXEC); assert(fd >= 0 && ftruncate(fd, 4096) == 0);
            zwp_linux_buffer_params_v1_add(params, fd, 0, 0, 4, 0, 0); close(fd);
            zwp_linux_buffer_params_v1_create(params, 1, 1, 0x34325241, 0); roundtrip();
            assert(failed); zwp_linux_buffer_params_v1_destroy(params);
        }
    }
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    struct zxdg_toplevel_decoration_v1 *decoration = legacy ? decorate(top) : NULL;
    wl_surface_commit(surface);
    while (!configures) roundtrip();
    draw(surface); roundtrip();
    if (!legacy) {
        decoration = decorate(top);
        if (mapped_error) {
            expect_error(&zxdg_decoration_manager_v1_interface, ZXDG_TOPLEVEL_DECORATION_V1_ERROR_UNCONFIGURED_BUFFER);
            goto success;
        }
    }
    while (!decoration_configures) roundtrip();
    assert(decoration_mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE ||
           decoration_mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    wl_surface_commit(surface); roundtrip();
    if (!legacy) {
        // Recreate both without a commit and after a commit. Each new object
        // needs an initial configure, even when it retains the previous mode.
        for (unsigned commit = 0; commit < 2; commit++) {
            zxdg_toplevel_decoration_v1_destroy(decoration);
            if (commit) { wl_surface_commit(surface); roundtrip(); }
            unsigned previous = decoration_configures;
            decoration = decorate(top);
            while (decoration_configures == previous) roundtrip();
            wl_surface_commit(surface); roundtrip();
        }
    }
    zxdg_toplevel_decoration_v1_destroy(decoration);
    xdg_toplevel_destroy(top); xdg_surface_destroy(xdg); wl_surface_destroy(surface); roundtrip();
success:
    wl_display_disconnect(display);
    printf("PASS protocol versions: %s (%s)\n", argv[1], argv[2]);
}
