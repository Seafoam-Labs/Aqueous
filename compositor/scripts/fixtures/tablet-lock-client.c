// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
// Private test lock: blank outputs, then unlock when the marker file exists.
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include "ext-session-lock-v1-client-protocol.h"

static struct ext_session_lock_manager_v1 *manager;
static bool locked;
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "ext_session_lock_manager_v1"))
        manager = wl_registry_bind(registry, name, &ext_session_lock_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static void lock_ready(void *data, struct ext_session_lock_v1 *lock) {
    (void)data; (void)lock;
    locked = true;
    puts("{\"event\":\"locked\"}"); fflush(stdout);
}
static void lock_finished(void *data, struct ext_session_lock_v1 *lock) {
    (void)data; (void)lock;
    assert(!"lock rejected");
}
int main(int argc, char **argv) {
    assert(argc == 2);
    struct wl_display *display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    static const struct wl_registry_listener globals = {.global = global, .global_remove = removed};
    wl_registry_add_listener(registry, &globals, NULL);
    assert(wl_display_roundtrip(display) >= 0 && manager);
    struct ext_session_lock_v1 *lock = ext_session_lock_manager_v1_lock(manager);
    static const struct ext_session_lock_v1_listener listener = {.locked = lock_ready, .finished = lock_finished};
    ext_session_lock_v1_add_listener(lock, &listener, NULL);
    while (!locked || access(argv[1], F_OK) != 0) {
        assert(wl_display_dispatch_pending(display) >= 0);
        wl_display_flush(display);
        struct pollfd fd = {.fd = wl_display_get_fd(display), .events = POLLIN};
        if (poll(&fd, 1, 20) > 0) assert(wl_display_dispatch(display) >= 0);
    }
    ext_session_lock_v1_unlock_and_destroy(lock);
    assert(wl_display_roundtrip(display) >= 0);
    wl_display_disconnect(display);
    return 0;
}
