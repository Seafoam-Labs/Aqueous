// SPDX-License-Identifier: GPL-3.0-only
// Minimal external policy for exercising application input protocols.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wayland-client.h>
#include "aqueous-window-management-v1-client-protocol.h"

static struct aqueous_window_manager_v1 *manager;
static struct aqueous_seat_v1 *seat;
static struct aqueous_window_v1 *window;
static struct aqueous_node_v1 *node;
static bool proposed;
static void watch(void *proxy);
static int event(const void *impl, void *object, uint32_t opcode,
        const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)opcode;
    unsigned arg=0;
    for (const char *s=message->signature; *s; s++) {
        if ((*s>='0' && *s<='9') || *s=='?') continue;
        if (*s=='n') watch(args[arg].o);
        arg++;
    }
    const char *type=wl_proxy_get_class(object), *name=message->name;
    if (!strcmp(type,"aqueous_window_manager_v1")) {
        if (!strcmp(name,"window")) { assert(!window); window=(void*)args[0].o; proposed=false; }
        else if (!strcmp(name,"seat")) seat=(void*)args[0].o;
        else if (!strcmp(name,"manage_start")) {
            if (window) {
                if (!node) { node=aqueous_window_v1_get_node(window); watch(node); }
                if (!proposed) { aqueous_window_v1_propose_dimensions(window,320,240); proposed=true; }
                if (seat) aqueous_seat_v1_focus_window(seat,window);
            }
            aqueous_window_manager_v1_manage_finish(manager);
        } else if (!strcmp(name,"render_start")) {
            if (node) { aqueous_node_v1_set_position(node,100,100); aqueous_node_v1_place_top(node); }
            aqueous_window_manager_v1_render_finish(manager);
        } else if (!strcmp(name,"unavailable")) assert(!"policy unavailable");
    } else if (!strcmp(type,"aqueous_window_v1") && !strcmp(name,"closed")) {
        aqueous_node_v1_destroy(node); node=NULL;
        aqueous_window_v1_destroy(window); window=NULL;
    }
    return 0;
}
static void watch(void *proxy) { assert(wl_proxy_add_dispatcher(proxy,event,NULL,NULL)==0); }
static void global(void *d, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)d;
    if (!strcmp(interface,"aqueous_window_manager_v1")) {
        manager=wl_registry_bind(r,name,&aqueous_window_manager_v1_interface,version<4?version:4); watch(manager);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t n) { (void)d;(void)r;(void)n; }
static const struct wl_registry_listener listener={.global=global,.global_remove=removed};
int main(void) {
    struct wl_display *display=wl_display_connect(NULL); assert(display);
    struct wl_registry *registry=wl_display_get_registry(display);
    wl_registry_add_listener(registry,&listener,NULL);
    assert(wl_display_roundtrip(display)>=0 && manager);
    while (wl_display_dispatch(display)>=0) {}
    wl_display_disconnect(display);
}
