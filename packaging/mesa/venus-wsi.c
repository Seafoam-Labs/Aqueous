// SPDX-License-Identifier: MIT
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int VkResult;
typedef int VkAllocationCallbacks;
#define VK_SUCCESS 0
#define VK_DRIVER_ID_NVIDIA_PROPRIETARY 4
#define VN_MAKE_NVIDIA_VERSION(a,b,c,d) (((unsigned)(a)<<22)|((b)<<14)|((c)<<6)|(d))
#define WSI_DEBUG_BUFFER 1
static unsigned WSI_DEBUG;
struct wsi_device {
    bool force_buffer_blit, supports_scanout, supports_modifiers;
};
struct wsi_device_options { bool sw_device, extra_xwayland_image; };
struct wsi_drm_image_params { bool same_gpu; unsigned num_modifier_lists; };
struct properties { unsigned vendorID, drmRenderMajor, drmRenderMinor, pciDomain, pciBus; };
struct extensions { bool EXT_external_memory_dma_buf, EXT_image_drm_format_modifier,
                         EXT_physical_device_drm, EXT_pci_bus_info; };
struct instance {
    struct { struct { VkAllocationCallbacks alloc; } vk; } base;
    struct { int options; } drirc;
};
struct vn_physical_device {
    struct { struct {
        struct extensions supported_extensions;
        struct properties properties;
        VkAllocationCallbacks alloc;
        struct wsi_device *wsi_device;
    } vk; } base;
    unsigned renderer_driver_id, renderer_driver_version;
    struct instance *instance;
    struct wsi_device wsi_device;
};
static struct wsi_device_options observed;
static VkResult init_result;
static int vn_wsi_proc_addr;
static void *vn_physical_device_to_handle(struct vn_physical_device *p) { return p; }
static VkResult wsi_device_init(struct wsi_device *wsi, void *handle, int proc,
        const VkAllocationCallbacks *alloc, int fd, int *options,
        const struct wsi_device_options *policy) {
    observed = *policy;
    return init_result;
}

#include "production.h"

int main(void) {
    for (unsigned vendor = 0; vendor < 3; vendor++) {
        for (unsigned old = 0; old < 2; old++) {
            for (unsigned external = 0; external < 2; external++) {
                struct instance instance = {0};
                struct vn_physical_device dev = {
                    .instance = &instance,
                    .renderer_driver_id = vendor == 0 ? VK_DRIVER_ID_NVIDIA_PROPRIETARY : 0,
                    .renderer_driver_version = old ? 0 : VN_MAKE_NVIDIA_VERSION(590,48,1,0),
                    .base.vk.properties = {vendor == 0 ? 0x10de : vendor == 1 ? 0x1002 : 0x8086, 226, 128, 4, 7},
                    .base.vk.supported_extensions = {external, true, true, true},
                };
                struct properties props = dev.base.vk.properties;
                struct extensions extensions = dev.base.vk.supported_extensions;
                assert(vn_wsi_init(&dev) == VK_SUCCESS);
                assert(memcmp(&props, &dev.base.vk.properties, sizeof(props)) == 0);
                assert(memcmp(&extensions, &dev.base.vk.supported_extensions, sizeof(extensions)) == 0);
                assert(observed.sw_device == (!external || (vendor == 0 && old)));
                assert(observed.extra_xwayland_image);
                assert(dev.wsi_device.force_buffer_blit == (vendor == 0));
                assert(dev.base.vk.wsi_device == &dev.wsi_device);
                for (unsigned same = 0; same < 2; same++) {
                    for (unsigned modifiers = 0; modifiers < 2; modifiers++) {
                        struct wsi_drm_image_params params = {same, modifiers};
                        assert(wsi_drm_image_needs_buffer_blit(&dev.wsi_device, &params) ==
                               (vendor == 0 || !same || !modifiers));
                    }
                }
            }
        }
    }
    struct wsi_device native = {.supports_scanout = true};
    struct wsi_drm_image_params same = {.same_gpu = true};
    assert(!wsi_drm_image_needs_buffer_blit(&native, &same));
    WSI_DEBUG = WSI_DEBUG_BUFFER;
    assert(wsi_drm_image_needs_buffer_blit(&native, &same));
    struct instance instance = {0};
    struct vn_physical_device failed = {.instance = &instance};
    init_result = -1;
    assert(vn_wsi_init(&failed) == -1 && !failed.base.vk.wsi_device);
    puts("PASS: Venus identity, old-driver policy, WSI forced blit, native paths and init failure");
}
