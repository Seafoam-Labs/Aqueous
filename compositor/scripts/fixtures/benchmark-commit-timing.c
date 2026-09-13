// SPDX-License-Identifier: GPL-3.0-only
// Identical workloads for comparing compositor revisions; untimed by default.
#define _GNU_SOURCE
#include <assert.h>
#include <inttypes.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "presentation-time-client-protocol.h"
#include "commit-timing-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static struct wp_commit_timing_manager_v1 *timing_manager;
static struct wp_commit_timer_v1 *parent_timer;
static const char *timing_mode;
static unsigned child_count, tile_count;
static bool nested, blocked;
static uint64_t buffer_waits, feedback_pending;
static struct wl_surface *surface;
static struct xdg_surface *xdg;
static bool configured, active, pending_frame, measuring;
static uint64_t commits, transactions, received, discarded, previous_present;
static uint64_t intervals[16384], latencies[16384];
static unsigned interval_count, latency_count, sample_count;
static struct sample { uint64_t submit, deadline; bool measure; } samples[32768];
static struct buffer { struct wl_buffer *object; bool busy; uint32_t *pixels; uint64_t uses, releases; } buffers[3];
static int width = 1280, height = 720;
static struct tile {
    struct wl_surface *surface;
    struct wl_subsurface *sub;
    struct buffer buffers[3];
    int x, y, width, height;
} tiles[65];
static unsigned draw_count;

static uint64_t now_ns(void) {
    struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void draw(void);
static void release(void *data, struct wl_buffer *object) {
    (void)object;
    struct buffer *buffer = data; assert(buffer->busy);
    buffer->busy = false; buffer->releases++;
    if (active && blocked && !pending_frame) draw();
}
static const struct wl_buffer_listener buffer_listener = {.release = release};
static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
    (void)data; (void)time; wl_callback_destroy(callback); pending_frame = false;
    if (active) draw();
}
static const struct wl_callback_listener frame_listener = {.done = frame_done};
static void sync_output(void *data, struct wp_presentation_feedback *f, struct wl_output *o) { (void)data; (void)f; (void)o; }
static void presented(void *data, struct wp_presentation_feedback *feedback,
        uint32_t hi, uint32_t lo, uint32_t ns, uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo, uint32_t flags) {
    (void)refresh; (void)seq_hi; (void)seq_lo; (void)flags;
    struct sample *sample = data;
    assert(feedback_pending); feedback_pending--;
    if (measuring && sample->measure) {
        uint64_t actual = (((uint64_t)hi << 32) | lo) * 1000000000 + ns;
        assert(actual >= sample->submit && actual >= sample->deadline);
        assert(latency_count < 16384);
        latencies[latency_count++] = actual - sample->submit;
        if (previous_present) { assert(interval_count < 16384); intervals[interval_count++] = actual - previous_present; }
        previous_present = actual;
        received++;
    }
    wl_proxy_destroy((struct wl_proxy *)feedback);
}
static void discard(void *data, struct wp_presentation_feedback *feedback) {
    struct sample *sample = data;
    assert(feedback_pending); feedback_pending--;
    if (measuring && sample->measure) discarded++;
    wl_proxy_destroy((struct wl_proxy *)feedback);
}
static const struct wp_presentation_feedback_listener feedback_listener = {
    .sync_output = sync_output, .presented = presented, .discarded = discard,
};
static void draw(void) {
    if (!configured || pending_frame) return;
    struct buffer *buffer = &buffers[draw_count % 3];
    bool busy = buffer->busy;
    for (unsigned i = 0; i < tile_count; i++) busy |= tiles[i].buffers[draw_count % 3].busy;
    if (busy) { if (measuring && !blocked) buffer_waits++; blocked = true; return; }
    blocked = false;
    buffer->busy = true; buffer->uses++;
    for (unsigned i = tile_count; i > 0; i--) {
        struct tile *tile = &tiles[i - 1];
        struct buffer *b = &tile->buffers[draw_count % 3];
        b->busy = true; b->uses++;
        // A common frame color permits a separate screencopy atomicity check.
        uint32_t color = 0xff000000 | ((draw_count & 255) << 16) | ((i & 255) << 8) | 0x55;
        for (unsigned pixel = 0; pixel < (unsigned)(tile->width * tile->height); pixel++) b->pixels[pixel] = color;
        wl_surface_attach(tile->surface, b->object, 0, 0);
        wl_surface_damage_buffer(tile->surface, 0, 0, tile->width, tile->height);
        wl_surface_commit(tile->surface);
        if (measuring) commits++;
    }
    // Reuse allocated SHM, but dirty each frame and force full scene damage.
    buffer->pixels[draw_count % ((unsigned)width * height)] ^= 0x00010101;
    draw_count++;
    assert(sample_count < 32768);
    struct sample *sample = &samples[sample_count++];
    *sample = (struct sample){.submit = now_ns(), .measure = measuring};
    if (parent_timer && !strcmp(timing_mode, "deadline")) {
        sample->deadline = sample->submit + 2000000;
        uint64_t sec = sample->deadline / 1000000000;
        wp_commit_timer_v1_set_timestamp(parent_timer, sec >> 32, sec, sample->deadline % 1000000000);
    }
    feedback_pending++;
    struct wp_presentation_feedback *feedback = wp_presentation_feedback(presentation, surface);
    wp_presentation_feedback_add_listener(feedback, &feedback_listener, sample);
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL); pending_frame = true;
    wl_surface_attach(surface, buffer->object, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    if (measuring) { commits++; transactions++; }
}
static void configure(void *data, struct xdg_surface *object, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(object, serial); configured = true;
}
static const struct xdg_surface_listener xdg_listener = {.configure = configure};
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
    (void)d; (void)t; (void)states;
    assert((w == 0 || w == width) && (h == 0 || h == height));
}
static void close_top(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(1); }
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = close_top};
static void ping(void *d, struct xdg_wm_base *base, uint32_t serial) { (void)d; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void clock_id(void *d, struct wp_presentation *p, uint32_t id) { (void)d; (void)p; assert(id == CLOCK_MONOTONIC); }
static const struct wp_presentation_listener presentation_listener = {.clock_id = clock_id};
static void global(void *d, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    (void)d; (void)version;
    if (!strcmp(name, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(name, "wl_subcompositor")) subcompositor = wl_registry_bind(registry, id, &wl_subcompositor_interface, 1);
    if (!strcmp(name, "wl_shm")) shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
    if (!strcmp(name, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
    if (strcmp(timing_mode, "none") && !strcmp(name, "wp_commit_timing_manager_v1")) timing_manager = wl_registry_bind(registry, id, &wp_commit_timing_manager_v1_interface, 1);
    if (!strcmp(name, "wp_presentation")) {
        presentation = wl_registry_bind(registry, id, &wp_presentation_interface, 1);
        wp_presentation_add_listener(presentation, &presentation_listener, NULL);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
static void dispatch_for(uint64_t duration) {
    uint64_t end = now_ns() + duration;
    while (now_ns() < end) {
        while (wl_display_prepare_read(display) != 0) assert(wl_display_dispatch_pending(display) >= 0);
        assert(wl_display_flush(display) >= 0);
        struct pollfd fd = {wl_display_get_fd(display), POLLIN, 0};
        int ready = poll(&fd, 1, 2);
        assert(ready >= 0);
        if (ready && (fd.revents & POLLIN)) assert(wl_display_read_events(display) >= 0);
        else wl_display_cancel_read(display);
        assert(wl_display_dispatch_pending(display) >= 0);
    }
}
static void print_array(const char *key, uint64_t *values, unsigned count) {
    printf(",\"%s\":[", key);
    for (unsigned i = 0; i < count; i++) printf("%s%" PRIu64, i ? "," : "", values[i]);
    putchar(']');
}
static void allocate_buffers(struct buffer *set, int w, int h) {
    for (unsigned i = 0; i < 3; i++) {
        size_t size = (size_t)w * h * 4;
        int fd = memfd_create("aqueous-benchmark", MFD_CLOEXEC); assert(fd >= 0 && ftruncate(fd, size) == 0);
        set[i].pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); assert(set[i].pixels != MAP_FAILED);
        for (size_t j = 0; j < size / 4; j++) set[i].pixels[j] = 0xff102040;
        struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
        set[i].object = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_XRGB8888);
        wl_buffer_add_listener(set[i].object, &buffer_listener, &set[i]);
        wl_shm_pool_destroy(pool); close(fd);
    }
}
int main(int argc, char **argv) {
    assert(argc == 6);
    child_count = atoi(argv[3]); assert(child_count > 0 && child_count <= 64);
    nested = !strcmp(argv[4], "nested");
    timing_mode = argv[5];
    const char *mode = argv[1];
    double seconds = atof(argv[2]); assert(seconds > 0 && seconds < 60);
    setvbuf(stdout, NULL, _IOLBF, 0);
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && wl_display_roundtrip(display) >= 0);
    assert(compositor && subcompositor && shm && wm && presentation);
    bool scene = !strcmp(mode, "scene") || !strcmp(mode, "subsurface-scene");
    bool subs = !strcmp(mode, "subsurface");
    struct wl_surface *plain[64];
    surface = wl_compositor_create_surface(compositor);
    if (scene) {
        allocate_buffers(buffers, width, height);
        if (!strcmp(mode, "subsurface-scene")) {
            tile_count = child_count + (nested ? 1 : 0);
            // Leave one parent scanline visible so its frame/presentation feedback
            // remains eligible even with opaque children.
            unsigned columns = child_count < 8 ? child_count : 8;
            unsigned rows = (child_count + columns - 1) / columns;
            assert(child_count % columns == 0);
            for (unsigned i = 0; i < tile_count; i++) {
                struct tile *tile = &tiles[i];
                tile->surface = wl_compositor_create_surface(compositor);
                tile->sub = wl_subcompositor_get_subsurface(subcompositor, tile->surface,
                    nested && i > 0 ? tiles[0].surface : surface);
                unsigned n = i - (nested ? 1 : 0);
                if (nested && i == 0) { tile->width = width; tile->height = height - 1; }
                else {
                    tile->x = (n % columns) * width / columns;
                    tile->y = (n / columns) * (height - 1) / rows;
                    tile->width = ((n % columns) + 1) * width / columns - tile->x;
                    tile->height = ((n / columns) + 1) * (height - 1) / rows - tile->y;
                }
                wl_subsurface_set_position(tile->sub, tile->x, tile->y);
                allocate_buffers(tile->buffers, tile->width, tile->height);
            }
        }
        if (strcmp(timing_mode, "none")) {
            assert(timing_manager);
            parent_timer = wp_commit_timing_manager_v1_get_timer(timing_manager, surface);
        }
        xdg = xdg_wm_base_get_xdg_surface(wm, surface);
        xdg_surface_add_listener(xdg, &xdg_listener, NULL);
        struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
        xdg_toplevel_add_listener(top, &top_listener, NULL);
        xdg_toplevel_set_app_id(top, "aqueous.benchmark");
        xdg_toplevel_set_fullscreen(top, NULL);
        wl_surface_commit(surface);
        while (!configured) assert(wl_display_dispatch(display) >= 0);
        draw(); dispatch_for(200000000);
    } else {
        for (unsigned i = 0; i < (subs ? 8 : 64); i++) {
            plain[i] = wl_compositor_create_surface(compositor);
            if (subs) wl_subcompositor_get_subsurface(subcompositor, plain[i], surface);
        }
        assert(wl_display_roundtrip(display) >= 0);
    }
    if (!scene && subs && strcmp(timing_mode, "none")) {
        assert(timing_manager);
        parent_timer = wp_commit_timing_manager_v1_get_timer(timing_manager, surface);
    }
    puts("{\"event\":\"ready\"}");
    for (;;) {
        int command = getchar();
        if (command == 'q' || command == EOF) break;
        if (command != 'w' && command != 'g') continue;
        measuring = command == 'g';
        commits = transactions = received = discarded = previous_present = buffer_waits = 0;
        interval_count = latency_count = 0;
        uint64_t start = now_ns();
        uint64_t duration = measuring ? (uint64_t)(seconds * 1e9) : 1000000000;
        if (scene) {
            active = true; draw(); dispatch_for(duration); active = false;
        } else {
            while (now_ns() - start < duration) {
                if (subs) {
                    for (unsigned batch = 0; batch < 64; batch++) {
                        for (unsigned i = 0; i < 8; i++) wl_surface_commit(plain[i]);
                        if (parent_timer && !strcmp(timing_mode, "deadline")) {
                            uint64_t deadline = now_ns() + 2000000, sec = deadline / 1000000000;
                            wp_commit_timer_v1_set_timestamp(parent_timer, sec >> 32, sec, deadline % 1000000000);
                        }
                        wl_surface_commit(surface); commits += 9; transactions++;
                    }
                } else {
                    for (unsigned i = 0; i < 256; i++) wl_surface_commit(plain[i % 64]);
                    commits += 256;
                }
                assert(wl_display_roundtrip(display) >= 0);
            }
        }
        uint64_t elapsed = now_ns() - start;
        printf("{\"event\":\"%s\",\"elapsed_ns\":%" PRIu64 ",\"commits\":%" PRIu64 ",\"transactions\":%" PRIu64 ",\"presented\":%" PRIu64 ",\"discarded\":%" PRIu64,
            command == 'g' ? "result" : "warmup", elapsed, commits, transactions, received, discarded);
        printf(",\"buffer_waits\":%" PRIu64 ",\"children\":%u,\"tree_depth\":%u", buffer_waits, tile_count, nested ? 2 : 1);
        print_array("intervals_ns", intervals, interval_count);
        print_array("latencies_ns", latencies, latency_count);
        puts("}");
        measuring = false;
    }
    // Finish pending feedback and release every attachment before reporting cleanup.
    if (scene) {
        for (unsigned i = tile_count; i > 0; i--) {
            wl_surface_attach(tiles[i-1].surface, NULL, 0, 0); wl_surface_commit(tiles[i-1].surface);
        }
        wl_surface_attach(surface, NULL, 0, 0); wl_surface_commit(surface);
        dispatch_for(50000000);
        assert(feedback_pending == 0);
        for (unsigned i = 0; i < 3; i++) assert(!buffers[i].busy && buffers[i].uses == buffers[i].releases);
        for (unsigned t = 0; t < tile_count; t++) for (unsigned i = 0; i < 3; i++)
            assert(!tiles[t].buffers[i].busy && tiles[t].buffers[i].uses == tiles[t].buffers[i].releases);
    }
    puts("{\"event\":\"cleanup\",\"buffers_released\":true}");
    wl_registry_destroy(registry); wl_display_disconnect(display);
    return 0;
}
