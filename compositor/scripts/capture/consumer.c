#define _GNU_SOURCE
#define CAPTURE_TRACE_UNIT "consumer"
#include "trace.h"
#include "pattern.h"
#include <errno.h>
#include <poll.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/buffer/meta.h>
#include <spa/pod/builder.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <gbm.h>
#include <drm_fourcc.h>

struct held {
    struct pw_buffer *buffer;
    uint64_t until;
};
struct app {
    struct pw_main_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct pw_proxy *link;
    struct pw_registry *registry;
    struct spa_hook registry_listener;
    uint32_t input_port, output_port;
    struct spa_hook listener, core_listener;
    struct spa_source *timer;
    struct spa_video_info_raw format;
    struct held held[64];
    int node, fps, wanted_buffers, hold_periods, seconds;
    unsigned dmabuf_frames, shm_frames, frames, bad, missing, stale, mixed, duplicates, regressions,
        metadata_bad, metadata_seen, additions, removals, previous;
    bool implicit_only, sparse, failed, stop, reference_valid, negotiated, summary_only;
    int transport; // 0 auto, 1 SHM, 2 DMA-BUF
    const char *directory, *render_node;
    uint64_t deadline, next_hold, max_gap, last_frame, reads_ns;
    uint32_t *pixels, *reference;
    size_t pixel_size;
    int drm_fd;
    struct gbm_device *gbm;
    EGLDisplay egl;
    EGLContext egl_context;
    EGLSurface egl_surface;
    PFNEGLCREATEIMAGEKHRPROC create_image;
    PFNEGLDESTROYIMAGEKHRPROC destroy_image;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target_image;
    PFNEGLQUERYDMABUFMODIFIERSEXTPROC query_modifiers;
};
static struct app app;
static void fail(const char *message) {
    fprintf(stderr, "capture consumer: %s\n", message);
    app.failed = true;
    app.stop = true;
}
static bool init_egl(void) {
    app.drm_fd = open(app.render_node, O_RDWR | O_CLOEXEC);
    if (app.drm_fd < 0)
        return false;
    app.gbm = gbm_create_device(app.drm_fd);
    if (!app.gbm)
        return false;
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
        (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!get_display)
        return false;
    app.egl = get_display(EGL_PLATFORM_GBM_KHR, app.gbm, NULL);
    EGLint major, minor;
    if (app.egl == EGL_NO_DISPLAY || !eglInitialize(app.egl, &major, &minor) ||
        !eglBindAPI(EGL_OPENGL_ES_API))
        return false;
    const EGLint config_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE,
                                   EGL_PBUFFER_BIT, EGL_NONE};
    EGLConfig config;
    EGLint count;
    if (!eglChooseConfig(app.egl, config_attrs, &config, 1, &count) || !count)
        return false;
    const EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    const EGLint surface_attrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    app.egl_context = eglCreateContext(app.egl, config, EGL_NO_CONTEXT, context_attrs);
    app.egl_surface = eglCreatePbufferSurface(app.egl, config, surface_attrs);
    if (app.egl_context == EGL_NO_CONTEXT || app.egl_surface == EGL_NO_SURFACE ||
        !eglMakeCurrent(app.egl, app.egl_surface, app.egl_surface, app.egl_context))
        return false;
    app.create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
    app.destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
    app.target_image = (void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    app.query_modifiers = (void *)eglGetProcAddress("eglQueryDmaBufModifiersEXT");
    return app.create_image && app.destroy_image && app.target_image && app.query_modifiers;
}
// EGL import alone does not reliably wait for DMA-BUF writes on every driver.
// Wait on the advertised producer fence before issuing any GPU read. This
// protects the oracle from blaming the compositor for a consumer-side race.
static bool wait_dmabuf(struct spa_buffer *buffer) {
    if (app.implicit_only)
        return true;
    for (unsigned j = 0; j < buffer->n_datas; j++) {
        struct dma_buf_export_sync_file sync = {.flags = DMA_BUF_SYNC_READ, .fd = -1};
        int fd = buffer->datas[j].fd;
        if (fd < 0)
            return false;
        int rc = ioctl(fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &sync);
        if (rc < 0 && errno != ENOTTY && errno != ENOSYS && errno != EINVAL)
            return false;
        struct pollfd p = {.fd = rc == 0 ? sync.fd : fd, .events = POLLIN};
        uint64_t start = capture_now();
        do {
            rc = poll(&p, 1, 2000);
        } while (rc < 0 && errno == EINTR);
        bool ok = rc > 0 && (p.revents & POLLIN) && !(p.revents & (POLLERR | POLLNVAL));
        capture_trace("producer_wait", 0, 0, ok, capture_now() - start);
        if (sync.fd >= 0)
            close(sync.fd);
        if (!ok)
            return false;
    }
    return true;
}
static bool read_dmabuf(struct spa_buffer *buffer) {
    if (buffer->n_datas < 1 || buffer->n_datas > 4 || !app.create_image)
        return false;
    if (!wait_dmabuf(buffer))
        return false;
    static const EGLint fd_keys[] = {EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
                                     EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT};
    static const EGLint offset_keys[] = {
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT, EGL_DMA_BUF_PLANE2_OFFSET_EXT,
        EGL_DMA_BUF_PLANE3_OFFSET_EXT};
    static const EGLint pitch_keys[] = {EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT,
                                        EGL_DMA_BUF_PLANE2_PITCH_EXT, EGL_DMA_BUF_PLANE3_PITCH_EXT};
    static const EGLint lo_keys[] = {
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
        EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT};
    static const EGLint hi_keys[] = {
        EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
        EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT};
    EGLint attrs[64] = {EGL_WIDTH,
                        app.format.size.width,
                        EGL_HEIGHT,
                        app.format.size.height,
                        EGL_LINUX_DRM_FOURCC_EXT,
                        DRM_FORMAT_ARGB8888};
    unsigned n = 6;
    for (unsigned j = 0; j < buffer->n_datas; j++) {
        struct spa_data *d = &buffer->datas[j];
        if (d->type != SPA_DATA_DmaBuf || d->fd < 0 || !d->chunk || d->chunk->stride <= 0)
            return false;
        attrs[n++] = fd_keys[j];
        attrs[n++] = d->fd;
        attrs[n++] = offset_keys[j];
        attrs[n++] = d->chunk->offset;
        attrs[n++] = pitch_keys[j];
        attrs[n++] = d->chunk->stride;
        if (app.format.modifier != DRM_FORMAT_MOD_INVALID) {
            attrs[n++] = lo_keys[j];
            attrs[n++] = (uint32_t)app.format.modifier;
            attrs[n++] = hi_keys[j];
            attrs[n++] = app.format.modifier >> 32;
        }
    }
    attrs[n] = EGL_NONE;
    EGLImageKHR image =
        app.create_image(app.egl, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
    if (image == EGL_NO_IMAGE_KHR) {
        fprintf(stderr, "EGL import error: 0x%x\n", eglGetError());
        return false;
    }
    GLuint texture, fbo;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    app.target_image(GL_TEXTURE_2D, image);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (ok) {
        // EGL imports carry implicit DMA-BUF synchronization. Readback completes
        // before returning the PipeWire buffer, including any GL use of it.
        glReadPixels(0, 0, app.format.size.width, app.format.size.height, GL_RGBA, GL_UNSIGNED_BYTE,
                     app.pixels);
        glFinish();
        ok = glGetError() == GL_NO_ERROR;
        for (size_t j = 0; j < app.pixel_size / 4; j++) {
            uint32_t p = app.pixels[j];
            app.pixels[j] = (p & 0xff00ff00) | ((p & 0xff) << 16) | ((p >> 16) & 0xff);
        }
    }
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(1, &texture);
    app.destroy_image(app.egl, image);
    return ok;
}
static bool read_shm(struct spa_buffer *buffer) {
    if (buffer->n_datas != 1)
        return false;
    struct spa_data *d = &buffer->datas[0];
    if (!d->chunk || d->chunk->stride <= 0)
        return false;
    size_t row = (size_t)app.format.size.width * 4;
    size_t needed =
        (size_t)d->chunk->offset + (app.format.size.height - 1) * (size_t)d->chunk->stride + row;
    if ((size_t)d->chunk->stride < row || needed > d->maxsize)
        return false;
    void *base = d->data;
    size_t length = (size_t)d->mapoffset + d->maxsize;
    bool mapped = false;
    if (!base && d->type == SPA_DATA_MemFd) {
        base = mmap(NULL, length, PROT_READ, MAP_SHARED, d->fd, 0);
        if (base == MAP_FAILED)
            return false;
        mapped = true;
    }
    if (!base)
        return false;
    const uint8_t *pixels = (uint8_t *)base + (mapped ? d->mapoffset : 0) + d->chunk->offset;
    for (unsigned y = 0; y < app.format.size.height; y++)
        memcpy(app.pixels + (size_t)y * app.format.size.width,
               pixels + (size_t)y * d->chunk->stride, row);
    if (mapped)
        munmap(base, length);
    if (app.format.format == SPA_VIDEO_FORMAT_RGBA || app.format.format == SPA_VIDEO_FORMAT_RGBx)
        for (size_t j = 0; j < app.pixel_size / 4; j++) {
            uint32_t p = app.pixels[j];
            app.pixels[j] = (p & 0xff00ff00) | ((p & 0xff) << 16) | ((p >> 16) & 0xff);
        }
    return true;
}
static void artifact(unsigned frame) {
    if (app.bad > 3)
        return;
    char path[4096];
    snprintf(path, sizeof(path), "%s/frame-%u-%u.ppm", app.directory, app.frames, frame);
    FILE *f = fopen(path, "wb");
    if (!f)
        return;
    fprintf(f, "P6\n%u %u\n255\n", app.format.size.width, app.format.size.height);
    for (size_t j = 0; j < app.pixel_size / 4; j++) {
        uint32_t p = app.pixels[j];
        unsigned char rgb[] = {p >> 16, p >> 8, p};
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
}
static void check_metadata(struct spa_buffer *buffer) {
    struct spa_meta *m = spa_buffer_find_meta(buffer, SPA_META_VideoDamage);
    if (!m) {
        app.reference_valid = false;
        return;
    }
    app.metadata_seen++;
    if (!app.reference_valid) {
        memcpy(app.reference, app.pixels, app.pixel_size);
        app.reference_valid = true;
        return;
    }
    struct spa_region *regions = m->data;
    unsigned w = app.format.size.width, h = app.format.size.height;
    for (size_t j = 0; j < m->size / sizeof(*regions); j++) {
        int64_t x = regions[j].position.x, y = regions[j].position.y;
        int64_t right = x + regions[j].size.width, bottom = y + regions[j].size.height;
        if (x < 0 || y < 0 || right > w || bottom > h) {
            fail("invalid damage rectangle");
            return;
        }
        for (int64_t row = y; row < bottom; row++)
            memcpy(app.reference + row * w + x, app.pixels + row * w + x, (right - x) * 4);
    }
    // Compare luminance class, not alpha or unused format bits.
    unsigned mismatch = 0;
    for (size_t j = 0; j < app.pixel_size / 4; j++)
        if (((app.reference[j] & 255) > 127) != ((app.pixels[j] & 255) > 127))
            mismatch++;
    if (mismatch) {
        app.metadata_bad++;
        capture_trace("metadata_mismatch", 0, 0, mismatch, app.frames);
    }
}
static void process(void *data) {
    (void)data;
    struct pw_buffer *b;
    while ((b = pw_stream_dequeue_buffer(app.stream))) {
        uint64_t begin = capture_now();
        struct spa_buffer *buf = b->buffer;
        if (!buf || !buf->n_datas) {
            fail("empty buffer data array");
            pw_stream_queue_buffer(app.stream, b);
            return;
        }
        capture_trace("acquire", (uintptr_t)b, 0, buf->datas[0].fd, 0);
        if (!app.negotiated || !buf->datas[0].chunk ||
            (buf->datas[0].chunk->flags & SPA_CHUNK_FLAG_CORRUPTED)) {
            capture_trace("corrupt_flag", (uintptr_t)b, 0, 0, 0);
            capture_trace("release", (uintptr_t)b, 0, 0, 0);
            pw_stream_queue_buffer(app.stream, b);
            continue;
        }
        bool ok = buf->datas[0].type == SPA_DATA_DmaBuf ? read_dmabuf(buf) : read_shm(buf);
        if (!ok) {
            fail("buffer import/read failed");
            capture_trace("release", (uintptr_t)b, 0, 0, 0);
            pw_stream_queue_buffer(app.stream, b);
            return;
        }
        if (buf->datas[0].type == SPA_DATA_DmaBuf)
            app.dmabuf_frames++;
        else
            app.shm_frames++;
        app.frames++;
        app.reads_ns += capture_now() - begin;
        if (app.last_frame && begin - app.last_frame > app.max_gap)
            app.max_gap = begin - app.last_frame;
        app.last_frame = begin;
        struct pattern_result r =
            pattern_check(app.pixels, app.format.size.width, app.format.size.height, app.sparse);
        if (r.missing_rows)
            app.missing++;
        if (r.bad_rows)
            app.mixed++;
        if (r.bad_pixels)
            app.stale++;
        if (r.missing_rows || r.bad_rows || r.bad_pixels) {
            app.bad++;
            artifact(r.frame);
        }
        if (app.frames > 1 && r.frame == app.previous)
            app.duplicates++;
        if (app.frames > 1 && r.frame < app.previous)
            app.regressions++;
        app.previous = r.frame;
        check_metadata(buf);
        capture_trace("read_complete", (uintptr_t)b, 0, r.frame,
                      r.bad_rows + r.bad_pixels + r.missing_rows);
        bool retain = app.hold_periods > 0 && begin >= app.next_hold &&
                      (begin - app.next_hold) % 2000000000 < 1000000000;
        bool stored = false;
        if (retain) {
            for (unsigned j = 0; j < 64; j++)
                if (!app.held[j].buffer) {
                    app.held[j] = (struct held){b, capture_now() + (uint64_t)app.hold_periods *
                                                                       1000000000 / app.fps};
                    stored = true;
                    break;
                }
        }
        if (!stored) {
            capture_trace("release", (uintptr_t)b, 0, r.frame, 0);
            pw_stream_queue_buffer(app.stream, b);
        } else
            capture_trace("hold", (uintptr_t)b, 0, app.hold_periods, 0);
    }
}
static void param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    (void)data;
    if (id != SPA_PARAM_Format || !param)
        return;
    if (spa_format_video_raw_parse(param, &app.format) < 0 ||
        (app.format.format != SPA_VIDEO_FORMAT_BGRA && app.format.format != SPA_VIDEO_FORMAT_BGRx &&
         app.format.format != SPA_VIDEO_FORMAT_RGBA &&
         app.format.format != SPA_VIDEO_FORMAT_RGBx) ||
        app.format.size.width < 256 || app.format.size.height < 1 || app.format.size.width > 8192 ||
        app.format.size.height > 8192) {
        fail("unsupported negotiated format/size");
        return;
    }
    size_t size = (size_t)app.format.size.width * app.format.size.height * 4;
    if (size != app.pixel_size) {
        free(app.pixels);
        free(app.reference);
        app.pixels = malloc(size);
        app.reference = malloc(size);
        app.pixel_size = size;
        app.reference_valid = false;
    }
    if (!app.pixels || !app.reference) {
        fail("allocation");
        return;
    }
    app.negotiated = true;
    fprintf(stderr, "negotiated SPA format=%u %ux%u modifier=%" PRIu64 " fps=%u/%u\n",
            app.format.format, app.format.size.width, app.format.size.height, app.format.modifier,
            app.format.max_framerate.num, app.format.max_framerate.denom);
    uint8_t storage[2048];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
    const struct spa_pod *params[3];
    uint32_t type = spa_pod_find_prop(param, NULL, SPA_FORMAT_VIDEO_modifier)
                        ? (1 << SPA_DATA_DmaBuf)
                        : (1 << SPA_DATA_MemFd);
    params[0] =
        spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
                                   SPA_PARAM_BUFFERS_buffers, SPA_POD_Int(app.wanted_buffers),
                                   SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(type));
    params[1] = spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
                                           SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
                                           SPA_PARAM_META_size,
                                           SPA_POD_Int(sizeof(struct spa_meta_header)));
    params[2] = spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
                                           SPA_PARAM_META_type, SPA_POD_Id(SPA_META_VideoDamage),
                                           SPA_PARAM_META_size,
                                           SPA_POD_Int(16 * sizeof(struct spa_region)));
    pw_stream_update_params(app.stream, params, 3);
}
static void add_buffer(void *data, struct pw_buffer *b) {
    (void)data;
    app.additions++;
    capture_trace("add_buffer", (uintptr_t)b, 0, app.additions, 0);
}
static void remove_buffer(void *data, struct pw_buffer *b) {
    (void)data;
    app.removals++;
    for (unsigned j = 0; j < 64; j++)
        if (app.held[j].buffer == b) {
            app.held[j].buffer = NULL;
            capture_trace("held_removed", (uintptr_t)b, 0, 0, 0);
        }
    capture_trace("remove_buffer", (uintptr_t)b, 0, 0, 0);
}
static void state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state,
                          const char *error) {
    (void)data;
    (void)old;
    capture_trace("state", 0, 0, state, 0);
    if (state == PW_STREAM_STATE_ERROR) {
        fail(error ? error : "stream error");
        return;
    }
}
static void registry_global(void *data, uint32_t id, uint32_t permissions, const char *type,
                            uint32_t version, const struct spa_dict *props) {
    (void)data;
    (void)permissions;
    (void)version;
    if (strcmp(type, PW_TYPE_INTERFACE_Port) || !props)
        return;
    const char *node = spa_dict_lookup(props, PW_KEY_NODE_ID);
    const char *direction = spa_dict_lookup(props, PW_KEY_PORT_DIRECTION);
    if (!node || !direction)
        return;
    uint32_t node_id = (uint32_t)strtoul(node, NULL, 10);
    if (node_id == (uint32_t)app.node && !strcmp(direction, "out"))
        app.output_port = id;
    if (node_id == pw_stream_get_node_id(app.stream) && !strcmp(direction, "in"))
        app.input_port = id;
    if (app.link || app.input_port == PW_ID_ANY || app.output_port == PW_ID_ANY)
        return;
    char source[32], target[32];
    snprintf(source, sizeof(source), "%u", app.output_port);
    snprintf(target, sizeof(target), "%u", app.input_port);
    struct pw_properties *p =
        pw_properties_new(PW_KEY_LINK_OUTPUT_PORT, source, PW_KEY_LINK_INPUT_PORT, target, NULL);
    app.link = pw_core_create_object(app.core, "link-factory", PW_TYPE_INTERFACE_Link,
                                     PW_VERSION_LINK, &p->dict, 0);
    pw_properties_free(p);
    if (!app.link)
        fail("link creation failed");
}
static const struct pw_registry_events registry_events = {PW_VERSION_REGISTRY_EVENTS,
                                                          .global = registry_global};
static const struct pw_stream_events events = {
    PW_VERSION_STREAM_EVENTS, .state_changed = state_changed, .param_changed = param_changed,
    .add_buffer = add_buffer, .remove_buffer = remove_buffer, .process = process};
static void core_error(void *data, uint32_t id, int seq, int result, const char *message) {
    (void)data;
    (void)id;
    (void)seq;
    fprintf(stderr, "PipeWire %d: %s\n", result, message);
    fail("core error");
}
static const struct pw_core_events core_events = {PW_VERSION_CORE_EVENTS, .error = core_error};
static void timer(void *data, uint64_t expirations) {
    (void)data;
    (void)expirations;
    uint64_t now = capture_now();
    for (unsigned j = 0; j < 64; j++)
        if (app.held[j].buffer && (now >= app.held[j].until || app.stop || now >= app.deadline)) {
            capture_trace("release", (uintptr_t)app.held[j].buffer, 0, 0, 0);
            pw_stream_queue_buffer(app.stream, app.held[j].buffer);
            app.held[j].buffer = NULL;
        }
    if (app.stop || now >= app.deadline)
        pw_main_loop_quit(app.loop);
}
static void stopped(void *data, int sig) {
    (void)data;
    (void)sig;
    app.stop = true;
}
int main(int argc, char **argv) {
    app = (struct app){.node = -1,
                       .input_port = PW_ID_ANY,
                       .output_port = PW_ID_ANY,
                       .fps = 60,
                       .wanted_buffers = 2,
                       .seconds = 10,
                       .drm_fd = -1,
                       .render_node = "/dev/dri/renderD128",
                       .directory = "."};
    for (int j = 1; j < argc; j++) {
        if (!strcmp(argv[j], "--implicit-only"))
            app.implicit_only = true;
        else if (!strcmp(argv[j], "--sparse"))
            app.sparse = true;
        else if (j + 1 < argc && !strcmp(argv[j], "--node"))
            app.node = atoi(argv[++j]);
        else if (j + 1 < argc && !strcmp(argv[j], "--fps"))
            app.fps = atoi(argv[++j]);
        else if (j + 1 < argc && !strcmp(argv[j], "--buffers"))
            app.wanted_buffers = atoi(argv[++j]);
        else if (j + 1 < argc && !strcmp(argv[j], "--hold-periods"))
            app.hold_periods = atoi(argv[++j]);
        else if (j + 1 < argc && !strcmp(argv[j], "--seconds"))
            app.seconds = atoi(argv[++j]);
        else if (j + 1 < argc && !strcmp(argv[j], "--directory"))
            app.directory = argv[++j];
        else if (j + 1 < argc && !strcmp(argv[j], "--render-node"))
            app.render_node = argv[++j];
        else if (j + 1 < argc && !strcmp(argv[j], "--transport")) {
            const char *v = argv[++j];
            app.transport = !strcmp(v, "shm") ? 1 : !strcmp(v, "dmabuf") ? 2 : 0;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[j]);
            return 2;
        }
    }
    if (app.node < 0 || app.fps < 1 || app.fps > 360 || app.wanted_buffers < 2 ||
        app.wanted_buffers > 32 || app.seconds < 1 || app.seconds > 3600 || app.hold_periods < 0 ||
        app.hold_periods > 60)
        return 2;
    bool egl = false;
    if (app.transport != 1)
        egl = init_egl();
    if (app.transport == 2 && !egl) {
        fprintf(stderr, "SKIP: EGL DMA-BUF import unavailable\n");
        return 77;
    }
    pw_init(&argc, &argv);
    app.loop = pw_main_loop_new(NULL);
    if (!app.loop)
        return 1;
    struct pw_loop *loop = pw_main_loop_get_loop(app.loop);
    app.context = pw_context_new(loop, NULL, 0);
    app.core = pw_context_connect(app.context, NULL, 0);
    if (!app.core)
        return 1;
    pw_core_add_listener(app.core, &app.core_listener, &core_events, NULL);
    app.stream = pw_stream_new(app.core, "aqueous-capture-check",
                               pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY,
                                                 "Capture", PW_KEY_MEDIA_ROLE, "Screen", NULL));
    pw_stream_add_listener(app.stream, &app.listener, &events, NULL);
    app.registry = pw_core_get_registry(app.core, PW_VERSION_REGISTRY, 0);
    pw_registry_add_listener(app.registry, &app.registry_listener, &registry_events, NULL);
    uint8_t storage[8192];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
    const struct spa_pod *params[2];
    unsigned n = 0;
    if (egl) {
        EGLuint64KHR mods[128];
        EGLBoolean external[128];
        EGLint count = 0;
        if (app.query_modifiers(app.egl, DRM_FORMAT_ARGB8888, 128, mods, external, &count) &&
            count > 0) {
            struct spa_pod_frame object, choice;
            spa_pod_builder_push_object(&builder, &object, SPA_TYPE_OBJECT_Format,
                                        SPA_PARAM_EnumFormat);
            spa_pod_builder_add(
                &builder, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
                SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
                SPA_POD_Id(SPA_VIDEO_FORMAT_BGRA), SPA_FORMAT_VIDEO_size,
                SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(640, 360), &SPA_RECTANGLE(256, 1),
                                               &SPA_RECTANGLE(8192, 8192)),
                SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(0, 1)),
                SPA_FORMAT_VIDEO_maxFramerate, SPA_POD_Fraction(&SPA_FRACTION(app.fps, 1)), 0);
            spa_pod_builder_prop(&builder, SPA_FORMAT_VIDEO_modifier,
                                 SPA_POD_PROP_FLAG_MANDATORY | SPA_POD_PROP_FLAG_DONT_FIXATE);
            spa_pod_builder_push_choice(&builder, &choice, SPA_CHOICE_Enum, 0);
            bool first = true;
            for (int j = 0; j < count; j++)
                if (!external[j]) {
                    if (first) {
                        spa_pod_builder_long(&builder, mods[j]);
                        first = false;
                    }
                    spa_pod_builder_long(&builder, mods[j]);
                }
            spa_pod_builder_pop(&builder, &choice);
            const struct spa_pod *pod = spa_pod_builder_pop(&builder, &object);
            if (!first)
                params[n++] = pod;
        }
    }
    if (app.transport != 2)
        params[n++] = spa_pod_builder_add_object(
            &builder, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType,
            SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
            SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
            SPA_POD_CHOICE_ENUM_Id(4, SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_BGRx,
                                   SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_RGBx),
            SPA_FORMAT_VIDEO_size,
            SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(640, 360), &SPA_RECTANGLE(256, 1),
                                           &SPA_RECTANGLE(8192, 8192)),
            SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(0, 1)),
            SPA_FORMAT_VIDEO_maxFramerate, SPA_POD_Fraction(&SPA_FRACTION(app.fps, 1)));
    if (!n) {
        fprintf(stderr, "SKIP: no importable modifiers\n");
        return 77;
    }
    app.deadline = capture_now() + (uint64_t)app.seconds * 1000000000;
    app.next_hold = capture_now() + 2000000000; // establish a clean baseline first
    app.timer = pw_loop_add_timer(loop, timer, NULL);
    struct timespec tick = {.tv_nsec = 1000000};
    pw_loop_update_timer(loop, app.timer, &tick, &tick, false);
    pw_loop_add_signal(loop, SIGINT, stopped, NULL);
    pw_loop_add_signal(loop, SIGTERM, stopped, NULL);
    if (pw_stream_connect(app.stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                          PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_NO_CONVERT, params, n) < 0)
        return 1;
    pw_main_loop_run(app.loop);
    uint64_t tail_gap =
        app.last_frame ? capture_now() - app.last_frame : (uint64_t)app.seconds * 1000000000;
    printf("{\"tail_gap_ns\":%" PRIu64
           ",\"dmabuf_frames\":%u,\"shm_frames\":%u,\"implicit_only\":%s,\"frames\":%u,\"bad_"
           "frames\":%u,\"missing\":%u,\"mixed\":%u,\"stale\":%u,\"duplicates\":%u,\"regressions\":"
           "%u,\"metadata_bad\":%u,\"metadata_seen\":%u,\"buffers_added\":%u,\"buffers_removed\":%"
           "u,\"width\":%u,\"height\":%u,\"modifier\":%" PRIu64 ",\"max_gap_ns\":%" PRIu64
           ",\"read_ns\":%" PRIu64 ",\"failed\":%s}\n",
           tail_gap, app.dmabuf_frames, app.shm_frames, app.implicit_only ? "true" : "false",
           app.frames, app.bad, app.missing, app.mixed, app.stale, app.duplicates, app.regressions,
           app.metadata_bad, app.metadata_seen, app.additions, app.removals, app.format.size.width,
           app.format.size.height, app.format.modifier, app.max_gap, app.reads_ns,
           app.failed ? "true" : "false");
    if (app.link)
        pw_proxy_destroy(app.link);
    pw_proxy_destroy((struct pw_proxy *)app.registry);
    pw_stream_destroy(app.stream);
    pw_core_disconnect(app.core);
    pw_context_destroy(app.context);
    pw_main_loop_destroy(app.loop);
    free(app.pixels);
    free(app.reference);
    if (egl) {
        eglMakeCurrent(app.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(app.egl, app.egl_surface);
        eglDestroyContext(app.egl, app.egl_context);
        eglTerminate(app.egl);
    }
    if (app.gbm)
        gbm_device_destroy(app.gbm);
    if (app.drm_fd >= 0)
        close(app.drm_fd);
    return app.failed || !app.frames                        ? 1
           : tail_gap > 500000000                           ? 4
           : app.bad || app.metadata_bad || app.regressions ? 3
                                                            : 0;
}
