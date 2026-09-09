// SPDX-License-Identifier: GPL-3.0-only
// A one-shot fullscreen client. 'd' submits one frame; 'q' exits.
// Optional animated mode keeps the second output busy independently.
#define _GNU_SOURCE
#include <assert.h>
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
#ifdef TEST_FIFO_V1
#include "fifo-v1-client-protocol.h"
static struct wp_fifo_manager_v1 *fifo_manager;
static struct wp_fifo_v1 *fifo;
static unsigned burst;
#endif

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static struct wl_surface *surface;
static struct xdg_surface *xdg;
static bool configured, animated;
static int width = 640, height = 480;
static unsigned submitted, callbacks, presented;
static double next_draw;
static struct output { struct wl_output *object; char name[128]; } outputs[16];
static unsigned output_count;

static double now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static void released(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener buffer_listener = { .release = released };
static void frame_done(void *data, struct wl_callback *cb, uint32_t time) {
    (void)data; (void)time; wl_callback_destroy(cb); callbacks++;
}
static const struct wl_callback_listener frame_listener = { .done = frame_done };
static void feedback_output(void *data, struct wp_presentation_feedback *feedback, struct wl_output *output) {
    (void)data; (void)feedback; (void)output;
}
static void feedback_presented(void *data, struct wp_presentation_feedback *feedback,
        uint32_t hi, uint32_t lo, uint32_t ns, uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo, uint32_t flags) {
    (void)hi; (void)lo; (void)ns; (void)refresh; (void)seq_hi; (void)seq_lo; (void)flags;
    presented++;
    printf("{\"event\":\"presented\",\"frame\":%u,\"ms\":%.3f}\n", (unsigned)(uintptr_t)data, now_ms());
    wp_presentation_feedback_destroy(feedback);
}
static void feedback_discarded(void *data, struct wp_presentation_feedback *feedback) {
    printf("{\"event\":\"discarded\",\"frame\":%u}\n", (unsigned)(uintptr_t)data);
    wp_presentation_feedback_destroy(feedback);
}
static const struct wp_presentation_feedback_listener feedback_listener = {
    .sync_output = feedback_output, .presented = feedback_presented, .discarded = feedback_discarded,
};
static void draw(void) {
    if (!configured) return;
    assert(width > 0 && height > 0 && width <= 4096 && height <= 4096);
    size_t size = (size_t)width * height * 4;
    int fd = memfd_create("output-retry", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    unsigned frame = ++submitted;
    uint32_t color = frame % 2 ? 0xff204060 : 0xffe03070;
    for (size_t i = 0; i < size / 4; i++) pixels[i] = color;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_shm_pool_destroy(pool); munmap(pixels, size); close(fd);
    struct wp_presentation_feedback *feedback = wp_presentation_feedback(presentation, surface);
    wp_presentation_feedback_add_listener(feedback, &feedback_listener, (void *)(uintptr_t)frame);
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    xdg_surface_set_window_geometry(xdg, 0, 0, width, height);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
    #ifdef TEST_FIFO_V1
    wp_fifo_v1_wait_barrier(fifo);
    wp_fifo_v1_set_barrier(fifo);
    #endif
    wl_surface_commit(surface);
    printf("{\"event\":\"submitted\",\"frame\":%u,\"color\":%u,\"ms\":%.3f}\n", frame, color, now_ms());
    next_draw = now_ms() + 50;
}
static void configure(void *data, struct xdg_surface *object, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(object, serial);
    configured = true; draw();
}
static const struct xdg_surface_listener xdg_listener = { .configure = configure };
static void top_configure(void *data, struct xdg_toplevel *object, int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)object; (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
}
static void top_close(void *data, struct xdg_toplevel *object) { (void)data; (void)object; exit(0); }
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = top_close };
static void ping(void *data, struct xdg_wm_base *object, uint32_t serial) {
    (void)data; xdg_wm_base_pong(object, serial);
}
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void presentation_clock(void *data, struct wp_presentation *object, uint32_t id) {
    (void)data; (void)object; (void)id;
}
static const struct wp_presentation_listener presentation_listener = { .clock_id = presentation_clock };
static void geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t w, int32_t h,
                     int32_t sub, const char *make, const char *model, int32_t tr) {
    (void)d; (void)o; (void)x; (void)y; (void)w; (void)h; (void)sub; (void)make; (void)model; (void)tr;
}
static void mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {
    (void)d; (void)o; (void)f; (void)w; (void)h; (void)r;
}
static void done(void *d, struct wl_output *o) { (void)d; (void)o; }
static void scale(void *d, struct wl_output *o, int32_t s) { (void)d; (void)o; (void)s; }
static void name(void *d, struct wl_output *o, const char *n) {
    (void)o; snprintf(((struct output *)d)->name, 128, "%s", n);
}
static void description(void *d, struct wl_output *o, const char *s) { (void)d; (void)o; (void)s; }
static const struct wl_output_listener output_listener = {
    .geometry = geometry, .mode = mode, .done = done, .scale = scale, .name = name, .description = description,
};
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    #ifdef TEST_FIFO_V1
    if (!strcmp(interface, "wp_fifo_manager_v1")) {
        assert(version == 1);
        fifo_manager = wl_registry_bind(registry, id, &wp_fifo_manager_v1_interface, 1);
    }
    #endif
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
    if (!strcmp(interface, "wp_presentation")) {
        presentation = wl_registry_bind(registry, id, &wp_presentation_interface, 1);
        wp_presentation_add_listener(presentation, &presentation_listener, NULL);
    }
    if (!strcmp(interface, "wl_output") && version >= 4 && output_count < 16) {
        struct output *o = &outputs[output_count++];
        o->object = wl_registry_bind(registry, id, &wl_output_interface, 4);
        wl_output_add_listener(o->object, &output_listener, o);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    animated = atoi(argv[3]);
    #ifdef TEST_FIFO_V1
    burst = (unsigned)atoi(argv[3]);
    assert(burst > 0 && burst <= 1000);
    animated = false;
    #endif
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display); wl_display_roundtrip(display);
    assert(compositor && shm && wm && presentation);
    struct wl_output *target = NULL;
    for (unsigned i = 0; i < output_count; i++) if (!strcmp(outputs[i].name, argv[2])) target = outputs[i].object;
    assert(target);
    surface = wl_compositor_create_surface(compositor);
    #ifdef TEST_FIFO_V1
    assert(fifo_manager);
    fifo = wp_fifo_manager_v1_get_fifo(fifo_manager, surface);
    #endif
    xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &xdg_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, argv[1]); xdg_toplevel_set_app_id(top, argv[1]);
    xdg_toplevel_set_fullscreen(top, target); wl_surface_commit(surface);
    double report = 0;
    for (;;) {
        if (animated && configured && now_ms() >= next_draw) draw();
        if (now_ms() >= report) {
            printf("{\"event\":\"sample\",\"submitted\":%u,\"presented\":%u,\"callbacks\":%u,\"ms\":%.3f}\n",
                   submitted, presented, callbacks, now_ms());
            report = now_ms() + 100;
        }
        wl_display_flush(display);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, 5) < 0) return 1;
        if (fds[0].revents & POLLIN) { if (wl_display_dispatch(display) < 0) return 1; }
        else if (wl_display_dispatch_pending(display) < 0) return 1;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char command;
            if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') return 0;
            if (command == 'd') draw();
            #ifdef TEST_FIFO_V1
            if (command == 'b') for (unsigned i = 0; i < burst; i++) draw();
            if (command == 'h') { wl_surface_attach(surface, NULL, 0, 0); wl_surface_commit(surface); configured = false; }
            if (command == 'm') wl_surface_commit(surface);
            #endif
        }
    }
}
