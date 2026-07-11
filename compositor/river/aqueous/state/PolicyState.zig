// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const types = @import("../layout/types.zig");

pub const Kind = enum { tiled, floating, maximized, minimized, scratchpad };

kind: Kind = .tiled,
previous: Kind = .tiled,
floating_geometry: types.Rect = .empty,
scratchpad: u64 = 0,
scratchpad_visible: bool = false,
