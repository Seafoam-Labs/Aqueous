// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const wp = @import("wayland").server.wp;

pub const Handle = u64;

pub const StackLayer = enum { below, normal, above };

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

/// A pointer-driven tiled resize changes at most one dimension per
/// interaction. Null dimensions retain the layout's existing override state.
pub const ResizeUpdate = struct {
    width: ?i32 = null,
    height: ?i32 = null,
};

pub const Window = struct {
    handle: Handle,
    /// Toplevel parent, when the client declared this window as a transient.
    /// The policy uses this relationship to keep dialogs and file pickers out
    /// of the tiling set.
    parent: ?Handle = null,
    app_id: ?[]u8 = null,
    title: ?[]u8 = null,
    content_type: wp.ContentTypeV1.Type = .none,
    accepts_focus: bool = true,
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,
    base_width: i32 = 0,
    base_height: i32 = 0,
    width_inc: i32 = 0,
    height_inc: i32 = 0,
    min_aspect_num: i32 = 0,
    min_aspect_den: i32 = 0,
    max_aspect_num: i32 = 0,
    max_aspect_den: i32 = 0,
    /// Client's current/natural content size. Floating placement prefers this
    /// over a compositor-chosen fraction when it is usable.
    preferred_width: i32 = 0,
    preferred_height: i32 = 0,
    floating: bool = false,
    fullscreen: bool = false,
    scrolling_full_width: bool = false,
};

pub const FloatingPlacement = enum {
    cascade,
    center,
    under_pointer,
    minimal_overlap,
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
    floating_placement: FloatingPlacement = .cascade,
    floating_cascade_step: i32 = 32,
    /// Runtime pointer coordinates injected into the per-output snapshot.
    /// They are deliberately optional so layout/config tests remain pure.
    pointer_x: ?i32 = null,
    pointer_y: ?i32 = null,
    floating_move_step: i32 = 10,
    floating_move_step_coarse: i32 = 50,
    floating_resize_step: i32 = 10,
    floating_snap_gap: i32 = 0,
    floating_snap_threshold: i32 = 24,
    floating_resistance: i32 = 12,
    floating_top_edge_maximize: bool = true,
};

pub const Placement = struct {
    handle: Handle,
    geometry: Rect,
    /// Scale of the output which owns this placement. It is deliberately not
    /// part of layout arithmetic: it resolves compositor geometry onto the
    /// destination output's physical pixel grid at the rendering boundary.
    output_scale: f32 = 1,
    output_origin_x: i32 = 0,
    output_origin_y: i32 = 0,
    /// Optional rendering clip in window-local coordinates. Layouts which
    /// expose only part of a full-sized window use this to describe their
    /// viewport without changing the configured window dimensions.
    clip: ?Rect = null,
    z_order: i32,
    /// Persistent raise order within a semantic stacking band. Layout engines
    /// may leave this at zero; policy overlays populate it from window state.
    stack_order: u64 = 0,
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

pub const DropZone = enum {
    stack_before,
    stack_after,
    column_before,
    column_after,
};
