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

var next_id: u32 = 1;

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

id: u32,

/// Human-readable name, heap owned by this workspace.
name: [:0]const u8,

/// Name of the output this workspace was originally created on, heap owned by
/// this workspace. Used to move a workspace back to its home output if that
/// output is reconnected after having been disconnected.
home_output_name: [:0]const u8,

/// Windows that are members of this workspace.
windows: wl.list.Head(Window, .workspace_link),

/// Set when a member window requests attention while the workspace is inactive.
urgent: bool = false,

pinned: bool = false,

pub fn create(output: *Output, name: []const u8) error{OutOfMemory}!*Workspace {
    const workspace = try util.gpa.create(Workspace);
    errdefer util.gpa.destroy(workspace);

    const owned_name = try util.gpa.dupeZ(u8, name);
    errdefer util.gpa.free(owned_name);

    const home_name = if (output.wlr_output) |wlr_output|
        try util.gpa.dupeZ(u8, std.mem.span(wlr_output.name))
    else
        try util.gpa.dupeZ(u8, "");
    errdefer comptime unreachable;

    const id = next_id;
    next_id += 1;

    workspace.* = .{
        .link = undefined,
        .output = output,
        .id = id,
        .name = owned_name,
        .home_output_name = home_name,
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
    util.gpa.free(workspace.home_output_name);
    util.gpa.destroy(workspace);
}

pub fn isActive(workspace: *const Workspace) bool {
    return workspace.output.active_workspace == workspace;
}

pub fn policyId(workspace: *const Workspace) u32 {
    return workspace.id;
}

pub fn empty(workspace: *const Workspace) bool {
    return workspace.windows.empty();
}
