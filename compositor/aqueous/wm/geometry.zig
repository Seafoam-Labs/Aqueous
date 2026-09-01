// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Compatibility facade for the shared freeform geometry policy.

const implementation = @import("layout/geometry.zig");

pub const ResizeEdges = implementation.ResizeEdges;
pub const Constraints = implementation.Constraints;
pub const Size = implementation.Size;
pub const SnapDirection = implementation.SnapDirection;
pub const constrainSize = implementation.constrainSize;
pub const resize = implementation.resize;
pub const keepReachable = implementation.keepReachable;
pub const snap = implementation.snap;
pub const constrainSnap = implementation.constrainSnap;
pub const snapDirectionAt = implementation.snapDirectionAt;
pub const attractToRect = implementation.attractToRect;

test {
    _ = implementation;
}
