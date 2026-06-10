using System;
using System.Collections.Generic;

namespace Aqueous.Features.Workspaces;

/// <summary>
/// A single workspace as mirrored from <c>ext_workspace_handle_v1</c> events. The
/// <see cref="Handle"/> is the client-side proxy for the workspace; <see cref="Group"/> is the
/// owning <c>ext_workspace_group_handle_v1</c> proxy (zero until a <c>workspace_enter</c> arrives).
/// </summary>
internal sealed class WorkspaceInfo
{
    public IntPtr Handle { get; }
    public IntPtr Group { get; set; }
    public string? Name { get; set; }
    public bool Active { get; set; }
    public bool Urgent { get; set; }

    public WorkspaceInfo(IntPtr handle) => Handle = handle;
}

/// <summary>
/// A workspace group (one per output, per the RiverDelta server policy) mirrored from
/// <c>ext_workspace_group_handle_v1</c> events. <see cref="Workspaces"/> preserves the order in
/// which workspaces entered the group, which is the order index-based keybindings address.
/// </summary>
internal sealed class WorkspaceGroupInfo
{
    public IntPtr Handle { get; }
    public List<IntPtr> Workspaces { get; } = new();

    public WorkspaceGroupInfo(IntPtr handle) => Handle = handle;
}

/// <summary>
/// Pump-thread-owned mirror of the compositor's <c>ext-workspace-v1</c> state. Populated by
/// <see cref="WorkspaceEventService"/> from protocol events and queried by
/// <see cref="WorkspaceService"/> to resolve index/directional workspace actions into the concrete
/// <c>ext_workspace_handle_v1</c> proxy to <c>activate</c> or move a window to.
/// <para>
/// ext-workspace groups carry a <c>wl_output</c> that Aqueous does not track as one of its
/// <c>river_output_v1</c> proxies, so there is no direct group&#8596;output bridge on the client.
/// Instead a single <see cref="CurrentGroup"/> is tracked: it follows the most recently activated
/// workspace's group. Index/directional actions operate on that group, which matches the focused
/// output for the common single-output and last-focused-output cases.
/// </para>
/// </summary>
internal sealed class WorkspaceStore
{
    private readonly Dictionary<IntPtr, WorkspaceInfo> _workspaces = new();
    private readonly Dictionary<IntPtr, WorkspaceGroupInfo> _groups = new();

    /// <summary>
    /// The group index/directional actions target. Follows the most recently activated workspace.
    /// </summary>
    public IntPtr CurrentGroup { get; set; }

    /// <summary>
    /// The workspace that was active in <see cref="CurrentGroup"/> immediately before the most
    /// recent switch, used by <c>FocusPreviousWorkspace</c>.
    /// </summary>
    public IntPtr PreviousWorkspace { get; set; }

    /// <summary>
    /// Optional sink invoked after any state change, for bar/IPC integration.
    /// </summary>
    public Action? Changed { get; set; }

    public WorkspaceGroupInfo AddGroup(IntPtr group)
    {
        if (!_groups.TryGetValue(group, out var g))
        {
            g = new WorkspaceGroupInfo(group);
            _groups[group] = g;
        }

        return g;
    }

    public void RemoveGroup(IntPtr group)
    {
        if (_groups.Remove(group, out var g))
        {
            foreach (var ws in g.Workspaces)
            {
                if (_workspaces.TryGetValue(ws, out var w) && w.Group == group)
                {
                    w.Group = IntPtr.Zero;
                }
            }
        }

        if (CurrentGroup == group)
        {
            CurrentGroup = IntPtr.Zero;
        }
    }

    public WorkspaceInfo AddWorkspace(IntPtr workspace)
    {
        if (!_workspaces.TryGetValue(workspace, out var w))
        {
            w = new WorkspaceInfo(workspace);
            _workspaces[workspace] = w;
        }

        return w;
    }

    public void RemoveWorkspace(IntPtr workspace)
    {
        if (_workspaces.Remove(workspace, out var w) && w.Group != IntPtr.Zero &&
            _groups.TryGetValue(w.Group, out var g))
        {
            g.Workspaces.Remove(workspace);
        }

        if (PreviousWorkspace == workspace)
        {
            PreviousWorkspace = IntPtr.Zero;
        }
    }

    public void EnterGroup(IntPtr group, IntPtr workspace)
    {
        var g = AddGroup(group);
        var w = AddWorkspace(workspace);
        w.Group = group;
        if (!g.Workspaces.Contains(workspace))
        {
            g.Workspaces.Add(workspace);
        }
    }

    public void LeaveGroup(IntPtr group, IntPtr workspace)
    {
        if (_groups.TryGetValue(group, out var g))
        {
            g.Workspaces.Remove(workspace);
        }

        if (_workspaces.TryGetValue(workspace, out var w) && w.Group == group)
        {
            w.Group = IntPtr.Zero;
        }
    }

    public void SetState(IntPtr workspace, bool active, bool urgent)
    {
        if (!_workspaces.TryGetValue(workspace, out var w))
        {
            return;
        }

        if (active && !w.Active && w.Group != IntPtr.Zero)
        {
            // The most recently activated workspace's group becomes the target of index/directional
            // actions. The previous-workspace bookkeeping is owned by the controller (which knows the
            // switch is deliberate) rather than reconstructed from event ordering here.
            CurrentGroup = w.Group;
        }

        w.Active = active;
        w.Urgent = urgent;
    }

    public bool TryGetWorkspace(IntPtr workspace, out WorkspaceInfo info)
        => _workspaces.TryGetValue(workspace, out info!);

    /// <summary>
    /// Whether a live workspace handle is still tracked. Used to guard against driving (activating /
    /// moving to) a workspace that has been reaped by the compositor.
    /// </summary>
    public bool ContainsWorkspace(IntPtr workspace)
        => workspace != IntPtr.Zero && _workspaces.ContainsKey(workspace);

    /// <summary>
    /// Whether a window assigned to <paramref name="workspace"/> must be hidden from the active
    /// layout this cycle. True only when the handle is still tracked <i>and</i> its workspace is not
    /// the active one in its group. Returns false for <see cref="IntPtr.Zero"/> (unassigned windows
    /// are visible everywhere) and for reaped/untracked handles (so a freed workspace can never
    /// strand its windows off-screen). Consumed by <c>LayoutProposer.ProposeForArea</c>.
    /// </summary>
    public bool IsHiddenByWorkspace(IntPtr workspace)
        => workspace != IntPtr.Zero
           && _workspaces.TryGetValue(workspace, out var w)
           && !w.Active;

    public WorkspaceGroupInfo? GetCurrentGroup()
    {
        if (CurrentGroup != IntPtr.Zero && _groups.TryGetValue(CurrentGroup, out var g))
        {
            return g;
        }

        foreach (var kv in _groups)
        {
            return kv.Value;
        }

        return null;
    }

    /// <summary>
    /// The active workspace handle within <paramref name="group"/>, or <see cref="IntPtr.Zero"/>.
    /// </summary>
    public IntPtr ActiveIn(WorkspaceGroupInfo group)
    {
        foreach (var ws in group.Workspaces)
        {
            if (_workspaces.TryGetValue(ws, out var w) && w.Active)
            {
                return ws;
            }
        }

        return IntPtr.Zero;
    }

    public void Clear()
    {
        _workspaces.Clear();
        _groups.Clear();
        CurrentGroup = IntPtr.Zero;
        PreviousWorkspace = IntPtr.Zero;
    }

    public void NotifyChanged() => Changed?.Invoke();
}
