// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

//! ext-workspace-v1 manager.
//!
//! Advertises the `ext_workspace_manager_v1` global and serves the protocol on
//! top of the compositor-owned workspace model (see `Workspace.zig`,
//! `Output.zig` and `Window.zig`). Each output maps to a workspace group and
//! each workspace to a workspace handle. Many clients may bind concurrently
//! (bars and the window manager); every bound client gets its own handle
//! objects for the same underlying workspaces.
//!
//! Inbound requests are buffered per client and applied atomically on commit.
//! Any state change is broadcast to all bound clients coalesced into a single
//! done per client per change. The full protocol surface served here is
//! documented in `protocol/EXT_WORKSPACE_NOTES.md`.

const WorkspaceManager = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const ext = @import("wayland").server.ext;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Workspace = @import("Workspace.zig");

const log = std.log.scoped(.workspace);

const group_capabilities: ext.WorkspaceGroupHandleV1.GroupCapabilities = .{
    .create_workspace = true,
};

const workspace_capabilities: ext.WorkspaceHandleV1.WorkspaceCapabilities = .{
    .activate = true,
    .remove = true,
};

/// A workspace group handle as seen by a single client.
const Group = struct {
    manager: *Manager,
    /// Set to null once the underlying output is gone (the handle is inert).
    output: ?*Output,
    resource: *ext.WorkspaceGroupHandleV1,
};

/// A workspace handle as seen by a single client.
const Handle = struct {
    manager: *Manager,
    /// Set to null once the underlying workspace is gone (the handle is inert).
    workspace: ?*Workspace,
    resource: *ext.WorkspaceHandleV1,
    /// Last state bitfield sent to the client, so only changes are re-emitted.
    sent_state: ext.WorkspaceHandleV1.State = .{},
    /// The group this handle currently belongs to from the client's view. Drives
    /// workspace_enter/workspace_leave and composes correctly with migration.
    entered_group: ?*Group = null,
};

/// A buffered request, applied atomically on commit. Workspace-targeting
/// variants carry the per-client *Handle (whose `workspace` field is nulled
/// when the underlying workspace is reaped) rather than a raw *Workspace, so
/// liveness can be re-resolved at apply time and stale entries skipped.
const Pending = union(enum) {
    activate: *Handle,
    deactivate: *Handle,
    remove: *Handle,
    create_workspace: struct { output: *Output, name: [:0]const u8 },
};

/// Per-client manager state. Owns the client's handle objects and its pending
/// transaction.
const Manager = struct {
    link: wl.list.Link,
    resource: *ext.WorkspaceManagerV1,
    groups: std.AutoHashMapUnmanaged(*Output, *Group) = .empty,
    handles: std.AutoHashMapUnmanaged(*Workspace, *Handle) = .empty,
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    stopped: bool = false,

    /// Bring the client up to date by emitting only the deltas since it was last
    /// told, terminating with a single done if anything changed.
    fn publish(manager: *Manager) void {
        const client = manager.resource.getClient();
        const version = manager.resource.getVersion();

        var changed = false;

        var output_it = server.om.outputs.iterator(.forward);
        while (output_it.next()) |output| {
            const group_result = manager.ensureGroup(output, client, version) orelse continue;
            if (group_result.created) changed = true;
            const group = group_result.group;

            var ws_it = output.workspaces.iterator(.forward);
            while (ws_it.next()) |workspace| {
                const result = manager.ensureHandle(workspace, client, version) orelse continue;
                const handle = result.handle;
                if (result.created) changed = true;

                if (handle.entered_group != group) {
                    if (handle.entered_group) |old| old.resource.sendWorkspaceLeave(handle.resource);
                    group.resource.sendWorkspaceEnter(handle.resource);
                    handle.entered_group = group;
                    changed = true;
                }

                const state: ext.WorkspaceHandleV1.State = .{
                    .active = workspace.isActive(),
                    .urgent = workspace.urgent,
                };
                if (!std.meta.eql(state, handle.sent_state)) {
                    handle.resource.sendState(state);
                    handle.sent_state = state;
                    changed = true;
                }
            }
        }

        if (changed) manager.resource.sendDone();
    }

    const EnsureGroup = struct { group: *Group, created: bool };

    fn ensureGroup(manager: *Manager, output: *Output, client: *wl.Client, version: u32) ?EnsureGroup {
        if (manager.groups.get(output)) |group| return .{ .group = group, .created = false };

        const resource = ext.WorkspaceGroupHandleV1.create(client, version, 0) catch {
            client.postNoMemory();
            return null;
        };
        const group = util.gpa.create(Group) catch {
            resource.destroy();
            client.postNoMemory();
            return null;
        };
        group.* = .{ .manager = manager, .output = output, .resource = resource };
        manager.groups.put(util.gpa, output, group) catch {
            util.gpa.destroy(group);
            resource.destroy();
            client.postNoMemory();
            return null;
        };

        resource.setHandler(*Group, handleGroupRequest, handleGroupDestroy, group);
        manager.resource.sendWorkspaceGroup(resource);
        resource.sendCapabilities(group_capabilities);

        if (output.wlr_output) |wlr_output| {
            var res_it = wlr_output.resources.iterator(.forward);
            while (res_it.next()) |output_resource| {
                if (output_resource.getClient() == client) {
                    resource.sendOutputEnter(output_resource);
                    break;
                }
            }
        }

        return .{ .group = group, .created = true };
    }

    const EnsureHandle = struct { handle: *Handle, created: bool };

    fn ensureHandle(manager: *Manager, workspace: *Workspace, client: *wl.Client, version: u32) ?EnsureHandle {
        if (manager.handles.get(workspace)) |handle| {
            return .{ .handle = handle, .created = false };
        }

        const resource = ext.WorkspaceHandleV1.create(client, version, 0) catch {
            client.postNoMemory();
            return null;
        };
        const handle = util.gpa.create(Handle) catch {
            resource.destroy();
            client.postNoMemory();
            return null;
        };
        handle.* = .{ .manager = manager, .workspace = workspace, .resource = resource };
        manager.handles.put(util.gpa, workspace, handle) catch {
            util.gpa.destroy(handle);
            resource.destroy();
            client.postNoMemory();
            return null;
        };

        resource.setHandler(*Handle, handleHandleRequest, handleHandleDestroy, handle);
        manager.resource.sendWorkspace(resource);
        resource.sendName(workspace.name.ptr);
        resource.sendCapabilities(workspace_capabilities);

        return .{ .handle = handle, .created = true };
    }

    fn apply(manager: *Manager) void {
        for (manager.pending.items) |pending| {
            switch (pending) {
                .activate => |handle| {
                    const workspace = handle.workspace orelse continue;
                    workspace.output.activateWorkspace(workspace);
                },
                .deactivate => {},
                .remove => |handle| {
                    const workspace = handle.workspace orelse continue;
                    if (!workspace.isActive() and workspace.empty()) workspace.destroy();
                },
                .create_workspace => |args| {
                    _ = Workspace.create(args.output, args.name) catch {
                        log.err("out of memory creating workspace", .{});
                    };
                    util.gpa.free(args.name);
                },
            }
        }
        manager.pending.clearRetainingCapacity();

        // Reaping is deferred until the whole transaction is applied so that no
        // entry in the same batch can resolve a workspace freed earlier in the
        // loop. activateWorkspace no longer reaps synchronously.
        server.workspace_manager.dirty();
    }

    fn destroyHandles(manager: *Manager) void {
        while (true) {
            var it = manager.handles.valueIterator();
            const handle = it.next() orelse break;
            handle.*.resource.destroy();
        }
        while (true) {
            var it = manager.groups.valueIterator();
            const group = it.next() orelse break;
            group.*.resource.destroy();
        }
    }
};

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

managers: wl.list.Head(Manager, .link),

initialized: bool = false,
publish_idle: ?*wl.EventSource = null,

pub fn init(wsm: *WorkspaceManager) !void {
    wsm.* = .{
        .global = try wl.Global.create(server.wl_server, ext.WorkspaceManagerV1, 1, *WorkspaceManager, wsm, bind),
        .managers = undefined,
    };
    wsm.managers.init();
    wsm.initialized = true;

    server.wl_server.addDestroyListener(&wsm.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const wsm: *WorkspaceManager = @fieldParentPtr("server_destroy", listener);
    if (wsm.publish_idle) |idle| {
        idle.remove();
        wsm.publish_idle = null;
    }
    wsm.global.destroy();
}

/// Resolve the native workspace backing a client-facing workspace handle
/// resource, or null if the handle is inert or not one of ours.
pub fn workspaceForResource(resource: *ext.WorkspaceHandleV1) ?*Workspace {
    const data = resource.getUserData() orelse return null;
    const handle: *Handle = @ptrCast(@alignCast(data));
    return handle.workspace;
}

/// Schedule a coalesced broadcast of the current state to all bound clients.
pub fn dirty(wsm: *WorkspaceManager) void {
    if (!wsm.initialized) return;
    if (wsm.publish_idle != null) return;
    const event_loop = server.wl_server.getEventLoop();
    wsm.publish_idle = event_loop.addIdle(*WorkspaceManager, publishIdle, wsm) catch {
        log.err("out of memory", .{});
        return;
    };
}

fn publishIdle(wsm: *WorkspaceManager) void {
    wsm.publish_idle = null;
    // Destroy empty workspaces and restore the trailing-empty invariant once per
    // coalesced cycle, after every dirtying mutation (switch, move, unmap) has
    // been applied. Doing this here, rather than synchronously inside the
    // mutating call sites, guarantees a workspace is only ever freed at a single
    // well-defined point where nothing holds a transient pointer to it.
    reapAllOutputs();
    var it = wsm.managers.iterator(.forward);
    while (it.next()) |manager| manager.publish();
}

/// Reap empty, non-active, non-trailing workspaces on every output, then ensure
/// each output still has an empty trailing workspace. Reap before ensuring so a
/// freshly created trailing empty is not immediately destroyed.
fn reapAllOutputs() void {
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| {
        output.reapEmpty();
        output.ensureTrailingEmpty();
    }
}

/// Notify clients that a workspace is about to be destroyed. Called before the
/// native workspace memory is freed so handles can be torn down safely.
pub fn notifyWorkspaceRemoved(wsm: *WorkspaceManager, workspace: *Workspace) void {
    if (!wsm.initialized) return;
    var it = wsm.managers.iterator(.forward);
    while (it.next()) |manager| {
        if (manager.handles.fetchRemove(workspace)) |entry| {
            const handle = entry.value;
            if (handle.entered_group) |group| {
                group.resource.sendWorkspaceLeave(handle.resource);
            }
            handle.resource.sendRemoved();
            handle.workspace = null;
            handle.entered_group = null;
        }
    }
    wsm.dirty();
}

/// Handle the disconnection of an output. Any workspaces have already either
/// been migrated to `dest` (if non-null) or destroyed. For each client this
/// emits the workspace_leave/workspace_enter choreography for migrated
/// workspaces, then removes the departing output's group, terminating with a
/// single done per client.
pub fn handleOutputRemoved(wsm: *WorkspaceManager, output: *Output, dest: ?*Output) void {
    if (!wsm.initialized) return;
    var it = wsm.managers.iterator(.forward);
    while (it.next()) |manager| {
        const client = manager.resource.getClient();
        const version = manager.resource.getVersion();
        var changed = false;

        if (dest) |to| {
            if (manager.ensureGroup(to, client, version)) |group_result| {
                if (group_result.created) changed = true;
                const dest_group = group_result.group;
                var hit = manager.handles.valueIterator();
                while (hit.next()) |handle_ptr| {
                    const handle = handle_ptr.*;
                    const ws = handle.workspace orelse continue;
                    if (ws.output != to) continue;
                    if (handle.entered_group == dest_group) continue;
                    if (handle.entered_group) |old| old.resource.sendWorkspaceLeave(handle.resource);
                    dest_group.resource.sendWorkspaceEnter(handle.resource);
                    handle.entered_group = dest_group;
                    changed = true;
                }
            }
        }

        if (manager.groups.fetchRemove(output)) |entry| {
            const group = entry.value;
            group.resource.sendRemoved();
            group.output = null;
            changed = true;
        }

        if (changed) manager.resource.sendDone();
    }
}

fn bind(client: *wl.Client, wsm: *WorkspaceManager, version: u32, id: u32) void {
    const resource = ext.WorkspaceManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };

    const manager = util.gpa.create(Manager) catch {
        resource.destroy();
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    manager.* = .{ .link = undefined, .resource = resource };
    wsm.managers.append(manager);

    resource.setHandler(*Manager, handleManagerRequest, handleManagerDestroy, manager);

    manager.publish();
}

fn handleManagerRequest(
    resource: *ext.WorkspaceManagerV1,
    request: ext.WorkspaceManagerV1.Request,
    manager: *Manager,
) void {
    switch (request) {
        .commit => {
            if (manager.stopped) return;
            manager.apply();
        },
        .stop => {
            manager.stopped = true;
            resource.destroySendFinished();
        },
    }
}

fn handleManagerDestroy(_: *ext.WorkspaceManagerV1, manager: *Manager) void {
    manager.destroyHandles();

    for (manager.pending.items) |pending| {
        if (pending == .create_workspace) util.gpa.free(pending.create_workspace.name);
    }
    manager.pending.deinit(util.gpa);
    manager.handles.deinit(util.gpa);
    manager.groups.deinit(util.gpa);

    manager.link.remove();
    util.gpa.destroy(manager);
}

fn handleGroupRequest(
    _: *ext.WorkspaceGroupHandleV1,
    request: ext.WorkspaceGroupHandleV1.Request,
    group: *Group,
) void {
    switch (request) {
        .create_workspace => |args| {
            const manager = group.manager;
            if (manager.stopped) return;
            const output = group.output orelse return;
            const name = util.gpa.dupeZ(u8, std.mem.span(args.workspace)) catch {
                log.err("out of memory", .{});
                return;
            };
            manager.pending.append(util.gpa, .{
                .create_workspace = .{ .output = output, .name = name },
            }) catch {
                util.gpa.free(name);
                log.err("out of memory", .{});
            };
        },
        .destroy => {},
    }
}

fn handleGroupDestroy(_: *ext.WorkspaceGroupHandleV1, group: *Group) void {
    if (group.output) |output| _ = group.manager.groups.remove(output);
    util.gpa.destroy(group);
}

fn handleHandleRequest(
    _: *ext.WorkspaceHandleV1,
    request: ext.WorkspaceHandleV1.Request,
    handle: *Handle,
) void {
    const manager = handle.manager;
    switch (request) {
        .activate => {
            if (manager.stopped) return;
            manager.pending.append(util.gpa, .{ .activate = handle }) catch
                log.err("out of memory", .{});
        },
        .deactivate => {
            if (manager.stopped) return;
            manager.pending.append(util.gpa, .{ .deactivate = handle }) catch
                log.err("out of memory", .{});
        },
        .remove => {
            if (manager.stopped) return;
            manager.pending.append(util.gpa, .{ .remove = handle }) catch
                log.err("out of memory", .{});
        },
        .assign => {},
        .destroy => {},
    }
}

fn handleHandleDestroy(_: *ext.WorkspaceHandleV1, handle: *Handle) void {
    if (handle.workspace) |workspace| _ = handle.manager.handles.remove(workspace);
    util.gpa.destroy(handle);
}
