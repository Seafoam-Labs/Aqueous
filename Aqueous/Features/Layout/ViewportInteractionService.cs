using System;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Tags;
using Aqueous.Features.Workspaces;

namespace Aqueous.Features.Layout;

/// <summary>
/// Increment: lifts the focused-window-aware viewport helpers (<c>HandleScrollViewport</c>,
/// <c>HandleMoveFocusedWindow</c>) off the <c>RiverWindowManagerClient.LayoutProposer</c> partial.
/// Combines the focused-window lookup (<see cref="FocusedWindowTracker"/> + <see
/// cref="IWindowRegistry"/>), the output-name resolution (<see
/// cref="ILayoutProposer.ResolveOutputName"/>), the layout-engine dispatch (<see
/// cref="LayoutController"/>) and the post-mutation manage cycle scheduling (<see
/// cref="IManagerRequestSender.ScheduleManage"/>) into a small DI-friendly service consumed by
/// <c>KeyBindingRouter</c>.
/// </summary>
internal sealed class ViewportInteractionService
{
    private readonly LayoutController _layoutController;
    private readonly FocusedWindowTracker _focused;
    private readonly IWindowRegistry _windows;
    private readonly IOutputRegistry _outputs;
    private readonly ILayoutProposer _layoutProposer;
    private readonly IManagerRequestSender _requests;
    private readonly WorkspaceStore _workspaceStore;

    public ViewportInteractionService(
        LayoutController layoutController,
        FocusedWindowTracker focused,
        IWindowRegistry windows,
        IOutputRegistry outputs,
        ILayoutProposer layoutProposer,
        IManagerRequestSender requests,
        WorkspaceStore workspaceStore)
    {
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _focused = focused ?? throw new ArgumentNullException(nameof(focused));
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _outputs = outputs ?? throw new ArgumentNullException(nameof(outputs));
        _layoutProposer = layoutProposer ?? throw new ArgumentNullException(nameof(layoutProposer));
        _requests = requests ?? throw new ArgumentNullException(nameof(requests));
        _workspaceStore = workspaceStore ?? throw new ArgumentNullException(nameof(workspaceStore));
    }

    private int ResolveWorkspaceNumber(IntPtr output)
    {
        int n = _workspaceStore.ActiveWorkspaceNumber(output, _outputs);
        return n > 0 ? n : 1;
    }


    /// <summary>
    /// Resolve the focused output: the output owning the focused window, or the first known output
    /// as a fallback when nothing is focused (so a fresh session's <c>set_layout_*</c> still lands
    /// on the visible monitor). Returns <see cref="IntPtr.Zero"/> only when no outputs exist.
    /// </summary>
    private IntPtr ResolveFocusedOutput()
    {
        var focused = _focused.Current;
        if (focused != IntPtr.Zero
            && _windows.Entries.TryGetValue(focused, out var fw)
            && fw.Output != IntPtr.Zero)
        {
            return fw.Output;
        }

        foreach (var k in _outputs.Entries.Keys)
        {
            return k;
        }

        return IntPtr.Zero;
    }

    /// <summary>
    /// Set the layout id of the currently-focused workspace (the focused output's visible-tag set)
    /// without touching the sibling workspaces or other monitors. This is the per-workspace
    /// <c>set_layout_*</c> entry point routed from <c>KeyBindingRouter</c>.
    /// </summary>
    public void SetLayoutForFocusedWorkspace(string layoutId)
    {
        var output = ResolveFocusedOutput();
        _layoutController.SetLayoutForWorkspace(output, ResolveWorkspaceNumber(output), layoutId);
        if (_requests.IsBound)
        {
            _requests.ScheduleManage();
        }
    }

    /// <summary>
    /// Pan the focused window's output by <paramref name="deltaColumns"/>.
    /// </summary>
    public void ScrollViewport(int deltaColumns)
    {
        var focused = _focused.Current;
        if (focused == IntPtr.Zero || !_windows.Entries.TryGetValue(focused, out var fw))
        {
            return;
        }

        _layoutController.ScrollViewport(
            fw.Output, _layoutProposer.ResolveOutputName(fw.Output), deltaColumns,
            ResolveWorkspaceNumber(fw.Output));
        if (_requests.IsBound)
        {
            _requests.ScheduleManage();
        }
    }

    /// <summary>
    /// Move the focused window in the given direction within the active layout's slot ordering.
    /// </summary>
    public void MoveFocusedWindow(FocusDirection dir)
    {
        var focused = _focused.Current;
        if (focused == IntPtr.Zero || !_windows.Entries.TryGetValue(focused, out var fw))
        {
            return;
        }

        // Slot-order mutation is purely local; the compositor only learns of the swap when the
        // next manage cycle drives LayoutProposer.ProposeForArea and the new set_position is
        // marshalled. Relying on a "natural" manage event (focus change, commit, pointer motion)
        // means a swap of two same-size tiles on the visible tag with no focus change
        // (Super+Shift+L/H repro) appears as a silent no-op until something unrelated wakes the
        // pump. ScheduleManage funnels manage_dirty through IManagerRequestSender's pump-thread
        // queue so the marshal happens on the dispatch thread — same guard that fixed the
        // `+0x2c` libwayland-client crash; calling it from this keybinding callback is safe.
        bool moved = _layoutController.MoveFocused(
            fw.Output, _layoutProposer.ResolveOutputName(fw.Output), focused, dir,
            ResolveWorkspaceNumber(fw.Output));
        if (moved && _requests.IsBound)
        {
            _requests.ScheduleManage();
        }
    }
}
