// Deterministic API failures at the actual production synchronization calls.
#include "render/color.h"
#include "render/vulkan.h"
#include "util/matrix.h"
#include <assert.h>
#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <poll.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/resource.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/util/log.h>

static const struct wlr_render_pass_impl render_pass_impl;
static const struct wlr_addon_interface vk_color_transform_impl;
static struct wlr_vk_renderer renderer;
static struct wlr_vk_device device;
static unsigned active_output;
static struct wlr_vk_texture texture, other_texture;
static struct wlr_vk_render_buffer target, other_target;
static struct wlr_buffer src_buffer, dst_buffer, other_src, other_dst;
static struct wlr_drm_syncobj_timeline source_timeline, dest_timeline;
static struct wl_listener lost_listener;
static unsigned export_count, import_count, publish_count, submit_count, stage_count;
static unsigned wait_count, reset_count, callback_count, signal_count, lost_count;
static unsigned fail_export, fail_import, fail_publish;
static unsigned create_count, fail_create;
static bool fail_explicit_export, fail_export_semaphore, fail_signal, sentinel;
static VkResult wait_result, queue_result;
static unsigned wait_timeouts;
static bool device_lost, check_recovery_wait;
static unsigned next_sem;
static bool sem_live[256], sem_signaled[256];
static int sem_payload[256];
static uint64_t sem_pending[256];
static bool external_access[5];
static uint64_t expected_wait_point;
static int exported_fds[256];
static unsigned num_fds;
static bool fd_owned[4096];
static uint64_t completed;
static int poll_mode;
static jmp_buf fatal_jump;
static bool expect_fatal;
static unsigned fatal_count;
static bool copy_complete, fail_copy_map;
static unsigned char copy_source[32 * 32 * 4], copy_destination[32 * (32 * 4 + 8)];

static void complete_gpu(uint64_t point) {
    completed = point;
    for (unsigned i = 1; i < 255; i++) {
        if (sem_pending[i] && sem_pending[i] <= completed) {
            assert(sem_payload[i] >= 0 && close(sem_payload[i]) == 0);
            sem_payload[i] = -1;
            sem_pending[i] = 0;
        }
    }
}

static void lose_device(void) {
    // Vulkan's lost-device resource-lifetime guarantee, not valid pixel data.
    device_lost = true;
    complete_gpu(UINT64_MAX);
}

// Record the operations which access external images. Submission tests check
// their dependencies in execution order, independent of the number of batches.
VKAPI_ATTR void VKAPI_CALL vkCmdPipelineBarrier(VkCommandBuffer cb,
        VkPipelineStageFlags src, VkPipelineStageFlags dst, VkDependencyFlags flags,
        uint32_t memory_count, const VkMemoryBarrier *memory,
        uint32_t buffer_count, const VkBufferMemoryBarrier *buffers,
        uint32_t image_count, const VkImageMemoryBarrier *images) {
    for (unsigned i = 0; i < image_count; i++) {
        if (images[i].srcQueueFamilyIndex == VK_QUEUE_FAMILY_FOREIGN_EXT ||
                images[i].dstQueueFamilyIndex == VK_QUEUE_FAMILY_FOREIGN_EXT)
            external_access[(uintptr_t)cb] = true;
    }
}

void vulkan_copy_buffer_record(struct wlr_vk_render_buffer *buffer, VkCommandBuffer cb) {
    assert(buffer->copy_target);
}
VKAPI_ATTR VkResult VKAPI_CALL vkInvalidateMappedMemoryRanges(VkDevice dev,
        uint32_t count, const VkMappedMemoryRange *ranges) {
    assert(!device_lost);
    assert(completed >= renderer.last_submitted_point);
    return VK_SUCCESS;
}
static bool mock_begin_data(struct wlr_buffer *buffer, uint32_t flags,
        void **data, uint32_t *format, size_t *stride) {
    assert(!device_lost);
    assert(completed >= renderer.last_submitted_point);
    *data = copy_destination;
    *format = DRM_FORMAT_XRGB8888;
    *stride = 32 * 4 + 8;
    return !fail_copy_map;
}
static void mock_end_data(struct wlr_buffer *buffer) { copy_complete = true; }

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
    if (++create_count == fail_create)
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    for (next_sem = 1; next_sem < 255 && sem_live[next_sem]; next_sem++) {}
    assert(next_sem < 255);
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
    assert(!sem_pending[n] || completed >= sem_pending[n]);
    if (sem_payload[n] >= 0) {
        assert(close(sem_payload[n]) == 0);
        sem_payload[n] = -1;
    }
    sem_live[n] = sem_signaled[n] = false;
}
static VkResult import_fd(VkDevice dev, const VkImportSemaphoreFdInfoKHR *info) {
    if (++import_count == fail_import)
        return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    unsigned n = (uintptr_t)info->semaphore;
    assert(sem_live[n] && !sem_pending[n] && sem_payload[n] == -1);
    // Model a driver duplicating a successful import and retaining its payload
    // until the consuming GPU wait completes (or an unsubmitted import dies).
    sem_payload[n] = fcntl(info->fd, F_DUPFD_CLOEXEC, 0);
    assert(sem_payload[n] >= 0 && !fd_owned[sem_payload[n]]);
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
    assert(*info->pValues == (expected_wait_point ? expected_wait_point : renderer.last_submitted_point));
    if (check_recovery_wait) {
        assert(src_buffer.n_locks == 1 && dst_buffer.n_locks == 1);
        assert(callback_count == 0 && reset_count == 0 && signal_count == 0);
        assert(!copy_complete);
    }
    VkResult result = wait_timeouts ? (wait_timeouts--, VK_TIMEOUT) : wait_result;
    if (result == VK_SUCCESS)
        complete_gpu(*info->pValues);
    else if (result == VK_ERROR_DEVICE_LOST)
        lose_device();
    return result;
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
    if (queue_result == VK_ERROR_DEVICE_LOST)
        lose_device();
    return queue_result;
}
static VkResult queue_submit(VkQueue queue, uint32_t count, const VkSubmitInfo2KHR *info,
                             VkFence fence) {
    submit_count++;
    assert(count > 0);
    bool waited[256] = {0};
    for (unsigned b = 0; b < count; b++) {
        for (unsigned i = 0; i < info[b].waitSemaphoreInfoCount; i++) {
            const VkSemaphoreSubmitInfoKHR *wait = &info[b].pWaitSemaphoreInfos[i];
            assert(wait->stageMask & (VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT_KHR | VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT_KHR));
            waited[(uintptr_t)wait->semaphore] = true;
        }
        for (unsigned i = 0; i < info[b].commandBufferInfoCount; i++) {
            if (external_access[(uintptr_t)info[b].pCommandBufferInfos[i].commandBuffer]) {
                for (unsigned n = 1; n < 255; n++)
                    assert(sem_payload[n] < 0 || sem_pending[n] || waited[n]);
            }
        }
        for (unsigned i = 0; i < info[b].signalSemaphoreInfoCount; i++) {
            const VkSemaphoreSubmitInfoKHR *sig = &info[b].pSignalSemaphoreInfos[i];
            assert(sig->stageMask & (VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT_KHR | VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT_KHR));
            if (sig->semaphore != renderer.timeline_semaphore && queue_result == VK_SUCCESS) {
                unsigned n = (uintptr_t)sig->semaphore;
                assert(sem_live[n] && !sem_signaled[n]);
                sem_signaled[n] = true;
            }
        }
    }
    // Unknown submission can accept work; device loss additionally establishes
    // that the device no longer uses its resources.
    if (queue_result == VK_SUCCESS || queue_result == VK_ERROR_DEVICE_LOST ||
            queue_result == VK_ERROR_UNKNOWN) {
        for (unsigned n = 1; n < 255; n++) {
            if (waited[n]) {
                assert(sem_payload[n] >= 0 && !sem_pending[n]);
                sem_pending[n] = renderer.timeline_point;
            }
        }
    }
    if (queue_result == VK_ERROR_DEVICE_LOST)
        lose_device();
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
    assert(buffer == &src_buffer || buffer == &dst_buffer || buffer == &other_src || buffer == &other_dst);
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
#define wlr_buffer_begin_data_ptr_access mock_begin_data
#define wlr_buffer_end_data_ptr_access mock_end_data
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
    for (unsigned i = 0; i < 4; i++)
        init_cb(&renderer.command_buffers[i], i);
    src_buffer = dst_buffer = (struct wlr_buffer){.width = 32, .height = 32};
    target = (struct wlr_vk_render_buffer){.renderer = &renderer, .wlr_buffer = &dst_buffer};
    texture = (struct wlr_vk_texture){.renderer = &renderer, .buffer = &src_buffer};
    active_output = 0;
    other_src = other_dst = src_buffer;
    other_target = (struct wlr_vk_render_buffer){.renderer = &renderer, .wlr_buffer = &other_dst};
    other_texture = (struct wlr_vk_texture){.renderer = &renderer, .buffer = &other_src};
    export_count = import_count = publish_count = submit_count = stage_count = 0;
    wait_count = reset_count = callback_count = signal_count = lost_count = 0;
    fail_export = fail_import = fail_publish = 0;
    create_count = fail_create = 0;
    fail_explicit_export = fail_export_semaphore = fail_signal = sentinel = false;
    wait_result = queue_result = VK_SUCCESS;
    wait_timeouts = 0;
    device_lost = check_recovery_wait = false;
    next_sem = num_fds = completed = 0;
    expected_wait_point = 0;
    for (unsigned i = 0; i < 256; i++) sem_payload[i] = -1;
    memset(sem_pending, 0, sizeof(sem_pending));
    memset(external_access, 0, sizeof(external_access));
    memset(sem_live, 0, sizeof(sem_live));
    memset(sem_signaled, 0, sizeof(sem_signaled));
    poll_mode = 1;
    expect_fatal = false;
    fatal_count = 0;
    copy_complete = fail_copy_map = false;
    memset(copy_source, 0x71, sizeof(copy_source));
    memset(copy_destination, 0xa5, sizeof(copy_destination));
}
static struct wlr_vk_render_pass *new_pass(bool explicit_source, bool explicit_dest) {
    struct wlr_vk_texture *sample = active_output ? &other_texture : &texture;
    struct wlr_vk_render_buffer *output = active_output ? &other_target : &target;
    struct wlr_vk_render_pass *pass = calloc(1, sizeof(*pass));
    pass->base.impl = &render_pass_impl;
    pass->renderer = &renderer;
    pass->render_buffer = output;
    pass->render_buffer_out = &output->linear.out;
    pass->command_buffer = &renderer.command_buffers[active_output * 2];
    pass->command_buffer->recording = true;
    pass->command_buffer->submitted = false;
    pass->transition_dummy = !renderer.dummy3d_image_transitioned;
    pass->signal_timeline = explicit_dest ? &dest_timeline : NULL;
    pass->signal_point = 10;
    rect_union_init(&pass->updated_region);
    struct wlr_vk_render_pass_texture *pt = wl_array_add(&pass->textures, sizeof(*pt));
    *pt = (struct wlr_vk_render_pass_texture){.texture = sample,
                                              .buffer = mock_lock(sample->buffer),
                                              .wait_timeline =
                                                  explicit_source ? &source_timeline : NULL};
    mock_lock(output->wlr_buffer);
    sample->owned = true;
    wl_list_insert(&renderer.foreign_textures, &sample->foreign_link);
    struct wlr_vk_render_completion *done = calloc(1, sizeof(*done));
    done->callback = callback;
    wl_list_insert(&pass->command_buffer->completion_callbacks, &done->link);
    return pass;
}
static void assert_fds_closed(void) {
    for (unsigned i = 0; i < num_fds; i++) {
        // Numeric FD slots can now belong to a driver's duplicated payload.
        // Check application ownership; the independent payload census follows
        // actual GPU completion in retire()/finish().
        assert(!fd_owned[exported_fds[i]]);
    }
    num_fds = 0;
}
static void retire(void) {
    complete_gpu(renderer.last_submitted_point);
    for (unsigned i = 0; i < 4; i++)
        release_command_buffer_resources(&renderer.command_buffers[i], &renderer, 0);
}
static void finish(void) {
    // Device teardown in fatal-path tests proves even unknown work complete.
    renderer.last_submitted_point = renderer.timeline_point > renderer.last_submitted_point ?
        renderer.timeline_point : renderer.last_submitted_point;
    retire();
    // Simulate proven-complete teardown of quarantined passes, never early reuse.
    while (renderer.failed_passes) {
        struct wlr_vk_render_pass *p = renderer.failed_passes;
        renderer.failed_passes = p->next_failed;
        struct wlr_buffer *buffer = p->render_buffer->wlr_buffer;
        vulkan_render_pass_destroy(p);
        mock_unlock(buffer);
    }
    for (unsigned i = 0; i < 4; i++) {
        struct wlr_vk_command_buffer *cb = &renderer.command_buffers[i];
        VkSemaphore *sem;
        wl_array_for_each(sem, &cb->wait_semaphores) vkDestroySemaphore(0, *sem, NULL);
        wl_array_release(&cb->wait_semaphores);
        vkDestroySemaphore(0, cb->binary_semaphore, NULL);
    }
    assert(src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
    assert(other_src.n_locks == 0 && other_dst.n_locks == 0);
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
static int fd_count(void) {
    int count = 0;
    for (int fd = 0; fd < 64; fd++) count += fcntl(fd, F_GETFD) >= 0;
    return count;
}
static void stress(void) {
    int baseline = fd_count();
    init();
    for (unsigned frame = 0; frame < 6000; frame++) {
        active_output = frame % 2;
        bool explicit = frame % 3 == 0;
        unsigned fault = frame % 19;
        if (fault == 0) fail_export = export_count + 2;
        if (fault == 1) fail_import = import_count + 2;
        if (fault == 2) fail_export_semaphore = true;
        if (fault == 3) fail_publish = publish_count + 1;
        bool ok = render_pass_submit(&new_pass(explicit, explicit)->base);
        assert(ok == (fault > 3));
        fail_export = fail_import = fail_publish = 0;
        fail_export_semaphore = false;
        assert_fds_closed();
        // Complete both outputs before replacing the buffer generation or
        // simulating renderer recovery/output removal. Never drop live work.
        retire();
        assert(fd_count() == baseline);
        assert(src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
        assert(other_src.n_locks == 0 && other_dst.n_locks == 0);
        if (frame % 97 == 0) { finish(); init(); }
    }
    finish();
    assert(fd_count() == baseline);
    printf("PASS: 6000 Vulkan frames, two output buffers/command slots, RLIMIT_NOFILE=64, baseline=%d after each frame and teardown\n", baseline);
}
int main(void) {
    struct rlimit limit = {64, 64};
    assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    wlr_log_init(WLR_SILENT, NULL);
    for (unsigned explicit = 0; explicit < 2; explicit++) {
        init();
        target.copy_target = true;
        target.copy_mapping = copy_source;
        assert(render_pass_submit(&new_pass(false, explicit)->base));
        assert(copy_complete && wait_count == 1 && signal_count == explicit);
        // Non-packed destinations must retain row padding.
        for (unsigned y = 0; y < 32; y++) {
            for (unsigned x = 0; x < 136; x++)
                assert(copy_destination[y * 136 + x] == (x < 128 ? 0x71 : 0xa5));
        }
        assert(src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
        finish();
    }
    init();
    target.copy_target = true;
    target.copy_mapping = copy_source;
    fail_copy_map = true;
    assert(!render_pass_submit(&new_pass(false, true)->base));
    assert(!copy_complete && src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
    finish();

    init();
    target.copy_target = true;
    wait_result = VK_TIMEOUT;
    struct wlr_vk_render_pass *copy_pass = new_pass(false, true);
    expect_fatal = true;
    if (setjmp(fatal_jump) == 0) {
        render_pass_submit(&copy_pass->base);
        assert(!"copy timeout must not publish incomplete pixels");
    }
    assert(!copy_complete && signal_count == 0 && wait_count == 10);
    assert(src_buffer.n_locks == 1 && dst_buffer.n_locks == 1);
    renderer.failed_passes = copy_pass;
    finish();
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

    // A failed independent upload cannot leave an unsubmitted point available
    // for later waits/reuse. Unknown acceptance is terminal on this route too.
    for (unsigned fault = 0; fault < 4; fault++) {
        init();
        fail_explicit_export = true;
        renderer.stage.cb = &renderer.command_buffers[1];
        renderer.stage.cb->recording = true;
        queue_result = fault == 0 ? VK_ERROR_OUT_OF_HOST_MEMORY :
            fault == 1 ? VK_ERROR_OUT_OF_DEVICE_MEMORY :
            fault == 2 ? VK_ERROR_DEVICE_LOST : VK_ERROR_UNKNOWN;
        struct wlr_vk_render_pass *upload_pass = new_pass(true, true);
        expect_fatal = fault == 3;
        if (setjmp(fatal_jump) == 0) {
            assert(!render_pass_submit(&upload_pass->base));
            assert(fault < 3 && renderer.sync_failed && lost_count == 1);
        } else {
            assert(fatal_count == 1);
            renderer.failed_passes = upload_pass;
        }
        assert(stage_count == 1 && submit_count == 0 && wait_count == 0);
        assert(callback_count == 0 && signal_count == 0 && reset_count == 0);
        assert(renderer.last_submitted_point == 0 && renderer.stage.last_timeline_point == 0);
        assert(src_buffer.n_locks == 1 && dst_buffer.n_locks == 1);
        finish();
    }

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
    assert(wait_count == 10);
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

    // Device loss retires resource use but retains the pass for renderer
    // teardown. It is neither a cancelled submission nor a successful frame.
    init();
    queue_result = VK_ERROR_DEVICE_LOST;
    struct wlr_vk_render_pass *lost_pass = new_pass(false, true);
    assert(!render_pass_submit(&lost_pass->base));
    assert(lost_pass->submission == WLR_VK_PASS_COMPLETE);
    assert(renderer.failed_passes == lost_pass && renderer.sync_failed && lost_count == 1);
    assert(fatal_count == 0 && callback_count == 0 && signal_count == 0 && reset_count == 0);
    assert(wait_count == 0 && src_buffer.n_locks == 1 && dst_buffer.n_locks == 1);
    assert(renderer.last_submitted_point == 0 && renderer.stage.last_timeline_point == 0);
    finish();

    // Unknown acceptance remains fatal: it cannot prove resource completion.
    init();
    queue_result = VK_ERROR_UNKNOWN;
    struct wlr_vk_render_pass *unknown_pass = new_pass(false, true);
    expect_fatal = true;
    if (setjmp(fatal_jump) == 0) {
        render_pass_submit(&unknown_pass->base);
        assert(!"unknown submission must stop before returning to the caller");
    }
    assert(fatal_count == 1 && callback_count == 0 && signal_count == 0 && reset_count == 0);
    assert(src_buffer.n_locks == 1 && dst_buffer.n_locks == 1);
    assert(renderer.last_submitted_point == 0 && renderer.stage.last_timeline_point == 0);
    renderer.failed_passes = unknown_pass;
    finish();

    // OOM rejection guarantees no work was accepted. Stage recording already
    // contains ownership barriers, so retain it for safe renderer replacement.
    for (unsigned i = 0; i < 2; i++) {
        init();
        queue_result = i ? VK_ERROR_OUT_OF_HOST_MEMORY : VK_ERROR_OUT_OF_DEVICE_MEMORY;
        assert(!render_pass_submit(&new_pass(false, true)->base));
        assert(renderer.failed_passes->submission == WLR_VK_PASS_REJECTED);
        assert(renderer.sync_failed && lost_count == 1 && callback_count == 0 && signal_count == 0);
        assert(wait_count == 0 && reset_count == 0);
        finish();
    }
    for (unsigned i = 1; i <= 5; i++) {
        init();
        fail_create = i;
        assert(!render_pass_submit(&new_pass(false, true)->base));
        assert(submit_count == 0);
        assert(callback_count == (i < 5));
        assert(renderer.sync_failed == (i == 5));
        finish();
    }

    // Recovery must wait for the submitted pass, never an allocated future
    // timeline point. Completion can also already be known from a copy.
    init();
    struct wlr_vk_render_pass *recover_pass = new_pass(false, true);
    recover_pass->command_buffer->submitted = true;
    recover_pass->command_buffer->recording = false;
    recover_pass->command_buffer->timeline_point = 7;
    recover_pass->submission = WLR_VK_PASS_PENDING;
    renderer.timeline_point = 9;
    renderer.last_submitted_point = expected_wait_point = 7;
    assert(vulkan_recover_render_pass(recover_pass));
    assert(wait_count == 1 && completed == 7 && recover_pass->submission == WLR_VK_PASS_COMPLETE);
    assert(vulkan_recover_render_pass(recover_pass) && wait_count == 1);
    renderer.failed_passes = recover_pass;
    finish();

    // A completed/lost pass must not wait again or emit duplicate loss events.
    init();
    recover_pass = new_pass(false, true);
    recover_pass->submission = WLR_VK_PASS_PENDING;
    recover_pass->command_buffer->submitted = true;
    recover_pass->command_buffer->recording = false;
    recover_pass->command_buffer->timeline_point = 7;
    renderer.timeline_point = 9;
    renderer.last_submitted_point = expected_wait_point = 7;
    wait_result = VK_ERROR_DEVICE_LOST;
    assert(vulkan_recover_render_pass(recover_pass));
    assert(recover_pass->submission == WLR_VK_PASS_COMPLETE);
    assert(renderer.sync_failed && lost_count == 1 && wait_count == 1);
    assert(vulkan_recover_render_pass(recover_pass));
    assert(lost_count == 1 && wait_count == 1 && callback_count == 0);
    renderer.failed_passes = recover_pass;
    finish();

    // Immediate completion/loss and retries through the last allowed slice.
    // No release or pixel access may occur while a slice still times out.
    const unsigned timeout_sequences[] = {0, 1, 9};
    for (unsigned copy = 0; copy < 2; copy++) {
        for (unsigned lost = 0; lost < 2; lost++) {
            for (unsigned sequence = 0; sequence < 3; sequence++) {
                init();
                target.copy_target = copy;
                target.copy_mapping = copy_source;
                fail_export_semaphore = !copy;
                wait_timeouts = timeout_sequences[sequence];
                wait_result = lost ? VK_ERROR_DEVICE_LOST : VK_SUCCESS;
                check_recovery_wait = true;
                bool ok = render_pass_submit(&new_pass(false, true)->base);
                assert(ok == (copy && !lost));
                assert(wait_count == timeout_sequences[sequence] + 1);
                assert(renderer.sync_failed == (bool)lost && lost_count == lost);
                assert(copy_complete == (copy && !lost));
                assert(signal_count == 1 && callback_count == 0 && reset_count == 0);
                assert(fatal_count == 0 && renderer.failed_passes == NULL);
                assert(src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
                if (lost) {
                    for (unsigned pixel = 0; pixel < sizeof(copy_destination); pixel++)
                        assert(copy_destination[pixel] == 0xa5);
                }
                finish();
            }
        }
    }

    // Cancellation also waits on earlier submitted work, including device loss.
    for (unsigned lost = 0; lost < 2; lost++) {
        init();
        fail_explicit_export = true;
        renderer.last_submitted_point = 7;
        wait_timeouts = 9;
        wait_result = lost ? VK_ERROR_DEVICE_LOST : VK_SUCCESS;
        check_recovery_wait = true;
        assert(!render_pass_submit(&new_pass(true, true)->base));
        assert(wait_count == 10 && callback_count == 1 && signal_count == 1);
        assert(renderer.sync_failed == (bool)lost && lost_count == lost);
        assert(fatal_count == 0 && src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
        finish();
    }

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
    // Exhausted timeout and unknown wait errors cannot release locks, reset
    // commands, signal a release point, or invoke completion callbacks.
    for (unsigned i = 0; i < 2; i++) {
        init();
        fail_export_semaphore = true;
        wait_result = i == 0 ? VK_TIMEOUT : VK_ERROR_UNKNOWN;
        check_recovery_wait = true;
        struct wlr_vk_render_pass *p = new_pass(false, true);
        expect_fatal = true;
        if (setjmp(fatal_jump) == 0) {
            render_pass_submit(&p->base);
            assert(!"unfenced live capture must not return to its caller");
        }
        assert(fatal_count == 1 && lost_count == 0);
        assert(wait_count == (i == 0 ? 10 : 1));
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
        unsigned pending = 0;
        for (unsigned n = 1; n < 255; n++) pending += sem_payload[n] >= 0;
        assert(pending == 4); // all source/destination plane payloads still live
        retire();
        assert(callback_count == i + 1);
    }
    finish();
    stress();
    puts("PASS: acquire/export/import/publication faults, FD/lock ownership, recovery, stage "
         "scopes, callbacks");
    return 0;
}
