// Deterministic API failures at the actual production synchronization calls.
#include "render/color.h"
#include "render/vulkan.h"
#include "util/matrix.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <poll.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/util/log.h>

static const struct wlr_render_pass_impl render_pass_impl;
static const struct wlr_addon_interface vk_color_transform_impl;
static struct wlr_vk_renderer renderer;
static struct wlr_vk_device device;
static struct wlr_vk_texture texture;
static struct wlr_vk_render_buffer target;
static struct wlr_buffer src_buffer, dst_buffer;
static struct wlr_drm_syncobj_timeline source_timeline, dest_timeline;
static struct wl_listener lost_listener;
static unsigned export_count, import_count, publish_count, submit_count, stage_count;
static unsigned wait_count, reset_count, callback_count, signal_count, lost_count;
static unsigned fail_export, fail_import, fail_publish;
static bool fail_explicit_export, fail_export_semaphore, fail_signal, sentinel;
static VkResult wait_result, queue_result;
static unsigned next_sem;
static bool sem_live[256], sem_signaled[256];
static int exported_fds[256];
static unsigned num_fds;
static bool fd_owned[4096];
static uint64_t completed;
static int poll_mode;
static jmp_buf fatal_jump;
static bool expect_fatal;
static unsigned fatal_count;

static int new_fd(void) {
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    assert(fd >= 0 && num_fds < 256);
    assert(fd < 4096 && !fd_owned[fd]);
    fd_owned[fd] = true;
    exported_fds[num_fds++] = fd;
    return fd;
}

static int mock_close(int fd) {
    assert(fd >= 0 && fd < 4096 && fd_owned[fd]);
    fd_owned[fd] = false;
    return close(fd);
}

// Preserve real file descriptor ownership: successful Vulkan import consumes it.
VKAPI_ATTR VkResult VKAPI_CALL vkCreateSemaphore(VkDevice dev, const VkSemaphoreCreateInfo *info,
                                                 const VkAllocationCallbacks *alloc,
                                                 VkSemaphore *sem) {
    assert(++next_sem < 256);
    sem_live[next_sem] = true;
    *sem = (VkSemaphore)(uintptr_t)next_sem;
    return VK_SUCCESS;
}
VKAPI_ATTR void VKAPI_CALL vkDestroySemaphore(VkDevice dev, VkSemaphore sem,
                                              const VkAllocationCallbacks *alloc) {
    if (!sem)
        return;
    unsigned n = (uintptr_t)sem;
    assert(sem_live[n]);
    // Destruction of submitted signal semaphores requires proven completion.
    assert(!sem_signaled[n] || completed >= renderer.last_submitted_point);
    sem_live[n] = sem_signaled[n] = false;
}
static VkResult import_fd(VkDevice dev, const VkImportSemaphoreFdInfoKHR *info) {
    if (++import_count == fail_import)
        return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    assert(sem_live[(uintptr_t)info->semaphore]);
    assert(mock_close(info->fd) == 0);
    return VK_SUCCESS;
}
static VkResult export_fd(VkDevice dev, const VkSemaphoreGetFdInfoKHR *info, int *fd) {
    assert(submit_count > 0);
    if (fail_export_semaphore)
        return VK_ERROR_TOO_MANY_OBJECTS;
    unsigned n = (uintptr_t)info->semaphore;
    assert(sem_signaled[n]);
    sem_signaled[n] = false;
    *fd = sentinel ? -1 : new_fd();
    return VK_SUCCESS;
}
static VkResult wait_semaphores(VkDevice dev, const VkSemaphoreWaitInfoKHR *info,
                                uint64_t timeout) {
    wait_count++;
    assert(timeout == 1000000000); // bounded error path
    assert(*info->pValues == renderer.last_submitted_point);
    if (wait_result == VK_SUCCESS)
        completed = *info->pValues;
    return wait_result;
}
VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer cb) { return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandBuffer(VkCommandBuffer cb,
                                                    VkCommandBufferResetFlags flags) {
    assert(completed >= renderer.last_submitted_point);
    reset_count++;
    return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue queue, uint32_t count,
                                             const VkSubmitInfo *info, VkFence fence) {
    stage_count++;
    assert(count == 1);
    return queue_result;
}
static VkResult queue_submit(VkQueue queue, uint32_t count, const VkSubmitInfo2KHR *info,
                             VkFence fence) {
    submit_count++;
    assert(count == 2);
    // Required waits must precede ownership transitions, not just the draw batch.
    assert(info[0].waitSemaphoreInfoCount >= 1);
    assert(info[1].waitSemaphoreInfoCount == 0);
    for (unsigned i = 0; i < info[0].waitSemaphoreInfoCount; i++)
        assert(info[0].pWaitSemaphoreInfos[i].stageMask ==
               VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT_KHR);
    for (unsigned b = 0; b < 2; b++) {
        for (unsigned i = 0; i < info[b].signalSemaphoreInfoCount; i++) {
            const VkSemaphoreSubmitInfoKHR *sig = &info[b].pSignalSemaphoreInfos[i];
            assert(sig->stageMask == VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT_KHR);
            if (sig->semaphore != renderer.timeline_semaphore && queue_result == VK_SUCCESS) {
                unsigned n = (uintptr_t)sig->semaphore;
                assert(sem_live[n] && !sem_signaled[n]);
                sem_signaled[n] = true;
            }
        }
    }
    return queue_result;
}
static int mock_export_sync_file(int fd, uint32_t flags) {
    if (++export_count == fail_export)
        return -1;
    return new_fd();
}
static bool mock_import_sync_file(int fd, uint32_t flags, int sync_fd) {
    assert(fcntl(sync_fd, F_GETFD) >= 0);
    return ++publish_count != fail_publish;
}
static int mock_poll(struct pollfd *fds, nfds_t n, int timeout) {
    assert(timeout == 1000 && n == 1);
    fds[0].revents = poll_mode == 1 ? fds[0].events : POLLNVAL;
    return poll_mode == 0 ? 0 : 1;
}
static bool mock_get_dmabuf(struct wlr_buffer *buffer, struct wlr_dmabuf_attributes *attr) {
    assert(buffer == &src_buffer || buffer == &dst_buffer);
    attr->n_planes = 2;
    attr->fd[0] = 1000;
    attr->fd[1] = 1001;
    return true;
}
static struct wlr_buffer *mock_lock(struct wlr_buffer *buffer) {
    buffer->n_locks++;
    return buffer;
}
static void mock_unlock(struct wlr_buffer *buffer) {
    if (!buffer)
        return;
    assert(buffer->n_locks > 0);
    buffer->n_locks--;
}
static int mock_timeline_export(struct wlr_drm_syncobj_timeline *tl, uint64_t point) {
    return fail_explicit_export ? -1 : new_fd();
}
static bool mock_timeline_import(struct wlr_drm_syncobj_timeline *tl, uint64_t point, int fd) {
    assert(fcntl(fd, F_GETFD) >= 0);
    return ++publish_count != fail_publish;
}
static bool mock_signal(struct wlr_drm_syncobj_timeline *tl, uint64_t point) {
    assert(sentinel || completed >= renderer.last_submitted_point);
    signal_count++;
    return !fail_signal;
}
static void mock_unref(struct wlr_drm_syncobj_timeline *tl) {}
static void mock_texture_destroy(struct wlr_texture *tex) {}
static int64_t get_current_time_msec(void) { return 0; }
const char *vulkan_strerror(VkResult result) { return "injected failure"; }
VkCommandBuffer vulkan_record_stage_cb(struct wlr_vk_renderer *r) {
    r->stage.cb = &r->command_buffers[1];
    r->stage.cb->recording = true;
    return r->stage.cb->vk;
}

static _Noreturn void mock_abort(void) {
    assert(expect_fatal);
    fatal_count++;
    longjmp(fatal_jump, 1);
}
#define abort mock_abort
#define close mock_close
#define dmabuf_export_sync_file mock_export_sync_file
#define dmabuf_import_sync_file mock_import_sync_file
#define poll mock_poll
#define wlr_buffer_get_dmabuf mock_get_dmabuf
#define wlr_buffer_lock mock_lock
#define wlr_buffer_unlock mock_unlock
#define wlr_drm_syncobj_timeline_export_sync_file mock_timeline_export
#define wlr_drm_syncobj_timeline_import_sync_file mock_timeline_import
#define wlr_drm_syncobj_timeline_signal mock_signal
#define wlr_drm_syncobj_timeline_unref mock_unref
#define wlr_texture_destroy mock_texture_destroy
#include "sync-command-stubs.h"
#include "sync-functions.h"

static void callback(void *data) {
    assert(completed >= renderer.last_submitted_point);
    callback_count++;
}
static void on_lost(struct wl_listener *listener, void *data) { lost_count++; }
static void init_cb(struct wlr_vk_command_buffer *cb, unsigned index) {
    *cb = (struct wlr_vk_command_buffer){.vk = (VkCommandBuffer)(uintptr_t)(index + 1)};
    wl_list_init(&cb->completion_callbacks);
    wl_list_init(&cb->destroy_textures);
    wl_list_init(&cb->stage_buffers);
}
static void init(void) {
    renderer =
        (struct wlr_vk_renderer){.dev = &device, .timeline_semaphore = (VkSemaphore)(uintptr_t)255};
    device = (struct wlr_vk_device){.implicit_sync_interop = true};
    device.api.vkImportSemaphoreFdKHR = import_fd;
    device.api.vkGetSemaphoreFdKHR = export_fd;
    device.api.vkWaitSemaphoresKHR = wait_semaphores;
    device.api.vkQueueSubmit2KHR = queue_submit;
    wl_list_init(&renderer.foreign_textures);
    wl_list_init(&renderer.stage.buffers);
    wl_signal_init(&renderer.wlr_renderer.events.lost);
    lost_listener = (struct wl_listener){.notify = on_lost};
    wl_signal_add(&renderer.wlr_renderer.events.lost, &lost_listener);
    for (unsigned i = 0; i < 2; i++)
        init_cb(&renderer.command_buffers[i], i);
    src_buffer = dst_buffer = (struct wlr_buffer){.width = 32, .height = 32};
    target = (struct wlr_vk_render_buffer){.renderer = &renderer, .wlr_buffer = &dst_buffer};
    texture = (struct wlr_vk_texture){.renderer = &renderer, .buffer = &src_buffer};
    export_count = import_count = publish_count = submit_count = stage_count = 0;
    wait_count = reset_count = callback_count = signal_count = lost_count = 0;
    fail_export = fail_import = fail_publish = 0;
    fail_explicit_export = fail_export_semaphore = fail_signal = sentinel = false;
    wait_result = queue_result = VK_SUCCESS;
    next_sem = num_fds = completed = 0;
    memset(sem_live, 0, sizeof(sem_live));
    memset(sem_signaled, 0, sizeof(sem_signaled));
    poll_mode = 1;
    expect_fatal = false;
    fatal_count = 0;
}
static struct wlr_vk_render_pass *new_pass(bool explicit_source, bool explicit_dest) {
    struct wlr_vk_render_pass *pass = calloc(1, sizeof(*pass));
    pass->base.impl = &render_pass_impl;
    pass->renderer = &renderer;
    pass->render_buffer = &target;
    pass->render_buffer_out = &target.linear.out;
    pass->command_buffer = &renderer.command_buffers[0];
    pass->command_buffer->recording = true;
    pass->command_buffer->submitted = false;
    pass->transition_dummy = !renderer.dummy3d_image_transitioned;
    pass->signal_timeline = explicit_dest ? &dest_timeline : NULL;
    pass->signal_point = 10;
    rect_union_init(&pass->updated_region);
    struct wlr_vk_render_pass_texture *pt = wl_array_add(&pass->textures, sizeof(*pt));
    *pt = (struct wlr_vk_render_pass_texture){.texture = &texture,
                                              .buffer = mock_lock(&src_buffer),
                                              .wait_timeline =
                                                  explicit_source ? &source_timeline : NULL};
    mock_lock(&dst_buffer);
    texture.owned = true;
    wl_list_insert(&renderer.foreign_textures, &texture.foreign_link);
    struct wlr_vk_render_completion *done = calloc(1, sizeof(*done));
    done->callback = callback;
    wl_list_insert(&pass->command_buffer->completion_callbacks, &done->link);
    return pass;
}
static void assert_fds_closed(void) {
    for (unsigned i = 0; i < num_fds; i++) {
        errno = 0;
        assert(fcntl(exported_fds[i], F_GETFD) == -1 && errno == EBADF);
    }
    num_fds = 0;
}
static void retire(void) {
    completed = renderer.last_submitted_point;
    for (unsigned i = 0; i < 2; i++)
        release_command_buffer_resources(&renderer.command_buffers[i], &renderer, 0);
}
static void finish(void) {
    retire();
    // Simulate proven-complete teardown of quarantined passes, never early reuse.
    while (renderer.failed_passes) {
        struct wlr_vk_render_pass *p = renderer.failed_passes;
        renderer.failed_passes = p->next_failed;
        vulkan_render_pass_destroy(p);
        mock_unlock(&dst_buffer);
    }
    for (unsigned i = 0; i < 2; i++) {
        struct wlr_vk_command_buffer *cb = &renderer.command_buffers[i];
        VkSemaphore *sem;
        wl_array_for_each(sem, &cb->wait_semaphores) vkDestroySemaphore(0, *sem, NULL);
        wl_array_release(&cb->wait_semaphores);
        vkDestroySemaphore(0, cb->binary_semaphore, NULL);
    }
    assert(src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
    assert_fds_closed();
    for (unsigned i = 1; i < 255; i++)
        assert(!sem_live[i]);
}
static void recover_next_frame(void) {
    fail_export = fail_import = fail_publish = 0;
    fail_explicit_export = fail_export_semaphore = false;
    retire();
    assert(render_pass_submit(&new_pass(false, false)->base));
    assert(src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
    assert_fds_closed();
}
int main(void) {
    wlr_log_init(WLR_SILENT, NULL);
    // Each of two source and destination planes: partial exports/imports close
    // every unconsumed FD, no render batch submitted, next frame succeeds.
    for (unsigned operation = 0; operation < 2; operation++) {
        for (unsigned plane = 1; plane <= 4; plane++) {
            init();
            if (operation == 0)
                fail_export = plane;
            else
                fail_import = plane;
            assert(!render_pass_submit(&new_pass(false, true)->base));
            assert((operation == 0 ? export_count : import_count) == plane);
            assert(submit_count == 0 && callback_count == 1 && signal_count == 1);
            assert(!target.linear.out.transitioned && !renderer.dummy3d_image_transitioned);
            assert(!texture.owned && !texture.transitioned && !renderer.sync_failed);
            assert_fds_closed();
            recover_next_frame();
            finish();
        }
    }
    init();
    fail_explicit_export = true;
    renderer.stage.cb = &renderer.command_buffers[1];
    renderer.stage.cb->recording = true;
    assert(!render_pass_submit(&new_pass(true, true)->base));
    assert(stage_count == 1 && submit_count == 0 && wait_count == 1);
    assert(callback_count == 1 && signal_count == 1);
    recover_next_frame();
    finish();

    // Repeated acquire failures on a reused slot must not retain imported
    // temporary payloads or an allocated-but-never-submitted timeline point.
    init();
    for (unsigned i = 0; i < 5; i++) {
        fail_import = import_count + 2;
        assert(!render_pass_submit(&new_pass(false, true)->base));
        assert(!renderer.sync_failed && callback_count == i + 1);
        assert(renderer.command_buffers[0].timeline_point == 0);
        assert_fds_closed();
    }
    recover_next_frame();
    finish();

    // Cancellation recovery cannot manufacture completion of previous work.
    init();
    fail_explicit_export = true;
    renderer.last_submitted_point = 7;
    wait_result = VK_TIMEOUT;
    assert(!render_pass_submit(&new_pass(true, true)->base));
    assert(renderer.sync_failed && lost_count == 1 && callback_count == 0 && signal_count == 0);
    assert(src_buffer.n_locks == 1 && dst_buffer.n_locks == 1);
    finish();

    // Renderer replacement must stop the standalone upload/readback route too.
    init();
    renderer.sync_failed = true;
    renderer.stage.cb = &renderer.command_buffers[1];
    renderer.stage.cb->recording = true;
    assert(!submit_stage(&renderer));
    assert(stage_count == 0 && renderer.stage.cb != NULL);
    finish();

    // A failed queue submission must not leave a reusable timeline point or
    // execute callbacks for commands whose lifecycle is uncertain.
    init();
    queue_result = VK_ERROR_DEVICE_LOST;
    assert(!render_pass_submit(&new_pass(false, true)->base));
    assert(renderer.sync_failed && lost_count == 1 && callback_count == 0);
    assert(renderer.last_submitted_point == 0 && renderer.stage.last_timeline_point == 0);
    finish();

    // Completion export and partial publication, including explicit release.
    for (unsigned operation = 0; operation < 6; operation++) {
        init();
        if (operation == 0)
            fail_export_semaphore = true;
        else
            fail_publish = operation == 5 ? 1 : operation;
        assert(!render_pass_submit(&new_pass(false, operation == 5)->base));
        assert(submit_count == 1 && wait_count == 1 && callback_count == 0);
        assert(!renderer.sync_failed && reset_count == 0);
        assert(renderer.command_buffers[0].binary_semaphore == VK_NULL_HANDLE);
        assert(signal_count == (operation == 5));
        assert_fds_closed();
        recover_next_frame();
        finish();
    }
    // A wait timeout/device loss cannot release locks, reset commands, signal
    // a release point, invoke completion callbacks, or report a good frame.
    for (unsigned i = 0; i < 2; i++) {
        init();
        fail_export_semaphore = true;
        wait_result = i == 0 ? VK_TIMEOUT : VK_ERROR_DEVICE_LOST;
        struct wlr_vk_render_pass *p = new_pass(false, true);
        expect_fatal = true;
        if (setjmp(fatal_jump) == 0) {
            render_pass_submit(&p->base);
            assert(!"unfenced live capture must not return to its caller");
        }
        assert(fatal_count == 1 && lost_count == 0);
        assert(callback_count == 0 && reset_count == 0 && signal_count == 0);
        assert(src_buffer.n_locks == 1 && dst_buffer.n_locks == 1);
        // Test teardown after simulated device completion, not the fatal path.
        renderer.failed_passes = p;
        finish();
    }
    init();
    fail_export_semaphore = fail_signal = true;
    assert(!render_pass_submit(&new_pass(false, true)->base));
    assert(renderer.sync_failed && lost_count == 1 && signal_count == 1);
    finish();

    // Poll error bits cannot masquerade as an acquired implicit dependency.
    for (unsigned mode = 0; mode < 3; mode += 2) {
        init();
        device.implicit_sync_interop = false;
        poll_mode = mode;
        assert(!render_pass_submit(&new_pass(false, true)->base));
        assert(submit_count == 0 && callback_count == 1);
        finish();
    }
    // Valid already-signalled Vulkan sync-file sentinel; no fd=-1 DRM import.
    init();
    sentinel = true;
    assert(render_pass_submit(&new_pass(false, true)->base));
    assert(signal_count == 1 && publish_count == 0 && wait_count == 0);
    finish();
    // Healthy path stays asynchronous, repeated reuse must not resignal a
    // binary semaphore with an unconsumed signal or double-run callbacks.
    init();
    for (unsigned i = 0; i < 20; i++) {
        assert(render_pass_submit(&new_pass(false, false)->base));
        assert(wait_count == 0 && callback_count == i);
        retire();
        assert(callback_count == i + 1);
    }
    finish();
    puts("PASS: acquire/export/import/publication faults, FD/lock ownership, recovery, stage "
         "scopes, callbacks");
    return 0;
}
