// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

// Integration fixture for aqueous_shell_manager_v1 version 4 shell-drawn
// decorations. Creates an xdg-toplevel with an xdg-decoration object,
// subscribes to shell state, waits for ssd_renderer "shell", creates an
// above-placement decoration, commits a buffer, and checks recoverable
// error statuses for an invalid move serial and an unknown window ID.

#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "aqueous-shell-v1-client-protocol.h"

#define APP_ID "org.test.ShellDecoration"
#define WINDOW_W 64
#define WINDOW_H 64
#define BAR_H 30

struct fixture {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct zxdg_decoration_manager_v1 *decoration_manager;
    struct aqueous_shell_manager_v1 *shell;

    struct wl_surface *window_surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct zxdg_toplevel_decoration_v1 *toplevel_decoration;

    struct wl_surface *deco_surface;
    struct aqueous_shell_decoration_v1 *deco;
    struct aqueous_shell_decoration_v1 *inert_deco;

    char window_id[64];
    int have_window_id;
    int configured;
    int saw_shell_renderer;
    int deco_applied;
    int move_invalid;
    int not_found;
    int failed;

    char *batch;
    size_t batch_len;
    size_t batch_cap;
    int in_batch;
};

static void fail(struct fixture *f, const char *msg) {
    fprintf(stderr, "FAIL: %s\n", msg);
    f->failed = 1;
}

static void *shm_buffer(struct fixture *f, int width, int height,
                        struct wl_buffer **buffer_out) {
    int stride = width * 4;
    int size = stride * height;
    int fd = memfd_create("shell-decoration-fixture", 0);
    if (fd < 0) return NULL;
    if (ftruncate(fd, size) < 0) { close(fd); return NULL; }
    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { close(fd); return NULL; }
    struct wl_shm_pool *pool = wl_shm_create_pool(f->shm, fd, size);
    *buffer_out = wl_shm_pool_create_buffer(pool, 0, width, height, stride,
                                            WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    memset(data, 0xff, size);
    return data;
}

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void xdg_surface_configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    struct fixture *f = data;
    xdg_surface_ack_configure(surface, serial);
    f->configured = 1;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                               int32_t width, int32_t height, struct wl_array *states) {
    (void)data; (void)toplevel; (void)width; (void)height; (void)states;
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)data; (void)toplevel;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
};

static void decoration_configure(void *data,
                                 struct zxdg_toplevel_decoration_v1 *decoration,
                                 uint32_t mode) {
    (void)data; (void)decoration; (void)mode;
}

static const struct zxdg_toplevel_decoration_v1_listener decoration_listener = {
    .configure = decoration_configure,
};

static void batch_append(struct fixture *f, const char *bytes, size_t len) {
    if (f->batch_len + len + 1 > f->batch_cap) {
        size_t cap = f->batch_cap ? f->batch_cap * 2 : 65536;
        while (cap < f->batch_len + len + 1) cap *= 2;
        char *fresh = realloc(f->batch, cap);
        if (!fresh) { fail(f, "out of memory"); return; }
        f->batch = fresh;
        f->batch_cap = cap;
    }
    memcpy(f->batch + f->batch_len, bytes, len);
    f->batch_len += len;
    f->batch[f->batch_len] = '\0';
}

// Locate our window entity and extract its shell ID plus ssd_renderer.
static void scan_batch(struct fixture *f) {
    const char *app = strstr(f->batch, "\"app_id\":\"" APP_ID "\"");
    if (!app) return;
    const char *id_key = NULL;
    for (const char *p = f->batch; p < app; ) {
        const char *hit = strstr(p, "\"id\":\"");
        if (!hit || hit >= app) break;
        id_key = hit;
        p = hit + 1;
    }
    if (!id_key) return;
    const char *start = id_key + 6;
    const char *end = strchr(start, '"');
    if (!end || (size_t)(end - start) >= sizeof(f->window_id)) return;
    if (!f->have_window_id) {
        memcpy(f->window_id, start, (size_t)(end - start));
        f->window_id[end - start] = '\0';
        f->have_window_id = 1;
        printf("WINDOW_ID %s\n", f->window_id);
        fflush(stdout);
    }
    // The renderer field follows the app_id within the same entity.
    const char *next_kind = strstr(app, "\"kind\":");
    const char *renderer = strstr(app, "\"ssd_renderer\":\"shell\"");
    if (renderer && (!next_kind || renderer < next_kind)) {
        if (!f->saw_shell_renderer) {
            f->saw_shell_renderer = 1;
            printf("SSD_RENDERER shell\n");
            fflush(stdout);
        }
    }
}

static void shell_capabilities(void *data, struct aqueous_shell_manager_v1 *shell,
                               const char *json) {
    (void)shell;
    struct fixture *f = data;
    if (!strstr(json, "\"window_decorations\":true"))
        fail(f, "capabilities missing window_decorations");
}

static void shell_begin(void *data, struct aqueous_shell_manager_v1 *shell, uint32_t serial) {
    (void)shell; (void)serial;
    struct fixture *f = data;
    f->batch_len = 0;
    f->in_batch = 1;
}

static void shell_data(void *data, struct aqueous_shell_manager_v1 *shell,
                       struct wl_array *bytes) {
    (void)shell;
    struct fixture *f = data;
    if (f->in_batch) batch_append(f, bytes->data, bytes->size);
}

static void shell_done(void *data, struct aqueous_shell_manager_v1 *shell, uint32_t serial) {
    (void)shell;
    struct fixture *f = data;
    f->in_batch = 0;
    if (f->batch_len) scan_batch(f);
    aqueous_shell_manager_v1_ack(shell, serial);
}

static void shell_result(void *data, struct aqueous_shell_manager_v1 *shell,
                         uint32_t request_id, uint32_t status, const char *sequence) {
    (void)shell; (void)sequence;
    struct fixture *f = data;
    if (request_id == 1 && status == AQUEOUS_SHELL_MANAGER_V1_STATUS_APPLIED) {
        f->deco_applied = 1;
        printf("DECORATION applied\n");
        fflush(stdout);
    } else if (request_id == 2 && status == AQUEOUS_SHELL_MANAGER_V1_STATUS_INVALID) {
        f->move_invalid = 1;
        printf("MOVE invalid\n");
        fflush(stdout);
    } else if (request_id == 3 && status == AQUEOUS_SHELL_MANAGER_V1_STATUS_NOT_FOUND) {
        f->not_found = 1;
        printf("UNKNOWN not_found\n");
        fflush(stdout);
    } else {
        fprintf(stderr, "unexpected result request=%u status=%u\n", request_id, status);
        f->failed = 1;
    }
}

static void shell_workspace_id(void *data, struct aqueous_shell_manager_v1 *shell,
                               uint32_t request_id, const char *id) {
    (void)data; (void)shell; (void)request_id; (void)id;
}

static const struct aqueous_shell_manager_v1_listener shell_listener = {
    .capabilities = shell_capabilities,
    .begin = shell_begin,
    .data = shell_data,
    .done = shell_done,
    .result = shell_result,
    .workspace_id = shell_workspace_id,
};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    struct fixture *f = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        f->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        f->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        f->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 2);
        xdg_wm_base_add_listener(f->wm_base, &wm_base_listener, f);
    } else if (strcmp(interface, zxdg_decoration_manager_v1_interface.name) == 0) {
        f->decoration_manager = wl_registry_bind(
            registry, name, &zxdg_decoration_manager_v1_interface, 1);
    } else if (strcmp(interface, aqueous_shell_manager_v1_interface.name) == 0) {
        uint32_t bind_version = version < 4 ? version : 4;
        f->shell = wl_registry_bind(registry, name,
                                    &aqueous_shell_manager_v1_interface, bind_version);
        aqueous_shell_manager_v1_add_listener(f->shell, &shell_listener, f);
    }
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global,
    .global_remove = global_remove,
};

static int dispatch_until(struct fixture *f, int (*done)(struct fixture *)) {
    for (int i = 0; i < 2000 && !f->failed; i++) {
        if (done(f)) return 1;
        if (wl_display_dispatch(f->display) < 0) {
            fail(f, "display disconnected");
            return 0;
        }
    }
    return done(f);
}

static int have_id_and_renderer(struct fixture *f) {
    return f->have_window_id && f->saw_shell_renderer;
}

static int deco_applied(struct fixture *f) { return f->deco_applied; }
static int all_results(struct fixture *f) { return f->move_invalid && f->not_found; }

int main(void) {
    struct fixture f = {0};
    f.display = wl_display_connect(NULL);
    if (!f.display) { fprintf(stderr, "unable to connect\n"); return 1; }

    struct wl_registry *registry = wl_display_get_registry(f.display);
    wl_registry_add_listener(registry, &registry_listener, &f);
    wl_display_roundtrip(f.display);
    if (!f.compositor || !f.shm || !f.wm_base || !f.shell || !f.decoration_manager) {
        fprintf(stderr, "missing globals\n");
        return 1;
    }
    if (aqueous_shell_manager_v1_get_version(f.shell) < 4) {
        fprintf(stderr, "shell manager version < 4\n");
        return 1;
    }

    // Our test window with an xdg-decoration object preferring SSD.
    f.window_surface = wl_compositor_create_surface(f.compositor);
    f.xdg_surface = xdg_wm_base_get_xdg_surface(f.wm_base, f.window_surface);
    xdg_surface_add_listener(f.xdg_surface, &xdg_surface_listener, &f);
    f.toplevel = xdg_surface_get_toplevel(f.xdg_surface);
    xdg_toplevel_add_listener(f.toplevel, &toplevel_listener, &f);
    xdg_toplevel_set_app_id(f.toplevel, APP_ID);
    xdg_toplevel_set_title(f.toplevel, "Shell decoration fixture");
    f.toplevel_decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(
        f.decoration_manager, f.toplevel);
    zxdg_toplevel_decoration_v1_add_listener(f.toplevel_decoration, &decoration_listener, &f);
    zxdg_toplevel_decoration_v1_set_mode(f.toplevel_decoration,
        ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);

    struct wl_buffer *window_buffer = NULL;
    void *window_data = shm_buffer(&f, WINDOW_W, WINDOW_H, &window_buffer);
    if (!window_data) { fprintf(stderr, "shm failed\n"); return 1; }
    // xdg-shell requires the initial configure before the first buffer commit.
    wl_surface_commit(f.window_surface);
    for (int i = 0; i < 1000 && !f.configured && !f.failed; i++) {
        if (wl_display_dispatch(f.display) < 0) { fail(&f, "display disconnected"); break; }
    }
    if (!f.configured) { fprintf(stderr, "never configured\n"); return 1; }
    wl_surface_attach(f.window_surface, window_buffer, 0, 0);
    wl_surface_damage_buffer(f.window_surface, 0, 0, WINDOW_W, WINDOW_H);
    wl_surface_commit(f.window_surface);

    aqueous_shell_manager_v1_subscribe(f.shell);
    if (!dispatch_until(&f, have_id_and_renderer)) {
        fprintf(stderr, "never saw window with ssd_renderer shell\n");
        return 1;
    }

    // Create the titlebar decoration and commit a solid buffer above the window.
    f.deco_surface = wl_compositor_create_surface(f.compositor);
    f.deco = aqueous_shell_manager_v1_get_window_decoration(
        f.shell, 1, f.window_id, AQUEOUS_SHELL_MANAGER_V1_DECORATION_PLACEMENT_ABOVE,
        f.deco_surface);
    if (!dispatch_until(&f, deco_applied)) {
        fprintf(stderr, "decoration creation not applied\n");
        return 1;
    }
    struct wl_buffer *bar_buffer = NULL;
    void *bar_data = shm_buffer(&f, WINDOW_W, BAR_H, &bar_buffer);
    if (!bar_data) { fprintf(stderr, "shm failed\n"); return 1; }
    aqueous_shell_decoration_v1_set_offset(f.deco, 0, -BAR_H);
    wl_surface_attach(f.deco_surface, bar_buffer, 0, 0);
    wl_surface_damage_buffer(f.deco_surface, 0, 0, WINDOW_W, BAR_H);
    wl_surface_commit(f.deco_surface);
    wl_display_roundtrip(f.display);

    // Invalid serial must be rejected recoverably.
    aqueous_shell_manager_v1_window_interactive_move(f.shell, 2, f.window_id, "", 0);
    // Unknown window ID must produce an inert decoration plus not_found.
    f.inert_deco = aqueous_shell_manager_v1_get_window_decoration(
        f.shell, 3, "no-such-window", AQUEOUS_SHELL_MANAGER_V1_DECORATION_PLACEMENT_ABOVE,
        wl_compositor_create_surface(f.compositor));
    if (!dispatch_until(&f, all_results)) {
        fprintf(stderr, "missing recoverable error results\n");
        return 1;
    }
    aqueous_shell_decoration_v1_destroy(f.inert_deco);
    wl_display_roundtrip(f.display);

    aqueous_shell_decoration_v1_destroy(f.deco);
    wl_surface_destroy(f.deco_surface);
    aqueous_shell_manager_v1_destroy(f.shell);
    wl_display_roundtrip(f.display);

    munmap(bar_data, WINDOW_W * 4 * BAR_H);
    munmap(window_data, WINDOW_W * 4 * WINDOW_H);
    wl_buffer_destroy(bar_buffer);
    wl_buffer_destroy(window_buffer);
    zxdg_toplevel_decoration_v1_destroy(f.toplevel_decoration);
    xdg_toplevel_destroy(f.toplevel);
    xdg_surface_destroy(f.xdg_surface);
    wl_surface_destroy(f.window_surface);
    free(f.batch);
    wl_registry_destroy(registry);
    wl_display_disconnect(f.display);
    printf("DONE\n");
    return f.failed ? 1 : 0;
}