// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

pub const Handle = u64;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub const empty: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    pub fn right(rect: Rect) i32 {
        return rect.x + rect.width;
    }

    pub fn bottom(rect: Rect) i32 {
        return rect.y + rect.height;
    }
};

pub const Window = struct {
    handle: Handle,
    /// Toplevel parent, when the client declared this window as a transient.
    /// The policy uses this relationship to keep dialogs and file pickers out
    /// of the tiling set.
    parent: ?Handle = null,
    app_id: ?[]u8 = null,
    title: ?[]u8 = null,
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,
    floating: bool = false,
    fullscreen: bool = false,
};

pub const Border = struct {
    width: i32,
    focused: u32,
    normal: u32,
    urgent: u32,

    pub const none: Border = .{ .width = 0, .focused = 0, .normal = 0, .urgent = 0 };
};

pub const Options = struct {
    gaps_outer: i32 = 8,
    gaps_inner: i32 = 4,
    master_ratio: f64 = 0.55,
    master_count: u32 = 1,
    border: Border = .none,
};

pub const Placement = struct {
    handle: Handle,
    geometry: Rect,
    /// Optional rendering clip in window-local coordinates. Layouts which
    /// expose only part of a full-sized window use this to describe their
    /// viewport without changing the configured window dimensions.
    clip: ?Rect = null,
    z_order: i32,
    visible: bool,
    border: Border,
    tiled: bool = true,
    maximized: bool = false,
};

pub const Direction = enum {
    left,
    right,
    up,
    down,
    prev,
    next,
};
