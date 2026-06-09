// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

//! A compositor-owned workspace.
//!
//! A workspace is an ordered, exclusive grouping of windows belonging to a
//! single output. Each output keeps an ordered list of workspaces and exactly
//! one active workspace; a window belongs to at most one workspace. Visibility
//! is derived natively from membership: a window renders only when it has no
//! workspace or when its workspace is the active one on its output.
//!
//! This file owns only the workspace state itself. The per-output ordered list,
//! the active-workspace pointer and the create/reap invariants live in
//! `Output.zig`; per-window membership lives in `Window.zig`.

const Workspace = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Window = @import("Window.zig");

/// Node in the owning output's ordered workspace list (`Output.workspaces`).
link: wl.list.Link,

/// The output this workspace belongs to.
output: *Output,

/// Human-readable name, heap owned by this workspace.
name: [:0]const u8,

/// Windows that are members of this workspace.
windows: wl.list.Head(Window, .workspace_link),

/// Set when a member window requests attention while the workspace is inactive.
urgent: bool = false,

pub fn create(output: *Output, name: []const u8) error{OutOfMemory}!*Workspace {
    const workspace = try util.gpa.create(Workspace);
    errdefer util.gpa.destroy(workspace);

    const owned_name = try util.gpa.dupeZ(u8, name);
    errdefer comptime unreachable;

    workspace.* = .{
        .link = undefined,
        .output = output,
        .name = owned_name,
        .windows = undefined,
    };
    workspace.windows.init();

    output.workspaces.append(workspace);

    server.workspace_manager.dirty();

    return workspace;
}

pub fn destroy(workspace: *Workspace) void {
    assert(workspace.windows.empty());
    assert(workspace.output.active_workspace != workspace);

    server.workspace_manager.notifyWorkspaceRemoved(workspace);

    workspace.link.remove();
    util.gpa.free(workspace.name);
    util.gpa.destroy(workspace);
}

pub fn isActive(workspace: *const Workspace) bool {
    return workspace.output.active_workspace == workspace;
}

pub fn empty(workspace: *const Workspace) bool {
    return workspace.windows.empty();
}
