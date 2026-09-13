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
static unsigned log_ids[65536], log_count;
static struct tracked {
    struct wlr_surface *surface;
    struct wl_surface *proxy;
    struct wp_commit_timer_v1 *timer;
    struct wl_listener commit, destroy;
    unsigned count, id;
} tracked[1024];
static unsigned surface_count;
static bool bypass;
// Diagnostic indices: alloc, reuse, free, live, peak, retained, clocks,
// state visits, idles, timer arms, immediate, snapshot, addons, state inits,
// parent notifications, fail-on-Nth-allocation-miss. Available only in diagnostic builds.
static uint64_t *stats;
static struct wl_surface *commit_on_callback;
static unsigned callback_trigger;
static struct wlr_surface *unlock_on_callback;
static uint32_t unlock_callback_seq;
static struct wl_subsurface *test_subs[1024];
static unsigned test_sub_count;
static void test_subsurface(struct wl_surface *child, struct wl_surface *parent) {
    assert(test_sub_count < 1024);
    test_subs[test_sub_count++] = wl_subcompositor_get_subsurface(subcompositor, child, parent);
}
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
    if (unlock_on_callback && s->id == callback_trigger) {
        struct wlr_surface *target = unlock_on_callback;
        unlock_on_callback = NULL;
        wlr_surface_unlock_cached(target, unlock_callback_seq);
    }
    if (commit_on_callback && s->id == callback_trigger) {
        struct wl_surface *proxy = commit_on_callback;
        commit_on_callback = NULL;
        wl_surface_commit(proxy);
        assert(wl_display_flush(client) >= 0);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
    }
    assert(log_count < 65536);
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
    assert(surface_count < 1024);
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
static struct tracked *create_optional_timer(bool timer) {
    unsigned index = surface_count;
    struct wl_surface *s = wl_compositor_create_surface(compositor);
    assert(sync_client());
    tracked[index].proxy = s;
    if (timer) tracked[index].timer = wp_commit_timing_manager_v1_get_timer(manager, s);
    assert(sync_client());
    return &tracked[index];
}
static struct tracked *create_surface(void) { return create_optional_timer(true); }
static void timestamp(struct tracked *s, uint64_t ns) {
    if (bypass) return;
    uint64_t sec = ns / 1000000000;
    wp_commit_timer_v1_set_timestamp(s->timer, sec >> 32, sec, ns % 1000000000);
}
static void commit(struct tracked *s) { wl_surface_commit(s->proxy); assert(sync_client()); }
// Cache/unlock a tick to notify the manager after advancing its test clock.
static void advance(struct tracked *tick, uint64_t ns) {
    fake_ns = ns;
    uint32_t seq = wlr_surface_lock_pending(tick->surface);
    timestamp(tick, 0); commit(tick);
    wlr_surface_unlock_cached(tick->surface, seq);
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
    uint64_t *(*get_stats)(void) = dlsym(RTLD_DEFAULT, "wlr_commit_timing_v1_debug_counters");
    if (get_stats) stats = get_stats();
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
    if (!strcmp(mode, "fast-path") || !strcmp(mode, "fast-boundary")) {
        unsigned children = !strcmp(mode, "fast-path") ? 8 : 33;
        struct tracked *parent = create_optional_timer(false), *child[33];
        for (unsigned i = 0; i < children; i++) {
            child[i] = create_optional_timer(false);
            test_subsurface(child[i]->proxy, parent->proxy);
        }
        assert(sync_client());
        uint64_t before[16] = {0}; if (stats) memcpy(before, stats, sizeof(before));
        for (unsigned n = 0; n < 10; n++) {
            for (unsigned i = 0; i < children; i++) wl_surface_commit(child[i]->proxy);
            commit(parent);
            assert(parent->count == n + 1);
            for (unsigned i = 0; i < children; i++) assert(child[i]->count == n + 1);
        }
        if (stats && children == 8) {
            assert(stats[10] - before[10] == 10);
            assert(stats[0] == before[0] && stats[12] == before[12]);
            assert(stats[6] == before[6] && stats[8] == before[8]);
        }
        if (stats && children == 33) assert(stats[11] > before[11]);
    } else if (!strcmp(mode, "transition") || !strcmp(mode, "fast-destroy") || !strcmp(mode, "fast-reentry")) {
        struct tracked *child = create_surface(), *sibling = create_surface();
        test_subsurface(child->proxy, s->proxy);
        test_subsurface(sibling->proxy, s->proxy);
        commit(child); commit(sibling); commit(s);
        assert(child->count == 1 && sibling->count == 1 && s->count == 1);
        if (!strcmp(mode, "fast-destroy")) {
            commit(child); commit(sibling);
            destroy_on_commit = sibling->surface; destroy_trigger = child->id;
            commit(s); assert(s->count == 2 && !sibling->surface);
        } else if (!strcmp(mode, "fast-reentry")) {
            commit(child); commit(sibling);
            commit_on_callback = child->proxy; callback_trigger = child->id;
            commit(s);
            assert(child->count == 2 && s->count == 2);
            assert(!wl_list_empty(&child->surface->cached));
            commit(s); assert(child->count == 3);
        } else {
            timestamp(child, start + 1000000000); commit(child); commit(sibling); commit(s);
            assert(s->count == 1);
            wp_commit_timer_v1_destroy(child->timer); child->timer = NULL;
            advance(tick, start + 1000000000);
            assert(s->count == 2 && child->count == 2);
            uint64_t immediate = stats ? stats[10] : 0;
            commit(child); commit(sibling); commit(s);
            assert(s->count == 3 && child->count == 3);
            if (stats) assert(stats[10] == immediate + 1);
            uint32_t lock = wlr_surface_lock_pending(s->surface);
            commit(child); commit(s); assert(s->count == 3);
            commit(child); commit(s);
            wlr_surface_unlock_cached(s->surface, lock); assert(sync_client());
            assert(s->count == 5 && child->count == 5);
        }
    } else if (!strcmp(mode, "pool") || !strcmp(mode, "pool-cap") || !strcmp(mode, "pool-oom")) {
        unsigned children = !strcmp(mode, "pool-cap") ? 300 : 8;
        struct tracked *child[300];
        for (unsigned i = 0; i < children; i++) {
            child[i] = create_optional_timer(false);
            test_subsurface(child[i]->proxy, s->proxy);
        }
        assert(sync_client());
        if (!strcmp(mode, "pool-oom") && stats) stats[15] = 4;
        uint64_t warmed_alloc = 0;
        for (unsigned n = 0; n < 4; n++) {
            uint64_t deadline = fake_ns + 1000000000;
            timestamp(s, deadline);
            for (unsigned i = 0; i < children; i++) wl_surface_commit(child[i]->proxy);
            wl_surface_commit(s->proxy);
            if (!strcmp(mode, "pool-oom") && stats) {
                assert(!sync_client()); goto cleanup;
            }
            assert(sync_client()); assert(s->count == n);
            advance(tick, deadline);
            assert(s->count == n + 1);
            for (unsigned i = 0; i < children; i++) assert(child[i]->count == n + 1);
            if (stats) {
                assert(stats[3] == 0 && stats[5] <= 256);
                if (n == 0) warmed_alloc = stats[0];
                else if (children <= 256) assert(stats[0] == warmed_alloc);
            }
        }
    } else if (!strcmp(mode, "queued-burst")) {
        struct tracked *child = create_optional_timer(false);
        test_subsurface(child->proxy, s->proxy);
        for (unsigned i = 0; i < 128; i++) {
            timestamp(s, start + 1000000000);
            wl_surface_commit(child->proxy); wl_surface_commit(s->proxy);
        }
        assert(sync_client()); assert(s->count == 0 && child->count == 0);
        uint64_t notifications = stats ? stats[14] : 0;
        advance(tick, start + 1000000000);
        assert(s->count == 128 && child->count == 128);
        if (stats) assert(stats[14] - notifications <= 128);
    } else if (!strcmp(mode, "late-timer")) {
        struct tracked *child = create_optional_timer(false);
        test_subsurface(child->proxy, s->proxy);
        uint32_t lock = wlr_surface_lock_pending(s->surface);
        commit(child); commit(s); assert(s->count == 0 && child->count == 0);
        child->timer = wp_commit_timing_manager_v1_get_timer(manager, child->proxy);
        timestamp(child, start + 2000000000); commit(child); commit(s);
        wlr_surface_unlock_cached(s->surface, lock); assert(sync_client());
        assert(s->count == 1 && child->count == 1);
        advance(tick, start + 2000000000);
        assert(s->count == 2 && child->count == 2);
    } else if (!strcmp(mode, "dispatch-unlock")) {
        struct tracked *early = create_surface();
        timestamp(tick, start + 3000000); commit(tick);
        unlock_callback_seq = wlr_surface_lock_pending(early->surface);
        timestamp(early, start + 2000000); commit(early);
        timestamp(s, start + 1000000); commit(s);
        // A native callback may release a lock during the timing idle. Do not
        // recursively dispatch libwayland's event loop from an idle callback.
        unlock_on_callback = early->surface; callback_trigger = s->id;
        fake_ns = start + 1000000; usleep(2000);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        assert(sync_client()); assert(s->count == 1 && early->count == 0 && tick->count == 0);
        fake_ns = start + 2000000; usleep(2000);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        assert(sync_client()); assert(early->count == 1 && tick->count == 0);
        fake_ns = start + 3000000; usleep(2000);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        assert(sync_client()); assert(tick->count == 1);
    } else if (!strcmp(mode, "deadline-changes")) {
        struct tracked *early = create_surface();
        timestamp(s, start + 3000000); commit(s);
        timestamp(early, start + 1000000); commit(early);
        fake_ns = start + 1000000; usleep(2000);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        assert(sync_client()); assert(early->count == 1 && s->count == 0);
        timestamp(early, start + 2000000); commit(early);
        wl_surface_destroy(early->proxy); assert(sync_client());
        wp_commit_timer_v1_destroy(early->timer);
        fake_ns = start + 3000000; usleep(4000);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        assert(sync_client()); assert(s->count == 1);
    } else if (!strcmp(mode, "deep-tree")) {
        struct tracked *nodes[64];
        for (unsigned i = 0; i < 64; i++) {
            nodes[i] = create_optional_timer(false);
            test_subsurface(nodes[i]->proxy, i ? nodes[i-1]->proxy : s->proxy);
        }
        for (unsigned n = 0; n < 3; n++) {
            for (unsigned i = 64; i > 0; i--) wl_surface_commit(nodes[i-1]->proxy);
            commit(s);
            assert(s->count == n + 1);
            for (unsigned i = 0; i < 64; i++) assert(nodes[i]->count == n + 1);
        }
    } else if (!strcmp(mode, "wakeups")) {
        // The expired timestamp remains blocked without repeated idle callbacks.
        uint32_t lock = wlr_surface_lock_pending(s->surface);
        timestamp(s, start + 1000000); commit(s);
        fake_ns = start + 1000000;
        usleep(3000);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        assert(sync_client());
        uint64_t idles = stats ? stats[8] : 0;
        for (unsigned i = 0; i < 16; i++) assert(sync_client());
        assert(s->count == 0);
        if (stats) assert(stats[8] == idles);
        wlr_surface_unlock_cached(s->surface, lock); assert(sync_client());
        assert(s->count == 1);
        timestamp(s, fake_ns + 3000000); commit(s);
        fake_ns += 3000000; usleep(5000);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        assert(sync_client()); assert(s->count == 2);
    } else if (!strcmp(mode, "duplicate")) {
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
        while (log_ids[n] == tick->id) n++;
        assert(log_ids[n++] == child->id);
        while (log_ids[n] == tick->id) n++;
        assert(log_ids[n] == s->id);
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
    for (unsigned i = 0; i < test_sub_count; i++) wl_proxy_destroy((struct wl_proxy *)test_subs[i]);
    if (duplicate) wl_proxy_destroy((struct wl_proxy *)duplicate);
    wl_registry_destroy(registry);
    wl_display_disconnect(client); wl_display_destroy_clients(server);
    wl_list_remove(&new_surface.link);
    wlr_backend_destroy(backend); wl_display_destroy(server);
    if (stats) {
        assert(stats[3] == 0 && stats[5] == 0);
        printf("COUNTERS"); for (unsigned i = 0; i < 16; i++) printf(" %llu", (unsigned long long)stats[i]); puts("");
    }
    printf("PASS %s\n", mode);
    return 0;
}
