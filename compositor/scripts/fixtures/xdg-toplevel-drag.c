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
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-toplevel-drag-client-protocol.h"
#include "virtual-pointer-client-protocol.h"
#include "security-context-client-protocol.h"
static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct xdg_toplevel_drag_manager_v1 *manager;
static struct zwlr_virtual_pointer_v1 *pointer;
static struct wp_security_context_manager_v1 *security;
static struct wl_seat *seat;
static struct wl_data_device_manager *data_manager;
static struct wl_data_device *device;
static struct wl_data_source *source;
static struct xdg_toplevel_drag_v1 *drag;
static struct wl_data_offer *offer;
static uint32_t input_serial, tick = 100;
static int receive_fd = -1;
static bool accept_drop = true;
static const char *label;
struct window {
    struct wl_surface *surface;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    int id, width, height, inset;
    bool delay, mapped;
    uint32_t serial, states;
};
static struct window windows[16], drag_icon;
static void release(void *data, struct wl_buffer *buffer) { (void)data; wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener buffer_listener = {.release = release};
static void draw(struct window *w) {
    int fd = memfd_create("xdg-toplevel-drag", MFD_CLOEXEC);
    size_t size = (size_t)w->width * w->height * 4;
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    // Primary colors make scene-layer assertions independent of color transforms.
    const uint32_t colors[] = {0xff0000, 0x00ff00, 0x0000ff, 0xffff00};
    for (size_t i = 0; i < size / 4; i++) pixels[i] = colors[w->id % 4];
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w->width, w->height, w->width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    if (w->xdg) xdg_surface_set_window_geometry(w->xdg, w->inset, w->inset, w->width - 2*w->inset, w->height - 2*w->inset);
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
static void p_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *w, wl_fixed_t x, wl_fixed_t y) { (void)d;(void)p;(void)s;(void)w;(void)x;(void)y; }
static void p_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *w) { (void)d;(void)p;(void)s;(void)w; }
static void p_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) { (void)d;(void)p;(void)t;(void)x;(void)y; }
static void p_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t state) {
    (void)d;(void)p;(void)t;(void)b;
    if (state) { input_serial = s; puts("{\"event\":\"press\"}"); }
}
static void p_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) { (void)d;(void)p;(void)t;(void)a;(void)v; }
static const struct wl_pointer_listener pointer_listener = { .enter=p_enter, .leave=p_leave, .motion=p_motion, .button=p_button, .axis=p_axis };
static void t_down(void *d, struct wl_touch *t, uint32_t s, uint32_t time, struct wl_surface *w, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    (void)d;(void)t;(void)time;(void)w;(void)x;(void)y;
    input_serial=s; printf("{\"event\":\"touch\",\"id\":%d}\n", id);
}
static void t_up(void *d, struct wl_touch *t, uint32_t s, uint32_t time, int32_t id) { (void)d;(void)t;(void)s;(void)time;(void)id; }
static void t_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y) { (void)d;(void)t;(void)time;(void)id;(void)x;(void)y; }
static void t_frame(void *d, struct wl_touch *t) { (void)d;(void)t; }
static const struct wl_touch_listener touch_listener = { .down=t_down, .up=t_up, .motion=t_motion, .frame=t_frame, .cancel=t_frame };
struct seat_binding { struct wl_seat *seat; uint32_t capabilities; };
static void caps(void *d, struct wl_seat *s, uint32_t capabilities) {
    struct seat_binding *binding=d; binding->capabilities=capabilities;
    if (s!=seat) return;
    static bool got_pointer, got_touch;
    if (!got_pointer && (capabilities & WL_SEAT_CAPABILITY_POINTER)) { got_pointer=true; wl_pointer_add_listener(wl_seat_get_pointer(s), &pointer_listener, NULL); }
    if (!got_touch && (capabilities & WL_SEAT_CAPABILITY_TOUCH)) { got_touch=true; wl_touch_add_listener(wl_seat_get_touch(s), &touch_listener, NULL); }
}
static void seat_name(void *d, struct wl_seat *s, const char *name) {
    const char *wanted=getenv("DRAG_TEST_SEAT");
    if (!strcmp(name,wanted?wanted:"default")) { seat=s; caps(d,s,((struct seat_binding*)d)->capabilities); }
}
static const struct wl_seat_listener seat_listener = { .capabilities=caps, .name=seat_name };
static void source_target(void *d, struct wl_data_source *s, const char *mime) { (void)d;(void)s;(void)mime; }
static void source_send(void *d, struct wl_data_source *s, const char *mime, int32_t fd) {
    (void)d;(void)s;(void)mime; assert(write(fd, "detached-tab", 12)==12); close(fd); puts("{\"event\":\"sent\"}");
}
static void source_cancel(void *d, struct wl_data_source *s) { (void)d;(void)s; puts("{\"event\":\"cancelled\"}"); }
static void source_drop(void *d, struct wl_data_source *s) { (void)d;(void)s; puts("{\"event\":\"dropped\"}"); }
static void source_finish(void *d, struct wl_data_source *s) { (void)d;(void)s; puts("{\"event\":\"finished\"}"); }
static void source_action(void *d, struct wl_data_source *s, uint32_t a) { (void)d;(void)s;(void)a; }
static const struct wl_data_source_listener source_listener = { .target=source_target, .send=source_send, .cancelled=source_cancel, .dnd_drop_performed=source_drop, .dnd_finished=source_finish, .action=source_action };
static void offer_mime(void *d, struct wl_data_offer *o, const char *mime) { (void)d;(void)o;(void)mime; }
static void offer_action(void *d, struct wl_data_offer *o, uint32_t a) { (void)d;(void)o;(void)a; }
static const struct wl_data_offer_listener offer_listener = { .offer=offer_mime, .source_actions=offer_action, .action=offer_action };
static void data_offer(void *d, struct wl_data_device *dd, struct wl_data_offer *o) { (void)d;(void)dd; wl_data_offer_add_listener(o, &offer_listener, NULL); }
static void data_enter(void *d, struct wl_data_device *dd, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *o) {
    (void)d;(void)dd; offer=o; int id=-1; for (int i=0;i<16;i++) if (windows[i].surface==surface) id=i;
    printf("{\"event\":\"enter\",\"id\":%d,\"x\":%f,\"y\":%f}\n",id,wl_fixed_to_double(x),wl_fixed_to_double(y));
    if (o) { wl_data_offer_set_actions(o, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE); wl_data_offer_accept(o, serial, accept_drop ? "text/plain" : NULL); }
}
static void data_leave(void *d, struct wl_data_device *dd) { (void)d;(void)dd; puts("{\"event\":\"leave\"}"); }
static void data_motion(void *d, struct wl_data_device *dd, uint32_t time, wl_fixed_t x, wl_fixed_t y) { (void)d;(void)dd;(void)time; printf("{\"event\":\"motion\",\"x\":%f,\"y\":%f}\n",wl_fixed_to_double(x),wl_fixed_to_double(y)); }
static void data_drop(void *d, struct wl_data_device *dd) { (void)d;(void)dd; puts("{\"event\":\"received-drop\"}"); if (offer) { receive_fd=memfd_create("drag-receive", MFD_CLOEXEC); assert(receive_fd>=0); wl_data_offer_receive(offer, "text/plain", receive_fd); } }
static void data_selection(void *d, struct wl_data_device *dd, struct wl_data_offer *o) { (void)d;(void)dd; if (o) wl_data_offer_destroy(o); }
static const struct wl_data_device_listener device_listener = { .data_offer=data_offer, .enter=data_enter, .leave=data_leave, .motion=data_motion, .drop=data_drop, .selection=data_selection };
static void global(void *d, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)d;
    if (!strcmp(interface,"wl_compositor")) compositor=wl_registry_bind(r,name,&wl_compositor_interface,4);
    else if (!strcmp(interface,"wl_shm")) shm=wl_registry_bind(r,name,&wl_shm_interface,1);
    else if (!strcmp(interface,"xdg_wm_base")) { wm=wl_registry_bind(r,name,&xdg_wm_base_interface,version<7?version:7); xdg_wm_base_add_listener(wm,&wm_listener,NULL); }
    else if (!strcmp(interface,"xdg_toplevel_drag_manager_v1")) { manager=wl_registry_bind(r,name,&xdg_toplevel_drag_manager_v1_interface,1); printf("{\"event\":\"global\",\"version\":%u}\n",version); }
    else if (!strcmp(interface,"wl_seat")) { struct seat_binding *binding=calloc(1,sizeof(*binding)); assert(binding); binding->seat=wl_registry_bind(r,name,&wl_seat_interface,2); wl_seat_add_listener(binding->seat,&seat_listener,binding); }
    else if (!strcmp(interface,"wl_data_device_manager")) data_manager=wl_registry_bind(r,name,&wl_data_device_manager_interface,3);
    else if (!strcmp(interface,"wp_security_context_manager_v1")) security=wl_registry_bind(r,name,&wp_security_context_manager_v1_interface,1);
    else if (!strcmp(interface,"zwlr_virtual_pointer_manager_v1") && strcmp(label,"target")) {
        struct zwlr_virtual_pointer_manager_v1 *pm=wl_registry_bind(r,name,&zwlr_virtual_pointer_manager_v1_interface,1);
        pointer=zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pm,NULL); zwlr_virtual_pointer_manager_v1_destroy(pm);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t name) { (void)d;(void)r;(void)name; }
static const struct wl_registry_listener registry_listener = {.global=global,.global_remove=removed};
static void create(int id, int delay, int inset) {
    struct window *w=&windows[id]; assert(!w->surface);
    *w=(struct window){.id=id,.width=320,.height=240,.delay=delay,.inset=inset};
    w->surface=wl_compositor_create_surface(compositor); w->xdg=xdg_wm_base_get_xdg_surface(wm,w->surface);
    xdg_surface_add_listener(w->xdg,&surface_listener,w); w->top=xdg_surface_get_toplevel(w->xdg);
    xdg_toplevel_add_listener(w->top,&top_listener,w);
    char name[100]; snprintf(name,sizeof(name),"%s-%d",label,id);
    xdg_toplevel_set_app_id(w->top,name); xdg_toplevel_set_title(w->top,name); wl_surface_commit(w->surface);
}
static bool command(char *line) {
    char op[32]; int a=0,b=0,c=0; assert(sscanf(line,"%31s %d %d %d",op,&a,&b,&c)>=1);
    struct window *w=(a>=0 && a<16)?&windows[a]:NULL;
    if (!strcmp(op,"quit")) return false;
    if (!strcmp(op,"create")) create(a,b,c);
    else if (!strcmp(op,"prepare")) { if (a==2) { source=NULL; return true; } source=wl_data_device_manager_create_data_source(data_manager); wl_data_source_add_listener(source,&source_listener,NULL); wl_data_source_offer(source,"text/plain"); wl_data_source_set_actions(source,WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE); if (!a) { drag=xdg_toplevel_drag_manager_v1_get_xdg_toplevel_drag(manager,source); printf("{\"event\":\"prepared\",\"id\":%u}\n",wl_proxy_get_id((struct wl_proxy*)drag)); } }
    else if (!strcmp(op,"duplicate")) (void)xdg_toplevel_drag_manager_v1_get_xdg_toplevel_drag(manager,source);
    else if (!strcmp(op,"selection")) wl_data_device_set_selection(device,source,input_serial);
    else if (!strcmp(op,"attach")) xdg_toplevel_drag_v1_attach(drag,w->top,b,c);
    else if (!strcmp(op,"start")) {
        if (c) drag_icon=(struct window){.surface=wl_compositor_create_surface(compositor),.width=20,.height=20};
        wl_data_device_start_drag(device,source,w->surface,c?drag_icon.surface:NULL,b?0:input_serial);
        if (c) draw(&drag_icon);
    }
    else if (!strcmp(op,"destroy-icon")) { wl_surface_destroy(drag_icon.surface); drag_icon.surface=NULL; }
    // Keep the proxy alive for this deliberately invalid destructor request
    // so libwayland can report the offending interface in the error event.
    else if (!strcmp(op,"destroy-ongoing")) wl_proxy_marshal_flags((struct wl_proxy*)drag, XDG_TOPLEVEL_DRAG_V1_DESTROY, NULL, 1, 0);
    else if (!strcmp(op,"destroy-drag")) { xdg_toplevel_drag_v1_destroy(drag); drag=NULL; }
    else if (!strcmp(op,"destroy-source")) { wl_data_source_destroy(source); source=NULL; }
    else if (!strcmp(op,"destroy-manager")) { xdg_toplevel_drag_manager_v1_destroy(manager); manager=NULL; }
    else if (!strcmp(op,"destroy-top")) { xdg_toplevel_destroy(w->top); xdg_surface_destroy(w->xdg); wl_surface_destroy(w->surface); *w=(struct window){0}; }
    else if (!strcmp(op,"unmap")) { w->delay=true; wl_surface_attach(w->surface,NULL,0,0); wl_surface_commit(w->surface); }
    else if (!strcmp(op,"remap")) { char name[100]; snprintf(name,sizeof(name),"%s-%d",label,a); xdg_toplevel_set_app_id(w->top,name); xdg_toplevel_set_title(w->top,name); w->delay=false; wl_surface_commit(w->surface); }
    else if (!strcmp(op,"map")) { w->delay=false; acknowledge(w); }
    else if (!strcmp(op,"fullscreen")) { if(b) xdg_toplevel_set_fullscreen(w->top,NULL); else xdg_toplevel_unset_fullscreen(w->top); }
    else if (!strcmp(op,"maximize")) { if(b) xdg_toplevel_set_maximized(w->top); else xdg_toplevel_unset_maximized(w->top); }
    else if (!strcmp(op,"accept")) accept_drop=a;
    else if (!strcmp(op,"move")) { zwlr_virtual_pointer_v1_motion_absolute(pointer,++tick,a,b,1280,720); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"button")) { zwlr_virtual_pointer_v1_button(pointer,++tick,(uint32_t)a,b?WL_POINTER_BUTTON_STATE_PRESSED:WL_POINTER_BUTTON_STATE_RELEASED); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"relative")) { zwlr_virtual_pointer_v1_motion(pointer,++tick,wl_fixed_from_int(a),wl_fixed_from_int(b)); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"press") || !strcmp(op,"release")) { zwlr_virtual_pointer_v1_button(pointer,++tick,0x110,!strcmp(op,"press")?WL_POINTER_BUTTON_STATE_PRESSED:WL_POINTER_BUTTON_STATE_RELEASED); zwlr_virtual_pointer_v1_frame(pointer); }
    else if (!strcmp(op,"finish")) { char content[32]={0}; assert(receive_fd>=0 && pread(receive_fd,content,31,0)==12 && !strcmp(content,"detached-tab")); close(receive_fd); receive_fd=-1; wl_data_offer_finish(offer); wl_data_offer_destroy(offer); offer=NULL; puts("{\"event\":\"transferred\"}"); }
    else if (!strcmp(op,"sandbox")) {
        int sock=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0), closefds[2]; assert(sock>=0 && pipe(closefds)==0);
        struct sockaddr_un addr={.sun_family=AF_UNIX}; snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/drag-sandbox",getenv("XDG_RUNTIME_DIR"));
        assert(bind(sock,(struct sockaddr*)&addr,sizeof(addr))==0 && listen(sock,8)==0);
        struct wp_security_context_v1 *ctx=wp_security_context_manager_v1_create_listener(security,sock,closefds[0]);
        wp_security_context_v1_set_sandbox_engine(ctx,"test"); wp_security_context_v1_set_app_id(ctx,"drag-test"); wp_security_context_v1_commit(ctx); wp_security_context_v1_destroy(ctx); close(sock); close(closefds[0]);
    }
    else assert(!"unknown command");
    return true;
}
int main(int argc, char **argv) {
    assert(argc==2); label=argv[1]; setvbuf(stdout,NULL,_IOLBF,0);
    display=wl_display_connect(NULL); assert(display);
    struct wl_registry *registry=wl_display_get_registry(display); wl_registry_add_listener(registry,&registry_listener,NULL);
    assert(wl_display_roundtrip(display)>=0);
    assert(wl_display_roundtrip(display)>=0);
    if (!strcmp(label,"probe-absent")) { assert(!manager); puts("unavailable"); wl_display_disconnect(display); return 0; }
    assert(compositor && shm && wm && manager && seat && data_manager);
    device=wl_data_device_manager_get_data_device(data_manager,seat); wl_data_device_add_listener(device,&device_listener,NULL);
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
