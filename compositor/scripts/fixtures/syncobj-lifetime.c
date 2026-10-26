// Real descriptor/heap lifetimes, controlled DRM availability and completion.
#define WLR_PRIVATE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <setjmp.h>
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
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/util/log.h>
#include "render/drm_syncobj_merger.h"

static bool available = true, fail_export, fail_merge, fail_import, fail_waiter;
static bool fail_check, fail_alloc, fail_signal, expect_fatal;
static unsigned waiters_len, signals, imports, waits, polls, fatal_count;
static unsigned expected_dependencies, complete_dependencies, fd_dependencies[64];
static bool fd_owned[64];
static int wait_result, poll_result = 1, poll_bits = POLLIN;
static bool interrupt_once;
static int64_t now_msec;
static jmp_buf fatal_jump;
static struct wlr_output sampled_output;
static struct wlr_linux_drm_syncobj_surface_v1_state sampled_state;
static struct wlr_output *get_surface_frame_pacing_output(struct wlr_surface *s) {
    return &sampled_output;
}
void wlr_presentation_surface_scanned_out_on_output(struct wlr_surface *s, struct wlr_output *o) {}
void wlr_presentation_surface_textured_on_output(struct wlr_surface *s, struct wlr_output *o) {}
struct wlr_linux_drm_syncobj_surface_v1_state *wlr_linux_drm_syncobj_v1_get_surface_state(struct wlr_surface *s) {
    return &sampled_state;
}
static struct wlr_drm_syncobj_timeline_waiter *waiters[16];
static int fd_count(void) {
    int count = 0;
    for (int fd = 0; fd < 64; fd++) count += fcntl(fd, F_GETFD) >= 0;
    return count;
}
static int new_fd(void) {
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    assert(fd >= 0);
    assert(fd < 64 && !fd_owned[fd]);
    fd_owned[fd] = true;
    fd_dependencies[fd] = 0;
    return fd;
}
static int mock_close(int fd) {
    assert(fd >= 0 && fd < 64 && fd_owned[fd]);
    fd_owned[fd] = false;
    return close(fd);
}
static int64_t get_current_time_msec(void) { return now_msec; }
static void *mock_calloc(size_t n, size_t size) {
    if (fail_alloc) return NULL;
    return calloc(n, size);
}
static _Noreturn void mock_abort(void) {
    assert(expect_fatal);
    fatal_count++;
    longjmp(fatal_jump, 1);
}
int drmSyncobjTimelineWait(int fd, uint32_t *handles, uint64_t *points,
        unsigned count, int64_t deadline, unsigned flags, uint32_t *first) {
    assert(count == 1 && points[0] > 0);
    assert(flags == DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT);
    assert(deadline > now_msec * 1000000 && deadline <= (now_msec + 1000) * 1000000);
    waits++;
    if (interrupt_once || wait_result == -EINTR) {
        interrupt_once = false;
        now_msec += 600;
        return -EINTR;
    }
    if (wait_result == 0) complete_dependencies |= 1u << handles[0];
    return wait_result;
}
static int mock_poll(struct pollfd *fds, nfds_t count, int timeout) {
    assert(count == 1 && timeout > 0 && timeout <= 1000 && fd_owned[fds[0].fd]);
    polls++;
    if (interrupt_once || poll_result < 0) {
        interrupt_once = false;
        now_msec += 600;
        errno = EINTR;
        return -1;
    }
    fds[0].revents = poll_bits;
    if (poll_result > 0 && poll_bits == POLLIN)
        complete_dependencies |= fd_dependencies[fds[0].fd];
    return poll_result;
}
struct wlr_drm_syncobj_timeline *wlr_drm_syncobj_timeline_ref(struct wlr_drm_syncobj_timeline *t) {
    assert(t->n_refs > 0); t->n_refs++; return t;
}
void wlr_drm_syncobj_timeline_unref(struct wlr_drm_syncobj_timeline *t) {
    if (t) { assert(t->n_refs > 1); t->n_refs--; }
}
int wlr_drm_syncobj_timeline_export_sync_file(struct wlr_drm_syncobj_timeline *t, uint64_t p) {
    if (fail_export) return -1;
    int fd = new_fd();
    fd_dependencies[fd] = 1u << t->handle;
    return fd;
}
bool wlr_drm_syncobj_timeline_import_sync_file(struct wlr_drm_syncobj_timeline *t, uint64_t p, int fd) {
    assert(fd >= 0 && fd_owned[fd]); imports++;
    // An imported release fence must cover every input still in flight.
    assert(!(expected_dependencies & ~complete_dependencies & ~fd_dependencies[fd]));
    return !fail_import;
}
bool wlr_drm_syncobj_timeline_signal(struct wlr_drm_syncobj_timeline *t, uint64_t p) {
    assert(!(expected_dependencies & ~complete_dependencies));
    if (fail_signal) return false;
    signals++; return true;
}
bool wlr_drm_syncobj_timeline_check(struct wlr_drm_syncobj_timeline *t, uint64_t p, uint32_t flags, bool *result) {
    assert(flags == DRM_SYNCOBJ_WAIT_FLAGS_WAIT_AVAILABLE);
    *result = available; return !fail_check;
}
int ioctl(int fd, unsigned long request, ...) {
    assert(request == SYNC_IOC_MERGE && fcntl(fd, F_GETFD) >= 0);
    va_list args; va_start(args, request);
    struct sync_merge_data *merge = va_arg(args, struct sync_merge_data *);
    va_end(args);
    if (fail_merge || merge->fd2 < 0) { errno = EINVAL; return -1; }
    assert(fcntl(merge->fd2, F_GETFD) >= 0);
    merge->fence = new_fd();
    fd_dependencies[merge->fence] = fd_dependencies[fd] | fd_dependencies[merge->fd2];
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
    fd_owned[w->ev_fd] = true;
    waiters[waiters_len++] = w;
    return true;
}
void wlr_drm_syncobj_timeline_waiter_finish(struct wlr_drm_syncobj_timeline_waiter *w) {
    assert(mock_close(w->ev_fd) == 0);
}
#define close mock_close
#define calloc mock_calloc
#define abort mock_abort
#define poll mock_poll
#include "syncobj-functions.h"
#undef close
#undef calloc
#undef abort
#undef poll

static void reset_faults(void) {
    available = true;
    fail_export = fail_merge = fail_import = fail_waiter = false;
    fail_check = fail_alloc = fail_signal = expect_fatal = interrupt_once = false;
    wait_result = 0;
    poll_result = 1;
    poll_bits = POLLIN;
    waits = polls = signals = imports = fatal_count = 0;
    expected_dependencies = complete_dependencies = 0;
    now_msec = 0;
}

// A fatal production path never returns. Tests intercept it to assert that no
// release escaped, then discard fixture memory as process teardown would.
static void discard_fatal_merger(struct wlr_drm_syncobj_merger *m) {
    if (m->sync_fd >= 0 && fd_owned[m->sync_fd]) mock_close(m->sync_fd);
    wlr_drm_syncobj_timeline_unref(m->dst_timeline);
    free(m);
}

int main(void) {
    struct rlimit limit = {64, 64};
    assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    wlr_log_init(WLR_SILENT, NULL);
    int baseline = fd_count();
    struct wlr_drm_syncobj_timeline dst = {.n_refs = 1}, src[2] = {
        {.n_refs = 1, .handle = 1}, {.n_refs = 1, .handle = 2}};
    struct wlr_linux_drm_syncobj_surface_v1 surface = {0};
    struct wl_event_loop *loop = (void *)&surface;
    for (unsigned frame = 0; frame < 6000; frame++) {
        expected_dependencies = (1u << 1) | (1u << 2);
        complete_dependencies = 0;
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
    assert(waits == 0 && polls == 0); // healthy merging stays asynchronous
    // Export/merge failure keeps the earlier, still-pending dependency. Only
    // the new dependency is omitted, after a bounded wait proves completion.
    for (unsigned fault = 0; fault < 2; fault++) {
        reset_faults();
        expected_dependencies = (1u << 1) | (1u << 2);
        struct wlr_drm_syncobj_merger *m = wlr_drm_syncobj_merger_create(&dst, 1);
        assert(wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
        int old_fd = m->sync_fd;
        fail_export = fault == 0; fail_merge = fault == 1;
        assert(wlr_drm_syncobj_merger_add(m, &src[1], 1, loop));
        assert(m->sync_fd == old_fd && fd_owned[old_fd]);
        assert(waits == 1 && complete_dependencies == (1u << 2) && signals == 0);
        wlr_drm_syncobj_merger_unref(m);
        assert(imports == 1 && signals == 0);
        assert(fd_count() == baseline && dst.n_refs == 1);
    }
    // The same fault before any earlier fence must not signal without a wait.
    reset_faults();
    expected_dependencies = 1u << 1;
    fail_export = true;
    struct wlr_drm_syncobj_merger *m = wlr_drm_syncobj_merger_create(&dst, 1);
    assert(wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
    wlr_drm_syncobj_merger_unref(m);
    assert(waits == 1 && signals == 1);

    // Check/allocation/waiter failures must either establish real completion
    // or poison the merger. Retrying EINTR shares the original deadline.
    for (unsigned fault = 0; fault < 3; fault++) {
        reset_faults();
        expected_dependencies = 1u << 1;
        m = wlr_drm_syncobj_merger_create(&dst, 1);
        available = false;
        fail_check = fault == 0; fail_alloc = fault == 1; fail_waiter = fault == 2;
        interrupt_once = true;
        assert(wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
        assert(waits == 2);
        wlr_drm_syncobj_merger_unref(m);
        assert(signals == 1);
    }
    for (unsigned fault = 0; fault < 3; fault++) {
        reset_faults();
        m = wlr_drm_syncobj_merger_create(&dst, 1);
        expected_dependencies = 1u << 1;
        fail_export = true;
        wait_result = fault == 0 ? -ETIME : fault == 1 ? -EIO : -EINTR;
        assert(!wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
        assert(m->failed && waits == (fault == 2 ? 2 : 1));
        assert(!wlr_drm_syncobj_merger_add(m, &src[1], 1, loop));
        expect_fatal = true;
        if (setjmp(fatal_jump) == 0) {
            wlr_drm_syncobj_merger_unref(m);
            assert(!"failed dependencies must never publish a release");
        }
        assert(fatal_count == 1 && signals == 0 && imports == 0);
        discard_fatal_merger(m);
    }

    // Deferred export/merge failures, with or without the owning surface ref.
    for (unsigned retained = 0; retained < 2; retained++) {
        for (unsigned fatal = 0; fatal < 2; fatal++) {
            for (unsigned merge = 0; merge < 2; merge++) {
                reset_faults();
                m = wlr_drm_syncobj_merger_create(&dst, 1);
                expected_dependencies = 1u << 2;
                if (merge) {
                    expected_dependencies |= 1u << 1;
                    assert(wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
                }
                available = false;
                assert(wlr_drm_syncobj_merger_add(m, &src[1], 1, loop));
                if (!retained) wlr_drm_syncobj_merger_unref(m);
                fail_export = !merge; fail_merge = merge;
                wait_result = fatal ? -ETIME : 0;
                expect_fatal = fatal;
                struct wlr_drm_syncobj_timeline_waiter *w = waiters[--waiters_len];
                if (setjmp(fatal_jump) == 0) {
                    w->callback(w);
                    assert(!fatal);
                    if (retained) wlr_drm_syncobj_merger_unref(m);
                } else {
                    assert(fatal_count == 1 && signals == 0 && imports == 0);
                    discard_fatal_merger(m);
                }
                assert(src[1].n_refs == 1 && dst.n_refs == 1 && fd_count() == baseline);
            }
        }
    }

    // Failed final import waits for the aggregate fence, including EINTR.
    // Timeout, invalid poll, permanent EINTR or signal failure are terminal.
    for (unsigned fault = 0; fault < 6; fault++) {
        reset_faults();
        m = wlr_drm_syncobj_merger_create(&dst, 1);
        expected_dependencies = (1u << 1) | (1u << 2);
        assert(wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
        assert(wlr_drm_syncobj_merger_add(m, &src[1], 1, loop));
        fail_import = true;
        interrupt_once = fault == 1;
        if (fault == 2) poll_result = 0;
        if (fault == 3) poll_bits = POLLNVAL;
        if (fault == 4) poll_result = -1;
        if (fault == 5) fail_signal = true;
        expect_fatal = fault > 1;
        if (setjmp(fatal_jump) == 0) {
            wlr_drm_syncobj_merger_unref(m);
            assert(fault <= 1 && signals == 1 && polls == fault + 1);
        } else {
            assert(fatal_count == 1 && signals == 0 && polls >= 1 && polls <= 2);
            discard_fatal_merger(m);
        }
        assert(fd_count() == baseline && dst.n_refs == 1);
    }
    reset_faults();
    m = wlr_drm_syncobj_merger_create(&dst, 1);
    fail_signal = expect_fatal = true;
    if (setjmp(fatal_jump) == 0) {
        wlr_drm_syncobj_merger_unref(m);
        assert(!"even an empty merger must report failed signal publication");
    }
    assert(fatal_count == 1 && signals == 0);
    discard_fatal_merger(m);

    // Exercise propagation through the public state helper and scene callback.
    reset_faults();
    m = wlr_drm_syncobj_merger_create(&dst, 1);
    sampled_state.release_merger = m;
    sampled_output.event_loop = loop;
    struct wlr_scene_output scene_output = {.output = &sampled_output};
    struct wlr_scene_surface scene_surface = {0};
    struct wlr_scene_output_sample_event sample_event = {
        .output = &scene_output, .release_timeline = &src[0], .release_point = 1};
    expected_dependencies = 1u << 1;
    fail_export = true;
    wait_result = -ETIME;
    expect_fatal = true;
    if (setjmp(fatal_jump) == 0) {
        handle_scene_buffer_output_sample(&scene_surface.output_sample, &sample_event);
        assert(!"scene must propagate an unresolved release dependency");
    }
    assert(m->failed && fatal_count == 1 && signals == 0 && imports == 0);
    discard_fatal_merger(m);
    sampled_state.release_merger = NULL;

    // A failed waiter setup frees its heap record, even when recovery succeeds.
    reset_faults();
    available = false; fail_waiter = true;
    for (unsigned i = 0; i < 1000; i++) {
        struct wlr_drm_syncobj_merger *m = wlr_drm_syncobj_merger_create(&dst, 1);
        assert(wlr_drm_syncobj_merger_add(m, &src[0], 1, loop));
        wlr_drm_syncobj_merger_unref(m);
    }
    assert(fd_count() == baseline && dst.n_refs == 1);
    printf("PASS: 6000 two-output releases; dependency-preserving export/merge recovery, deferred failures, publication failure, bounded EINTR/timeouts, no early release; RLIMIT_NOFILE=64 baseline=%d\n", baseline);
}
