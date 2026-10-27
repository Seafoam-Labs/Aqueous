// Production error paths must preserve the first errno across logs and cleanup.
#define WLR_PRIVATE
#define HAVE_EVENTFD 1
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/eventfd.h>
#include <xf86drm.h>
#include <wayland-server-core.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/util/log.h>

enum fault { NONE, CREATE, TRANSFER, EXPORT, IMPORT, CHECK, SIGNAL, EVENTFD, IOCTL, ADD_FD };
static enum fault fault;
static unsigned destroys, closes;
static int waiter_fd;
static int fail(enum fault operation) {
    if (fault != operation) return 0;
    errno = EMFILE;
    return -EMFILE;
}
int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle) {
    *handle = 42;
    return fail(CREATE);
}
int drmSyncobjDestroy(int fd, uint32_t handle) {
    assert(handle == 42);
    destroys++;
    errno = EIO; // even a successful cleanup may change errno
    return 0;
}
int drmSyncobjTransfer(int fd, uint32_t dst, uint64_t dst_point,
        uint32_t src, uint64_t src_point, uint32_t flags) {
    return fail(TRANSFER);
}
int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd) {
    if (fail(EXPORT)) return -EMFILE;
    *sync_file_fd = 17;
    return 0;
}
int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd) {
    return fail(IMPORT);
}
int drmSyncobjTimelineWait(int fd, uint32_t *handles, uint64_t *points,
        unsigned count, int64_t timeout, unsigned flags, uint32_t *first) {
    return fail(CHECK);
}
int drmSyncobjTimelineSignal(int fd, const uint32_t *handles,
        uint64_t *points, uint32_t count) {
    return fail(SIGNAL);
}
int drmIoctl(int fd, unsigned long request, void *arg) { return fail(IOCTL); }
struct wl_event_source *wl_event_loop_add_fd(struct wl_event_loop *loop,
        int fd, uint32_t mask, wl_event_loop_fd_func_t func, void *data) {
    return fail(ADD_FD) ? NULL : (void *)loop;
}
static int handle_eventfd_ready(int fd, uint32_t mask, void *data) { return 0; }
static void ready(struct wlr_drm_syncobj_timeline_waiter *waiter) {}
static int mock_eventfd(unsigned init, int flags) {
    if (fail(EVENTFD)) return -1;
    waiter_fd = eventfd(init, flags);
    assert(waiter_fd >= 0);
    return waiter_fd;
}
static int mock_close(int fd) {
    assert(close(fd) == 0);
    closes++;
    errno = EBADF;
    return 0;
}
#undef wlr_log
#undef wlr_log_errno
#define wlr_log(...) ((void)(errno = EINVAL))
#define wlr_log_errno(...) ((void)(errno = EINVAL))
#define eventfd mock_eventfd
#define close mock_close
#include "syncobj-errors.h"
#undef close
#undef eventfd

int main(void) {
    struct wlr_drm_syncobj_timeline timeline = {.drm_fd = -1, .handle = 1};
    for (unsigned importing = 0; importing < 2; importing++) {
        enum fault cases[] = {CREATE, TRANSFER, importing ? IMPORT : EXPORT};
        for (unsigned i = 0; i < 3; i++) {
            fault = cases[i];
            destroys = 0;
            errno = 0;
            if (importing)
                assert(!wlr_drm_syncobj_timeline_import_sync_file(&timeline, 1, 17));
            else
                assert(wlr_drm_syncobj_timeline_export_sync_file(&timeline, 1) == -1);
            assert(errno == EMFILE);
            assert(destroys == (fault == CREATE ? 0u : 1u));
        }
    }
    bool available;
    fault = CHECK;
    assert(!wlr_drm_syncobj_timeline_check(&timeline, 1, 0, &available) && errno == EMFILE);
    fault = SIGNAL;
    assert(!wlr_drm_syncobj_timeline_signal(&timeline, 1) && errno == EMFILE);
    for (fault = EVENTFD; fault <= ADD_FD; fault++) {
        struct wlr_drm_syncobj_timeline_waiter waiter = {0};
        closes = 0;
        assert(!wlr_drm_syncobj_timeline_waiter_init(&waiter, &timeline, 1, 0, (void *)&timeline, ready));
        assert(errno == EMFILE);
        assert(closes == (fault == EVENTFD ? 0u : 1u));
        if (fault != EVENTFD) assert(fcntl(waiter_fd, F_GETFD) == -1 && errno == EBADF);
    }
    puts("PASS: original synchronization errno survives logging, syncobj destruction and FD cleanup");
}
