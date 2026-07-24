// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <linux/input-event-codes.h>
#include <libevdev/libevdev.h>
#include <libinput.h>

// SceneFX provides an augmented scene API (rounded corners, blur, shadows).
// Only included when the build links SceneFX (see build.zig). Its headers live
// under <scenefx/...> and do not replace the wlroots <wlr/...> ones.
#ifdef RIVER_SCENEFX
#include <scenefx/types/wlr_scene.h>
#include <scenefx/render/fx_renderer/fx_renderer.h>
#endif

#ifdef RIVER_VULKAN_EFFECTS
#include <vulkan/vulkan_core.h>
#include <wlr/render/vulkan.h>
#include <wlr/types/wlr_scene.h>
#if !defined(WLR_AQUEOUS_RENDER_HOOK_VERSION) || WLR_AQUEOUS_RENDER_HOOK_VERSION != 4
#error "Vulkan effects require the pinned Aqueous wlroots render hook"
#endif
#endif
