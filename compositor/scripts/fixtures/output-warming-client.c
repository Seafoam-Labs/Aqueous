// SPDX-License-Identifier: GPL-3.0-only
#define _POSIX_C_SOURCE 200809L
#include "aqueous-output-warming-v1-client-protocol.h"
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
static struct wl_display *display;
static struct aqueous_output_warming_manager_v1 *manager;
static struct wl_output *outputs[16];
static struct aqueous_output_warming_output_v1 *observations[16];
static uint64_t generations[16];
static size_t count;
static struct aqueous_output_warming_lease_v1 *lease;
static uint32_t next_id;
static void state(void *data, struct aqueous_output_warming_output_v1 *o, uint32_t sh, uint32_t sl,
                  uint32_t ih, uint32_t il, uint32_t gh, uint32_t gl, uint32_t rh, uint32_t rl,
                  uint32_t reason, uint32_t encoding, uint32_t baseline, uint32_t qualification,
                  uint32_t owner, uint32_t committed, uint32_t pending) {
    (void)o;
    (void)sh;
    (void)sl;
    (void)ih;
    (void)il;
    (void)rh;
    (void)rl;
    size_t index = (size_t)data;
    generations[index] = ((uint64_t)gh << 32) | gl;
    printf("{\"event\":\"state\",\"output\":%zu,\"generation\":%llu,\"reason\":%"
           "u,\"encoding\":%u,\"baseline\":%u,\"qualification\":%u,\"owner\":%u,"
           "\"committed\":%u,\"pending\":%u}\n",
           index, (unsigned long long)generations[index], reason, encoding, baseline, qualification,
           owner, committed, pending);
}
static void done(void *data, struct aqueous_output_warming_output_v1 *o) {
    (void)data;
    (void)o;
    fflush(stdout);
}
static const struct aqueous_output_warming_output_v1_listener output_listener = {.state = state,
                                                                                 .done = done};
static void acquired(void *data, struct aqueous_output_warming_lease_v1 *l, uint32_t hi,
                     uint32_t lo) {
    (void)data;
    (void)l;
    (void)hi;
    (void)lo;
    puts("{\"event\":\"acquired\"}");
    fflush(stdout);
}
static void denied(void *data, struct aqueous_output_warming_lease_v1 *l, uint32_t reason) {
    (void)data;
    (void)l;
    printf("{\"event\":\"denied\",\"reason\":%u}\n", reason);
    fflush(stdout);
}
static void revoked(void *data, struct aqueous_output_warming_lease_v1 *l, uint32_t reason,
                    uint32_t hi, uint32_t lo) {
    (void)data;
    (void)l;
    (void)hi;
    (void)lo;
    printf("{\"event\":\"revoked\",\"reason\":%u}\n", reason);
    fflush(stdout);
}
static void result(void *data, struct aqueous_output_warming_lease_v1 *l, uint32_t id,
                   uint32_t status, uint32_t reason, uint32_t hi, uint32_t lo, uint32_t seq,
                   uint32_t kelvin) {
    (void)data;
    (void)l;
    (void)hi;
    (void)lo;
    printf("{\"event\":\"result\",\"id\":%u,\"status\":%u,\"reason\":%u,"
           "\"sequence\":%u,\"kelvin\":%u}\n",
           id, status, reason, seq, kelvin);
    fflush(stdout);
}
static const struct aqueous_output_warming_lease_v1_listener lease_listener = {
    .acquired = acquired, .denied = denied, .revoked = revoked, .result = result};
static void geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                     int32_t sub, const char *make, const char *model, int32_t transform) {
    (void)d;
    (void)o;
    (void)x;
    (void)y;
    (void)pw;
    (void)ph;
    (void)sub;
    (void)make;
    (void)model;
    (void)transform;
}
static void mode(void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h,
                 int32_t refresh) {
    (void)d;
    (void)o;
    (void)flags;
    (void)w;
    (void)h;
    (void)refresh;
}
static void output_done(void *d, struct wl_output *o) {
    (void)d;
    (void)o;
}
static void scale(void *d, struct wl_output *o, int32_t factor) {
    (void)d;
    (void)o;
    (void)factor;
}
static void name(void *d, struct wl_output *o, const char *value) {
    (void)o;
    printf("{\"event\":\"name\",\"output\":%zu,\"name\":\"%s\"}\n", (size_t)d, value);
    fflush(stdout);
}
static void description(void *d, struct wl_output *o, const char *value) {
    (void)d;
    (void)o;
    (void)value;
}
static const struct wl_output_listener wl_output_listener = {geometry, mode, output_done,
                                                             scale,    name, description};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface,
                   uint32_t version) {
    (void)data;
    if (!strcmp(interface, "aqueous_output_warming_manager_v1"))
        manager = wl_registry_bind(registry, name, &aqueous_output_warming_manager_v1_interface, 1);
    if (!strcmp(interface, "wl_output") && count < 16) {
        outputs[count] =
            wl_registry_bind(registry, name, &wl_output_interface, version < 4 ? version : 4);
        wl_output_add_listener(outputs[count], &wl_output_listener, (void *)count);
        count++;
    }
}
static void removed(void *data, struct wl_registry *r, uint32_t name) {
    (void)data;
    (void)r;
    (void)name;
}
static const struct wl_registry_listener registry_listener = {global, removed};
int main(void) {
    setvbuf(stdin, NULL, _IONBF, 0);
    display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(manager && count);
    for (size_t i = 0; i < count; i++) {
        observations[i] = aqueous_output_warming_manager_v1_get_output(manager, outputs[i]);
        aqueous_output_warming_output_v1_add_listener(observations[i], &output_listener, (void *)i);
    }
    assert(wl_display_roundtrip(display) >= 0);
    puts("{\"event\":\"ready\"}");
    fflush(stdout);
    size_t target = 0;
    for (;;) {
        while (wl_display_prepare_read(display) != 0)
            if (wl_display_dispatch_pending(display) < 0)
                return 1;
        wl_display_flush(display);
        struct pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) {
            wl_display_cancel_read(display);
            return 1;
        }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(display) < 0)
                return 1;
        } else
            wl_display_cancel_read(display);
        if (wl_display_dispatch_pending(display) < 0)
            return 1;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char line[128];
            if (!fgets(line, sizeof(line), stdin))
                break;
            unsigned value;
            if (sscanf(line, "output %u", &value) == 1) {
                assert(value < count);
                target = value;
            } else if (!strncmp(line, "acquire", 7)) {
                if (lease)
                    aqueous_output_warming_lease_v1_destroy(lease);
                lease = aqueous_output_warming_output_v1_acquire(
                    observations[target], generations[target] >> 32, generations[target]);
                next_id = 0;
                aqueous_output_warming_lease_v1_add_listener(lease, &lease_listener, NULL);
            } else if (sscanf(line, "set %u", &value) == 1) {
                assert(lease);
                aqueous_output_warming_lease_v1_set(lease, generations[target] >> 32,
                                                    generations[target], ++next_id, value);
            } else if (!strncmp(line, "release", 7)) {
                assert(lease);
                aqueous_output_warming_lease_v1_release(lease, ++next_id);
            } else if (!strncmp(line, "quit", 4))
                break;
            else if (!strncmp(line, "drop", 4)) {
                if (lease)
                    aqueous_output_warming_lease_v1_destroy(lease);
                lease = NULL;
            } else
                assert(false);
            wl_display_flush(display);
        }
    }
    if (lease)
        aqueous_output_warming_lease_v1_destroy(lease);
    for (size_t i = 0; i < count; i++) {
        aqueous_output_warming_output_v1_destroy(observations[i]);
        wl_output_destroy(outputs[i]);
    }
    aqueous_output_warming_manager_v1_destroy(manager);
    wl_registry_destroy(registry);
    wl_display_flush(display);
    wl_display_disconnect(display);
}
