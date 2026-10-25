// Real descriptor/heap lifetimes, controlled DRM availability and completion.
#define WLR_PRIVATE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <linux/sync_file.h>
#include <sys/ioctl.h>
#include <xf86drm.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/util/log.h>
#include "render/drm_syncobj_merger.h"

static bool available = true, fail_export, fail_merge, fail_import, fail_waiter;
static unsigned waiters_len, signals, imports;
static struct wlr_drm_syncobj_timeline_waiter *waiters[16];
static int fd_count(void) {
    int count = 0;
    for (int fd = 0; fd < 64; fd++) count += fcntl(fd, F_GETFD) >= 0;
    return count;
}
static int new_fd(void) {
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    assert(fd >= 0);
    return fd;
}
struct wlr_drm_syncobj_timeline *wlr_drm_syncobj_timeline_ref(struct wlr_drm_syncobj_timeline *t) {
    assert(t->n_refs > 0); t->n_refs++; return t;
}
void wlr_drm_syncobj_timeline_unref(struct wlr_drm_syncobj_timeline *t) {
    if (t) { assert(t->n_refs > 1); t->n_refs--; }
}
int wlr_drm_syncobj_timeline_export_sync_file(struct wlr_drm_syncobj_timeline *t, uint64_t p) {
    return fail_export ? -1 : new_fd();
}
bool wlr_drm_syncobj_timeline_import_sync_file(struct wlr_drm_syncobj_timeline *t, uint64_t p, int fd) {
    assert(fcntl(fd, F_GETFD) >= 0); imports++; return !fail_import;
}
bool wlr_drm_syncobj_timeline_signal(struct wlr_drm_syncobj_timeline *t, uint64_t p) {
    signals++; return true;
}
bool wlr_drm_syncobj_timeline_check(struct wlr_drm_syncobj_timeline *t, uint64_t p, uint32_t flags, bool *result) {
    *result = available; return true;
}
int ioctl(int fd, unsigned long request, ...) {
    assert(request == SYNC_IOC_MERGE && fcntl(fd, F_GETFD) >= 0);
    va_list args; va_start(args, request);
    struct sync_merge_data *merge = va_arg(args, struct sync_merge_data *);
    va_end(args);
    if (fail_merge || merge->fd2 < 0) { errno = EINVAL; return -1; }
    assert(fcntl(merge->fd2, F_GETFD) >= 0);
    merge->fence = new_fd();
    return 0;
}
bool wlr_drm_syncobj_timeline_waiter_init(struct wlr_drm_syncobj_timeline_waiter *w,
        struct wlr_drm_syncobj_timeline *t, uint64_t p, uint32_t flags,
        struct wl_event_loop *loop, wlr_drm_syncobj_timeline_ready_callback callback) {
    if (fail_waiter) return false;
    assert(waiters_len < 16);
    w->callback = callback;
    w->ev_fd = eventfd(0, EFD_CLOEXEC);
    assert(w->ev_fd >= 0);
    waiters[waiters_len++] = w;
    return true;
}
void wlr_drm_syncobj_timeline_waiter_finish(struct wlr_drm_syncobj_timeline_waiter *w) {
    assert(close(w->ev_fd) == 0);
}
#include "syncobj-functions.h"

int main(void) {
    struct rlimit limit = {64, 64};
    assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    wlr_log_init(WLR_SILENT, NULL);
    int baseline = fd_count();
    struct wlr_drm_syncobj_timeline dst = {.n_refs = 1}, src[2] = {{.n_refs = 1}, {.n_refs = 1}};
    struct wlr_linux_drm_syncobj_surface_v1 surface = {0};
    struct wl_event_loop *loop = (void *)&surface;
    for (unsigned frame = 0; frame < 6000; frame++) {
        // Apply a new buffer/acquire/release generation using production state
        // move/commit. Bufferless commits must preserve the retained merger.
        surface.pending = (struct wlr_linux_drm_syncobj_surface_v1_state){
            .committed = true, .acquire_timeline = wlr_drm_syncobj_timeline_ref(&src[0]),
            .release_timeline = wlr_drm_syncobj_timeline_ref(&dst), .release_point = frame + 1};
        surface_synced_move_state(&surface.current, &surface.pending);
        surface_synced_commit(&surface.synced);
        struct wlr_drm_syncobj_merger *merger = surface.current.release_merger;
        assert(merger);
        available = frame % 2 == 0;
        for (unsigned output = 0; output < 2; output++) {
            assert(wlr_drm_syncobj_merger_add(merger, &src[output], frame + 1, loop));
        }
        if (available) assert(fd_count() == baseline + 1); // one merged fence
        else assert(fd_count() == baseline + 2); // two pending eventfd waiters
        surface_synced_move_state(&surface.current, &surface.pending);
        surface_synced_commit(&surface.synced);
        assert(surface.current.release_merger == merger);
        surface.pending.committed = true; // NULL buffer attachment
        surface_synced_move_state(&surface.current, &surface.pending);
        surface_synced_commit(&surface.synced);
        assert(!surface.current.release_merger);
        // Detach may release the surface ref, but deferred output dependencies
        // still own the merger until availability callbacks arrive.
        while (waiters_len) {
            struct wlr_drm_syncobj_timeline_waiter *w = waiters[--waiters_len];
            w->callback(w);
        }
        assert(fd_count() == baseline);
        assert(dst.n_refs == 1 && src[0].n_refs == 1 && src[1].n_refs == 1);
    }
    // Error-path FD accounting only: the merger's existing failure signalling
    // semantics are NOT qualified by this test (see the investigation report).
    for (unsigned fault = 0; fault < 3; fault++) {
        struct wlr_drm_syncobj_merger *m = wlr_drm_syncobj_merger_create(&dst, 1);
        available = true;
        assert(wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
        fail_export = fault == 0; fail_merge = fault == 1; fail_import = fault == 2;
        wlr_drm_syncobj_merger_add(m, &src[1], 1, loop);
        wlr_drm_syncobj_merger_unref(m);
        fail_export = fail_merge = fail_import = false;
        assert(fd_count() == baseline && dst.n_refs == 1);
    }
    // A failed waiter setup must free its heap record independently of FDs.
    available = false; fail_waiter = true;
    for (unsigned i = 0; i < 1000; i++) {
        struct wlr_drm_syncobj_merger *m = wlr_drm_syncobj_merger_create(&dst, 1);
        assert(!wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
        wlr_drm_syncobj_merger_unref(m);
    }
    assert(fd_count() == baseline && dst.n_refs == 1);
    printf("PASS: 6000 two-output release merges/buffer replacements/detaches, deferred callbacks, import/export/merge faults; RLIMIT_NOFILE=64 baseline=%d; waiter-allocation cleanup\n", baseline);
}
