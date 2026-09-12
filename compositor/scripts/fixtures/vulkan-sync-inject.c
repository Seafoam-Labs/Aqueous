// Private LD_PRELOAD probe. Never linked into production wlroots or Aqueous.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_renderer.h>

static PFN_vkImportSemaphoreFdKHR real_import;
static PFN_vkGetSemaphoreFdKHR real_export;
static unsigned seen;
static struct wlr_render_pass *capture_pass;
static bool in_capture_submit;
static int inject(const char *operation);

struct wlr_render_pass *
wlr_renderer_begin_buffer_pass(struct wlr_renderer *renderer, struct wlr_buffer *buffer,
                               const struct wlr_buffer_pass_options *options) {
    struct wlr_render_pass *(*begin)(struct wlr_renderer *, struct wlr_buffer *,
                                     const struct wlr_buffer_pass_options *) =
        dlsym(RTLD_NEXT, "wlr_renderer_begin_buffer_pass");
    if (!begin)
        abort();
    struct wlr_render_pass *pass = begin(renderer, buffer, options);
    // The pinned capture DMA-BUF copy calls begin_buffer_pass with NULL
    // options; scene rendering always supplies options, even without syncobj.
    capture_pass = options == NULL ? pass : NULL;
    return pass;
}
bool wlr_render_pass_submit(struct wlr_render_pass *pass) {
    bool (*submit)(struct wlr_render_pass *) = dlsym(RTLD_NEXT, "wlr_render_pass_submit");
    if (!submit)
        abort();
    in_capture_submit = pass == capture_pass;
    if (in_capture_submit)
        capture_pass = NULL;
    bool result = submit(pass);
    // Attribution control: reject an otherwise successfully synchronized copy.
    // This does not exercise a synchronization API failure.
    if (result && inject("capture-reject"))
        result = false;
    in_capture_submit = false;
    return result;
}

static int inject(const char *operation) {
    const char *selected = getenv("AQUEOUS_TEST_SYNC_FAULT");
    if (!in_capture_submit || !selected || strcmp(selected, operation) != 0)
        return 0;
    const char *after = getenv("AQUEOUS_TEST_SYNC_FAULT_AFTER");
    unsigned occurrence = after ? strtoul(after, NULL, 10) : 500;
    if (++seen != occurrence)
        return 0;
    fprintf(stderr, "AQUEOUS_SYNC_FAULT injected %s occurrence=%u\n", operation, seen);
    return 1;
}

static VkResult import_fd(VkDevice dev, const VkImportSemaphoreFdInfoKHR *info) {
    if (inject("acquire-import"))
        return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    return real_import(dev, info);
}
static VkResult export_fd(VkDevice dev, const VkSemaphoreGetFdInfoKHR *info, int *fd) {
    if (inject("completion-export"))
        return VK_ERROR_TOO_MANY_OBJECTS;
    return real_export(dev, info, fd);
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice dev, const char *name) {
    PFN_vkGetDeviceProcAddr get_proc =
        (PFN_vkGetDeviceProcAddr)dlsym(RTLD_NEXT, "vkGetDeviceProcAddr");
    if (!get_proc)
        abort();
    PFN_vkVoidFunction proc = get_proc(dev, name);
    if (proc && strcmp(name, "vkImportSemaphoreFdKHR") == 0) {
        real_import = (PFN_vkImportSemaphoreFdKHR)proc;
        return (PFN_vkVoidFunction)import_fd;
    }
    if (proc && strcmp(name, "vkGetSemaphoreFdKHR") == 0) {
        real_export = (PFN_vkGetSemaphoreFdKHR)proc;
        return (PFN_vkVoidFunction)export_fd;
    }
    return proc;
}
