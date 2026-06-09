using System;
using Aqueous.Diagnostics;

namespace Aqueous.Features.Workspaces;

/// <summary>
/// niri-shaped workspace logic operating against the <see cref="WorkspaceStore"/> mirror. The
/// protocol side-effects (activate+commit, set_workspace, post-mutation scheduling) are abstracted
/// behind <see cref="IWorkspaceHost"/> so the resolution logic is testable without Wayland.
/// </summary>
internal sealed class WorkspaceController
{
    /// <summary>Side-effect seam driven by <see cref="WorkspaceController"/>.</summary>
    internal interface IWorkspaceHost
    {
        WorkspaceStore Store { get; }

        /// <summary>Issue <c>activate</c> on the workspace then <c>commit</c> on the manager.</summary>
        void ActivateWorkspace(IntPtr workspace);

        /// <summary>
        /// Move the focused window to <paramref name="workspace"/> via
        /// <c>river_window_v1.set_workspace</c>. Returns false if there is no focused window.
        /// </summary>
        bool MoveFocusedToWorkspace(IntPtr workspace);

        /// <summary>Run after any successful mutation (schedule a manage cycle, fire change hook).</summary>
        void AfterChange();
    }

    private readonly IWorkspaceHost _host;

    public WorkspaceController(IWorkspaceHost host)
        => _host = host ?? throw new ArgumentNullException(nameof(host));

    private WorkspaceStore Store => _host.Store;

    /// <summary>Resolve the workspace handle at a 1-based index in the current group.</summary>
    private IntPtr ResolveByIndex(int index)
    {
        var group = Store.GetCurrentGroup();
        if (group is null || index < 1 || index > group.Workspaces.Count)
        {
            return IntPtr.Zero;
        }

        return group.Workspaces[index - 1];
    }

    /// <summary>Resolve the workspace handle <paramref name="delta"/> steps from the active one.</summary>
    private IntPtr ResolveRelative(int delta)
    {
        var group = Store.GetCurrentGroup();
        if (group is null || group.Workspaces.Count == 0)
        {
            return IntPtr.Zero;
        }

        var active = Store.ActiveIn(group);
        int idx = active == IntPtr.Zero ? 0 : group.Workspaces.IndexOf(active);
        int target = idx + delta;
        if (target < 0 || target >= group.Workspaces.Count)
        {
            return IntPtr.Zero;
        }

        return group.Workspaces[target];
    }

    public bool FocusWorkspaceByIndex(int index) => Focus(ResolveByIndex(index));

    public bool FocusWorkspaceUp() => Focus(ResolveRelative(-1));

    public bool FocusWorkspaceDown() => Focus(ResolveRelative(+1));

    public bool FocusPreviousWorkspace() => Focus(Store.PreviousWorkspace);

    public bool MoveFocusedToWorkspaceByIndex(int index) => Move(ResolveByIndex(index));

    public bool MoveFocusedToWorkspaceUp() => Move(ResolveRelative(-1));

    public bool MoveFocusedToWorkspaceDown() => Move(ResolveRelative(+1));

    public bool MoveWorkspaceUp() => Reorder();

    public bool MoveWorkspaceDown() => Reorder();

    private bool Focus(IntPtr workspace)
    {
        if (workspace == IntPtr.Zero)
        {
            return false;
        }

        // Record the workspace being left so FocusPreviousWorkspace can return to it (deterministic,
        // not reconstructed from compositor state-event ordering).
        var group = Store.GetCurrentGroup();
        if (group is not null)
        {
            var active = Store.ActiveIn(group);
            if (active != IntPtr.Zero && active != workspace)
            {
                Store.PreviousWorkspace = active;
            }
        }

        _host.ActivateWorkspace(workspace);
        _host.AfterChange();
        return true;
    }

    private bool Move(IntPtr workspace)
    {
        if (workspace == IntPtr.Zero)
        {
            return false;
        }

        if (!_host.MoveFocusedToWorkspace(workspace))
        {
            return false;
        }

        _host.AfterChange();
        return true;
    }

    private static bool Reorder()
    {
        // ext-workspace-v1 exposes no request to reorder workspaces within a group, so the niri
        // move-workspace-up/down verbs have no wire representation in this backend.
        RiverLog.Write("move_workspace: reordering is not supported by ext-workspace-v1");
        return false;
    }
}
