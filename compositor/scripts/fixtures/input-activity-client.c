// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
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
#include <sys/wait.h>
#include <time.h>
#include <wayland-client.h>
#include "activity-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "session-lock-client-protocol.h"
static struct wl_display *display;
static struct wl_registry *registry;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_surface *surface;
static struct xdg_wm_base *wm;
static struct xdg_surface *xdg_surface;
static struct xdg_toplevel *toplevel;
static struct ext_session_lock_manager_v1 *lock_manager;
static struct ext_session_lock_v1 *lock;
static struct aqueous_input_activity_manager_v1 *manager;
static struct aqueous_input_activity_v1 *sub;
static struct aqueous_input_activity_inhibitor_v1 *inhibitors[8];
static uint32_t global, generation_hi, generation_lo, serial;
static int proof = -1;
static bool auto_ack = true;
static bool latency = false;
static void delivered(const char *kind, bool pressed) {
    if (latency) {
        struct timespec ts;
        assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
        long long ns = (long long)ts.tv_sec * 1000000000 + ts.tv_nsec;
        printf("{\"event\":\"%s-delivered\",\"pressed\":%s,\"time_ns\":%lld}\n", kind, pressed ? "true" : "false", ns);
    } else printf("{\"event\":\"%s-delivered\"}\n", kind);
}
static uint32_t last_authorization = 99, last_state = 99;
static void capabilities(void *data, struct aqueous_input_activity_manager_v1 *m, uint32_t ms, uint32_t cats) {
    (void)data; (void)m; assert(ms == 100 && cats == 3);
    puts("{\"event\":\"capabilities\"}");
}
static void authorization(void *data, struct aqueous_input_activity_manager_v1 *m, uint32_t status) {
    (void)data; (void)m; last_authorization = status; printf("{\"event\":\"authorization\",\"status\":%u}\n", status);
}
static const struct aqueous_input_activity_manager_v1_listener manager_listener = {capabilities, authorization};
static void state(void *data, struct aqueous_input_activity_v1 *s, uint32_t status, uint32_t hi, uint32_t lo, uint32_t ack) {
    (void)data; (void)s; last_state = status; generation_hi = hi; generation_lo = lo;
    printf("{\"event\":\"state\",\"status\":%u,\"generation\":%llu,\"serial\":%u}\n", status, ((unsigned long long)hi<<32)|lo, ack);
}
static void activity(void *data, struct aqueous_input_activity_v1 *s, uint32_t hi, uint32_t lo, uint32_t seq, uint32_t cats) {
    (void)data; assert(cats > 0 && cats <= 3);
    printf("{\"event\":\"activity\",\"generation\":%llu,\"sequence\":%u,\"categories\":%u}\n", ((unsigned long long)hi<<32)|lo, seq, cats);
    if (auto_ack) aqueous_input_activity_v1_ack(s, hi, lo, seq);
}
static const struct aqueous_input_activity_v1_listener sub_listener = {state, activity};
static void ping(void *data, struct xdg_wm_base *base, uint32_t value) { (void)data; xdg_wm_base_pong(base,value); }
static const struct xdg_wm_base_listener wm_listener = {ping};
static void configure(void *data, struct xdg_surface *s, uint32_t value) {
    (void)data; xdg_surface_ack_configure(s,value);
    int fd = memfd_create("activity-test-window", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd,320*200*4) == 0);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm,fd,320*200*4);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool,0,320,200,320*4,WL_SHM_FORMAT_XRGB8888);
    wl_surface_attach(surface,buffer,0,0);
    wl_surface_damage(surface,0,0,320,200);
    wl_surface_commit(surface);
    wl_shm_pool_destroy(pool); close(fd);
    puts("{\"event\":\"mapped\"}");
}
static const struct xdg_surface_listener surface_listener = {configure};
static void top_configure(void *d, struct xdg_toplevel *t,int32_t w,int32_t h,struct wl_array *s){(void)d;(void)t;(void)w;(void)h;(void)s;}
static void top_close(void *d,struct xdg_toplevel *t){(void)d;(void)t;}
static const struct xdg_toplevel_listener top_listener = {.configure=top_configure,.close=top_close};
static void locked(void *d,struct ext_session_lock_v1 *l){(void)d;(void)l;puts("{\"event\":\"locked\"}");}
static void finished(void *d,struct ext_session_lock_v1 *l){(void)d;(void)l;puts("{\"event\":\"lock_finished\"}");}
static const struct ext_session_lock_v1_listener lock_listener = {locked,finished};
static void keymap(void*d,struct wl_keyboard*k,uint32_t format,int32_t fd,uint32_t size){(void)d;(void)k;(void)format;(void)size;close(fd);}
static void key_enter(void*d,struct wl_keyboard*k,uint32_t s,struct wl_surface*w,struct wl_array*keys){(void)d;(void)k;(void)s;(void)w;(void)keys;puts("{\"event\":\"keyboard-focus\"}");}
static void key_leave(void*d,struct wl_keyboard*k,uint32_t s,struct wl_surface*w){(void)d;(void)k;(void)s;(void)w;}
static void key_event(void*d,struct wl_keyboard*k,uint32_t serial_,uint32_t time_,uint32_t key_,uint32_t state_){(void)d;(void)k;(void)serial_;(void)time_;(void)key_;delivered("key", state_ == WL_KEYBOARD_KEY_STATE_PRESSED);}
static void modifiers(void*d,struct wl_keyboard*k,uint32_t s,uint32_t a,uint32_t b,uint32_t c,uint32_t group){(void)d;(void)k;(void)s;(void)a;(void)b;(void)c;(void)group;}
static void repeat_info(void*d,struct wl_keyboard*k,int32_t rate,int32_t delay){(void)d;(void)k;(void)rate;(void)delay;}
static const struct wl_keyboard_listener keyboard_listener={keymap,key_enter,key_leave,key_event,modifiers,repeat_info};
static void pointer_enter(void*d,struct wl_pointer*p,uint32_t s,struct wl_surface*w,wl_fixed_t x,wl_fixed_t y){(void)d;(void)p;(void)s;(void)w;(void)x;(void)y;puts("{\"event\":\"pointer-focus\"}");}
static void pointer_leave(void*d,struct wl_pointer*p,uint32_t s,struct wl_surface*w){(void)d;(void)p;(void)s;(void)w;}
static void pointer_motion(void*d,struct wl_pointer*p,uint32_t t,wl_fixed_t x,wl_fixed_t y){(void)d;(void)p;(void)t;(void)x;(void)y;}
static void pointer_button(void*d,struct wl_pointer*p,uint32_t s,uint32_t t,uint32_t button,uint32_t state_){(void)d;(void)p;(void)s;(void)t;(void)button;delivered("button",state_ == WL_POINTER_BUTTON_STATE_PRESSED);}
static void pointer_axis(void*d,struct wl_pointer*p,uint32_t t,uint32_t axis,wl_fixed_t value){(void)d;(void)p;(void)t;(void)axis;(void)value;}
static void pointer_frame(void*d,struct wl_pointer*p){(void)d;(void)p;}
static void pointer_source(void*d,struct wl_pointer*p,uint32_t s){(void)d;(void)p;(void)s;}
static void pointer_stop(void*d,struct wl_pointer*p,uint32_t t,uint32_t axis){(void)d;(void)p;(void)t;(void)axis;}
static void pointer_discrete(void*d,struct wl_pointer*p,uint32_t axis,int32_t value){(void)d;(void)p;(void)axis;(void)value;}
static const struct wl_pointer_listener pointer_listener = {.enter=pointer_enter,.leave=pointer_leave,.motion=pointer_motion,.button=pointer_button,.axis=pointer_axis,.frame=pointer_frame,.axis_source=pointer_source,.axis_stop=pointer_stop,.axis_discrete=pointer_discrete};
static void seat_caps(void*d,struct wl_seat*seat,uint32_t caps){
    (void)d;static bool keyboard_bound=false,pointer_bound=false;
    if(!keyboard_bound&&(caps&WL_SEAT_CAPABILITY_KEYBOARD)){keyboard_bound=true;struct wl_keyboard*k=wl_seat_get_keyboard(seat);wl_keyboard_add_listener(k,&keyboard_listener,NULL);}
    if(latency&&!pointer_bound&&(caps&WL_SEAT_CAPABILITY_POINTER)){pointer_bound=true;struct wl_pointer*p=wl_seat_get_pointer(seat);wl_pointer_add_listener(p,&pointer_listener,NULL);}
}
static void seat_name(void*d,struct wl_seat*s,const char*n){(void)d;(void)s;(void)n;}
static const struct wl_seat_listener seat_listener={seat_caps,seat_name};
static void registry_global(void *data,struct wl_registry *r,uint32_t name,const char *interface,uint32_t version){
    (void)data;(void)version;
    if (!strcmp(interface,"aqueous_input_activity_manager_v1")) {
        global=name; manager=wl_registry_bind(r,name,&aqueous_input_activity_manager_v1_interface,1);
        aqueous_input_activity_manager_v1_add_listener(manager,&manager_listener,NULL);
    } else if (!strcmp(interface,"wl_compositor")) compositor=wl_registry_bind(r,name,&wl_compositor_interface,4);
    else if (!strcmp(interface,"wl_seat")) {struct wl_seat*s=wl_registry_bind(r,name,&wl_seat_interface,5);wl_seat_add_listener(s,&seat_listener,NULL);}
    else if (!strcmp(interface,"wl_shm")) shm=wl_registry_bind(r,name,&wl_shm_interface,1);
    else if (!strcmp(interface,"xdg_wm_base")) {wm=wl_registry_bind(r,name,&xdg_wm_base_interface,1);xdg_wm_base_add_listener(wm,&wm_listener,NULL);}
    else if (!strcmp(interface,"ext_session_lock_manager_v1")) lock_manager=wl_registry_bind(r,name,&ext_session_lock_manager_v1_interface,1);
}
static void removed(void *data,struct wl_registry *r,uint32_t name){(void)data;(void)r;(void)name;}
static const struct wl_registry_listener registry_listener = {registry_global,removed};
static int get_capability(void){
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    const char *ipc=getenv("AQUEOUS_SOCKET"); assert(ipc && strlen(ipc)<sizeof(addr.sun_path));
    strcpy(addr.sun_path,ipc); char *slash=strrchr(addr.sun_path,'/'); assert(slash); strcpy(slash,"/activity.sock");
    int sock=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0); assert(sock>=0);
    assert(connect(sock,(void*)&addr,sizeof(addr))==0);
    struct pollfd p={.fd=sock,.events=POLLIN}; assert(poll(&p,1,3000)>0);
    char byte; struct iovec iov={.iov_base=&byte,.iov_len=1};
    union{struct cmsghdr align;char bytes[CMSG_SPACE(sizeof(int))];} control={0};
    struct msghdr msg={.msg_iov=&iov,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof(control)};
    int result=-1;
    if(recvmsg(sock,&msg,MSG_CMSG_CLOEXEC)==1){struct cmsghdr*c=CMSG_FIRSTHDR(&msg);assert(c&&c->cmsg_type==SCM_RIGHTS);memcpy(&result,CMSG_DATA(c),sizeof(result));}
    close(sock); return result;
}
int main(int argc, char **argv){
    latency = argc == 2 && !strcmp(argv[1], "--latency");
    setvbuf(stdout,NULL,_IOLBF,0);
    display=wl_display_connect(NULL); assert(display);
    registry=wl_display_get_registry(display);wl_registry_add_listener(registry,&registry_listener,NULL);
    assert(wl_display_roundtrip(display)>=0);assert(wl_display_roundtrip(display)>=0);assert(manager&&compositor);
    surface=wl_compositor_create_surface(compositor);
    puts("{\"event\":\"connected\"}");
    if(argc == 3 && !strcmp(argv[1],"--bootstrap-smoke")) {
        const char *value=getenv("AQUEOUS_INPUT_ACTIVITY_FD"); assert(value);
        proof=atoi(value); assert(proof>=3); fcntl(proof,F_SETFD,FD_CLOEXEC); unsetenv("AQUEOUS_INPUT_ACTIVITY_FD");
        aqueous_input_activity_manager_v1_authorize(manager,proof); close(proof); proof=-1;
        assert(wl_display_roundtrip(display)>=0 && last_authorization==0);
        sub=aqueous_input_activity_manager_v1_get_subscription(manager);aqueous_input_activity_v1_add_listener(sub,&sub_listener,NULL);
        assert(wl_display_roundtrip(display)>=0 && last_state==2);
        aqueous_input_activity_v1_destroy(sub);aqueous_input_activity_manager_v1_destroy(manager);
        assert(wl_display_roundtrip(display)>=0);
        wl_display_disconnect(display);
        // Model the independent locker lifetime without creating a host lock.
        int ready[2];assert(pipe2(ready,O_CLOEXEC)==0);
        pid_t child=fork();assert(child>=0);
        if(child==0){close(ready[0]);FILE*f=fopen(argv[2],"w");assert(f);fprintf(f,"%d",getpid());fclose(f);close(0);close(1);close(2);assert(write(ready[1],"x",1)==1);close(ready[1]);for(;;)pause();}
        close(ready[1]);char byte;assert(read(ready[0],&byte,1)==1);close(ready[0]);
        puts("BOOTSTRAP_OK");return 0;
    }
    char input[256];
    while(true){
        assert(wl_display_dispatch_pending(display)>=0);wl_display_flush(display);
        struct pollfd fds[2]={{.fd=wl_display_get_fd(display),.events=POLLIN},{.fd=STDIN_FILENO,.events=POLLIN}};
        assert(poll(fds,2,3000)>=0);
        if(fds[0].revents&POLLIN)assert(wl_display_dispatch(display)>=0);
        if(fds[0].revents&(POLLERR|POLLHUP))break;
        if(!(fds[1].revents&POLLIN)){if(fds[1].revents&POLLHUP)break;continue;}
        if(!fgets(input,sizeof(input),stdin))break;
        int index=0;sscanf(input,"%*s %d",&index);
        if(!strncmp(input,"cap",3)){proof=get_capability();printf("{\"event\":\"proof\",\"ok\":%s}\n",proof>=0?"true":"false");}
        else if(!strncmp(input,"forge",5)){int fd=memfd_create("forged",MFD_CLOEXEC);aqueous_input_activity_manager_v1_authorize(manager,fd);close(fd);}
        else if(!strncmp(input,"authorize",9)){assert(proof>=0);aqueous_input_activity_manager_v1_authorize(manager,proof);}
        else if(!strncmp(input,"replay",6)){struct aqueous_input_activity_manager_v1*m=wl_registry_bind(registry,global,&aqueous_input_activity_manager_v1_interface,1);aqueous_input_activity_manager_v1_add_listener(m,&manager_listener,NULL);aqueous_input_activity_manager_v1_authorize(m,proof);wl_display_roundtrip(display);aqueous_input_activity_manager_v1_destroy(m);}
        else if(!strncmp(input,"subscribe",9)){sub=aqueous_input_activity_manager_v1_get_subscription(manager);aqueous_input_activity_v1_add_listener(sub,&sub_listener,NULL);}
        else if(!strncmp(input,"unsubscribe",11)){aqueous_input_activity_v1_destroy(sub);sub=NULL;}
        else if(!strncmp(input,"stale",5)){aqueous_input_activity_v1_set_ready(sub,++serial,0,1,1);}
        else if(!strncmp(input,"ready",5)){aqueous_input_activity_v1_set_ready(sub,++serial,generation_hi,generation_lo,index!=0);}
        else if(!strncmp(input,"inhibit",7)){assert(index>=0&&index<8);inhibitors[index]=aqueous_input_activity_v1_inhibit(sub,++serial);}
        else if(!strncmp(input,"release",7)){assert(index>=0&&index<8&&inhibitors[index]);aqueous_input_activity_inhibitor_v1_destroy(inhibitors[index]);inhibitors[index]=NULL;}
        else if(!strncmp(input,"autoack",7)){auto_ack=index!=0;}
        else if(!strncmp(input,"destroy-manager",15)){aqueous_input_activity_manager_v1_destroy(manager);manager=NULL;}
        else if(!strncmp(input,"window",6)){xdg_surface=xdg_wm_base_get_xdg_surface(wm,surface);xdg_surface_add_listener(xdg_surface,&surface_listener,NULL);toplevel=xdg_surface_get_toplevel(xdg_surface);xdg_toplevel_add_listener(toplevel,&top_listener,NULL);xdg_toplevel_set_app_id(toplevel,"aqueous-activity-test-window");wl_surface_commit(surface);}
        else if(!strncmp(input,"unlock",6)){ext_session_lock_v1_unlock_and_destroy(lock);lock=NULL;}
        else if(!strncmp(input,"lock",4)){lock=ext_session_lock_manager_v1_lock(lock_manager);ext_session_lock_v1_add_listener(lock,&lock_listener,NULL);}
        else if(!strncmp(input,"quit",4))break;
        else if(strncmp(input,"sync",4))assert(false);
        assert(wl_display_roundtrip(display)>=0);
        puts("{\"event\":\"command\"}");
    }
    if(proof>=0)close(proof);
    wl_display_disconnect(display);
    return 0;
}
