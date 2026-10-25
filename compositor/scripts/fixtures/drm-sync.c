// Exercise production atomic preparation/commit with real FD ownership.
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/resource.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/util/log.h>
#include "backend/drm/drm.h"
#include "backend/drm/fb.h"
#include "render/color.h"

static unsigned operation, fail_operation, blobs, next_blob, exports, commits;
static bool blob_live[128], reject_commit;
static int baseline;
static bool fail(void) { return ++operation == fail_operation; }
static int fd_count(void) {
    int count = 0;
    for (int fd = 0; fd < 64; fd++) count += fcntl(fd, F_GETFD) >= 0;
    return count;
}
static bool new_blob(uint32_t *id) {
    if (fail()) return false;
    for (next_blob = 1; next_blob < 128 && blob_live[next_blob]; next_blob++) {}
    assert(next_blob < 128);
    *id = next_blob;
    blob_live[*id] = true;
    blobs++;
    return true;
}
int drmModeCreatePropertyBlob(int fd, const void *data, size_t size, uint32_t *id) {
    return new_blob(id) ? 0 : -1;
}
bool drm_legacy_crtc_set_gamma(struct wlr_drm_backend *d, struct wlr_drm_crtc *c,
        size_t n, uint16_t *lut) { return !fail(); }
int drmModeDestroyPropertyBlob(int fd, uint32_t id) {
    assert(id < 128 && blob_live[id]);
    blob_live[id] = false;
    blobs--;
    return 0;
}
int wlr_drm_syncobj_timeline_export_sync_file(struct wlr_drm_syncobj_timeline *t, uint64_t p) {
    if (fail()) return -1;
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    assert(fd >= 0);
    exports++;
    return fd;
}
static int checked_close(int fd) {
    assert(fd >= 0 && fcntl(fd, F_GETFD) >= 0);
    return close(fd);
}
void drm_color_pipeline_state_finish(struct wlr_drm_connector_state *s, bool committed) {}
struct atomic { drmModeAtomicReq *req; bool failed; };
static void atomic_begin(struct atomic *a) { *a = (struct atomic){0}; }
static void atomic_finish(struct atomic *a) {}
static void atomic_connector_add(struct atomic *a, const struct wlr_drm_connector_state *s, bool modeset) {
    if (s->wait_timeline) assert(fcntl(s->primary_in_fence_fd, F_GETFD) >= 0);
}
static bool atomic_commit(struct atomic *a, struct wlr_drm_backend *d,
        const struct wlr_drm_device_state *s, struct wlr_drm_page_flip *p, uint32_t flags) {
    commits++;
    // KMS borrows IN_FENCE_FD; it does not consume the userspace descriptor.
    for (size_t i = 0; i < s->connectors_len; i++)
        if (s->connectors[i].wait_timeline)
            assert(fcntl(s->connectors[i].primary_in_fence_fd, F_GETFD) >= 0);
    return !reject_commit;
}
bool drm_color_pipeline_reset(struct wlr_drm_connector_state *s, drmModeAtomicReq *r) { return true; }
bool drm_color_pipeline_add(struct wlr_drm_connector_state *s, drmModeAtomicReq *r,
        struct wlr_drm_plane *p, struct wlr_buffer *b) { return true; }
#define close checked_close
#include "drm-sync-functions.h"

int main(void) {
    struct rlimit limit = {64, 64};
    assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    baseline = fd_count();
    wlr_log_init(WLR_SILENT, NULL);
    struct wlr_drm_backend drm = {0};
    struct wlr_drm_syncobj_timeline timeline = {0};
    uint16_t lut[3] = {0};
    struct wlr_color_transform_lut_3x1d transform = {
        .base.type = COLOR_TRANSFORM_LUT_3X1D, .dim = 1, .lut_3x1d = lut};
    struct wlr_output_image_description hdr = {
        .primaries = WLR_COLOR_NAMED_PRIMARIES_BT2020,
        .transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ};
    struct wlr_buffer buffer = {.width = 1920, .height = 1080};
    struct wlr_drm_fb fb = {.wlr_buf = &buffer};
    struct wlr_drm_plane plane[2] = {0};
    struct wlr_drm_crtc crtc[2] = {0};
    struct wlr_drm_connector conn[2] = {0};
    struct wlr_output_state base[2] = {0};
    struct wlr_drm_connector_state state[2] = {0};
    for (unsigned i = 0; i < 2; i++) {
        plane[i].props.fb_damage_clips = 1;
        crtc[i].primary = &plane[i];
        crtc[i].props.gamma_lut = 1;
        crtc[i].own_mode_id = true;
        conn[i].backend = &drm;
        conn[i].crtc = &crtc[i];
        conn[i].output.adaptive_sync_supported = true;
    }
    struct wlr_drm_device_state device = {.connectors = state, .connectors_len = 2, .modeset = true};
    for (unsigned frame = 0; frame < 6000; frame++) {
        operation = 0;
        // Five preparation operations per output, including HDR failure after
        // fence export, then a healthy commit. Also fail the second output.
        fail_operation = (frame + 5) % 12;
        reject_commit = frame % 13 == 0;
        bool test_only = frame % 2;
        for (unsigned i = 0; i < 2; i++) {
            base[i] = (struct wlr_output_state){
                .committed = WLR_OUTPUT_STATE_COLOR_TRANSFORM | WLR_OUTPUT_STATE_DAMAGE |
                    WLR_OUTPUT_STATE_IMAGE_DESCRIPTION,
                .image_description = &hdr, .color_transform = &transform.base,
            };
            pixman_region32_init_rect(&base[i].damage, 0, 0, buffer.width, buffer.height);
            state[i] = (struct wlr_drm_connector_state){.connector = &conn[i],
                .base = &base[i], .active = true, .primary_fb = &fb,
                .primary_in_fence_fd = -1, .wait_timeline = &timeline, .wait_point = frame + 1};
        }
        bool ok = atomic_device_commit(&drm, &device, NULL, 0, test_only);
        for (unsigned i = 0; i < 2; i++) pixman_region32_fini(&base[i].damage);
        // Damage blob allocation is deliberately best effort in production.
        bool preparation_ok = fail_operation == 0 || fail_operation == 3 ||
            fail_operation == 8 || fail_operation > 10;
        assert(ok == (preparation_ok && !reject_commit));
        assert(fd_count() == baseline);
        // Blob ownership is measured separately from descriptor ownership.
        unsigned current = 0;
        for (unsigned i = 0; i < 2; i++)
            current += !!crtc[i].mode_id + !!crtc[i].gamma_lut + !!conn[i].hdr_output_metadata;
        assert(blobs == current);
    }
    // Repeated output disable/re-enable after completed commits. A disabled
    // output has no input fence; re-enabling must allocate and release a new one.
    fail_operation = 0;
    reject_commit = false;
    for (unsigned toggle = 0; toggle < 2000; toggle++) {
        for (unsigned i = 0; i < 2; i++) {
            base[i] = (struct wlr_output_state){0};
            state[i] = (struct wlr_drm_connector_state){.connector = &conn[i],
                .base = &base[i], .active = toggle % 2, .primary_fb = &fb,
                .primary_in_fence_fd = -1, .wait_timeline = toggle % 2 ? &timeline : NULL};
        }
        assert(atomic_device_commit(&drm, &device, NULL, 0, false));
        assert(fd_count() == baseline);
    }
    for (unsigned i = 0; i < 2; i++) {
        destroy_blob(&drm, crtc[i].mode_id);
        destroy_blob(&drm, crtc[i].gamma_lut);
        destroy_blob(&drm, conn[i].hdr_output_metadata);
    }
    assert(blobs == 0 && fd_count() == baseline);
    printf("PASS: 6000 two-output atomic transactions + 2000 disable/re-enable transactions, RLIMIT_NOFILE=64, exports=%u, commits=%u, baseline=%d; zero retained FDs/blobs after teardown\n", exports, commits, baseline);
}
