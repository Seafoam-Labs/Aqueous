// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define WLR_USE_UNSTABLE
#include "icon_png.h"
#include <drm_fourcc.h>
#include <errno.h>
#include <pixman.h>
#include <png.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <wlr/types/wlr_buffer.h>

struct aqueous_icon_png {
    pthread_t thread;
    int fd, edge;
    bool joined;
    unsigned char *pixels, *png;
    size_t size;
};

static pixman_format_code_t pixel_format(uint32_t drm) {
    switch (drm) {
    case DRM_FORMAT_ARGB8888: return PIXMAN_a8r8g8b8;
    case DRM_FORMAT_XRGB8888: return PIXMAN_x8r8g8b8;
    case DRM_FORMAT_ABGR8888: return PIXMAN_a8b8g8r8;
    case DRM_FORMAT_XBGR8888: return PIXMAN_x8b8g8r8;
    case DRM_FORMAT_RGBA8888: return PIXMAN_r8g8b8a8;
    case DRM_FORMAT_RGBX8888: return PIXMAN_r8g8b8x8;
    case DRM_FORMAT_BGRA8888: return PIXMAN_b8g8r8a8;
    case DRM_FORMAT_BGRX8888: return PIXMAN_b8g8r8x8;
    case DRM_FORMAT_RGB565: return PIXMAN_r5g6b5;
    case DRM_FORMAT_BGR565: return PIXMAN_b5g6r5;
    case DRM_FORMAT_ARGB2101010: return PIXMAN_a2r10g10b10;
    case DRM_FORMAT_XRGB2101010: return PIXMAN_x2r10g10b10;
    case DRM_FORMAT_ABGR2101010: return PIXMAN_a2b10g10r10;
    case DRM_FORMAT_XBGR2101010: return PIXMAN_x2b10g10r10;
    case DRM_FORMAT_ABGR16161616: return PIXMAN_a16b16g16r16;
    default: return 0;
    }
}

static void *encode(void *data) {
    struct aqueous_icon_png *job = data;
    // pixman produces premultiplied native ARGB; PNG requires straight RGBA.
    for (int i = 0; i < job->edge * job->edge; i++) {
        uint32_t pixel = ((uint32_t *)job->pixels)[i];
        unsigned a = pixel >> 24;
        unsigned char *p = job->pixels + 4 * i;
        for (int c = 0; c < 3; c++) {
            unsigned channel = (pixel >> (16 - 8 * c)) & 255;
            unsigned straight = a ? (channel * 255 + a / 2) / a : 0;
            p[c] = straight > 255 ? 255 : straight;
        }
        p[3] = a;
    }
    png_image image = { .version = PNG_IMAGE_VERSION, .width = job->edge,
        .height = job->edge, .format = PNG_FORMAT_RGBA };
    png_alloc_size_t bytes = 0;
    if (png_image_write_to_memory(&image, NULL, &bytes, 0, job->pixels, 0, NULL) && bytes <= 384 * 1024) {
        job->png = malloc(bytes);
        if (job->png && png_image_write_to_memory(&image, job->png, &bytes, 0, job->pixels, 0, NULL)) {
            job->size = bytes;
        }
    }
    png_image_free(&image);
    free(job->pixels);
    job->pixels = NULL;
    uint64_t done = 1;
    // The descriptor stays alive until the thread has joined.
    while (write(job->fd, &done, sizeof(done)) < 0 && errno == EINTR) {}
    return NULL;
}

struct aqueous_icon_png *aqueous_icon_png_start(struct wlr_buffer *buffer, int size) {
    if (size < 1 || size > 256) return NULL;
    void *pixels;
    uint32_t drm;
    size_t stride;
    if (!wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
            &pixels, &drm, &stride)) return NULL;
    pixman_format_code_t format = pixel_format(drm);
    pixman_image_t *src = format ? pixman_image_create_bits_no_clear(format,
        buffer->width, buffer->height, pixels, stride) : NULL;
    struct aqueous_icon_png *job = calloc(1, sizeof(*job));
    if (job) job->pixels = malloc((size_t)size * size * 4);
    pixman_image_t *dst = job && job->pixels ? pixman_image_create_bits_no_clear(
        PIXMAN_a8r8g8b8, size, size, (uint32_t *)job->pixels, size * 4) : NULL;
    bool ok = src && dst;
    if (ok) {
        pixman_transform_t transform;
        pixman_transform_init_scale(&transform,
            pixman_double_to_fixed((double)buffer->width / size),
            pixman_double_to_fixed((double)buffer->height / size));
        ok = pixman_image_set_transform(src, &transform);
        pixman_image_set_filter(src, PIXMAN_FILTER_BILINEAR, NULL, 0);
        pixman_image_set_repeat(src, PIXMAN_REPEAT_PAD);
        if (ok) pixman_image_composite32(PIXMAN_OP_SRC, src, NULL, dst, 0, 0, 0, 0, 0, 0, size, size);
    }
    if (src) pixman_image_unref(src);
    if (dst) pixman_image_unref(dst);
    wlr_buffer_end_data_ptr_access(buffer);
    if (ok) {
        job->edge = size;
        job->fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        if (job->fd >= 0) {
            if (pthread_create(&job->thread, NULL, encode, job) == 0) return job;
            close(job->fd);
        }
    }
    if (job) free(job->pixels);
    free(job);
    return NULL;
}

int aqueous_icon_png_fd(struct aqueous_icon_png *job) { return job->fd; }
const unsigned char *aqueous_icon_png_result(struct aqueous_icon_png *job, size_t *size) {
    // Called after eventfd readability; joining synchronizes the result fields.
    if (!job->joined) pthread_join(job->thread, NULL);
    job->joined = true;
    *size = job->size;
    return job->png;
}
void aqueous_icon_png_destroy(struct aqueous_icon_png *job) {
    // Also joins on cancellation, bounding shutdown to a single 256px encode.
    if (!job->joined) pthread_join(job->thread, NULL);
    job->joined = true;
    close(job->fd);
    free(job->pixels);
    free(job->png);
    free(job);
}
