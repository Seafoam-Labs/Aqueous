// SPDX-License-Identifier: MIT
#include <assert.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include <xf86drm.h>

struct wlr_backend { int fd; };
struct wlr_vk_instance {
    size_t refs;
    VkInstance instance;
    VkDebugUtilsMessengerEXT messenger;
    struct { PFN_vkDestroyDebugUtilsMessengerEXT destroyDebugUtilsMessengerEXT; } api;
};
struct wlr_vk_device {
    struct wlr_vk_instance *instance;
    VkPhysicalDevice phdev;
    int drm_fd;
};
struct wlr_renderer {
    struct wlr_vk_device *dev;
    struct { bool timeline; } features;
};
struct wlr_vk_renderer_candidates;
static unsigned live_instances, live_devices, device_fail, renderer_fail;
static bool inaccessible_first, enumerate_fail;
static int open_fds;
#define WLR_ERROR 0
#define WLR_INFO 1
#define wlr_log(...) ((void)0)
#define wlr_log_errno(...) ((void)0)
static bool env_parse_bool(const char *name) { return getenv(name) && strcmp(getenv(name), "1") == 0; }
static int wlr_backend_get_drm_fd(struct wlr_backend *b) { return b->fd; }
static int fake_open(const char *path, int flags) {
    if (!strcmp(path, "/explicit-a") || (!strcmp(path, "/a") && !inaccessible_first)) { open_fds++; return 128; }
    if (!strcmp(path, "/explicit-b") || !strcmp(path, "/b")) { open_fds++; return 129; }
    return -1;
}
static int fake_close(int fd) { assert(fd >= 128); open_fds--; return 0; }
static int fake_fstat(int fd, struct stat *st) { st->st_rdev = makedev(226, fd); return 0; }
static int fake_drmGetNodeTypeFromFd(int fd) { return DRM_NODE_RENDER; }
static int fake_drmGetDevices2(uint32_t flags, drmDevicePtr *devices, int max) {
    if (!devices) return 2;
    static char *nodes[2][DRM_NODE_MAX] = { { [DRM_NODE_RENDER] = "/a" }, { [DRM_NODE_RENDER] = "/b" } };
    for (int i = 0; i < 2; i++) {
        devices[i] = calloc(1, sizeof(*devices[i]));
        devices[i]->available_nodes = 1 << DRM_NODE_RENDER;
        devices[i]->nodes = nodes[i];
    }
    return 2;
}
static void fake_drmFreeDevices(drmDevicePtr *devices, int count) { for (int i = 0; i < count; i++) free(devices[i]); }
#define open fake_open
#define close fake_close
#define fstat fake_fstat
#define drmGetNodeTypeFromFd fake_drmGetNodeTypeFromFd
#define drmGetDevices2 fake_drmGetDevices2
#define drmFreeDevices fake_drmFreeDevices

static struct wlr_vk_instance *vulkan_instance_create(bool debug) {
    struct wlr_vk_instance *ini = calloc(1, sizeof(*ini));
    ini->refs = 1; ini->instance = (VkInstance)ini; live_instances++; return ini;
}
void vkDestroyInstance(VkInstance ini, const VkAllocationCallbacks *alloc) { live_instances--; }
VkResult vkEnumeratePhysicalDevices(VkInstance ini, uint32_t *count, VkPhysicalDevice *devices) {
    if (enumerate_fail) return VK_ERROR_INITIALIZATION_FAILED;
    *count = 6;
    if (devices) for (uintptr_t i = 1; i <= 6; i++) devices[i - 1] = (VkPhysicalDevice)i;
    return VK_SUCCESS;
}
void vkGetPhysicalDeviceProperties(VkPhysicalDevice phdev, VkPhysicalDeviceProperties *props) {
    uintptr_t id = (uintptr_t)phdev;
    *props = (VkPhysicalDeviceProperties){
        .apiVersion = id == 5 ? VK_API_VERSION_1_0 : VK_API_VERSION_1_1,
        .deviceType = id == 1 ? VK_PHYSICAL_DEVICE_TYPE_CPU : id == 3 ?
            VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU : VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU,
    };
}
static bool phdev_drm_props(VkPhysicalDevice phdev, VkPhysicalDeviceDrmPropertiesEXT *props) {
    uintptr_t id = (uintptr_t)phdev;
    if (id == 1 || id == 6) return false;
    *props = (VkPhysicalDeviceDrmPropertiesEXT){ .hasRender = true, .renderMajor = 226,
        .renderMinor = (id == 3 || id == 4) ? 128 : 129 };
    return true;
}
static int vulkan_open_phdev_drm_fd(VkPhysicalDevice phdev) { return -1; }
static struct wlr_vk_device *vulkan_device_create(struct wlr_vk_instance *ini, VkPhysicalDevice phdev) {
    if (device_fail & (1u << (uintptr_t)phdev)) return NULL;
    struct wlr_vk_device *dev = calloc(1, sizeof(*dev));
    dev->instance = ini; dev->phdev = phdev; live_devices++; return dev;
}
static void vulkan_instance_destroy(struct wlr_vk_instance *ini);
static struct wlr_renderer *vulkan_renderer_create_for_device(struct wlr_vk_device *dev) {
    if (renderer_fail & (1u << (uintptr_t)dev->phdev)) {
        vulkan_instance_destroy(dev->instance); free(dev); live_devices--; return NULL;
    }
    struct wlr_renderer *r = calloc(1, sizeof(*r)); r->dev = dev; r->features.timeline = true; return r;
}
static void destroy_renderer(struct wlr_renderer *r) {
    vulkan_instance_destroy(r->dev->instance); free(r->dev); free(r); live_devices--;
}
void wlr_vk_renderer_candidates_destroy(struct wlr_vk_renderer_candidates *candidates);
#include "selection-functions.h"

static void check(struct wlr_backend *backend, bool software, const unsigned *expected, size_t count) {
    struct wlr_vk_renderer_candidates *c = wlr_vk_renderer_candidates_create(backend, software);
    assert(c && c->len <= 6);
    for (size_t i = 0; i < count; i++) {
        struct wlr_renderer *r = wlr_vk_renderer_candidates_next(c);
        assert(r && (uintptr_t)r->dev->phdev == expected[i]);
        assert(r->features.timeline == !env_parse_bool("WLR_RENDER_NO_EXPLICIT_SYNC"));
        destroy_renderer(r);
    }
    assert(!wlr_vk_renderer_candidates_next(c));
    assert(!wlr_vk_renderer_candidates_next(c));
    wlr_vk_renderer_candidates_destroy(c);
    assert(live_devices == 0 && live_instances == 0 && open_fds == 0);
}
#define CHECK(software, ...) do { unsigned ids[] = {__VA_ARGS__}; check(&backend, software, ids, sizeof(ids)/sizeof(*ids)); } while (0)
int main(void) {
    unsetenv("WLR_RENDER_DRM_DEVICE"); unsetenv("WLR_RENDERER_FORCE_SOFTWARE"); unsetenv("WLR_RENDER_NO_EXPLICIT_SYNC");
    struct wlr_backend backend = { .fd = -1 };
    CHECK(true, 3, 4, 2, 6, 1); // Preferred GPU, alternate ICD, other GPUs, CPU last.
    CHECK(false, 3, 4, 2, 6);
    inaccessible_first = true; CHECK(true, 2, 3, 4, 6, 1); inaccessible_first = false;
    backend.fd = 129; CHECK(true, 2, 3, 4, 6, 1); backend.fd = -1;
    device_fail = 1u << 3; renderer_fail = 1u << 4; CHECK(true, 2, 6, 1);
    device_fail = 0x7c; renderer_fail = 0; CHECK(true, 1); CHECK(false); device_fail = 0;
    setenv("WLR_RENDER_DRM_DEVICE", "/explicit-a", 1); CHECK(true, 3, 4);
    device_fail = (1u << 3) | (1u << 4); CHECK(true); device_fail = 0;
    setenv("WLR_RENDER_DRM_DEVICE", "/explicit-b", 1); CHECK(true, 2);
    setenv("WLR_RENDER_DRM_DEVICE", "/missing", 1); assert(!wlr_vk_renderer_candidates_create(&backend, true));
    unsetenv("WLR_RENDER_DRM_DEVICE");
    setenv("WLR_RENDERER_FORCE_SOFTWARE", "1", 1); CHECK(true, 1); CHECK(false);
    unsetenv("WLR_RENDERER_FORCE_SOFTWARE");
    setenv("WLR_RENDER_NO_EXPLICIT_SYNC", "1", 1); CHECK(true, 3, 4, 2, 6, 1);
    unsetenv("WLR_RENDER_NO_EXPLICIT_SYNC");
    struct wlr_vk_renderer_candidates *c = wlr_vk_renderer_candidates_create(&backend, true);
    struct wlr_renderer *r = wlr_vk_renderer_candidates_next(c);
    wlr_vk_renderer_candidates_destroy(c);
    assert(r->dev->instance->refs == 1 && live_instances == 1); destroy_renderer(r);
    enumerate_fail = true; assert(!wlr_vk_renderer_candidates_create(&backend, true));
    assert(live_instances == 0 && live_devices == 0 && open_fds == 0);
    return 0;
}
