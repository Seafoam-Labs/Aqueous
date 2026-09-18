// SPDX-License-Identifier: GPL-3.0-only
#include <wayland-client.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "aqueous-shell-client-protocol.h"
static struct aqueous_shell_manager_v1 *manager;
static int done;
static void capabilities(void *data, struct aqueous_shell_manager_v1 *m, const char *json) {(void)data; (void)m; (void)json;}
static void begin(void *data, struct aqueous_shell_manager_v1 *m, uint32_t serial) {(void)data; (void)m; (void)serial;}
static void fragment(void *data, struct aqueous_shell_manager_v1 *m, struct wl_array *json) {(void)data; (void)m; fwrite(json->data, 1, json->size, stdout);}
static void end(void *data, struct aqueous_shell_manager_v1 *m, uint32_t serial) {(void)data; (void)m; (void)serial; done = 1;}
static void result(void *data, struct aqueous_shell_manager_v1 *m, uint32_t id, uint32_t status, const char *sequence) {(void)data; (void)m; (void)id; (void)status; (void)sequence;}
static const struct aqueous_shell_manager_v1_listener listener = {.capabilities=capabilities,.begin=begin,.data=fragment,.done=end,.result=result};
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(interface, "aqueous_shell_manager_v1")) return;
    manager = wl_registry_bind(r, name, &aqueous_shell_manager_v1_interface, 2);
    aqueous_shell_manager_v1_add_listener(manager, &listener, NULL);
}
static void removed(void *data, struct wl_registry *r, uint32_t name) {(void)data; (void)r; (void)name;}
int main(void) {
    struct wl_display *d = wl_display_connect(NULL); assert(d);
    struct wl_registry *r = wl_display_get_registry(d);
    const struct wl_registry_listener registry = {.global=global,.global_remove=removed};
    wl_registry_add_listener(r, &registry, NULL);
    assert(wl_display_roundtrip(d) >= 0 && manager);
    aqueous_shell_manager_v1_subscribe(manager);
    while (!done) assert(wl_display_dispatch(d) >= 0);
    puts("");
    wl_display_disconnect(d);
}
