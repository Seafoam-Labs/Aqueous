// SPDX-License-Identifier: GPL-3.0-only
// Reuse the xdg window/foreign-handle fixture, and exercise actual capture pixels.
#define main xdg_states_main
#define FIXTURE_PIXEL (!strcmp(app_id, "scene-cover") ? 0xffff00ff : 0xff204060)
#include "xdg-shell-states.c"
#undef main
#include "aqueous-capture-color-v1-client-protocol.h"
#include "security-context-client-protocol.h"
#include <sys/socket.h>
#include <sys/un.h>
static struct aqueous_capture_color_manager_v1 *colors;
static struct wp_security_context_manager_v1 *security;
static int capture_width, capture_height;
static unsigned capture_format_value;
static bool stopped;
static void color_global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    if (!strcmp(interface, "aqueous_capture_color_manager_v1"))
        colors = wl_registry_bind(registry, id, &aqueous_capture_color_manager_v1_interface, 1);
    if (!strcmp(interface, "wp_security_context_manager_v1"))
        security = wl_registry_bind(registry, id, &wp_security_context_manager_v1_interface, 1);
}
static const struct wl_registry_listener colors_registry_listener = {.global=color_global, .global_remove=removed};
static void restricted_global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    assert(strcmp(interface,"aqueous_capture_color_manager_v1") &&
        strcmp(interface,"ext_image_copy_capture_manager_v1") &&
        strcmp(interface,"ext_foreign_toplevel_image_capture_source_manager_v1") &&
        strcmp(interface,"ext_output_image_capture_source_manager_v1") &&
        strcmp(interface,"ext_foreign_toplevel_list_v1"));
    if (!strcmp(interface,"wl_compositor")) *(bool *)data=true;
}
static void check_restricted(void) {
    assert(security);
    int fd=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0), lifetime[2];
    assert(fd>=0 && socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,lifetime)==0);
    struct sockaddr_un address={.sun_family=AF_UNIX};
    int len=snprintf(address.sun_path,sizeof(address.sun_path),"%s/capture-restricted",getenv("XDG_RUNTIME_DIR"));
    assert(len>0 && (size_t)len<sizeof(address.sun_path));
    assert(bind(fd,(struct sockaddr *)&address,sizeof(address))==0 && listen(fd,8)==0);
    struct wp_security_context_v1 *context=wp_security_context_manager_v1_create_listener(security,fd,lifetime[0]);
    wp_security_context_v1_set_sandbox_engine(context,"aqueous-test");
    wp_security_context_v1_set_app_id(context,"scene-capture-test");
    wp_security_context_v1_commit(context); wp_security_context_v1_destroy(context);
    close(fd); close(lifetime[0]); assert(wl_display_roundtrip(display)>=0);
    struct wl_display *restricted=wl_display_connect(address.sun_path); assert(restricted);
    struct wl_registry *registry=wl_display_get_registry(restricted);
    bool compositor_seen=false;
    const struct wl_registry_listener listener={.global=restricted_global,.global_remove=removed};
    wl_registry_add_listener(registry,&listener,&compositor_seen);
    assert(wl_display_roundtrip(restricted)>=0 && compositor_seen);
    wl_registry_destroy(registry); wl_display_disconnect(restricted);
    close(lifetime[1]); unlink(address.sun_path);
}
static void size_event(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h) { capture_width=w; capture_height=h; }
static void format_event(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t f) {
    if (f == WL_SHM_FORMAT_XRGB8888 || f == WL_SHM_FORMAT_ARGB8888) capture_format_value=f;
}
static void stopped_event(void *data, struct ext_image_copy_capture_session_v1 *s) { stopped=true; puts("{\"event\":\"stopped\"}"); }
static const struct ext_image_copy_capture_session_v1_listener scene_listener = {
    .buffer_size=size_event, .shm_format=format_event, .dmabuf_device=capture_device,
    .dmabuf_format=capture_dmabuf, .done=capture_done, .stopped=stopped_event,
};
struct frame {
	struct ext_image_copy_capture_frame_v1 *proxy;
	struct aqueous_capture_color_info_v1 *info;
	struct wl_buffer *buffer;
	uint8_t *pixels;
	size_t stride, size;
	bool ready, failed, color_done, unavailable;
	uint32_t reason, primaries, tf, reference, white, mastering_max, max_cll;
};
static void frame_transform(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t t) {}
static void frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y, int32_t w, int32_t h) {}
static void frame_time(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c) {}
static void frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *f) {
	struct frame *v = data; assert(v->color_done || v->unavailable); v->ready = true;
}
static void frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
	struct frame *v = data; v->failed = true; v->reason = reason;
}
static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
	.transform = frame_transform, .damage = frame_damage, .presentation_time = frame_time,
	.ready = frame_ready, .failed = frame_failed,
};
static void color_encoding(void *data, struct aqueous_capture_color_info_v1 *i, uint32_t p, uint32_t tf, uint32_t r, uint32_t w) {
	struct frame *v = data; v->primaries = p; v->tf = tf; v->reference = r; v->white = w;
}
static void color_mastering(void *data, struct aqueous_capture_color_info_v1 *i,
		uint32_t rx, uint32_t ry, uint32_t gx, uint32_t gy, uint32_t bx, uint32_t by,
		uint32_t wx, uint32_t wy, uint32_t min, uint32_t max) { ((struct frame *)data)->mastering_max = max; }
static void color_light(void *data, struct aqueous_capture_color_info_v1 *i, uint32_t cll, uint32_t fall) { ((struct frame *)data)->max_cll = cll; }
static void color_done(void *data, struct aqueous_capture_color_info_v1 *i) {
	struct frame *v = data; assert(!v->unavailable && !v->color_done); v->color_done = true;
}
static void color_unavailable(void *data, struct aqueous_capture_color_info_v1 *i) {
	struct frame *v = data; assert(!v->unavailable && !v->color_done); v->unavailable = true;
}
static const struct aqueous_capture_color_info_v1_listener color_listener = {
	.encoding = color_encoding, .mastering_display = color_mastering, .content_light = color_light,
	.done = color_done, .unavailable = color_unavailable,
};
static void frame_init(struct frame *f, struct ext_image_copy_capture_session_v1 *s, uint32_t format, bool start) {
	*f = (struct frame){0};
	f->stride = capture_width * 4 + 16; f->size = f->stride * capture_height;
	int fd = memfd_create("capture-fixture", MFD_CLOEXEC); assert(fd >= 0);
	assert(ftruncate(fd, (off_t)f->size) == 0);
	f->pixels = mmap(NULL, f->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	assert(f->pixels != MAP_FAILED); memset(f->pixels, 0xA5, f->size);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)f->size);
	f->buffer = wl_shm_pool_create_buffer(pool, 0, capture_width, capture_height, (int32_t)f->stride, format);
	wl_shm_pool_destroy(pool); close(fd);
	f->proxy = ext_image_copy_capture_session_v1_create_frame(s);
	ext_image_copy_capture_frame_v1_add_listener(f->proxy, &frame_listener, f);
	f->info = aqueous_capture_color_manager_v1_get_frame_info(colors, f->proxy);
	aqueous_capture_color_info_v1_add_listener(f->info, &color_listener, f);
	ext_image_copy_capture_frame_v1_attach_buffer(f->proxy, f->buffer);
	ext_image_copy_capture_frame_v1_damage_buffer(f->proxy, 0, 0, capture_width, capture_height);
	if (start) ext_image_copy_capture_frame_v1_capture(f->proxy);
	assert(wl_display_roundtrip(display) >= 0);
}
static void frame_finish(struct frame *f) {
	ext_image_copy_capture_frame_v1_destroy(f->proxy);
	aqueous_capture_color_info_v1_destroy(f->info);
	wl_buffer_destroy(f->buffer); munmap(f->pixels, f->size); assert(wl_display_roundtrip(display) >= 0);
}
static void padding_unchanged(struct frame *f) {
	for (int y = 0; y < capture_height; y++) for (size_t x = capture_width * 4; x < f->stride; x++)
		assert(f->pixels[(size_t)y * f->stride + x] == 0xA5);
}


static void open_session(void) {
    assert(foreign);
    if (capture_session) ext_image_copy_capture_session_v1_destroy(capture_session);
    if (capture_source) ext_image_capture_source_v1_destroy(capture_source);
    stopped=false;
    capture_source=ext_foreign_toplevel_image_capture_source_manager_v1_create_source(capture_manager,foreign);
    capture_session=ext_image_copy_capture_manager_v1_create_session(copy_manager,capture_source,0);
    ext_image_copy_capture_session_v1_add_listener(capture_session,&scene_listener,NULL);
    assert(wl_display_roundtrip(display)>=0);
}
int main(int argc, char **argv) {
    assert(argc==2); app_id=argv[1]; bind_version=7;
    setvbuf(stdout,NULL,_IOLBF,0);
    display=wl_display_connect(NULL); assert(display);
    struct wl_registry *registry=wl_display_get_registry(display);
    wl_registry_add_listener(registry,&registry_listener,NULL);
    struct wl_registry *cr=wl_display_get_registry(display);
    wl_registry_add_listener(cr,&colors_registry_listener,NULL);
    assert(wl_display_roundtrip(display)>=0 && colors && compositor && shm && wm);
    surface=wl_compositor_create_surface(compositor);
    xdg=xdg_wm_base_get_xdg_surface(wm,surface); xdg_surface_add_listener(xdg,&surface_listener,NULL);
    top=xdg_surface_get_toplevel(xdg); xdg_toplevel_add_listener(top,&top_listener,NULL);
    xdg_toplevel_set_app_id(top,app_id); xdg_toplevel_set_title(top,app_id); wl_surface_commit(surface);
    struct frame frame={0};
    for (;;) {
        while (wl_display_prepare_read(display)!=0) assert(wl_display_dispatch_pending(display)>=0);
        wl_display_flush(display);
        struct pollfd fds[]={{wl_display_get_fd(display),POLLIN,0},{STDIN_FILENO,POLLIN,0}};
        assert(poll(fds,2,-1)>=0);
        if (fds[0].revents&POLLIN) assert(wl_display_read_events(display)>=0); else wl_display_cancel_read(display);
        assert(wl_display_dispatch_pending(display)>=0);
        if (!(fds[1].revents&POLLIN)) continue;
        char cmd; if (read(STDIN_FILENO,&cmd,1)!=1 || cmd=='q') break;
        switch(cmd) {
        case 'b': check_restricted(); break;
        case 'o': open_session(); break;
        case 'p': frame_init(&frame,capture_session,capture_format_value,false); break;
        case 'c':
            draw();
            frame_init(&frame,capture_session,capture_format_value,true);
            while (!frame.ready && !frame.failed) assert(wl_display_dispatch(display)>=0);
            assert(frame.ready && frame.color_done && !frame.unavailable);
            assert(frame.tf==AQUEOUS_CAPTURE_COLOR_INFO_V1_TRANSFER_FUNCTION_GAMMA22 && frame.primaries==AQUEOUS_CAPTURE_COLOR_INFO_V1_PRIMARIES_SRGB);
            // Capture the surface contents, not decorations or the occluding window.
            for (int y=0;y<capture_height;y++) for (int x=0;x<capture_width;x++) {
                const unsigned char *pixel=frame.pixels+y*frame.stride+x*4;
                assert(abs(pixel[0]-0x60)<=1 && abs(pixel[1]-0x40)<=1 && abs(pixel[2]-0x20)<=1);
            }
            padding_unchanged(&frame); frame_finish(&frame);
            puts("{\"event\":\"capture\"}"); break;
        case 'f':
            ext_image_copy_capture_frame_v1_capture(frame.proxy);
            while (!frame.ready && !frame.failed) assert(wl_display_dispatch(display)>=0);
            assert(wl_display_roundtrip(display)>=0);
            assert(frame.failed && frame.unavailable && !frame.ready);
            for (size_t i=0;i<frame.size;i++) assert(frame.pixels[i]==0xA5);
            frame_finish(&frame); puts("{\"event\":\"denied\"}"); break;
        case 'u': wl_surface_attach(surface,NULL,0,0); wl_surface_commit(surface); mapped=false; break;
        case 's': assert(wl_display_roundtrip(display)>=0); break;
        default: abort();
        }
        printf("{\"event\":\"command\",\"value\":\"%c\"}\n",cmd);
    }
    wl_display_disconnect(display); return 0;
}
