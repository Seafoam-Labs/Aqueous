// SPDX-License-Identifier: MIT

#define _POSIX_C_SOURCE 200809L

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

struct app {
    struct wl_display *display;
    struct wl_seat *seat;
    struct zwlr_foreign_toplevel_manager_v1 *manager;
    const char *wanted_app_id;
    bool activated;
};

struct candidate {
    struct app *app;
    char *app_id;
};

static void handle_title(
    void *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle,
    const char *title) {
    (void)data;
    (void)handle;
    (void)title;
}

static void handle_app_id(
    void *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle,
    const char *app_id) {
    (void)handle;
    struct candidate *candidate = data;
    free(candidate->app_id);
    candidate->app_id = strdup(app_id);
}

static void handle_output(
    void *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle,
    struct wl_output *output) {
    (void)data;
    (void)handle;
    (void)output;
}

static void handle_state(
    void *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle,
    struct wl_array *state) {
    (void)data;
    (void)handle;
    (void)state;
}

static void handle_done(
    void *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle) {
    struct candidate *candidate = data;
    struct app *app = candidate->app;
    if (app->activated || app->seat == NULL || candidate->app_id == NULL) return;
    if (strcmp(candidate->app_id, app->wanted_app_id) != 0) return;
    zwlr_foreign_toplevel_handle_v1_activate(handle, app->seat);
    app->activated = true;
}

static void handle_closed(
    void *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle) {
    (void)data;
    (void)handle;
}

static void handle_parent(
    void *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle,
    struct zwlr_foreign_toplevel_handle_v1 *parent) {
    (void)data;
    (void)handle;
    (void)parent;
}

static const struct zwlr_foreign_toplevel_handle_v1_listener handle_listener = {
    .title = handle_title,
    .app_id = handle_app_id,
    .output_enter = handle_output,
    .output_leave = handle_output,
    .state = handle_state,
    .done = handle_done,
    .closed = handle_closed,
    .parent = handle_parent,
};

static void manager_toplevel(
    void *data,
    struct zwlr_foreign_toplevel_manager_v1 *manager,
    struct zwlr_foreign_toplevel_handle_v1 *handle) {
    (void)manager;
    struct app *app = data;
    struct candidate *candidate = calloc(1, sizeof(*candidate));
    if (candidate == NULL) exit(2);
    candidate->app = app;
    zwlr_foreign_toplevel_handle_v1_add_listener(handle, &handle_listener, candidate);
}

static void manager_finished(
    void *data,
    struct zwlr_foreign_toplevel_manager_v1 *manager) {
    (void)data;
    (void)manager;
}

static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = {
    .toplevel = manager_toplevel,
    .finished = manager_finished,
};

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version) {
    struct app *app = data;
    if (strcmp(interface, wl_seat_interface.name) == 0) {
        app->seat = wl_registry_bind(
            registry, name, &wl_seat_interface, version < 7 ? version : 7);
    } else if (strcmp(
        interface,
        zwlr_foreign_toplevel_manager_v1_interface.name) == 0) {
        app->manager = wl_registry_bind(
            registry,
            name,
            &zwlr_foreign_toplevel_manager_v1_interface,
            version < 3 ? version : 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(
            app->manager, &manager_listener, app);
    }
}

static void registry_remove(
    void *data,
    struct wl_registry *registry,
    uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_remove,
};

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    struct app app = {
        .display = wl_display_connect(NULL),
        .wanted_app_id = argv[1],
    };
    if (app.display == NULL) return 2;

    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    if (wl_display_roundtrip(app.display) < 0 || app.manager == NULL ||
        app.seat == NULL) return 2;
    for (unsigned int i = 0; i < 10 && !app.activated; i++) {
        if (wl_display_roundtrip(app.display) < 0) return 2;
    }
    if (!app.activated) return 1;
    return wl_display_flush(app.display) < 0 ? 2 : 0;
}
