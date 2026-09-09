// SPDX-License-Identifier: GPL-3.0-only
// Real wire requests and wlroots commit cache, with deterministic output events.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wlr/backend/headless.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_fifo_v1.h>
#include "fifo-v1-client-protocol.h"

static struct wl_display *server, *client;
static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wp_fifo_manager_v1 *manager;
static struct wlr_fifo_manager_v1 *fifo_manager;
static struct wlr_surface *surface;
static unsigned commits;
static bool bypass, no_expiry;
static struct wl_listener new_surface, committed, destroyed;
static struct wlr_output *reentrant_output;
static uint32_t latch(struct wlr_output *output, bool success);
static void present(struct wlr_output *output, uint32_t seq, bool success);
static void commit_notify(struct wl_listener *listener, void *data) {
    (void)listener; (void)data; commits++;
    if (reentrant_output) {
        struct wlr_output *output = reentrant_output; reentrant_output = NULL;
        present(output, latch(output, true), true);
    }
}
static void destroy_notify(struct wl_listener *listener, void *data) {
    (void)listener; (void)data;
    wl_list_remove(&committed.link); wl_list_remove(&destroyed.link); surface = NULL;
}
static void new_notify(struct wl_listener *listener, void *data) {
    (void)listener;
    if (surface) { wl_list_remove(&committed.link); wl_list_remove(&destroyed.link); }
    surface = data;
    committed.notify = commit_notify; destroyed.notify = destroy_notify;
    wl_signal_add(&surface->events.commit, &committed);
    wl_signal_add(&surface->events.destroy, &destroyed);
}
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    (void)data;
    if (!strcmp(name, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(name, "wl_subcompositor")) subcompositor = wl_registry_bind(registry, id, &wl_subcompositor_interface, 1);
    if (!strcmp(name, "wp_fifo_manager_v1")) {
        assert(version == 1);
        manager = wl_registry_bind(registry, id, &wp_fifo_manager_v1_interface, 1);
    }
}
static void remove_global(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener registry_listener = {global, remove_global};
static void done(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial; *(bool *)data = true; wl_callback_destroy(callback);
}
static const struct wl_callback_listener sync_listener = {done};
static void sync_client(void) {
    bool synced = false;
    struct wl_callback *callback = wl_display_sync(client);
    wl_callback_add_listener(callback, &sync_listener, &synced);
    for (int i = 0; i < 100 && !synced; i++) {
        assert(wl_display_flush(client) >= 0);
        assert(wl_event_loop_dispatch(wl_display_get_event_loop(server), 0) >= 0);
        wl_display_flush_clients(server);
        struct pollfd fd = {wl_display_get_fd(client), POLLIN, 0};
        if (poll(&fd, 1, 10) > 0) assert(wl_display_dispatch(client) >= 0);
    }
    assert(synced);
}
static void submit(struct wp_fifo_v1 *fifo, struct wl_surface *s, bool set, bool wait) {
    if (wait && !bypass) wp_fifo_v1_wait_barrier(fifo);
    if (set) wp_fifo_v1_set_barrier(fifo);
    wl_surface_commit(s);
    sync_client();
}
static uint32_t latch(struct wlr_output *output, bool success) {
    wlr_fifo_manager_v1_prepare(fifo_manager, output);
    if (success) output->commit_seq++;
    wlr_fifo_manager_v1_finish(fifo_manager, output, success);
    return output->commit_seq;
}
static void present(struct wlr_output *output, uint32_t seq, bool success) {
    if (no_expiry) return;
    struct wlr_output_event_present event = {.commit_seq = seq, .presented = success};
    wlr_fifo_manager_v1_present(fifo_manager, output, &event);
}
int main(int argc, char **argv) {
    server = wl_display_create(); assert(server);
    struct wlr_compositor *wc = wlr_compositor_create(server, 6, NULL); assert(wc);
    assert(wlr_subcompositor_create(server));
    fifo_manager = wlr_fifo_manager_v1_create(server); assert(fifo_manager);
    new_surface.notify = new_notify; wl_signal_add(&wc->events.new_surface, &new_surface);
    struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(server)); assert(backend);
    struct wlr_output *output = wlr_headless_add_output(backend, 100, 100); assert(output);
    // The output timeline is controlled by this fixture, not a wall-clock timer.
    output->enabled = true;
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(wl_client_create(server, pair[0]));
    client = wl_display_connect_to_fd(pair[1]); assert(client);
    struct wl_registry *registry = wl_display_get_registry(client);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    sync_client(); sync_client(); assert(manager && compositor && subcompositor);
    struct wl_surface *s = wl_compositor_create_surface(compositor);
    struct wp_fifo_v1 *fifo = wp_fifo_manager_v1_get_fifo(manager, s);
    sync_client(); assert(surface);
    wlr_surface_send_enter(surface, output);

    bypass = argc > 1 && !strcmp(argv[1], "bypass");
    no_expiry = argc > 1 && !strcmp(argv[1], "no-expiry");
    if (argc > 1 && !bypass && !no_expiry) {
        struct wp_fifo_v1 *duplicate = NULL;
        if (!strcmp(argv[1], "duplicate")) duplicate = wp_fifo_manager_v1_get_fifo(manager, s);
        else {
            wl_surface_destroy(s); sync_client();
            if (!strcmp(argv[1], "dead-set")) wp_fifo_v1_set_barrier(fifo);
            else wp_fifo_v1_wait_barrier(fifo);
        }
        wl_display_flush(client);
        wl_event_loop_dispatch(wl_display_get_event_loop(server), 0);
        wl_display_flush_clients(server);
        assert(wl_display_dispatch(client) == -1);
        const struct wl_interface *interface = NULL; uint32_t id = 0;
        assert(wl_display_get_protocol_error(client, &interface, &id) == 0);
        assert(interface && !strcmp(interface->name, !strcmp(argv[1], "duplicate") ? "wp_fifo_manager_v1" : "wp_fifo_v1"));
        if (duplicate) { wp_fifo_v1_destroy(duplicate); wl_surface_destroy(s); }
        wp_fifo_v1_destroy(fifo); wp_fifo_manager_v1_destroy(manager);
        goto cleanup;
    }

    // A is blocked by a separate lock; B arrives before A installs its barrier.
    uint32_t lock = wlr_surface_lock_pending(surface);
    submit(fifo, s, true, false); submit(fifo, s, true, true); submit(fifo, s, false, true);
    assert(commits == 0);
    wlr_surface_unlock_cached(surface, lock); assert(commits == 1);
    uint32_t seq = latch(output, false); present(output, seq, true); assert(commits == 1);
    seq = latch(output, true); present(output, seq, false); assert(commits == 1);
    present(output, seq - 1, true); assert(commits == 1);
    present(output, seq + 1, true); assert(commits == 1);
    present(output, seq, true); assert(commits == 1); // failed submission stays rejected
    assert(wlr_fifo_manager_v1_output_pending(fifo_manager, output));
    seq = latch(output, true); present(output, seq, true); assert(commits == 2);
    present(output, seq, true); assert(commits == 2); // old completion vs new barrier
    seq = latch(output, true); present(output, seq, true); assert(commits == 3);
    assert(!wlr_fifo_manager_v1_output_pending(fifo_manager, output));

    // FIFO clear cannot release an independently owned lock.
    submit(fifo, s, true, false); assert(commits == 4);
    lock = wlr_surface_lock_pending(surface);
    submit(fifo, s, false, true); assert(commits == 4);
    seq = latch(output, true); present(output, seq, true); assert(commits == 4);
    wlr_surface_unlock_cached(surface, lock); assert(commits == 5);

    // Pending requests survive resource destruction; recreation reuses state.
    wp_fifo_v1_set_barrier(fifo); wp_fifo_v1_destroy(fifo);
    fifo = wp_fifo_manager_v1_get_fifo(manager, s);
    submit(fifo, s, false, false); assert(commits == 6);
    submit(fifo, s, false, true); assert(commits == 6);
    wp_fifo_v1_destroy(fifo); sync_client();
    seq = latch(output, true); present(output, seq, true); assert(commits == 7);
    fifo = wp_fifo_manager_v1_get_fifo(manager, s); sync_client();
    // Requests are one-commit state; unconstrained updates bypass an active barrier.
    wp_fifo_v1_set_barrier(fifo); wp_fifo_v1_set_barrier(fifo);
    submit(fifo, s, false, false); assert(commits == 8);
    submit(fifo, s, false, false); assert(commits == 9);
    submit(fifo, s, false, true); assert(commits == 9);
    // Hiding releases waits without needing another frame or mouse movement.
    wlr_surface_send_leave(surface, output); sync_client(); assert(commits == 10);
    submit(fifo, s, true, true); submit(fifo, s, false, true); assert(commits == 12);

    // Surface and output sequence wrap do not alias the barrier generation.
    wlr_surface_send_enter(surface, output);
    surface->pending.seq = UINT32_MAX; output->commit_seq = UINT32_MAX;
    submit(fifo, s, true, false); submit(fifo, s, false, true); assert(commits == 13);
    seq = latch(output, true); assert(seq == 0); present(output, seq, true); assert(commits == 14);
    // Moving between outputs invalidates the earlier submission.
    struct wlr_output *other = wlr_headless_add_output(backend, 100, 100); assert(other);
    other->enabled = true;
    submit(fifo, s, true, false); submit(fifo, s, false, true); assert(commits == 15);
    seq = latch(output, true);
    wlr_surface_send_leave(surface, output); wlr_surface_send_enter(surface, other); sync_client();
    present(output, seq, true); assert(commits == 15);
    seq = latch(other, true); present(other, seq, true); assert(commits == 16);
    submit(fifo, s, true, false); submit(fifo, s, false, true); assert(commits == 17);
    wlr_output_destroy(other); sync_client(); assert(commits == 18);

    // Synchronized children bypass FIFO but still wait for parent application.
    wp_fifo_v1_destroy(fifo); wl_surface_destroy(s); sync_client();
    struct wl_surface *ancestor = wl_compositor_create_surface(compositor);
    struct wl_surface *parent = wl_compositor_create_surface(compositor);
    struct wl_subsurface *parent_sub = wl_subcompositor_get_subsurface(subcompositor, parent, ancestor);
    wl_subsurface_set_desync(parent_sub);
    s = wl_compositor_create_surface(compositor);
    struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, s, parent);
    fifo = wp_fifo_manager_v1_get_fifo(manager, s); sync_client();
    wlr_surface_send_enter(surface, output);
    unsigned before = commits;
    submit(fifo, s, true, false); submit(fifo, s, true, true);
    assert(commits == before);
    wl_surface_commit(parent); sync_client(); assert(commits == before + 2);
    wl_subsurface_set_desync(sub); sync_client();
    submit(fifo, s, true, false); submit(fifo, s, false, true);
    assert(commits == before + 3);
    seq = latch(output, true); present(output, seq, true); assert(commits == before + 4);
    // Changing to synchronized mode also unblocks already queued FIFO state.
    submit(fifo, s, true, false); submit(fifo, s, false, true);
    assert(commits == before + 5);
    wl_subsurface_set_sync(sub); sync_client(); assert(commits == before + 6);
    wl_subsurface_set_desync(sub); sync_client();
    submit(fifo, s, true, false); submit(fifo, s, false, true);
    assert(commits == before + 7);
    // An ancestor's sync mode also changes this unmapped child's effective mode.
    wl_subsurface_set_sync(parent_sub); sync_client(); assert(commits == before + 8);
    wl_subsurface_destroy(sub); wl_subsurface_destroy(parent_sub);
    wl_surface_destroy(parent); wl_surface_destroy(ancestor); sync_client();
    wlr_surface_send_leave(surface, output); sync_client();
    before = commits;

    // A compositor may submit/present synchronously from a commit listener.
    // Reentrant readiness must not apply/free the same cache head twice.
    wlr_surface_send_enter(surface, output);
    lock = wlr_surface_lock_pending(surface);
    submit(fifo, s, true, false); submit(fifo, s, true, true); submit(fifo, s, false, true);
    reentrant_output = output;
    wlr_surface_unlock_cached(surface, lock); assert(commits == before + 2);
    seq = latch(output, true); present(output, seq, true); assert(commits == before + 3);
    wlr_surface_send_leave(surface, output); sync_client();
    before = commits;

    // Manager resource destruction leaves existing FIFO objects operational.
    wp_fifo_manager_v1_destroy(manager);
    submit(fifo, s, true, false); submit(fifo, s, false, true); assert(commits == before + 2);
    // Destroy a surface with both cached and uncommitted FIFO state.
    wlr_surface_send_enter(surface, output);
    submit(fifo, s, true, false); submit(fifo, s, true, true);
    wp_fifo_v1_wait_barrier(fifo);
    wl_surface_destroy(s); sync_client();
    wp_fifo_v1_destroy(fifo);
cleanup:
    wl_registry_destroy(registry);
    wl_compositor_destroy(compositor);
    wl_subcompositor_destroy(subcompositor);
    wl_display_disconnect(client); wl_display_destroy_clients(server);
    wl_list_remove(&new_surface.link);
    wlr_backend_destroy(backend); wl_display_destroy(server);
    puts("PASS FIFO wire, cached queue, independent locks, lifetime and output generations");
    return 0;
}
