// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <linux/input-event-codes.h>
#include <libevdev/libevdev.h>
#include <libinput.h>

#ifdef RIVER_VULKAN_EFFECTS
#include <vulkan/vulkan_core.h>
#include <wlr/render/vulkan.h>
#include <wlr/types/wlr_scene.h>
#if !defined(WLR_AQUEOUS_RENDER_HOOK_VERSION) || WLR_AQUEOUS_RENDER_HOOK_VERSION != 5
#error "Vulkan effects require the pinned Aqueous wlroots render hook"
#endif
#endif
