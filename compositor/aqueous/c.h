// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <linux/input-event-codes.h>
#include <libevdev/libevdev.h>
#include <libinput.h>
#include <wlr/types/wlr_output_layer.h>
#include <wlr/types/wlr_scene.h>

#if !defined(WLR_AQUEOUS_OUTPUT_LAYER_PROMOTION_VERSION) || WLR_AQUEOUS_OUTPUT_LAYER_PROMOTION_VERSION != 2
#error "Aqueous requires the pinned wlroots output-layer promotion API"
#endif

struct wlr_scene_node;
void aqueous_scene_node_set_enabled(struct wlr_scene_node *node, int enabled);

#ifdef RIVER_VULKAN_EFFECTS
#include <vulkan/vulkan_core.h>
#include <wlr/render/vulkan.h>
#include <wlr/util/region.h>
#if !defined(WLR_AQUEOUS_RENDER_HOOK_VERSION) || WLR_AQUEOUS_RENDER_HOOK_VERSION != 9
#error "Vulkan effects require the pinned Aqueous wlroots render hook"
#endif
#endif
