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

    /// <summary>
    /// Default coalescing window for rapid workspace switches. Bursts of focus requests landing
    /// within this many milliseconds of the last committed switch are collapsed so that only the
    /// leading request is dispatched immediately and only the latest target is flushed afterwards
    /// (see <see cref="FlushPending"/>). This throttles the <c>activate</c>+<c>commit</c> storm that
    /// rapid back-and-forth switching otherwise produces.
    /// </summary>
    internal const int DefaultDebounceMillis = 60;

    private readonly IWorkspaceHost _host;
    private readonly Func<long> _nowMillis;
    private readonly int _debounceMillis;

    // Pump-thread only: keybinding dispatch and the per-iteration FlushPending both run on the
    // Wayland event-pump thread, so no synchronization is required for this debounce state.
    private IntPtr _pendingFocus;
    private bool _hasPendingFocus;
    private bool _everCommitted;
    private IntPtr _lastCommittedFocus;
    private long _lastFocusCommitMillis;

    public WorkspaceController(IWorkspaceHost host, Func<long>? nowMillis = null, int debounceMillis = DefaultDebounceMillis)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _nowMillis = nowMillis ?? (static () => Environment.TickCount64);
        _debounceMillis = debounceMillis < 0 ? 0 : debounceMillis;
    }

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
        if (!Store.ContainsWorkspace(workspace))
        {
            // The target was reaped by the compositor between resolution and dispatch; never drive a
            // dead handle (it would activate a workspace mid-reap and can crash the compositor).
            return false;
        }

        long now = _nowMillis();
        if (!_everCommitted || now - _lastFocusCommitMillis >= _debounceMillis)
        {
            // Leading edge: dispatch immediately.
            CommitFocus(workspace, now);
        }
        else
        {
            // Inside the debounce window: coalesce. Remember only the latest target; it is dispatched
            // by FlushPending once the window elapses, so a rapid burst commits at most twice (the
            // leading request and the final target) instead of once per keystroke.
            _pendingFocus = workspace;
            _hasPendingFocus = true;
        }

        return true;
    }

    private void CommitFocus(IntPtr workspace, long now)
    {
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

        _lastFocusCommitMillis = now;
        _lastCommittedFocus = workspace;
        _everCommitted = true;
        _pendingFocus = IntPtr.Zero;
        _hasPendingFocus = false;
    }

    /// <summary>
    /// Dispatch any focus target that was coalesced during a rapid switch burst, once the debounce
    /// window has elapsed. Invoked once per Wayland dispatch iteration (pump-thread). No-ops when
    /// nothing is pending, when still inside the window, or when the pending target has since been
    /// reaped or is already the active workspace.
    /// </summary>
    public void FlushPending()
    {
        if (!_hasPendingFocus)
        {
            return;
        }

        long now = _nowMillis();
        if (now - _lastFocusCommitMillis < _debounceMillis)
        {
            return;
        }

        IntPtr workspace = _pendingFocus;
        _pendingFocus = IntPtr.Zero;
        _hasPendingFocus = false;

        if (!Store.ContainsWorkspace(workspace) || workspace == _lastCommittedFocus)
        {
            return;
        }

        CommitFocus(workspace, now);
    }

    private bool Move(IntPtr workspace)
    {
        if (!Store.ContainsWorkspace(workspace))
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
