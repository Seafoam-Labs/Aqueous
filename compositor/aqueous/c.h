// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <linux/input-event-codes.h>
#include <wlr/render/pass.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/wlr_texture.h>
#include <xf86drm.h>
#include <libevdev/libevdev.h>
#include <libinput.h>
#include <libudev.h>
#include <wlr/types/wlr_output_layer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_fifo_v1.h>
#include <wlr/types/wlr_xdg_dialog_v1.h>
#include <wlr/types/wlr_xdg_system_bell_v1.h>
#include <wlr/types/wlr_xdg_toplevel_drag_v1.h>
#include <wlr/types/wlr_xdg_toplevel_icon_v1.h>
#include <wlr/types/wlr_xdg_toplevel_tag_v1.h>

#if !defined(WLR_AQUEOUS_TOPLEVEL_ICON_VERSION) || WLR_AQUEOUS_TOPLEVEL_ICON_VERSION != 1
#error "Aqueous requires the pinned wlroots toplevel icon fixes"
#endif

#if !defined(WLR_AQUEOUS_FIFO_VERSION) || WLR_AQUEOUS_FIFO_VERSION != 1
#error "Aqueous requires the pinned wlroots FIFO API"
#endif

#if !defined(WLR_AQUEOUS_OUTPUT_LAYER_PROMOTION_VERSION) || WLR_AQUEOUS_OUTPUT_LAYER_PROMOTION_VERSION != 3
#error "Aqueous requires the pinned wlroots output-layer promotion API"
#endif

struct wlr_scene_node;
void aqueous_scene_node_set_enabled(struct wlr_scene_node *node, int enabled);

#ifdef RIVER_VULKAN_EFFECTS
#include <vulkan/vulkan_core.h>
#include <wlr/render/vulkan.h>
#include <wlr/util/region.h>
#if !defined(WLR_AQUEOUS_RENDER_HOOK_VERSION) || WLR_AQUEOUS_RENDER_HOOK_VERSION != 10
#error "Vulkan effects require the pinned Aqueous wlroots render hook"
#endif
#endif

#include "icon_png.h"
