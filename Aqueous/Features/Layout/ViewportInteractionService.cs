using System;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;

namespace Aqueous.Features.Layout;

/// <summary>
/// Increment: lifts the focused-window-aware viewport helpers (<c>HandleScrollViewport</c>,
/// <c>HandleMoveColumn</c>) off the <c>RiverWindowManagerClient.LayoutProposer</c> partial.
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
    private readonly ILayoutProposer _layoutProposer;
    private readonly IManagerRequestSender _requests;

    public ViewportInteractionService(
        LayoutController layoutController,
        FocusedWindowTracker focused,
        IWindowRegistry windows,
        ILayoutProposer layoutProposer,
        IManagerRequestSender requests)
    {
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _focused = focused ?? throw new ArgumentNullException(nameof(focused));
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _layoutProposer = layoutProposer ?? throw new ArgumentNullException(nameof(layoutProposer));
        _requests = requests ?? throw new ArgumentNullException(nameof(requests));
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

        _layoutController.ScrollViewport(fw.Output, _layoutProposer.ResolveOutputName(fw.Output), deltaColumns);
        _requests.ScheduleManage();
    }

    /// <summary>
    /// Move the focused window's column in the given direction.
    /// </summary>
    public void MoveColumn(FocusDirection dir)
    {
        var focused = _focused.Current;
        if (focused == IntPtr.Zero || !_windows.Entries.TryGetValue(focused, out var fw))
        {
            return;
        }

        if (_layoutController.MoveFocused(fw.Output, _layoutProposer.ResolveOutputName(fw.Output), focused, dir))
        {
            _requests.ScheduleManage();
        }
    }
}
