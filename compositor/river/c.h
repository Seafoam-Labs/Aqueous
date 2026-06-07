// SPDX-FileCopyrightText: © 2020 The River Developers
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
