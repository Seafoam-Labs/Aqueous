// Upstream submission/FD ownership and copy-only completion regressions.
// Error-recovery guarantees from the removed 0020 patch are not asserted.
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
static unsigned next_sem;
static bool sem_live[256], sem_signaled[256];
static int sem_payload[256];
static uint64_t sem_pending[256];
static uint64_t expected_wait_point, last_submitted_point, prior_stage_point;
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

void vulkan_copy_buffer_record(struct wlr_vk_render_buffer *buffer, VkCommandBuffer cb) {
    assert(buffer->copy_target);
}
VKAPI_ATTR VkResult VKAPI_CALL vkInvalidateMappedMemoryRanges(VkDevice dev,
        uint32_t count, const VkMappedMemoryRange *ranges) {
    assert(completed >= last_submitted_point);
    return VK_SUCCESS;
}
static bool mock_begin_data(struct wlr_buffer *buffer, uint32_t flags,
        void **data, uint32_t *format, size_t *stride) {
    assert(completed >= last_submitted_point);
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
    assert(!sem_signaled[n] || completed >= last_submitted_point);
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
    assert(*info->pValues == (expected_wait_point ? expected_wait_point : last_submitted_point));
    if (wait_result == VK_SUCCESS)
        complete_gpu(*info->pValues);
    return wait_result;
}
VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer cb) { return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandBuffer(VkCommandBuffer cb,
                                                    VkCommandBufferResetFlags flags) {
    assert(completed >= last_submitted_point);
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
    last_submitted_point = renderer.timeline_point;
    // Preserve wlroots 0.20.2's submission layout: prior uploads gate staging,
    // imported source/destination fences gate rendering. This checks baseline
    // compatibility and FD ownership; it does not simulate GPU execution scopes.
    assert(count == 2);
    assert(info[0].waitSemaphoreInfoCount == (prior_stage_point > 0));
    bool waited[256] = {0};
    for (unsigned b = 0; b < count; b++) {
        for (unsigned i = 0; i < info[b].waitSemaphoreInfoCount; i++) {
            const VkSemaphoreSubmitInfoKHR *wait = &info[b].pWaitSemaphoreInfos[i];
            assert(wait->stageMask & (VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT_KHR | VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT_KHR));
            if (wait->semaphore == renderer.timeline_semaphore) {
                assert(b == 0 && wait->value == prior_stage_point);
            } else {
                assert(b == 1 && !waited[(uintptr_t)wait->semaphore]);
            }
            waited[(uintptr_t)wait->semaphore] = true;
        }
        for (unsigned i = 0; i < info[b].signalSemaphoreInfoCount; i++) {
            const VkSemaphoreSubmitInfoKHR *sig = &info[b].pSignalSemaphoreInfos[i];
            assert(sig->stageMask == 0); // upstream 0.20.2 baseline
            if (sig->semaphore != renderer.timeline_semaphore && queue_result == VK_SUCCESS) {
                unsigned n = (uintptr_t)sig->semaphore;
                assert(sem_live[n] && !sem_signaled[n]);
                sem_signaled[n] = true;
            }
        }
    }
    for (unsigned n = 1; n < 255; n++)
        assert(sem_payload[n] < 0 || sem_pending[n] || waited[n]);
    // Device loss can accept work without reporting successful submission.
    if (queue_result == VK_SUCCESS || queue_result == VK_ERROR_DEVICE_LOST) {
        for (unsigned n = 1; n < 255; n++) {
            if (waited[n]) {
                assert(sem_payload[n] >= 0 && !sem_pending[n]);
                sem_pending[n] = renderer.timeline_point;
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
    assert(sentinel || completed >= last_submitted_point);
    signal_count++;
    return !fail_signal;
}
static void mock_unref(struct wlr_drm_syncobj_timeline *tl) {}
static void mock_texture_destroy(struct wlr_texture *tex) {}
const char *vulkan_strerror(VkResult result) { return "injected failure"; }
VkCommandBuffer vulkan_record_stage_cb(struct wlr_vk_renderer *r) {
    prior_stage_point = r->stage.last_timeline_point;
    r->stage.cb = &r->command_buffers[active_output * 2 + 1];
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
    assert(completed >= last_submitted_point);
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
    next_sem = num_fds = completed = 0;
    expected_wait_point = last_submitted_point = prior_stage_point = 0;
    for (unsigned i = 0; i < 256; i++) sem_payload[i] = -1;
    memset(sem_pending, 0, sizeof(sem_pending));
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
    pass->signal_timeline = explicit_dest ? &dest_timeline : NULL;
    pass->signal_point = 10;
    rect_union_init(&pass->updated_region);
    struct wlr_vk_render_pass_texture *pt = wl_array_add(&pass->textures, sizeof(*pt));
    *pt = (struct wlr_vk_render_pass_texture){.texture = sample,
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
    complete_gpu(last_submitted_point);
    for (unsigned i = 0; i < 4; i++)
        release_command_buffer_resources(&renderer.command_buffers[i], &renderer, 0);
}
static void finish(void) {
    // Device teardown in fatal-path tests proves even unknown work complete.
    last_submitted_point = renderer.timeline_point > last_submitted_point ?
        renderer.timeline_point : last_submitted_point;
    retire();
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
        bool explicit = (frame / 2) % 2;
        assert(render_pass_submit(&new_pass(explicit, explicit)->base));
        assert_fds_closed();
        retire();
        assert(fd_count() == baseline);
        assert(src_buffer.n_locks == 0 && dst_buffer.n_locks == 0);
        assert(other_src.n_locks == 0 && other_dst.n_locks == 0);
        if (frame % 97 == 0) { finish(); init(); }
    }
    finish();
    assert(fd_count() == baseline);
    printf("PASS: 6000 Vulkan frames, explicit/implicit sync, two output buffers/command slots, RLIMIT_NOFILE=64, baseline=%d\n", baseline);
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
        for (unsigned y = 0; y < 32; y++) {
            for (unsigned x = 0; x < 136; x++)
                assert(copy_destination[y * 136 + x] == (x < 128 ? 0x71 : 0xa5));
        }
        finish();
    }
    init();
    target.copy_target = true;
    target.copy_mapping = copy_source;
    fail_copy_map = true;
    assert(!render_pass_submit(&new_pass(false, true)->base));
    assert(!copy_complete && signal_count == 1);
    finish();

    // A copy timeout must stop before CPU access or release publication.
    init();
    target.copy_target = true;
    wait_result = VK_TIMEOUT;
    struct wlr_vk_render_pass *copy_pass = new_pass(false, true);
    expect_fatal = true;
    if (setjmp(fatal_jump) == 0) {
        render_pass_submit(&copy_pass->base);
        assert(!"copy timeout must not publish incomplete pixels");
    }
    assert(fatal_count == 1 && !copy_complete && signal_count == 0 && wait_count == 1);
    complete_gpu(last_submitted_point);
    render_pass_destroy(copy_pass);
    mock_unlock(&dst_buffer);
    finish();
    stress();
    puts("PASS: copy completion, padded readback, failed mapping and timeout isolation");
    return 0;
}
