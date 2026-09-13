// SPDX-License-Identifier: GPL-3.0-only
// Real protocol/cache tests. clock_gettime is interposed only for wlroots:
// the event loop retains its real clock and timerfd scheduling.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wlr/backend/headless.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_fifo_v1.h>
#include <wlr/types/wlr_commit_timing_v1.h>
#include "commit-timing-v1-client-protocol.h"
#include "fifo-v1-client-protocol.h"

static struct wl_display *server, *client;
static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wp_commit_timing_manager_v1 *manager;
static struct wp_fifo_manager_v1 *fifo;
static struct wlr_fifo_manager_v1 *fifo_server;
static struct wl_listener new_surface;
static uint64_t fake_ns = 1000000000000ULL;
static unsigned log_ids[256], log_count;
static struct tracked {
    struct wlr_surface *surface;
    struct wl_surface *proxy;
    struct wp_commit_timer_v1 *timer;
    struct wl_listener commit, destroy;
    unsigned count, id;
} tracked[16];
static unsigned surface_count;
static bool bypass;
static struct wlr_surface *destroy_on_commit;
static unsigned destroy_trigger;

int clock_gettime(clockid_t id, struct timespec *ts) {
    static int (*real_clock)(clockid_t, struct timespec *);
    if (!real_clock) real_clock = dlsym(RTLD_NEXT, "clock_gettime");
    Dl_info info = {0};
    if (id == CLOCK_MONOTONIC && dladdr(__builtin_return_address(0), &info) &&
            info.dli_fname && strstr(info.dli_fname, "libwlroots")) {
        *ts = (struct timespec){.tv_sec = fake_ns / 1000000000, .tv_nsec = fake_ns % 1000000000};
        return 0;
    }
    return real_clock(id, ts);
}
static void committed(struct wl_listener *listener, void *data) {
    struct tracked *s = wl_container_of(listener, s, commit);
    s->count++;
    assert(log_count < 256);
    log_ids[log_count++] = s->id;
    if (destroy_on_commit && s->id == destroy_trigger) {
        struct wlr_surface *target = destroy_on_commit;
        destroy_on_commit = NULL;
        wl_resource_destroy(target->resource);
    }
}
static void destroyed(struct wl_listener *listener, void *data) {
    struct tracked *s = wl_container_of(listener, s, destroy);
    s->surface = NULL;
    wl_list_remove(&s->commit.link); wl_list_remove(&s->destroy.link);
}
static void new_notify(struct wl_listener *listener, void *data) {
    assert(surface_count < 16);
    struct tracked *s = &tracked[surface_count];
    s->id = surface_count++;
    s->surface = data;
    s->commit.notify = committed; s->destroy.notify = destroyed;
    wl_signal_add(&s->surface->events.commit, &s->commit);
    wl_signal_add(&s->surface->events.destroy, &s->destroy);
}
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    if (!strcmp(name, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(name, "wl_subcompositor")) subcompositor = wl_registry_bind(registry, id, &wl_subcompositor_interface, 1);
    if (!strcmp(name, "wp_commit_timing_manager_v1")) {
        assert(version == 1);
        manager = wl_registry_bind(registry, id, &wp_commit_timing_manager_v1_interface, 1);
    }
    if (!strcmp(name, "wp_fifo_manager_v1")) fifo = wl_registry_bind(registry, id, &wp_fifo_manager_v1_interface, 1);
}
static void removed(void *d, struct wl_registry *r, uint32_t id) {}
static const struct wl_registry_listener registry_listener = {global, removed};
static void done(void *data, struct wl_callback *cb, uint32_t serial) {
    *(bool *)data = true; wl_callback_destroy(cb);
}
static const struct wl_callback_listener callback_listener = {done};
static bool sync_client(void) {
    bool done = false;
    struct wl_callback *cb = wl_display_sync(client);
    wl_callback_add_listener(cb, &callback_listener, &done);
    for (unsigned i = 0; i < 100 && !done; i++) {
        if (wl_display_flush(client) < 0) goto failed;
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        wl_display_flush_clients(server);
        struct pollfd fd = {wl_display_get_fd(client), POLLIN, 0};
        if (poll(&fd, 1, 10) > 0 && wl_display_dispatch(client) < 0) goto failed;
    }
    assert(done);
    return true;
failed:
    if (!done) wl_callback_destroy(cb);
    return false;
}
static struct tracked *create_surface(void) {
    unsigned index = surface_count;
    struct wl_surface *s = wl_compositor_create_surface(compositor);
    assert(sync_client());
    tracked[index].proxy = s;
    tracked[index].timer = wp_commit_timing_manager_v1_get_timer(manager, s);
    assert(sync_client());
    return &tracked[index];
}
static void timestamp(struct tracked *s, uint64_t ns) {
    if (bypass) return;
    uint64_t sec = ns / 1000000000;
    wp_commit_timer_v1_set_timestamp(s->timer, sec >> 32, sec, ns % 1000000000);
}
static void commit(struct tracked *s) { wl_surface_commit(s->proxy); assert(sync_client()); }
// A zero-time commit schedules manager reevaluation without moving real time.
static void advance(struct tracked *tick, uint64_t ns) {
    fake_ns = ns;
    timestamp(tick, 0); commit(tick);
    assert(sync_client());
}
static void latch(struct wlr_output *output) {
    wlr_fifo_manager_v1_prepare(fifo_server, output);
    output->commit_seq++;
    wlr_fifo_manager_v1_finish(fifo_server, output, true);
    struct wlr_output_event_present event = {.commit_seq = output->commit_seq, .presented = true};
    wlr_fifo_manager_v1_present(fifo_server, output, &event);
    assert(sync_client());
}
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "queue";
    bypass = !strcmp(mode, "bypass");
    server = wl_display_create(); assert(server);
    struct wlr_compositor *wc = wlr_compositor_create(server, 6, NULL); assert(wc);
    assert(wlr_subcompositor_create(server));
    assert(wlr_commit_timing_manager_v1_create(server));
    fifo_server = wlr_fifo_manager_v1_create(server); assert(fifo_server);
    new_surface.notify = new_notify; wl_signal_add(&wc->events.new_surface, &new_surface);
    struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(server)); assert(backend);
    struct wlr_output *output = wlr_headless_add_output(backend, 100, 100); assert(output);
    output->enabled = true;
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(wl_client_create(server, pair[0]));
    client = wl_display_connect_to_fd(pair[1]); assert(client);
    struct wl_registry *registry = wl_display_get_registry(client);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(sync_client()); assert(sync_client());
    assert(manager && compositor && subcompositor && fifo);
    struct tracked *s = create_surface(), *tick = create_surface();
    const uint64_t start = fake_ns;
    uint32_t expected_error = 0;
    struct wp_commit_timer_v1 *duplicate = NULL;
    const struct wl_interface *expected_interface = &wp_commit_timer_v1_interface;
    if (!strcmp(mode, "duplicate")) {
        duplicate = wp_commit_timing_manager_v1_get_timer(manager, s->proxy);
        expected_interface = &wp_commit_timing_manager_v1_interface;
        goto protocol_error;
    } else if (!strcmp(mode, "invalid")) {
        wp_commit_timer_v1_set_timestamp(s->timer, 0, 0, 1000000000);
        goto protocol_error;
    } else if (!strcmp(mode, "timestamp-exists") || !strcmp(mode, "recreate-pending")) {
        timestamp(s, start + 1000000000);
        if (!strcmp(mode, "recreate-pending")) {
            wp_commit_timer_v1_destroy(s->timer);
            s->timer = wp_commit_timing_manager_v1_get_timer(manager, s->proxy);
        }
        timestamp(s, 0); expected_error = 1;
        goto protocol_error;
    } else if (!strcmp(mode, "surface-destroyed")) {
        wl_surface_destroy(s->proxy); assert(sync_client());
        timestamp(s, 0); expected_error = 2;
        goto protocol_error;
    } else if (!strcmp(mode, "many")) {
        struct tracked *surfaces[12];
        for (unsigned i = 0; i < 12; i++) {
            surfaces[i] = create_surface();
            timestamp(surfaces[i], start + 2000000000); commit(surfaces[i]);
            timestamp(surfaces[i], start + 1000000000); commit(surfaces[i]);
            commit(surfaces[i]);
        }
        advance(tick, start + 1000000000);
        for (unsigned i = 0; i < 12; i++) assert(surfaces[i]->count == 0);
        advance(tick, start + 2000000000);
        for (unsigned i = 0; i < 12; i++) assert(surfaces[i]->count == 3);
    } else if (!strcmp(mode, "timer")) {
        timestamp(s, start + 1000000); commit(s); assert(s->count == 0);
        // Trigger an early real timer callback with the presentation clock held.
        usleep(3000); assert(sync_client()); assert(s->count == 0);
        fake_ns = start + 1000000;
        usleep(3000); assert(sync_client()); assert(s->count == 1);
        // An expired deadline behind another lock does not poll forever.
        uint32_t lock = wlr_surface_lock_pending(s->surface);
        timestamp(s, fake_ns + 1000000); commit(s);
        fake_ns += 1000000; usleep(3000); assert(sync_client());
        assert(s->count == 1);
        wlr_surface_unlock_cached(s->surface, lock); assert(sync_client());
        assert(s->count == 2);
    } else if (!strcmp(mode, "subsurface")) {
        struct tracked *child = create_surface(), *grandchild = create_surface();
        struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, child->proxy, s->proxy);
        struct wl_subsurface *grand = wl_subcompositor_get_subsurface(subcompositor, grandchild->proxy, child->proxy);
        timestamp(grandchild, start + 2000000000); commit(grandchild);
        commit(child); commit(s);
        assert(s->count == 0 && child->count == 0 && grandchild->count == 0);
        // This child update belongs to a later parent transaction.
        timestamp(child, start + 4000000000); commit(child); commit(s);
        advance(tick, start + 2000000000);
        assert(s->count == 1 && child->count == 1 && grandchild->count == 1);
        unsigned n = log_count;
        advance(tick, start + 4000000000);
        assert(s->count == 2 && child->count == 2);
        assert(log_ids[n + 1] == child->id && log_ids[n + 2] == s->id);
        timestamp(s, start + 6000000000); commit(child); commit(s);
        assert(child->count == 2 && s->count == 2);
        advance(tick, start + 6000000000);
        assert(child->count == 3 && s->count == 3);
        // Independent child lock keeps the entire transaction atomic.
        uint32_t lock = wlr_surface_lock_pending(child->surface);
        commit(child); commit(s); assert(s->count == 3);
        wlr_surface_unlock_cached(child->surface, lock); assert(sync_client());
        assert(child->count == 4 && s->count == 4);
        timestamp(child, start + 8000000000); commit(child); commit(s);
        wl_subsurface_set_desync(sub); assert(sync_client());
        assert(s->count == 5 && child->count == 4);
        advance(tick, start + 8000000000); assert(child->count == 5);
        wl_subsurface_destroy(grand); wl_subsurface_destroy(sub); assert(sync_client());
    } else if (!strcmp(mode, "reentry")) {
        struct tracked *other = create_surface();
        timestamp(s, start + 1000000000); commit(s);
        timestamp(other, start + 1000000000); commit(other);
        destroy_trigger = other->id; destroy_on_commit = s->surface;
        advance(tick, start + 1000000000);
        assert(!s->surface && other->count == 1);
        struct tracked *parent = create_surface(), *child = create_surface();
        struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, child->proxy, parent->proxy);
        timestamp(child, start + 2000000000); commit(child); commit(parent);
        destroy_trigger = child->id; destroy_on_commit = parent->surface;
        advance(tick, start + 2000000000);
        assert(!parent->surface && child->count == 1);
        wl_subsurface_destroy(sub);
    } else if (!strcmp(mode, "parent-destroy")) {
        struct tracked *child = create_surface();
        struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, child->proxy, s->proxy);
        timestamp(child, start + 1000000000); commit(child); commit(s);
        wl_surface_destroy(s->proxy); assert(sync_client());
        assert(child->count == 0);
        advance(tick, start + 1000000000); assert(child->count == 1);
        wl_subsurface_destroy(sub);
    } else if (!strcmp(mode, "waits")) {
        struct wp_fifo_v1 *f = wp_fifo_manager_v1_get_fifo(fifo, s->proxy);
        wlr_surface_send_enter(s->surface, output);
        // Exercise all six completion orders of time, FIFO, and a cache lock.
        const unsigned orders[6][3] = {{0,1,2},{0,2,1},{1,0,2},{1,2,0},{2,0,1},{2,1,0}};
        for (unsigned i = 0; i < 6; i++) {
            wp_fifo_v1_set_barrier(f); commit(s);
            unsigned count = s->count;
            uint32_t lock = wlr_surface_lock_pending(s->surface);
            wp_fifo_v1_wait_barrier(f); timestamp(s, fake_ns + 1000000000); commit(s);
            for (unsigned j = 0; j < 3; j++) {
                switch (orders[i][j]) {
                case 0: advance(tick, fake_ns + 1000000000); break;
                case 1: latch(output); break;
                case 2: wlr_surface_unlock_cached(s->surface, lock); assert(sync_client()); break;
                }
                assert(s->count == count + (j == 2));
            }
        }
        wp_fifo_v1_destroy(f);
    } else if (!strcmp(mode, "lifetime")) {
        timestamp(s, start + 1000000000);
        wp_commit_timer_v1_destroy(s->timer);
        s->timer = wp_commit_timing_manager_v1_get_timer(manager, s->proxy);
        commit(s); assert(s->count == 0);
        wp_commit_timer_v1_destroy(s->timer);
        advance(tick, start + 1000000000); assert(s->count == 1);
        s->timer = wp_commit_timing_manager_v1_get_timer(manager, s->proxy);
        wp_commit_timing_manager_v1_destroy(manager);
        timestamp(s, start + 2000000000); commit(s); assert(s->count == 1);
        advance(tick, start + 2000000000); assert(s->count == 2);
        wp_commit_timer_v1_set_timestamp(s->timer, UINT32_MAX, UINT32_MAX, 999999999);
        commit(s); assert(s->count == 2);
        timestamp(s, 0); // Pending state and a far-future queued state at teardown.
        wl_surface_destroy(s->proxy); assert(sync_client());
        wp_commit_timer_v1_destroy(s->timer);
    } else {
        timestamp(s, start + 2000000000); commit(s);
        commit(s);
        timestamp(s, start + 1000000000); commit(s);
        assert(s->count == 0); // Negative control must fail here.
        advance(tick, start + 1999999999); assert(s->count == 0);
        advance(tick, start + 2000000000); assert(s->count == 3);
        commit(s); assert(s->count == 4);
        timestamp(s, 0); commit(s); assert(s->count == 5);
        wp_commit_timer_v1_set_timestamp(s->timer, 0, 0, 999999999); commit(s);
        assert(s->count == 6);
    }
    goto cleanup;
protocol_error:
    assert(!sync_client());
    const struct wl_interface *interface;
    uint32_t id;
    assert(wl_display_get_protocol_error(client, &interface, &id) == expected_error);
    assert(interface && !strcmp(interface->name, expected_interface->name));
cleanup:
    if (duplicate) wl_proxy_destroy((struct wl_proxy *)duplicate);
    wl_registry_destroy(registry);
    wl_display_disconnect(client); wl_display_destroy_clients(server);
    wl_list_remove(&new_surface.link);
    wlr_backend_destroy(backend); wl_display_destroy(server);
    printf("PASS %s\n", mode);
    return 0;
}
