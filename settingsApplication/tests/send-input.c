/* Input injection for the isolated test compositor only. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-client.h"
#include "virtual-pointer-client.h"
static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *km;
static struct zwlr_virtual_pointer_manager_v1 *pm;
static void global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(iface,"wl_seat")) seat=wl_registry_bind(r,name,&wl_seat_interface,1);
    if (!strcmp(iface,"zwp_virtual_keyboard_manager_v1")) km=wl_registry_bind(r,name,&zwp_virtual_keyboard_manager_v1_interface,1);
    if (!strcmp(iface,"zwlr_virtual_pointer_manager_v1")) pm=wl_registry_bind(r,name,&zwlr_virtual_pointer_manager_v1_interface,1);
}
static void removed(void *data,struct wl_registry *r,uint32_t name) {(void)data;(void)r;(void)name;}
int main(int argc,char **argv) {
    struct wl_display *d=wl_display_connect(NULL);assert(d);
    struct wl_registry *r=wl_display_get_registry(d);
    const struct wl_registry_listener listener={global,removed};
    wl_registry_add_listener(r,&listener,NULL);assert(wl_display_roundtrip(d)>=0 && seat && km && pm);
    struct zwp_virtual_keyboard_v1 *kbd=zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(km,seat);
    struct zwlr_virtual_pointer_v1 *ptr=zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pm,seat);
    struct xkb_context *ctx=xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *map=xkb_keymap_new_from_names(ctx,NULL,XKB_KEYMAP_COMPILE_NO_FLAGS);assert(map);
    char *text=xkb_keymap_get_as_string(map,XKB_KEYMAP_FORMAT_TEXT_V1);size_t len=strlen(text)+1;
    int fd=memfd_create("settings-test-keymap",MFD_CLOEXEC);assert(fd>=0 && write(fd,text,len)==(ssize_t)len);
    zwp_virtual_keyboard_v1_keymap(kbd,WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,fd,len);close(fd);wl_display_roundtrip(d);usleep(150000);
    for(int i=1;i<argc;i++) {
        unsigned stamp=i*300;
        if(!strcmp(argv[i],"click")) {
            assert(i+2<argc);unsigned x=atoi(argv[++i]),y=atoi(argv[++i]);
            zwlr_virtual_pointer_v1_motion_absolute(ptr,stamp,x,y,1280,720);
            zwlr_virtual_pointer_v1_frame(ptr);wl_display_roundtrip(d);usleep(100000);
            zwlr_virtual_pointer_v1_button(ptr,stamp+1,0x110,WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(ptr);wl_display_roundtrip(d);usleep(100000);
            zwlr_virtual_pointer_v1_button(ptr,stamp+2,0x110,WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if(!strcmp(argv[i],"wheel")) {
            assert(i+3<argc);unsigned x=atoi(argv[++i]),y=atoi(argv[++i]);double amount=atof(argv[++i]);
            zwlr_virtual_pointer_v1_motion_absolute(ptr,stamp,x,y,1280,720);
            zwlr_virtual_pointer_v1_axis(ptr,stamp+1,WL_POINTER_AXIS_VERTICAL_SCROLL,wl_fixed_from_double(amount));
            zwlr_virtual_pointer_v1_frame(ptr);
        } else {
            unsigned mods=0;const char *key=argv[i];
            if(*key=='C'){mods=4;key++;}else if(*key=='S'){mods=1;key++;}
            zwp_virtual_keyboard_v1_modifiers(kbd,mods,0,0,0);
            zwp_virtual_keyboard_v1_key(kbd,stamp,atoi(key),WL_KEYBOARD_KEY_STATE_PRESSED);
            zwp_virtual_keyboard_v1_key(kbd,stamp+50,atoi(key),WL_KEYBOARD_KEY_STATE_RELEASED);
            zwp_virtual_keyboard_v1_modifiers(kbd,0,0,0,0);
        }
        assert(wl_display_roundtrip(d)>=0);usleep(150000);
    }
    zwp_virtual_keyboard_v1_destroy(kbd);zwlr_virtual_pointer_v1_destroy(ptr);
    wl_display_roundtrip(d);wl_display_disconnect(d);free(text);xkb_keymap_unref(map);xkb_context_unref(ctx);
}
