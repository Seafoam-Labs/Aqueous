// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

//! ext-workspace-v1 manager.
//!
//! Scaffold only: this file exists to prove the generated zig-wayland server
//! bindings for `ext-workspace-v1` resolve and to give later work its import
//! seam. It creates no global and registers no handlers yet. The full protocol
//! surface this module must serve is specified in
//! `protocol/EXT_WORKSPACE_NOTES.md`.

const ext = @import("wayland").server.ext;

/// Compile-only reference: forces analysis of all three generated server-side
/// `ext-workspace-v1` interface types and their bitfield enums so a build fails
/// loudly if the scanner wiring regresses. Referenced from Server.zig.
pub const bindings_resolve = blk: {
    // The three interfaces (see EXT_WORKSPACE_NOTES.md §2a).
    _ = ext.WorkspaceManagerV1;
    _ = ext.WorkspaceGroupHandleV1;
    _ = ext.WorkspaceHandleV1;
    // The pinned bitfields (see EXT_WORKSPACE_NOTES.md §2b).
    _ = ext.WorkspaceGroupHandleV1.GroupCapabilities;
    _ = ext.WorkspaceHandleV1.State;
    _ = ext.WorkspaceHandleV1.WorkspaceCapabilities;
    break :blk true;
};
