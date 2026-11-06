/* SPDX-License-Identifier: GPL-3.0-only
 *
 * Native-Wayland buffer-retention client for probe-buffer-retention.py.
 *
 * Reproduces Wine's Wayland driver buffer bookkeeping against a live
 * compositor without the game: every frame callback attaches one buffer and
 * commits; the client counts how many committed buffers the compositor has
 * released.
 *
 * Modes:
 *   pool  honest client: recycles a fixed pool and waits when every buffer
 *         is un-released. A compositor that releases promptly keeps
 *         unreleased near the working set; one that retains stalls this
 *         client (stalled_s grows while frames/s collapses).
 *   wine  Wine-like client: never blocks. When no released buffer exists it
 *         allocates a fresh shm buffer for the next frame and frees memory
 *         only when the compositor sends release. Client RSS and live_kb
 *         climb linearly with frames exactly when the compositor retains
 *         buffers: the client-side leak shape of the WoW Forever report.
 *
 * usage: buffer-retention-client pool|wine <seconds> <width> <height> <pool>
 *
 * stdout: one CSV line per second
 *   t_ms,frames,unreleased,live_buffers,live_kb,rss_kb,stalled_ms
 * and a final SUMMARY,<mode> line with the same totals.
 */
#define _GNU_SOURCE
#include <assert.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

enum { MAX_BUFFERS = 16384, REPORT_MS = 1000, SETTLE_MS = 1500 };
/* Wine itself would grow until the OOM killer; the probe stops short so a
 * retention finding cannot take the session down with it. */
enum { LIVE_BYTE_CAP = 1024u * 1024u * 1024u };
enum { POOL, WINE };

struct buffer {
    struct wl_buffer *buffer;
    void *memory;
    size_t size;
    int fd;
    int in_flight; /* attached to a commit the compositor has not released */
    int released;  /* compositor sent release at least once */
};

static int mode = POOL, seconds = 10, width = 640, height = 480, pool_size = 3;
static struct wl_display *display;
static struct wl_registry *registry;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct xdg_surface *xdg_surface;
static struct xdg_toplevel *toplevel;
static struct wl_surface *surface;
static struct buffer buffers[MAX_BUFFERS];
static size_t buffer_count, release_count;
static long frames, stalled_ms;
static int mapped, running = 1;

static long nowMs(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static long rssKb(void) {
    FILE *file = fopen("/proc/self/status", "r");
    if (!file) return 0;
    char line[128];
    long kb = 0;
    while (fgets(line, sizeof(line), file))
        if (!strncmp(line, "VmRSS:", 6)) { sscanf(line + 6, "%ld", &kb); break; }
    fclose(file);
    return kb;
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t serial);
static const struct wl_callback_listener frame_listener = {.done = frame_done};

static void buffer_release(void *data, struct wl_buffer *buffer);
static const struct wl_buffer_listener buffer_listener = {.release = buffer_release};

static struct buffer *create_buffer(void) {
    if (buffer_count >= MAX_BUFFERS) return NULL;
    size_t stride = (size_t)width * sizeof(uint32_t);
    size_t size = stride * (size_t)height;
    size_t live_bytes = 0;
    for (size_t i = 0; i < buffer_count; i++)
        if (buffers[i].memory) live_bytes += buffers[i].size;
    if (live_bytes + size > (size_t)LIVE_BYTE_CAP) return NULL;
    struct buffer *entry = &buffers[buffer_count];
    entry->fd = memfd_create("retention-probe", MFD_CLOEXEC);
    if (entry->fd < 0 || ftruncate(entry->fd, (off_t)size) != 0) abort();
    entry->memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, entry->fd, 0);
    if (entry->memory == MAP_FAILED) abort();
    memset(entry->memory, 0x40, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, entry->fd, (int32_t)size);
    entry->buffer = wl_shm_pool_create_buffer(pool, 0, width, height, (int32_t)stride,
                                              WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    entry->size = size;
    entry->in_flight = 0;
    entry->released = 0;
    wl_buffer_add_listener(entry->buffer, &buffer_listener, entry);
    buffer_count++;
    return entry;
}

static void commit(struct buffer *entry) {
    wl_surface_attach(surface, entry->buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    struct wl_callback *callback = wl_surface_frame(surface);
    wl_callback_add_listener(callback, &frame_listener, NULL);
    entry->in_flight = 1;
    wl_surface_commit(surface);
    frames++;
}

static void next_frame(void) {
    if (!mapped || !running) return;
    for (size_t i = 0; i < buffer_count; i++)
        if (buffers[i].released && !buffers[i].in_flight) {
            commit(&buffers[i]);
            return;
        }
    if (frames == 0) { /* first commit: the frame callback drives the loop */
        commit(&buffers[0]);
        return;
    }
    if (mode == POOL) return; /* an honest client waits for release */
    struct buffer *fresh = create_buffer();
    if (fresh) commit(fresh);
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)data; (void)serial;
    wl_callback_destroy(callback);
    next_frame();
}

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void)buffer;
    struct buffer *entry = data;
    if (!entry->released) release_count++;
    entry->released = 1;
    entry->in_flight = 0;
}

static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = {.ping = ping};

static void xdg_configure(void *data, struct xdg_surface *self, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(self, serial);
    mapped = 1;
}
static const struct xdg_surface_listener xdg_surface_listener = {xdg_configure};
static void toplevel_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h,
                               struct wl_array *states) {
    (void)d; (void)t; (void)w; (void)h; (void)states;
}
static void toplevel_close(void *d, struct xdg_toplevel *t) {
    (void)d; (void)t;
    running = 0;
}
static const struct xdg_toplevel_listener toplevel_listener = {.configure = toplevel_configure,
                                                               .close = toplevel_close};

static void global(void *data, struct wl_registry *reg, uint32_t name, const char *interface,
                   uint32_t version) {
    (void)data;
    if (!strcmp(interface, wl_compositor_interface.name))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, wl_shm_interface.name))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, xdg_wm_base_interface.name)) {
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    }
    (void)version;
}
static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener registry_listener = {global, registry_global_remove};

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s pool|wine <seconds> <width> <height> <pool>\n", argv[0]);
        return 2;
    }
    if (!strcmp(argv[1], "pool")) mode = POOL;
    else if (!strcmp(argv[1], "wine")) mode = WINE;
    else return 2;
    seconds = atoi(argv[2]);
    width = atoi(argv[3]);
    height = atoi(argv[4]);
    pool_size = atoi(argv[5]);

    display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "cannot connect to wayland display\n"); return 77; }
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && wm_base);

    surface = wl_compositor_create_surface(compositor);
    xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xdg_surface);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(toplevel, "Aqueous buffer retention probe");
    xdg_toplevel_set_app_id(toplevel, "aq-buffer-retention-probe");

    for (int i = 0; i < pool_size; i++)
        create_buffer();
    wl_surface_commit(surface); /* initial map commit with no buffer */
    assert(wl_display_roundtrip(display) >= 0);
    next_frame();

    long start = nowMs(), next_report = start + REPORT_MS;
    size_t previous_releases = release_count;
    long previous_frames = frames;
    while (running && nowMs() - start < (long)seconds * 1000L) {
        while (wl_display_prepare_read(display) != 0)
            if (wl_display_dispatch_pending(display) < 0) return 1;
        wl_display_flush(display);
        struct pollfd pfd = {wl_display_get_fd(display), POLLIN, 0};
        long wake = next_report > nowMs() ? next_report - nowMs() : 0;
        if (poll(&pfd, 1, (int)wake) < 0) {
            wl_display_cancel_read(display);
            return 1;
        }
        if (pfd.revents & POLLIN) {
            if (wl_display_read_events(display) < 0) return 1;
        } else
            wl_display_cancel_read(display);
        if (wl_display_dispatch_pending(display) < 0) return 1;

        long now = nowMs();
        size_t unreleased = 0, live = 0, live_bytes = 0;
        for (size_t i = 0; i < buffer_count; i++) {
            if (!buffers[i].released) unreleased++;
            if (buffers[i].memory) { live++; live_bytes += buffers[i].size; }
        }
        if (now >= next_report) {
            /* Stalled: a whole report window with no frame out and no buffer
             * back. Evaluated at the boundary so a busy event loop cannot
             * inflate it. */
            if (mode == POOL && frames == previous_frames && release_count == previous_releases &&
                frames > 0)
                stalled_ms += REPORT_MS;
            previous_frames = frames;
            previous_releases = release_count;
            printf("%ld,%ld,%zu,%zu,%zu,%ld,%ld\n", now - start, frames, unreleased, live,
                   live_bytes / 1024, rssKb(), stalled_ms);
            fflush(stdout);
            next_report += REPORT_MS;
        }
    }
    size_t unreleased = 0, live = 0, live_bytes = 0;
    for (size_t i = 0; i < buffer_count; i++) {
        if (!buffers[i].released) unreleased++;
        if (buffers[i].memory) { live++; live_bytes += buffers[i].size; }
    }
    printf("SUMMARY,%s,%ld,%zu,%zu,%zu,%ld,%ld\n", argv[1], frames, unreleased, live,
           live_bytes / 1024, rssKb(), stalled_ms);
    fflush(stdout);
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdg_surface);
    wl_surface_destroy(surface);
    wl_display_flush(display);
    wl_display_disconnect(display);
    return 0;
}
