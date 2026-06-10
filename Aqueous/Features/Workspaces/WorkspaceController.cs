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
    /// Retained for source/binary compatibility with callers that pass a debounce window. The
    /// debounce/coalesce machinery has been replaced by a per-dispatch-iteration chord guard
    /// (see <see cref="Focus"/>), so this value is no longer used to throttle commits.
    /// </summary>
    internal const int DefaultDebounceMillis = 60;

    private readonly IWorkspaceHost _host;

    // Pump-thread affinity is enforced by the WorkspaceService facade, which funnels every verb
    // through IManagerRequestSender.Post; both the verb entry points and the per-iteration
    // FlushPending therefore run on the Wayland event-pump thread, so no synchronization is
    // required for this state.
    private bool _everCommitted;
    private IntPtr _lastCommittedFocus;

    // Set by the first workspace switch/move in a Wayland dispatch iteration and cleared by
    // FlushPending at the iteration boundary. A simultaneous multi-key chord (e.g. Super+1+2)
    // delivers all `pressed` events in the same DispatchPending batch, so every press after the
    // first sees this flag set and is ignored. This collapses the chord to a single switch
    // (first-wins), committed immediately on the pump thread, eliminating the second
    // activate+commit transaction that previously raced the compositor's workspace reap (crash)
    // and the deferred commit that later stalled the pump past river's watchdog (hang).
    private bool _switchedThisIteration;

    public WorkspaceController(IWorkspaceHost host, Func<long>? nowMillis = null, int debounceMillis = DefaultDebounceMillis)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        // nowMillis / debounceMillis are retained for API compatibility but no longer used: the
        // first-wins chord guard does not depend on wall-clock timing.
        _ = nowMillis;
        _ = debounceMillis;
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

        if (_switchedThisIteration)
        {
            // A workspace switch already happened in this dispatch iteration: this press is one of
            // the trailing keys of a simultaneous chord (e.g. the `2` of Super+1+2). Ignore it so
            // the gesture produces a single switch (first-wins) rather than two activate+commit
            // transactions that can straddle the compositor's workspace reap.
            RiverLog.Write("workspace switch ignored: chord (already switched this dispatch frame)");
            return true;
        }

        // Claim the frame even when the target is already active, so a chord's trailing keys are
        // still ignored, then commit immediately on the pump thread (the press already runs there).
        // Committing on the calling edge keeps river's manage transaction fed promptly — fully
        // deferring it could leave the WM silent past river's 3s watchdog.
        _switchedThisIteration = true;

        if (_everCommitted && workspace == _lastCommittedFocus)
        {
            // Already on this workspace; nothing to dispatch.
            return true;
        }

        CommitFocus(workspace);
        return true;
    }

    private void CommitFocus(IntPtr workspace)
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

        _lastCommittedFocus = workspace;
        _everCommitted = true;
    }

    /// <summary>
    /// Clears the per-dispatch-iteration chord guard. Invoked once per Wayland dispatch iteration
    /// (pump-thread), at the iteration boundary, so the next batch of input is free to switch
    /// again. Switches themselves now commit immediately in <see cref="Focus"/>, so this no longer
    /// dispatches any deferred work.
    /// </summary>
    public void FlushPending()
    {
        _switchedThisIteration = false;
    }

    private bool Move(IntPtr workspace)
    {
        if (!Store.ContainsWorkspace(workspace))
        {
            return false;
        }

        if (_switchedThisIteration)
        {
            // Trailing key of a same-frame chord (e.g. Super+Shift+1+2): collapse to a single move.
            RiverLog.Write("workspace move ignored: chord (already switched this dispatch frame)");
            return true;
        }

        if (!_host.MoveFocusedToWorkspace(workspace))
        {
            return false;
        }

        _switchedThisIteration = true;
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
