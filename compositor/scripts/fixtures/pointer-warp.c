// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <time.h>
#include <xkbcommon/xkbcommon.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "pointer-warp-client-protocol.h"
#include "pointer-constraints-client-protocol.h"
#include "relative-pointer-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "aqueous-input-client-protocol.h"
#include "virtual-keyboard-client-protocol.h"
#include "virtual-pointer-client-protocol.h"
#include "security-context-client-protocol.h"
static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_pointer_warp_v1 *manager;
static struct wl_registry *registry;
static uint32_t manager_name;
static struct wl_subcompositor *subcompositor;
static struct wp_viewporter *viewporter;
static struct zwp_pointer_constraints_v1 *constraints;
static struct zwp_relative_pointer_manager_v1 *relative_manager;
static struct zwp_locked_pointer_v1 *locked;
static struct zwp_confined_pointer_v1 *confined;
static struct wl_pointer *pointers[8];
static uint32_t enter_serial, saved_serial;
static int pointer_count;
static struct zwlr_virtual_pointer_v1 *pointer;
static struct wp_security_context_manager_v1 *security;
static struct wl_seat *seat, *second_seat;
static struct aqueous_input_manager_v1 *input_manager;
static struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
static struct zwp_virtual_keyboard_v1 *second_keyboard;
static struct wl_data_device_manager *data_manager;
static struct wl_data_device *data_device;
static struct wl_data_source *data_source;
static uint32_t keyboard_serial;
static uint32_t input_serial;
static uint32_t timestamp(void) {
    struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC,&t)==0);
    return (uint32_t)((uint64_t)t.tv_sec*1000+t.tv_nsec/1000000);
}
static const char *label;
struct window {
    struct wl_surface *surface;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    struct xdg_popup *popup;
    struct wl_subsurface *sub;
    struct wp_viewport *viewport;
    int id, width, height, inset, scale, transform;
    bool delay, mapped;
    uint32_t serial, states;
};
static struct window windows[16];
static void release(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener buffer_listener = {.release = release};
static void draw(struct window *w) {
    int fd = memfd_create("pointer-warp", MFD_CLOEXEC);
    int bw=w->width*w->scale, bh=w->height*w->scale;
    if (w->transform % 2) { int swap=bw; bw=bh; bh=swap; }
    size_t size = (size_t)bw * bh * 4;
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    // Primary colors make scene-layer assertions independent of color transforms.
    const uint32_t colors[] = {0xff0000, 0x00ff00, 0x0000ff, 0xffff00};
    for (size_t i = 0; i < size / 4; i++) pixels[i] = colors[w->id % 4];
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, bw, bh, bw * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    if (w->xdg) xdg_surface_set_window_geometry(w->xdg, w->inset, w->inset, w->width - 2*w->inset, w->height - 2*w->inset);
    wl_surface_set_buffer_scale(w->surface,w->scale);
    wl_surface_set_buffer_transform(w->surface,w->transform);
    wl_surface_attach(w->surface, buffer, 0, 0);
    wl_surface_damage(w->surface, 0, 0, w->width, w->height);
    wl_surface_commit(w->surface);
    wl_shm_pool_destroy(pool); munmap(pixels, size); close(fd);
    w->mapped = true;
}
static void acknowledge(struct window *w) {
    xdg_surface_ack_configure(w->xdg, w->serial);
    draw(w);
}
static void configured(void *data, struct xdg_surface *surface, uint32_t serial) {
    (void)surface; struct window *w = data; w->serial = serial;
    printf("{\"event\":\"configure\",\"id\":%d,\"states\":%u,\"width\":%d,\"height\":%d}\n", w->id, w->states, w->width, w->height);
    if (!w->delay) acknowledge(w);
}
static const struct xdg_surface_listener surface_listener = {.configure = configured};
static void top_configured(void *data, struct xdg_toplevel *top, int32_t width, int32_t height, struct wl_array *states) {
    (void)top; struct window *w = data;
    if (width > 0) w->width = width + 2*w->inset;
    if (height > 0) w->height = height + 2*w->inset;
    w->states = 0; uint32_t *state;
    wl_array_for_each(state, states) if (*state < 32) w->states |= 1u << *state;
}
static void closed(void *data, struct xdg_toplevel *top) { (void)data; (void)top; }
static void bounds(void *data, struct xdg_toplevel *top, int32_t w, int32_t h) { (void)data; (void)top; (void)w; (void)h; }
static void capabilities(void *data, struct xdg_toplevel *top, struct wl_array *caps) { (void)data; (void)top; (void)caps; }
static const struct xdg_toplevel_listener top_listener = {.configure = top_configured, .close = closed, .configure_bounds = bounds, .wm_capabilities = capabilities};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) { (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static int surface_id(struct wl_surface *surface) {
    for (int i=0;i<16;i++) if (windows[i].surface==surface) return i;
    return -1;
}
static void p_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    (void)p; enter_serial=serial;
    printf("{\"event\":\"enter\",\"pointer\":%ld,\"id\":%d,\"serial\":%u,\"x\":%f,\"y\":%f}\n",(long)d,surface_id(surface),serial,wl_fixed_to_double(x),wl_fixed_to_double(y));
}
static void p_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *surface) {
    (void)p;(void)serial; printf("{\"event\":\"leave\",\"pointer\":%ld,\"id\":%d}\n",(long)d,surface_id(surface));
}
static void p_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    (void)p;(void)t; printf("{\"event\":\"motion\",\"pointer\":%ld,\"x\":%f,\"y\":%f}\n",(long)d,wl_fixed_to_double(x),wl_fixed_to_double(y));
}
static void p_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t state) {
    (void)d;(void)p;(void)t;(void)b; input_serial=s;
    printf("{\"event\":\"button\",\"serial\":%u,\"state\":%u}\n",s,state);
}
static void p_frame(void *d, struct wl_pointer *p) { (void)p; printf("{\"event\":\"frame\",\"pointer\":%ld}\n",(long)d); }
static void p_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) { (void)d;(void)p;(void)t;(void)a;(void)v; }
static void p_source(void *d, struct wl_pointer *p, uint32_t s) { (void)d;(void)p;(void)s; }
static void p_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) { (void)d;(void)p;(void)t;(void)a; }
static void p_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d;(void)p;(void)a;(void)v; }
static const struct wl_pointer_listener pointer_listener = { .enter=p_enter,.leave=p_leave,.motion=p_motion,.button=p_button,.axis=p_axis,.frame=p_frame,.axis_source=p_source,.axis_stop=p_stop,.axis_discrete=p_discrete };
static void relative(void *d, struct zwp_relative_pointer_v1 *p, uint32_t hi, uint32_t lo, wl_fixed_t dx, wl_fixed_t dy, wl_fixed_t ux, wl_fixed_t uy) {
    (void)d;(void)p;(void)hi;(void)lo;(void)dx;(void)dy;(void)ux;(void)uy; puts("{\"event\":\"relative\"}");
}
static const struct zwp_relative_pointer_v1_listener relative_listener = {.relative_motion=relative};
static void add_pointer(void) {
    assert(pointer_count<8); int id=pointer_count++;
    pointers[id]=wl_seat_get_pointer(seat); wl_pointer_add_listener(pointers[id],&pointer_listener,(void*)(long)id);
    if (!id) {
        struct zwp_relative_pointer_v1 *rp=zwp_relative_pointer_manager_v1_get_relative_pointer(relative_manager,pointers[id]);
        zwp_relative_pointer_v1_add_listener(rp,&relative_listener,NULL);
    }
}
static void caps(void *d, struct wl_seat *s, uint32_t caps) {
    (void)d;
    if (s==seat && !pointer_count && (caps & WL_SEAT_CAPABILITY_POINTER)) add_pointer();
    else if (s==second_seat && (caps & WL_SEAT_CAPABILITY_POINTER) && !pointers[7]) {
        pointers[7]=wl_seat_get_pointer(s); wl_pointer_add_listener(pointers[7],&pointer_listener,(void*)7);
        puts("{\"event\":\"second-seat\"}");
    }
}
static void keyboard_keymap(struct zwp_virtual_keyboard_v1 *keyboard) {
    struct xkb_context *context=xkb_context_new(XKB_CONTEXT_NO_FLAGS); assert(context);
    struct xkb_keymap *keymap=xkb_keymap_new_from_names(context,NULL,XKB_KEYMAP_COMPILE_NO_FLAGS); assert(keymap);
    char *text=xkb_keymap_get_as_string(keymap,XKB_KEYMAP_FORMAT_TEXT_V1); assert(text);
    size_t size=strlen(text)+1; int fd=memfd_create("pointer-warp-keymap",MFD_CLOEXEC); assert(fd>=0);
    assert(write(fd,text,size)==(ssize_t)size);
    zwp_virtual_keyboard_v1_keymap(keyboard,WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,fd,size);
    close(fd); free(text); xkb_keymap_unref(keymap); xkb_context_unref(context);
}
static void seat_name(void *d, struct wl_seat *s, const char *name) {
    (void)d;
    if (!strcmp(name,"warp-second")) {
        second_seat=s;
        second_keyboard=zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager,s);
        keyboard_keymap(second_keyboard);
        assert(wl_display_flush(display)>=0);
    }
}
static const struct wl_seat_listener seat_listener = {.capabilities=caps,.name=seat_name};
static void lock_on(void *d, struct zwp_locked_pointer_v1 *p) { (void)d;(void)p; puts("{\"event\":\"locked\"}"); }
static void lock_off(void *d, struct zwp_locked_pointer_v1 *p) { (void)d;(void)p; puts("{\"event\":\"unlocked\"}"); }
static const struct zwp_locked_pointer_v1_listener lock_listener = {.locked=lock_on,.unlocked=lock_off};
static void confine_on(void *d, struct zwp_confined_pointer_v1 *p) { (void)d;(void)p; puts("{\"event\":\"confined\"}"); }
static void confine_off(void *d, struct zwp_confined_pointer_v1 *p) { (void)d;(void)p; puts("{\"event\":\"unconfined\"}"); }
static const struct zwp_confined_pointer_v1_listener confine_listener = {.confined=confine_on,.unconfined=confine_off};
static void global(void *d, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)d;
    if (!strcmp(interface,"wl_compositor")) compositor=wl_registry_bind(r,name,&wl_compositor_interface,4);
    else if (!strcmp(interface,"wl_subcompositor")) subcompositor=wl_registry_bind(r,name,&wl_subcompositor_interface,1);
    else if (!strcmp(interface,"wp_viewporter")) viewporter=wl_registry_bind(r,name,&wp_viewporter_interface,1);
    else if (!strcmp(interface,"wl_shm")) shm=wl_registry_bind(r,name,&wl_shm_interface,1);
    else if (!strcmp(interface,"xdg_wm_base")) { wm=wl_registry_bind(r,name,&xdg_wm_base_interface,version<7?version:7); xdg_wm_base_add_listener(wm,&wm_listener,NULL); }
    else if (!strcmp(interface,"wp_pointer_warp_v1")) { manager_name=name; manager=wl_registry_bind(r,name,&wp_pointer_warp_v1_interface,1); printf("{\"event\":\"global\",\"version\":%u}\n",version); }
    else if (!strcmp(interface,"wl_seat")) { struct wl_seat *s=wl_registry_bind(r,name,&wl_seat_interface,7); if (!seat) seat=s; wl_seat_add_listener(s,&seat_listener,NULL); }
    else if (!strcmp(interface,"aqueous_input_manager_v1")) input_manager=wl_registry_bind(r,name,&aqueous_input_manager_v1_interface,1);
    else if (!strcmp(interface,"zwp_virtual_keyboard_manager_v1")) keyboard_manager=wl_registry_bind(r,name,&zwp_virtual_keyboard_manager_v1_interface,1);
    else if (!strcmp(interface,"wl_data_device_manager")) data_manager=wl_registry_bind(r,name,&wl_data_device_manager_interface,3);
    else if (!strcmp(interface,"zwp_pointer_constraints_v1")) constraints=wl_registry_bind(r,name,&zwp_pointer_constraints_v1_interface,1);
    else if (!strcmp(interface,"zwp_relative_pointer_manager_v1")) relative_manager=wl_registry_bind(r,name,&zwp_relative_pointer_manager_v1_interface,1);
    else if (!strcmp(interface,"wp_security_context_manager_v1")) security=wl_registry_bind(r,name,&wp_security_context_manager_v1_interface,1);
    else if (!strcmp(interface,"zwlr_virtual_pointer_manager_v1")) {
        struct zwlr_virtual_pointer_manager_v1 *pm=wl_registry_bind(r,name,&zwlr_virtual_pointer_manager_v1_interface,1);
        pointer=zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pm,NULL); zwlr_virtual_pointer_manager_v1_destroy(pm);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t name) { (void)d;(void)r;(void)name; }
static const struct wl_registry_listener registry_listener = {.global=global,.global_remove=removed};
static void create(int id, int delay, int inset) {
    struct window *w=&windows[id]; assert(!w->surface);
    *w=(struct window){.id=id,.width=320,.height=240,.delay=delay,.inset=inset,.scale=1};
    w->surface=wl_compositor_create_surface(compositor); w->xdg=xdg_wm_base_get_xdg_surface(wm,w->surface);
    xdg_surface_add_listener(w->xdg,&surface_listener,w); w->top=xdg_surface_get_toplevel(w->xdg);
    xdg_toplevel_add_listener(w->top,&top_listener,w);
    char name[100]; snprintf(name,sizeof(name),"%s-%d",label,id);
    xdg_toplevel_set_app_id(w->top,name); xdg_toplevel_set_title(w->top,name); wl_surface_commit(w->surface);
}
static void source_target(void *d, struct wl_data_source *s, const char *m) { (void)d;(void)s;(void)m; }
static void source_send(void *d, struct wl_data_source *s, const char *m, int32_t fd) { (void)d;(void)s;(void)m; close(fd); }
static void source_event(void *d, struct wl_data_source *s) { (void)d;(void)s; puts("{\"event\":\"drag-event\"}"); }
static void source_action(void *d, struct wl_data_source *s, uint32_t a) { (void)d;(void)s;(void)a; }
static const struct wl_data_source_listener source_listener = {.target=source_target,.send=source_send,.cancelled=source_event,.dnd_drop_performed=source_event,.dnd_finished=source_event,.action=source_action};
static int discard_event(const void *impl, void *object, uint32_t opcode, const struct wl_message *message, union wl_argument *args) {
    (void)impl;(void)opcode;
    unsigned arg=0;
    for (const char *s=message->signature; *s; s++) {
        if ((*s>='0' && *s<='9') || *s=='?') continue;
        if (*s=='n') wl_proxy_add_dispatcher((struct wl_proxy*)args[arg].o,discard_event,NULL,NULL);
        arg++;
    }
    if (!strcmp(wl_proxy_get_class(object),"wl_keyboard")) {
        if (!strcmp(message->name,"keymap")) close(args[1].h);
        else if (!strcmp(message->name,"enter") || !strcmp(message->name,"key")) { keyboard_serial=args[0].u; printf("{\"event\":\"keyboard\",\"serial\":%u}\n",keyboard_serial); }
    }
    return 0;
}
static void popup_configure(void *data, struct xdg_popup *popup, int32_t x, int32_t y, int32_t width, int32_t height) {
    (void)popup; struct window *w=data; w->width=width; w->height=height;
    printf("{\"event\":\"popup\",\"id\":%d,\"x\":%d,\"y\":%d}\n",w->id,x,y);
}
static void popup_done(void *d, struct xdg_popup *p) { (void)d;(void)p; }
static void popup_repositioned(void *d, struct xdg_popup *p, uint32_t token) { (void)d;(void)p;(void)token; }
static const struct xdg_popup_listener popup_listener={.configure=popup_configure,.popup_done=popup_done,.repositioned=popup_repositioned};
static bool command(char *line) {
    char op[32]; int a=0,b=0,c=0; assert(sscanf(line,"%31s %d %d %d",op,&a,&b,&c)>=1);
    struct window *w=(a>=0 && a<16)?&windows[a]:NULL;
    if (!strcmp(op,"quit")) return false;
    if (!strcmp(op,"create")) create(a,b,c);
    else if (!strcmp(op,"warp")) {
        double x,y; unsigned serial=enter_serial; int p=0; char kind[32]="enter";
        assert(sscanf(line,"%*s %d %lf %lf %31s %d",&a,&x,&y,kind,&p)>=3);
        if (!strcmp(kind,"saved")) serial=saved_serial;
        else if (!strcmp(kind,"button")) serial=input_serial;
        else if (!strcmp(kind,"keyboard")) serial=keyboard_serial;
        else if (strcmp(kind,"enter")) serial=(uint32_t)strtoul(kind,NULL,10);
        wp_pointer_warp_v1_warp_pointer(manager,windows[a].surface,pointers[p],wl_fixed_from_double(x),wl_fixed_from_double(y),serial);
    }
    else if (!strcmp(op,"create-seat")) aqueous_input_manager_v1_create_seat(input_manager,"warp-second");
    else if (!strcmp(op,"destroy-seat")) aqueous_input_manager_v1_destroy_seat(input_manager,"warp-second");
    else if (!strcmp(op,"keyboard")) {
        struct zwp_virtual_keyboard_v1 *vk=zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager,seat);
        keyboard_keymap(vk);
        struct wl_keyboard *k=wl_seat_get_keyboard(seat); wl_proxy_add_dispatcher((struct wl_proxy*)k,discard_event,NULL,NULL);
    }
    else if (!strcmp(op,"drag")) {
        if (!data_device) {
            data_device=wl_data_device_manager_get_data_device(data_manager,seat);
            wl_proxy_add_dispatcher((struct wl_proxy*)data_device,discard_event,NULL,NULL);
        }
        data_source=wl_data_device_manager_create_data_source(data_manager);
        wl_data_source_add_listener(data_source,&source_listener,NULL);
        wl_data_source_offer(data_source,"text/plain"); wl_data_source_set_actions(data_source,WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
        wl_data_device_start_drag(data_device,data_source,w->surface,NULL,input_serial);
    }
    else if (!strcmp(op,"end-drag")) { wl_data_source_destroy(data_source); data_source=NULL; }
    else if (!strcmp(op,"save")) saved_serial=enter_serial;
    else if (!strcmp(op,"pointer")) add_pointer();
    else if (!strcmp(op,"rebind")) {
        struct wp_pointer_warp_v1 *second=wl_registry_bind(registry,manager_name,&wp_pointer_warp_v1_interface,1);
        wp_pointer_warp_v1_destroy(manager); manager=second;
    }
    else if (!strcmp(op,"unmap")) { w->delay=true; wl_surface_attach(w->surface,NULL,0,0); wl_surface_commit(w->surface); }
    else if (!strcmp(op,"map")) { w->delay=false; if (w->xdg) acknowledge(w); else draw(w); }
    else if (!strcmp(op,"destroy")) {
        if(w->viewport) wp_viewport_destroy(w->viewport);
        if(w->sub) wl_subsurface_destroy(w->sub);
        if(w->top) xdg_toplevel_destroy(w->top);
        if(w->popup) xdg_popup_destroy(w->popup);
        if(w->xdg) xdg_surface_destroy(w->xdg);
        wl_surface_destroy(w->surface); *w=(struct window){0};
    }
    else if (!strcmp(op,"input")) {
        struct wl_region *region=wl_compositor_create_region(compositor);
        if (b) wl_region_add(region,0,0,b,c);
        wl_surface_set_input_region(w->surface,region); wl_region_destroy(region); wl_surface_commit(w->surface);
    }
    else if (!strcmp(op,"scale")) { w->scale=b; w->transform=c; draw(w); }
    else if (!strcmp(op,"viewport")) {
        if (!w->viewport) w->viewport=wp_viewporter_get_viewport(viewporter,w->surface);
        wp_viewport_set_source(w->viewport,wl_fixed_from_int(0),wl_fixed_from_int(0),wl_fixed_from_int(b),wl_fixed_from_int(c));
        wp_viewport_set_destination(w->viewport,w->width,w->height); draw(w);
    }
    else if (!strcmp(op,"child")) {
        assert(!w->surface); *w=(struct window){.id=a,.width=80,.height=60,.scale=1};
        w->surface=wl_compositor_create_surface(compositor);
        w->sub=wl_subcompositor_get_subsurface(subcompositor,w->surface,windows[b].surface);
        wl_subsurface_set_position(w->sub,c,c); wl_subsurface_set_desync(w->sub); draw(w); wl_surface_commit(windows[b].surface);
    }
    else if (!strcmp(op,"popup")) {
        assert(!w->surface); *w=(struct window){.id=a,.width=80,.height=60,.scale=1};
        w->surface=wl_compositor_create_surface(compositor); w->xdg=xdg_wm_base_get_xdg_surface(wm,w->surface);
        xdg_surface_add_listener(w->xdg,&surface_listener,w);
        struct xdg_positioner *positioner=xdg_wm_base_create_positioner(wm);
        xdg_positioner_set_size(positioner,80,60); xdg_positioner_set_anchor_rect(positioner,100,100,1,1);
        xdg_positioner_set_anchor(positioner,XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
        xdg_positioner_set_gravity(positioner,XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
        w->popup=xdg_surface_get_popup(w->xdg,windows[b].xdg,positioner);
        xdg_popup_add_listener(w->popup,&popup_listener,w); xdg_positioner_destroy(positioner); wl_surface_commit(w->surface);
    }
    else if (!strcmp(op,"lock")) {
        locked=zwp_pointer_constraints_v1_lock_pointer(constraints,w->surface,pointers[0],NULL,ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
        zwp_locked_pointer_v1_add_listener(locked,&lock_listener,NULL); wl_surface_commit(w->surface);
    }
    else if (!strcmp(op,"confine")) {
        struct wl_region *region=wl_compositor_create_region(compositor);
        wl_region_add(region,0,0,b,c);
        if (b==80) wl_region_add(region,120,0,80,c); // disconnected region case
        confined=zwp_pointer_constraints_v1_confine_pointer(constraints,w->surface,pointers[0],region,ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
        zwp_confined_pointer_v1_add_listener(confined,&confine_listener,NULL); wl_region_destroy(region); wl_surface_commit(w->surface);
    }
    else if (!strcmp(op,"unconstrain")) {
        if (locked) { zwp_locked_pointer_v1_destroy(locked); locked=NULL; }
        if (confined) { zwp_confined_pointer_v1_destroy(confined); confined=NULL; }
    }
    else if (!strcmp(op,"move")) { zwlr_virtual_pointer_v1_motion_absolute(pointer,timestamp(),a,b,1280,720); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"button")) { zwlr_virtual_pointer_v1_button(pointer,timestamp(),(uint32_t)a,b?WL_POINTER_BUTTON_STATE_PRESSED:WL_POINTER_BUTTON_STATE_RELEASED); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"relative")) { zwlr_virtual_pointer_v1_motion(pointer,timestamp(),wl_fixed_from_int(a),wl_fixed_from_int(b)); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"press") || !strcmp(op,"release")) { zwlr_virtual_pointer_v1_button(pointer,timestamp(),0x110,!strcmp(op,"press")?WL_POINTER_BUTTON_STATE_PRESSED:WL_POINTER_BUTTON_STATE_RELEASED); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"sandbox")) {
        int sock=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0), closefds[2]; assert(sock>=0 && pipe(closefds)==0);
        struct sockaddr_un addr={.sun_family=AF_UNIX}; snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/warp-sandbox",getenv("XDG_RUNTIME_DIR"));
        assert(bind(sock,(struct sockaddr*)&addr,sizeof(addr))==0 && listen(sock,8)==0);
        struct wp_security_context_v1 *ctx=wp_security_context_manager_v1_create_listener(security,sock,closefds[0]);
        wp_security_context_v1_set_sandbox_engine(ctx,"test"); wp_security_context_v1_set_app_id(ctx,"warp-test"); wp_security_context_v1_commit(ctx); wp_security_context_v1_destroy(ctx); close(sock); close(closefds[0]);
    }
    else assert(!"unknown command");
    return true;
}
int main(int argc, char **argv) {
    assert(argc==2); label=argv[1]; setvbuf(stdout,NULL,_IOLBF,0);
    display=wl_display_connect(NULL); assert(display);
    registry=wl_display_get_registry(display); wl_registry_add_listener(registry,&registry_listener,NULL);
    assert(wl_display_roundtrip(display)>=0);
    assert(wl_display_roundtrip(display)>=0);
    assert(compositor && shm && wm && manager && seat);
    assert(wl_display_roundtrip(display)>=0); puts("{\"event\":\"ready\"}");
    for (;;) {
        while (wl_display_prepare_read(display)!=0) if (wl_display_dispatch_pending(display)<0) goto error;
        if (wl_display_flush(display)<0) { wl_display_cancel_read(display); goto error; }
        struct pollfd fds[]={{wl_display_get_fd(display),POLLIN,0},{STDIN_FILENO,POLLIN,0}};
        assert(poll(fds,2,-1)>=0);
        if (fds[0].revents & (POLLIN|POLLHUP|POLLERR)) { if (wl_display_read_events(display)<0) goto error; } else wl_display_cancel_read(display);
        if (wl_display_dispatch_pending(display)<0) goto error;
        if (fds[1].revents & (POLLIN|POLLHUP)) {
            char line[128]; if (!fgets(line,sizeof(line),stdin) || !command(line)) break;
            if (wl_display_roundtrip(display)<0) goto error;
            printf("{\"event\":\"command\",\"value\":\"%.*s\"}\n",(int)strcspn(line,"\n"),line);
        }
    }
    wl_display_disconnect(display); return 0;
error: {
    const struct wl_interface *interface=NULL; uint32_t id;
    uint32_t code=wl_display_get_protocol_error(display,&interface,&id);
    printf("{\"event\":\"error\",\"interface\":\"%s\",\"code\":%u,\"id\":%u}\n",interface?interface->name:"",code,id);
    wl_display_disconnect(display); return 2;
}
}
