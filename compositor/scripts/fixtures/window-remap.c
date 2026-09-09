// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
// Persistent window controlled with single-byte commands: h(ide), s(how), q(uit).
// Compile with -DX11 for the XWayland variant. Neither variant recreates its
// window on show, matching an application's hide-to-tray lifecycle.
#define _POSIX_C_SOURCE 200809L
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    Display *display = XOpenDisplay(NULL);
    if (!display) return 1;
    Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
        0, 0, 320, 240, 0, 0, strtoul(argv[2], NULL, 16));
    XClassHint hint = {.res_name = argv[1], .res_class = argv[1]};
    XSetClassHint(display, window, &hint);
    XStoreName(display, window, argv[1]);
    XSelectInput(display, window, StructureNotifyMask | ExposureMask);
    XMapWindow(display, window);
    printf("WINDOW %lu\n", window);
    for (;;) {
        while (XPending(display)) {
            XEvent event;
            XNextEvent(display, &event);
            if (event.type == MapNotify) puts("MAPPED");
            if (event.type == UnmapNotify) puts("UNMAPPED");
            if (event.type == ConfigureNotify) {
                printf("CONFIGURE %d %d\n", event.xconfigure.width, event.xconfigure.height);
            }
            if (event.type == Expose || event.type == ConfigureNotify || event.type == MapNotify)
                XClearWindow(display, window);
        }
        XFlush(display);
        struct pollfd fds[] = {{ConnectionNumber(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) return 1;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char command;
            if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') break;
            if (command == 'h') XUnmapWindow(display, window);
            if (command == 's') XMapWindow(display, window);
        }
    }
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    return 0;
}
#else
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#ifdef TEST_FIFO_V1
#include "fifo-v1-client-protocol.h"
static struct wp_fifo_manager_v1 *fifo_manager;
static struct wp_fifo_v1 *fifo;
#endif
#ifdef SYNCOBJ
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <xf86drm.h>
#include <gbm.h>
#include "linux-drm-syncobj-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
static struct zwp_linux_dmabuf_v1 *dmabuf;
static struct gbm_device *gbm;
static struct wp_linux_drm_syncobj_manager_v1 *sync_manager;
static struct wp_linux_drm_syncobj_surface_v1 *sync_surface;
static struct wp_linux_drm_syncobj_timeline_v1 *acquire_timeline, *release_timeline;
static int drm_fd;
static uint32_t acquire_handle, release_handle;
static uint64_t release_point;

static struct wp_linux_drm_syncobj_timeline_v1 *create_timeline(uint32_t *handle) {
    int fd;
    if (drmSyncobjCreate(drm_fd, 0, handle) || drmSyncobjHandleToFD(drm_fd, *handle, &fd)) exit(1);
    struct wp_linux_drm_syncobj_timeline_v1 *timeline =
        wp_linux_drm_syncobj_manager_v1_import_timeline(sync_manager, fd);
    close(fd);
    return timeline;
}

static void check_detach_release(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t deadline = (int64_t)now.tv_sec * 1000000000 + now.tv_nsec + 2000000000;
    if (drmSyncobjTimelineWait(drm_fd, &release_handle, &release_point, 1, deadline,
                              DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT, NULL)) {
        fprintf(stderr, "FAIL: detached buffer release point %llu did not signal: %s\n",
                (unsigned long long)release_point, strerror(errno));
        exit(1);
    }
    printf("DETACH_RELEASED %llu\n", (unsigned long long)release_point);
}
#endif

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static bool showing = true;
static bool remapping;
static int width = 320, height = 240;
static uint32_t color;

static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data;
#ifdef SYNCOBJ
    if (!strcmp(interface, "zwp_linux_dmabuf_v1") && version >= 3)
        dmabuf = wl_registry_bind(registry, name, &zwp_linux_dmabuf_v1_interface, 3);
    if (!strcmp(interface, "wp_linux_drm_syncobj_manager_v1"))
        sync_manager = wl_registry_bind(registry, name, &wp_linux_drm_syncobj_manager_v1_interface, 1);
#endif
    #ifdef TEST_FIFO_V1
    if (!strcmp(interface, "wp_fifo_manager_v1"))
        fifo_manager = wl_registry_bind(registry, name, &wp_fifo_manager_v1_interface, 1);
    #endif
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
static void released(void *data, struct wl_buffer *buffer) {
#ifdef SYNCOBJ
    if (data) gbm_bo_destroy(data);
#else
    (void)data;
#endif
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {.release = released};
static void configured(void *data, struct xdg_surface *xdg, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xdg, serial);
    printf("CONFIGURE %u %d %d showing=%d\n", serial, width, height, showing);
    if (!showing) return;
    if (remapping && getenv("AQUEOUS_REMAP_WITHHOLD_BUFFER")) {
        puts("NEGATIVE_CONTROL: withholding remap buffer");
        return;
    }
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) exit(1);
#ifdef SYNCOBJ
    // This variant checks release fences, not pixel color. Use a DMA-BUF
    // without a CPU upload so allocation does not depend on driver mapping.
    struct gbm_bo *bo = gbm_bo_create(gbm, width, height, GBM_FORMAT_XRGB8888,
                                     GBM_BO_USE_RENDERING);
    if (!bo) { perror("gbm_bo_create"); exit(1); }
    release_point++;
    if (drmSyncobjTimelineSignal(drm_fd, &acquire_handle, &release_point, 1)) exit(1);
    uint64_t modifier = gbm_bo_get_modifier(bo);
    struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(dmabuf);
    for (int plane = 0; plane < gbm_bo_get_plane_count(bo); plane++) {
        int fd = gbm_bo_get_fd_for_plane(bo, plane);
        if (fd < 0) { perror("gbm_bo_get_fd_for_plane"); exit(1); }
        zwp_linux_buffer_params_v1_add(params, fd, plane, gbm_bo_get_offset(bo, plane),
                                      gbm_bo_get_stride_for_plane(bo, plane),
                                      modifier >> 32, (uint32_t)modifier);
        close(fd);
    }
    struct wl_buffer *buffer = zwp_linux_buffer_params_v1_create_immed(
        params, width, height, GBM_FORMAT_XRGB8888, 0);
    zwp_linux_buffer_params_v1_destroy(params);
    wl_buffer_add_listener(buffer, &buffer_listener, bo);
#else
    size_t size = (size_t)width * height * 4;
    char path[] = "/tmp/aqueous-remap-buffer.XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) exit(1);
    unlink(path);
    if (ftruncate(fd, (off_t)size)) exit(1);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) exit(1);
    for (size_t i = 0; i < size / 4; i++) pixels[i] = color;
    munmap(pixels, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_shm_pool_destroy(pool);
    close(fd);
#endif
    xdg_surface_set_window_geometry(xdg, 0, 0, width, height);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
#ifdef SYNCOBJ
    wp_linux_drm_syncobj_surface_v1_set_acquire_point(sync_surface, acquire_timeline,
                                                  release_point >> 32, (uint32_t)release_point);
    wp_linux_drm_syncobj_surface_v1_set_release_point(sync_surface, release_timeline,
                                                  release_point >> 32, (uint32_t)release_point);
#endif
    #ifdef TEST_FIFO_V1
    wp_fifo_v1_wait_barrier(fifo);
    wp_fifo_v1_set_barrier(fifo);
    #endif
    wl_surface_commit(surface);
    puts("BUFFER_COMMITTED");
}
static const struct xdg_surface_listener surface_listener = {.configure = configured};
static void size_configured(void *data, struct xdg_toplevel *toplevel, int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)toplevel; (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
}
static void closed(void *data, struct xdg_toplevel *toplevel) {
    (void)data; (void)toplevel;
    exit(0);
}
static const struct xdg_toplevel_listener toplevel_listener = {.configure = size_configured, .close = closed};

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    color = (uint32_t)strtoul(argv[2], NULL, 16);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !shm || !wm) return 1;
    surface = wl_compositor_create_surface(compositor);
    #ifdef TEST_FIFO_V1
    if (!fifo_manager) return 1;
    fifo = wp_fifo_manager_v1_get_fifo(fifo_manager, surface);
    #endif
#ifdef SYNCOBJ
    const char *device = getenv("AQUEOUS_REMAP_DRM_DEVICE");
    drm_fd = open(device ? device : "/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (drm_fd < 0 || !sync_manager || !dmabuf || !(gbm = gbm_create_device(drm_fd))) {
        fputs("FAIL: syncobj fixture needs a DRM render device and syncobj protocol\n", stderr);
        return 1;
    }
    acquire_timeline = create_timeline(&acquire_handle);
    release_timeline = create_timeline(&release_handle);
    sync_surface = wp_linux_drm_syncobj_manager_v1_get_surface(sync_manager, surface);
#endif
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, argv[1]);
    xdg_toplevel_set_title(toplevel, argv[1]);
    wl_surface_commit(surface);
    printf("WINDOW %u\n", wl_proxy_get_id((struct wl_proxy *)surface));
    for (;;) {
        if (wl_display_dispatch_pending(display) < 0) return 1;
        wl_display_flush(display);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) return 1;
        if (fds[0].revents & (POLLERR | POLLHUP)) return 1;
        if ((fds[0].revents & POLLIN) && wl_display_dispatch(display) < 0) return 1;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            char command;
            if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') break;
            if (command == 'h' && showing) {
#ifdef SYNCOBJ
                // An empty commit must preserve the attached buffer's release
                // state; only the subsequent explicit NULL attachment ends it.
                wl_surface_commit(surface);
                if (wl_display_roundtrip(display) < 0) return 1;
                uint64_t signalled;
                if (drmSyncobjQuery(drm_fd, &release_handle, &signalled, 1) || signalled >= release_point) {
                    fputs("FAIL: bufferless commit released the still-attached buffer\n", stderr);
                    return 1;
                }
                puts("BUFFERLESS_COMMIT_RETAINED");
#endif
                showing = false;
                wl_surface_attach(surface, NULL, 0, 0);
                wl_surface_commit(surface);
                puts("UNMAP_COMMITTED");
#ifdef SYNCOBJ
                // Do not commit a replacement buffer until the detached one is
                // released: this is the dependency that stalls Electron's queue.
                if (wl_display_roundtrip(display) < 0) return 1;
                check_detach_release();
#endif
            }
            if (command == 's' && !showing) {
                showing = true;
                remapping = true;
                // xdg-shell resets toplevel attributes on unmap.
                xdg_toplevel_set_app_id(toplevel, argv[1]);
                xdg_toplevel_set_title(toplevel, argv[1]);
                wl_surface_commit(surface);
                puts("REMAP_REQUESTED");
            }
        }
    }
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdg);
    wl_surface_destroy(surface);
    wl_display_flush(display);
    wl_display_disconnect(display);
#ifdef SYNCOBJ
    drmSyncobjDestroy(drm_fd, acquire_handle);
    drmSyncobjDestroy(drm_fd, release_handle);
    gbm_device_destroy(gbm);
    close(drm_fd);
#endif
    return 0;
}
#endif
