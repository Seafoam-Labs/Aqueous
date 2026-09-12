#define _GNU_SOURCE
#define CAPTURE_TRACE_UNIT "fixture"
#include "trace.h"
#include "pattern.h"
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include "xdg-shell-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static struct xdg_surface *xdg;
static struct xdg_toplevel *top;
static struct {
    struct wl_output *object;
    char name[128];
} outputs[16];
static unsigned output_count, frame;
static int width = 640, height = 360, fps = 60, seconds = 60;
static bool configured, sparse, fullscreen = true;
static volatile sig_atomic_t stopped;
static const char *output_name, *fault = "none";
static struct buffer {
    struct wl_buffer *wl;
    uint32_t *pixels;
    size_t size;
    int width, height;
    bool busy;
} buffers[3];
static void stop(int sig) {
    (void)sig;
    stopped = 1;
}
static void release(void *data, struct wl_buffer *wl) {
    struct buffer *b = data;
    b->busy = false;
    capture_trace("client_release", (uintptr_t)wl, 0, frame, 0);
}
static const struct wl_buffer_listener buffer_listener = {.release = release};
static bool gpu;
static EGLDisplay egl;
static EGLContext context;
static EGLSurface egl_surface;
static struct wl_egl_window *egl_window;
static GLuint program, texture;
static PFNEGLSWAPBUFFERSWITHDAMAGEEXTPROC swap_damage;
static GLuint shader(GLenum type, const char *source) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &source, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        fprintf(stderr, "fixture shader compilation failed\n");
        exit(1);
    }
    return s;
}
static void gpu_init(void) {
    egl = eglGetDisplay((EGLNativeDisplayType)display);
    EGLint major, minor, count;
    if (!eglInitialize(egl, &major, &minor) || !eglBindAPI(EGL_OPENGL_ES_API))
        goto fail;
    const EGLint attributes[] = {EGL_SURFACE_TYPE,
                                 EGL_WINDOW_BIT,
                                 EGL_RENDERABLE_TYPE,
                                 EGL_OPENGL_ES2_BIT,
                                 EGL_RED_SIZE,
                                 8,
                                 EGL_GREEN_SIZE,
                                 8,
                                 EGL_BLUE_SIZE,
                                 8,
                                 EGL_ALPHA_SIZE,
                                 0,
                                 EGL_NONE};
    EGLConfig config;
    if (!eglChooseConfig(egl, attributes, &config, 1, &count) || !count)
        goto fail;
    const EGLint ctx[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    context = eglCreateContext(egl, config, EGL_NO_CONTEXT, ctx);
    egl_window = wl_egl_window_create(surface, width, height);
    egl_surface = eglCreateWindowSurface(egl, config, (EGLNativeWindowType)egl_window, NULL);
    if (!eglMakeCurrent(egl, egl_surface, egl_surface, context))
        goto fail;
    eglSwapInterval(egl, 0);
    GLuint vs = shader(GL_VERTEX_SHADER,
                       "attribute vec2 p; varying vec2 uv; void "
                       "main(){gl_Position=vec4(p,0.,1.);uv=vec2((p.x+1.)/2.,(1.-p.y)/2.);}");
    GLuint fs =
        shader(GL_FRAGMENT_SHADER, "precision mediump float; varying vec2 uv; uniform sampler2D "
                                   "tex; void main(){gl_FragColor=texture2D(tex,uv);}");
    program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "p");
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok)
        goto fail;
    glUseProgram(program);
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    const char *extensions = eglQueryString(egl, EGL_EXTENSIONS);
    if (extensions && strstr(extensions, "EGL_EXT_swap_buffers_with_damage"))
        swap_damage = (void *)eglGetProcAddress("eglSwapBuffersWithDamageEXT");
    return;
fail:
    fprintf(stderr, "fixture EGL initialization failed: 0x%x\n", eglGetError());
    exit(77);
}
static void draw(void) {
    struct buffer *b = NULL;
    if (gpu && !egl_window)
        gpu_init();
    for (unsigned i = 0; i < 3; i++)
        if (!buffers[i].busy) {
            b = &buffers[i];
            break;
        }
    if (!b) {
        capture_trace("client_no_buffer", 0, 0, frame, 0);
        return;
    }
    if (gpu) {
        size_t size = (size_t)width * height * 4;
        if (b->size != size) {
            free(b->pixels);
            b->pixels = malloc(size);
            b->size = size;
            if (!b->pixels)
                exit(1);
        }
        wl_egl_window_resize(egl_window, width, height, 0, 0);
    } else if (!b->wl || b->width != width || b->height != height) {
        if (b->wl) {
            wl_buffer_destroy(b->wl);
            munmap(b->pixels, b->size);
        }
        b->width = width;
        b->height = height;
        b->size = (size_t)width * height * 4;
        int fd = memfd_create("capture-pattern", MFD_CLOEXEC);
        if (fd < 0 || ftruncate(fd, b->size)) {
            perror("buffer");
            exit(1);
        }
        b->pixels = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (b->pixels == MAP_FAILED) {
            perror("mmap");
            exit(1);
        }
        struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, b->size);
        b->wl =
            wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
        wl_buffer_add_listener(b->wl, &buffer_listener, b);
        wl_shm_pool_destroy(pool);
        close(fd);
    }
    frame++;
    for (int y = 0; y < height; y++) {
        if (y >= 16 && !strcmp(fault, "none")) {
            memcpy(b->pixels + (size_t)y * width, b->pixels + (size_t)(y % 16) * width,
                   (size_t)width * 4);
            continue;
        }
        for (int x = 0; x < width; x++) {
            unsigned f = frame;
            if (frame > 20 && !strcmp(fault, "mixed") && y > height / 2)
                f--;
            if (frame > 20 && !strcmp(fault, "stale") && x > width / 2)
                f -= sparse ? 8 : 1;
            b->pixels[(size_t)y * width + x] =
                frame > 20 && !strcmp(fault, "missing") ? 0 : pattern_pixel(f, x, y, width, sparse);
        }
    }
    if (!gpu) {
        wl_surface_attach(surface, b->wl, 0, 0);
        b->busy = true;
    }
    if (!sparse || frame == 1 || strcmp(fault, "none")) {
        wl_surface_damage_buffer(surface, 0, 0, width, height);
    } else {
        wl_surface_damage_buffer(surface, 0, 0, 128, height);
        int tile = (frame - 1) % 8;
        int x1 = 128 + (tile * (width - 128) + 7) / 8;
        int x2 = 128 + ((tile + 1) * (width - 128) + 7) / 8;
        wl_surface_damage_buffer(surface, x1, 0, x2 - x1, height);
    }
    struct wl_region *opaque = wl_compositor_create_region(compositor);
    wl_region_add(opaque, 0, 0, width, height);
    wl_surface_set_opaque_region(surface, opaque);
    wl_region_destroy(opaque);
    if (gpu) {
        glViewport(0, 0, width, height);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                     b->pixels);
        const GLfloat vertices[] = {-1, -1, 1, -1, -1, 1, 1, 1};
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
        glEnableVertexAttribArray(0);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        EGLint damage[] = {0, 0, 128, height, 0, 0, 0, height};
        int tile = (frame - 1) % 8;
        damage[4] = 128 + (tile * (width - 128) + 7) / 8;
        damage[6] = 128 + ((tile + 1) * (width - 128) + 7) / 8 - damage[4];
        bool ok = (sparse && frame > 1 && !strcmp(fault, "none") && swap_damage)
                      ? swap_damage(egl, egl_surface, damage, 2)
                      : eglSwapBuffers(egl, egl_surface);
        GLenum error = glGetError();
        if (!ok || error != GL_NO_ERROR) {
            fprintf(stderr, "fixture EGL render failed: swap=%d egl=0x%x gl=0x%x\n", ok,
                    eglGetError(), error);
            exit(1);
        }
    } else
        wl_surface_commit(surface);
    capture_trace("client_commit", (uintptr_t)b->wl, 0, frame, sparse);
}
static void configure(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(s, serial);
    configured = true;
    capture_trace("configure", 0, 0, width, height);
}
static const struct xdg_surface_listener xdg_listener = {.configure = configure};
static void top_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h,
                          struct wl_array *states) {
    (void)data;
    (void)t;
    (void)states;
    if (w > 0 && h > 0 && w <= 8192 && h <= 8192) {
        width = w;
        height = h;
    }
}
static void top_close(void *data, struct xdg_toplevel *t) {
    (void)data;
    (void)t;
    stopped = 1;
}
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure,
                                                          .close = top_close};
static void ping(void *data, struct xdg_wm_base *w, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(w, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t w, int32_t h,
                     int32_t s, const char *m, const char *mo, int32_t t) {
    (void)d;
    (void)o;
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)s;
    (void)m;
    (void)mo;
    (void)t;
}
static void mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {
    (void)d;
    (void)o;
    (void)f;
    (void)w;
    (void)h;
    (void)r;
}
static void done(void *d, struct wl_output *o) {
    (void)d;
    (void)o;
}
static void scale(void *d, struct wl_output *o, int32_t s) {
    (void)d;
    (void)o;
    (void)s;
}
static void name(void *d, struct wl_output *o, const char *n) {
    (void)o;
    snprintf(outputs[(uintptr_t)d].name, 128, "%s", n);
}
static void description(void *d, struct wl_output *o, const char *s) {
    (void)d;
    (void)o;
    (void)s;
}
static const struct wl_output_listener output_listener = {.geometry = geometry,
                                                          .mode = mode,
                                                          .done = done,
                                                          .scale = scale,
                                                          .name = name,
                                                          .description = description};
static void global(void *data, struct wl_registry *reg, uint32_t id, const char *interface,
                   uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(reg, id, &wl_compositor_interface, 4);
    if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(reg, id, &wl_shm_interface, 1);
    if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(reg, id, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
    if (!strcmp(interface, "wl_output") && version >= 4 && output_count < 16) {
        outputs[output_count].object = wl_registry_bind(reg, id, &wl_output_interface, 4);
        wl_output_add_listener(outputs[output_count].object, &output_listener,
                               (void *)(uintptr_t)output_count);
        output_count++;
    }
}
static void removed(void *data, struct wl_registry *r, uint32_t id) {
    (void)data;
    (void)r;
    (void)id;
}
static const struct wl_registry_listener registry_listener = {.global = global,
                                                              .global_remove = removed};
int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--gpu"))
            gpu = true;
        else if (!strcmp(argv[i], "--sparse"))
            sparse = true;
        else if (!strcmp(argv[i], "--windowed"))
            fullscreen = false;
        else if (i + 1 < argc && !strcmp(argv[i], "--fps"))
            fps = atoi(argv[++i]);
        else if (i + 1 < argc && !strcmp(argv[i], "--seconds"))
            seconds = atoi(argv[++i]);
        else if (i + 1 < argc && !strcmp(argv[i], "--output"))
            output_name = argv[++i];
        else if (i + 1 < argc && !strcmp(argv[i], "--fault"))
            fault = argv[++i];
        else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }
    if (fps < 1 || fps > 360 || seconds < 1 || seconds > 86400)
        return 2;
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    display = wl_display_connect(NULL);
    if (!display) {
        perror("Wayland");
        return 1;
    }
    struct wl_registry *reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm)
        return 77;
    surface = wl_compositor_create_surface(compositor);
    xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &xdg_listener, NULL);
    top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_app_id(top, "aqueous.capture-pattern");
    xdg_toplevel_set_title(top, "Aqueous capture integrity fixture");
    struct wl_output *output = NULL;
    for (unsigned i = 0; i < output_count; i++)
        if (output_name && !strcmp(output_name, outputs[i].name))
            output = outputs[i].object;
    if (output_name && !output) {
        fprintf(stderr, "output not found: %s\n", output_name);
        return 77;
    }
    if (fullscreen)
        xdg_toplevel_set_fullscreen(top, output);
    wl_surface_commit(surface);
    uint64_t end = capture_now() + (uint64_t)seconds * 1000000000, next = 0;
    while (!stopped && capture_now() < end) {
        if (wl_display_dispatch_pending(display) < 0)
            break;
        if (configured && capture_now() >= next) {
            draw();
            next += 1000000000 / fps;
            if (next < capture_now())
                next = capture_now() + 1000000000 / fps;
        }
        wl_display_flush(display);
        struct pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, 2) < 0 && errno != EINTR)
            break;
        if (fds[0].revents & POLLIN)
            if (wl_display_dispatch(display) < 0)
                break;
        if (fds[1].revents & POLLIN) {
            char cmd;
            if (read(0, &cmd, 1) == 1) {
                if (cmd == 'q')
                    stopped = 1;
                if (cmd == 'f') {
                    fullscreen = !fullscreen;
                    if (fullscreen)
                        xdg_toplevel_set_fullscreen(top, output);
                    else
                        xdg_toplevel_unset_fullscreen(top);
                }
            }
        }
    }
    if (gpu && egl_window) {
        glDeleteTextures(1, &texture);
        glDeleteProgram(program);
        eglMakeCurrent(egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(egl, egl_surface);
        eglDestroyContext(egl, context);
        wl_egl_window_destroy(egl_window);
        eglTerminate(egl);
    }
    for (unsigned i = 0; i < 3; i++) {
        if (buffers[i].wl)
            wl_buffer_destroy(buffers[i].wl);
        if (buffers[i].pixels) {
            if (gpu)
                free(buffers[i].pixels);
            else
                munmap(buffers[i].pixels, buffers[i].size);
        }
    }
    xdg_toplevel_destroy(top);
    xdg_surface_destroy(xdg);
    wl_surface_destroy(surface);
    wl_display_flush(display);
    wl_display_disconnect(display);
    return 0;
}
