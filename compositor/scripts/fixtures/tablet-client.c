// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "tablet-v2-client-protocol.h"
#include "xdg-shell-client-protocol.h"
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct zwp_tablet_manager_v2 *manager;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static struct wl_output *target;
static const char *wanted;
static int width=640, height=480;
static void zwp_tablet_tool_v2_type_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t tool_type) { (void)data; (void)object; (void)tool_type; printf("{\"event\":\"type\",\"tool_type\":%u}\n", (unsigned)tool_type); }
static void zwp_tablet_tool_v2_hardware_serial_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t hardware_serial_hi, uint32_t hardware_serial_lo) { (void)data; (void)object; (void)hardware_serial_hi; (void)hardware_serial_lo; printf("{\"event\":\"hardware_serial\",\"hardware_serial_hi\":%u,\"hardware_serial_lo\":%u}\n", (unsigned)hardware_serial_hi, (unsigned)hardware_serial_lo); }
static void zwp_tablet_tool_v2_hardware_id_wacom_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t hardware_id_hi, uint32_t hardware_id_lo) { (void)data; (void)object; (void)hardware_id_hi; (void)hardware_id_lo; printf("{\"event\":\"hardware_id_wacom\",\"hardware_id_hi\":%u,\"hardware_id_lo\":%u}\n", (unsigned)hardware_id_hi, (unsigned)hardware_id_lo); }
static void zwp_tablet_tool_v2_capability_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t capability) { (void)data; (void)object; (void)capability; printf("{\"event\":\"capability\",\"capability\":%u}\n", (unsigned)capability); }
static void zwp_tablet_tool_v2_done_event(void *data, struct zwp_tablet_tool_v2 *object) { (void)data; (void)object; printf("{\"event\":\"done\"}\n"); }
static void zwp_tablet_tool_v2_removed_event(void *data, struct zwp_tablet_tool_v2 *object) { (void)data; (void)object; printf("{\"event\":\"removed\"}\n"); zwp_tablet_tool_v2_destroy(object); }
static void zwp_tablet_tool_v2_proximity_in_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t serial, struct zwp_tablet_v2 * tablet, struct wl_surface * surface) { (void)data; (void)object; (void)serial; (void)tablet; (void)surface; printf("{\"event\":\"proximity_in\",\"serial\":%u}\n", (unsigned)serial); }
static void zwp_tablet_tool_v2_proximity_out_event(void *data, struct zwp_tablet_tool_v2 *object) { (void)data; (void)object; printf("{\"event\":\"proximity_out\"}\n"); }
static void zwp_tablet_tool_v2_down_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t serial) { (void)data; (void)object; (void)serial; printf("{\"event\":\"down\",\"serial\":%u}\n", (unsigned)serial); }
static void zwp_tablet_tool_v2_up_event(void *data, struct zwp_tablet_tool_v2 *object) { (void)data; (void)object; printf("{\"event\":\"up\"}\n"); }
static void zwp_tablet_tool_v2_motion_event(void *data, struct zwp_tablet_tool_v2 *object, wl_fixed_t x, wl_fixed_t y) { (void)data; (void)object; (void)x; (void)y; printf("{\"event\":\"motion\",\"x\":%f,\"y\":%f}\n", wl_fixed_to_double(x), wl_fixed_to_double(y)); }
static void zwp_tablet_tool_v2_pressure_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t pressure) { (void)data; (void)object; (void)pressure; printf("{\"event\":\"pressure\",\"pressure\":%u}\n", (unsigned)pressure); }
static void zwp_tablet_tool_v2_distance_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t distance) { (void)data; (void)object; (void)distance; printf("{\"event\":\"distance\",\"distance\":%u}\n", (unsigned)distance); }
static void zwp_tablet_tool_v2_tilt_event(void *data, struct zwp_tablet_tool_v2 *object, wl_fixed_t tilt_x, wl_fixed_t tilt_y) { (void)data; (void)object; (void)tilt_x; (void)tilt_y; printf("{\"event\":\"tilt\",\"tilt_x\":%f,\"tilt_y\":%f}\n", wl_fixed_to_double(tilt_x), wl_fixed_to_double(tilt_y)); }
static void zwp_tablet_tool_v2_rotation_event(void *data, struct zwp_tablet_tool_v2 *object, wl_fixed_t degrees) { (void)data; (void)object; (void)degrees; printf("{\"event\":\"rotation\",\"degrees\":%f}\n", wl_fixed_to_double(degrees)); }
static void zwp_tablet_tool_v2_slider_event(void *data, struct zwp_tablet_tool_v2 *object, int32_t position) { (void)data; (void)object; (void)position; printf("{\"event\":\"slider\",\"position\":%u}\n", (unsigned)position); }
static void zwp_tablet_tool_v2_wheel_event(void *data, struct zwp_tablet_tool_v2 *object, wl_fixed_t degrees, int32_t clicks) { (void)data; (void)object; (void)degrees; (void)clicks; printf("{\"event\":\"wheel\",\"degrees\":%f,\"clicks\":%u}\n", wl_fixed_to_double(degrees), (unsigned)clicks); }
static void zwp_tablet_tool_v2_button_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t serial, uint32_t button, uint32_t state) { (void)data; (void)object; (void)serial; (void)button; (void)state; printf("{\"event\":\"button\",\"serial\":%u,\"button\":%u,\"state\":%u}\n", (unsigned)serial, (unsigned)button, (unsigned)state); }
static void zwp_tablet_tool_v2_frame_event(void *data, struct zwp_tablet_tool_v2 *object, uint32_t time) { (void)data; (void)object; (void)time; printf("{\"event\":\"frame\",\"time\":%u}\n", (unsigned)time); }
static const struct zwp_tablet_tool_v2_listener zwp_tablet_tool_v2_listener = {.type=zwp_tablet_tool_v2_type_event, .hardware_serial=zwp_tablet_tool_v2_hardware_serial_event, .hardware_id_wacom=zwp_tablet_tool_v2_hardware_id_wacom_event, .capability=zwp_tablet_tool_v2_capability_event, .done=zwp_tablet_tool_v2_done_event, .removed=zwp_tablet_tool_v2_removed_event, .proximity_in=zwp_tablet_tool_v2_proximity_in_event, .proximity_out=zwp_tablet_tool_v2_proximity_out_event, .down=zwp_tablet_tool_v2_down_event, .up=zwp_tablet_tool_v2_up_event, .motion=zwp_tablet_tool_v2_motion_event, .pressure=zwp_tablet_tool_v2_pressure_event, .distance=zwp_tablet_tool_v2_distance_event, .tilt=zwp_tablet_tool_v2_tilt_event, .rotation=zwp_tablet_tool_v2_rotation_event, .slider=zwp_tablet_tool_v2_slider_event, .wheel=zwp_tablet_tool_v2_wheel_event, .button=zwp_tablet_tool_v2_button_event, .frame=zwp_tablet_tool_v2_frame_event};
static void zwp_tablet_v2_name_event(void *data, struct zwp_tablet_v2 *object, const char * name) { (void)data; (void)object; (void)name; printf("{\"event\":\"name\"}\n"); }
static void zwp_tablet_v2_id_event(void *data, struct zwp_tablet_v2 *object, uint32_t vid, uint32_t pid) { (void)data; (void)object; (void)vid; (void)pid; printf("{\"event\":\"id\",\"vid\":%u,\"pid\":%u}\n", (unsigned)vid, (unsigned)pid); }
static void zwp_tablet_v2_path_event(void *data, struct zwp_tablet_v2 *object, const char * path) { (void)data; (void)object; (void)path; printf("{\"event\":\"path\"}\n"); }
static void zwp_tablet_v2_done_event(void *data, struct zwp_tablet_v2 *object) { (void)data; (void)object; printf("{\"event\":\"done\"}\n"); }
static void zwp_tablet_v2_removed_event(void *data, struct zwp_tablet_v2 *object) { (void)data; (void)object; printf("{\"event\":\"removed\"}\n"); zwp_tablet_v2_destroy(object); }
static void zwp_tablet_v2_bustype_event(void *data, struct zwp_tablet_v2 *object, uint32_t bustype) { (void)data; (void)object; (void)bustype; printf("{\"event\":\"bustype\",\"bustype\":%u}\n", (unsigned)bustype); }
static const struct zwp_tablet_v2_listener zwp_tablet_v2_listener = {.name=zwp_tablet_v2_name_event, .id=zwp_tablet_v2_id_event, .path=zwp_tablet_v2_path_event, .done=zwp_tablet_v2_done_event, .removed=zwp_tablet_v2_removed_event, .bustype=zwp_tablet_v2_bustype_event};

static void tablet_added(void *d, struct zwp_tablet_seat_v2 *s, struct zwp_tablet_v2 *t) { (void)d;(void)s; zwp_tablet_v2_add_listener(t,&zwp_tablet_v2_listener,NULL); }
static void tool_added(void *d, struct zwp_tablet_seat_v2 *s, struct zwp_tablet_tool_v2 *t) { (void)d;(void)s; zwp_tablet_tool_v2_add_listener(t,&zwp_tablet_tool_v2_listener,NULL); }
static void pad_added(void *d, struct zwp_tablet_seat_v2 *s, struct zwp_tablet_pad_v2 *t) { (void)d;(void)s;zwp_tablet_pad_v2_destroy(t); }
static const struct zwp_tablet_seat_v2_listener tablet_seat_listener = {.tablet_added=tablet_added,.tool_added=tool_added,.pad_added=pad_added};
static void pointer_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y) { (void)d;(void)p;(void)s;(void)sf;(void)x;(void)y; puts("{\"event\":\"pointer_enter\"}"); }
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf) { (void)d;(void)p;(void)s;(void)sf; }
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) { (void)d;(void)p;(void)t;(void)x;(void)y; puts("{\"event\":\"pointer_motion\"}"); }
static void pointer_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t st) { (void)d;(void)p;(void)s;(void)t;(void)b;(void)st;puts("{\"event\":\"pointer_button\"}"); }
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t ax, wl_fixed_t v) { (void)d;(void)p;(void)t;(void)ax;(void)v; }
static const struct wl_pointer_listener pointer_listener = {.enter=pointer_enter,.leave=pointer_leave,.motion=pointer_motion,.button=pointer_button,.axis=pointer_axis};
static void ping(void *d, struct xdg_wm_base *w, uint32_t s) { (void)d;xdg_wm_base_pong(w,s); }
static const struct xdg_wm_base_listener wm_listener = {.ping=ping};
static void output_geometry(void *d,struct wl_output *o,int32_t x,int32_t y,int32_t pw,int32_t ph,int32_t sub,const char *make,const char *model,int32_t t) { (void)d;(void)o;(void)x;(void)y;(void)pw;(void)ph;(void)sub;(void)make;(void)model;(void)t; }
static void output_mode(void *d,struct wl_output *o,uint32_t f,int32_t w,int32_t h,int32_t r) { (void)d;(void)o;(void)f;(void)w;(void)h;(void)r; }
static void output_done(void *d,struct wl_output *o) { (void)d;(void)o; }
static void output_scale(void *d,struct wl_output *o,int32_t s) { (void)d;(void)o;(void)s; }
static void output_name(void *d,struct wl_output *o,const char *n) { (void)d;if(!strcmp(n,wanted))target=o; }
static void output_description(void *d,struct wl_output *o,const char *n) { (void)d;(void)o;(void)n; }
static const struct wl_output_listener output_listener={.geometry=output_geometry,.mode=output_mode,.done=output_done,.scale=output_scale,.name=output_name,.description=output_description};
static void global(void *d,struct wl_registry *r,uint32_t n,const char *i,uint32_t v) {
 (void)d;
 if(!strcmp(i,"wl_compositor"))compositor=wl_registry_bind(r,n,&wl_compositor_interface,4);
 if(!strcmp(i,"wl_shm"))shm=wl_registry_bind(r,n,&wl_shm_interface,1);
 if(!strcmp(i,"wl_seat"))seat=wl_registry_bind(r,n,&wl_seat_interface,1);
 if(!strcmp(i,"zwp_tablet_manager_v2"))manager=wl_registry_bind(r,n,&zwp_tablet_manager_v2_interface,1);
 if(!strcmp(i,"xdg_wm_base")){wm=wl_registry_bind(r,n,&xdg_wm_base_interface,1);xdg_wm_base_add_listener(wm,&wm_listener,NULL);}
 if(!strcmp(i,"wl_output")&&v>=4){struct wl_output *o=wl_registry_bind(r,n,&wl_output_interface,4);wl_output_add_listener(o,&output_listener,NULL);}
}
static void global_remove(void *d,struct wl_registry *r,uint32_t n) { (void)d;(void)r;(void)n; }
static const struct wl_registry_listener registry_listener={.global=global,.global_remove=global_remove};
static void buffer_release(void *d,struct wl_buffer *b){(void)d;wl_buffer_destroy(b);}
static const struct wl_buffer_listener buffer_listener={.release=buffer_release};
static void configure(void *d,struct xdg_surface *xs,uint32_t serial) {
 (void)d;xdg_surface_ack_configure(xs,serial);
 int fd=memfd_create("tablet-client",MFD_CLOEXEC);assert(fd>=0);
 size_t bytes=(size_t)width*height*4;assert(!ftruncate(fd,bytes));
 struct wl_shm_pool *pool=wl_shm_create_pool(shm,fd,bytes);
 struct wl_buffer *buffer=wl_shm_pool_create_buffer(pool,0,width,height,width*4,WL_SHM_FORMAT_XRGB8888);
 wl_buffer_add_listener(buffer,&buffer_listener,NULL);wl_shm_pool_destroy(pool);close(fd);
 wl_surface_attach(surface,buffer,0,0);wl_surface_damage_buffer(surface,0,0,width,height);wl_surface_commit(surface);
 puts("{\"event\":\"configured\"}");
}
static const struct xdg_surface_listener surface_listener={.configure=configure};
static void toplevel_configure(void *d,struct xdg_toplevel *t,int32_t w,int32_t h,struct wl_array *s){(void)d;(void)t;(void)s;if(w>0)width=w;if(h>0)height=h;}
static void toplevel_close(void *d,struct xdg_toplevel *t){(void)d;(void)t;exit(0);}
static const struct xdg_toplevel_listener toplevel_listener={.configure=toplevel_configure,.close=toplevel_close};
int main(int argc,char **argv){
 assert(argc==2);wanted=argv[1];setvbuf(stdout,NULL,_IONBF,0);
 struct wl_display *display=wl_display_connect(NULL);assert(display);
 struct wl_registry *registry=wl_display_get_registry(display);wl_registry_add_listener(registry,&registry_listener,NULL);
 assert(wl_display_roundtrip(display)>=0);assert(wl_display_roundtrip(display)>=0);assert(compositor&&shm&&wm&&seat&&manager&&target);
 struct zwp_tablet_seat_v2 *ts=zwp_tablet_manager_v2_get_tablet_seat(manager,seat);zwp_tablet_seat_v2_add_listener(ts,&tablet_seat_listener,NULL);
 struct wl_pointer *pointer=wl_seat_get_pointer(seat);wl_pointer_add_listener(pointer,&pointer_listener,NULL);
 surface=wl_compositor_create_surface(compositor);struct xdg_surface *xs=xdg_wm_base_get_xdg_surface(wm,surface);xdg_surface_add_listener(xs,&surface_listener,NULL);
 struct xdg_toplevel *t=xdg_surface_get_toplevel(xs);xdg_toplevel_add_listener(t,&toplevel_listener,NULL);xdg_toplevel_set_app_id(t,"aqueous.tablet-test");xdg_toplevel_set_fullscreen(t,target);wl_surface_commit(surface);
 while(wl_display_dispatch(display)>=0){} return 0;
}
