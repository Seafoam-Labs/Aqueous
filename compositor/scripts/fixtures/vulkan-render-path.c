// SPDX-License-Identifier: GPL-3.0-only
#include <assert.h>
#include <stdio.h>
#include "render/vulkan/render_path.h"
int main(void) {
    uint32_t transforms[] = { 0, WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR,
        WLR_COLOR_TRANSFER_FUNCTION_SRGB, WLR_COLOR_TRANSFER_FUNCTION_GAMMA22,
        WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ, WLR_COLOR_TRANSFER_FUNCTION_BT1886 };
    for (unsigned i = 0; i < sizeof(transforms) / sizeof(*transforms); i++) {
        for (int srgb = 0; srgb < 2; srgb++) {
            assert(vulkan_choose_render_path(transforms[i], true, srgb) == WLR_VK_PATH_BACKDROP);
        }
    }
    assert(vulkan_choose_render_path(WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR, false, false) == WLR_VK_PATH_LINEAR);
    assert(vulkan_choose_render_path(WLR_COLOR_TRANSFER_FUNCTION_SRGB, false, true) == WLR_VK_PATH_SRGB);
    assert(vulkan_choose_render_path(WLR_COLOR_TRANSFER_FUNCTION_SRGB, false, false) == WLR_VK_PATH_COLOR_TRANSFORM);
    for (unsigned i = 3; i < sizeof(transforms) / sizeof(*transforms); i++) {
        assert(vulkan_choose_render_path(transforms[i], false, true) == WLR_VK_PATH_COLOR_TRANSFORM);
    }
    assert(vulkan_choose_render_path(0, false, true) == WLR_VK_PATH_COLOR_TRANSFORM);
    assert(!vulkan_blend_can_retire(7, 42, 42));
    assert(!vulkan_blend_can_retire(8, 42, 41));
    assert(vulkan_blend_can_retire(8, 42, 42));
    assert(vulkan_blend_can_retire(8, 0, 0));
    puts("PASS: render path requirements, color transforms and completion-gated retirement");
}
