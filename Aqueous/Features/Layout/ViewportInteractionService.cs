using System;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Tags;

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

    public ViewportInteractionService(
        LayoutController layoutController,
        FocusedWindowTracker focused,
        IWindowRegistry windows,
        IOutputRegistry outputs,
        ILayoutProposer layoutProposer,
        IManagerRequestSender requests)
    {
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _focused = focused ?? throw new ArgumentNullException(nameof(focused));
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _outputs = outputs ?? throw new ArgumentNullException(nameof(outputs));
        _layoutProposer = layoutProposer ?? throw new ArgumentNullException(nameof(layoutProposer));
        _requests = requests ?? throw new ArgumentNullException(nameof(requests));
    }

    /// <summary>
    /// Read the currently-visible tag mask for the output owning the focused window. The mask is
    /// the scope key on <see cref="LayoutController"/>'s engine-state dictionaries — it must match
    /// the value <c>LayoutProposer</c> used when it last populated the per-scope state (i.e. the
    /// output's <c>OutputEntry.VisibleTags</c>), otherwise MoveFocused/ScrollViewport would mutate
    /// (or lazily create) a different scope than the one the user is looking at, restoring the old
    /// "only tag 1 swaps" bug.
    /// </summary>
    private uint ResolveVisibleTags(IntPtr output)
    {
        if (output != IntPtr.Zero && _outputs.Entries.TryGetValue(output, out var oe))
        {
            return oe.VisibleTags;
        }
        return TagState.AllTags;
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
            ResolveVisibleTags(fw.Output));
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
            ResolveVisibleTags(fw.Output));
        if (moved && _requests.IsBound)
        {
            _requests.ScheduleManage();
        }
    }
}
