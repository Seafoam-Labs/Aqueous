using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout.Builtin;

/// <summary>
/// One window at a time fills the usable area; every other visible window has <c>Visible =
/// false</c> so the controller skips its <c>OP_SHOW</c>. The "current" handle is remembered
/// per-output and falls back to <see cref="ILayoutEngine.Arrange"/>'s <c>focusedWindow</c> if the
/// previously-current one disappears.
/// </summary>
public sealed class MonocleLayout : ILayoutEngine
{
    public string Id => "monocle";

    private sealed class State
    {
        public IntPtr Current;

        /// <summary>
        /// Stable z-stack ordering of every window the engine has seen on this output. Reordered
        /// only by <see cref="MoveFocused"/>; otherwise rebuilt by appending new windows in
        /// encounter order and dropping handles that have disappeared from <c>visibleWindows</c>.
        /// </summary>
        public readonly List<IntPtr> Order = new();
    }

    private static void SyncOrder(State state, IReadOnlyList<WindowEntryView> windows)
    {
        // Drop entries no longer visible.
        if (state.Order.Count > 0)
        {
            var live = new HashSet<IntPtr>();
            for (int i = 0; i < windows.Count; i++) live.Add(windows[i].Handle);
            state.Order.RemoveAll(h => !live.Contains(h));
        }

        // Append newly-seen handles in encounter order.
        var known = new HashSet<IntPtr>(state.Order);
        for (int i = 0; i < windows.Count; i++)
        {
            var h = windows[i].Handle;
            if (!known.Contains(h))
            {
                state.Order.Add(h);
                known.Add(h);
            }
        }
    }

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var state = perOutputState as State ?? new State();
        perOutputState = state;
        SyncOrder(state, windows);

        var result = new List<WindowPlacement>(windows.Count);
        if (windows.Count == 0) { state.Current = IntPtr.Zero; return result; }

        // Validate Current; fall back to focused, then first.
        bool stillThere = false;
        for (int i = 0; i < windows.Count; i++)
        {
            if (windows[i].Handle == state.Current) { stillThere = true; break; }
        }

        if (!stillThere)
        {
            state.Current = focusedWindow != IntPtr.Zero ? focusedWindow : windows[0].Handle;
            // If even focused isn't in the visible set, pick the first one.
            bool focusedHere = false;
            for (int i = 0; i < windows.Count; i++)
            {
                if (windows[i].Handle == state.Current) { focusedHere = true; break; }
            }

            if (!focusedHere)
            {
                state.Current = windows[0].Handle;
            }
        }

        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        bool hideOthers = opts.GetExtraBool("hide_others", true);
        bool showBorders = opts.GetExtraBool("show_borders", false);
        var border = showBorders ? new BorderSpec(2, 0, 0, 0) : BorderSpec.None;

        for (int i = 0; i < windows.Count; i++)
        {
            var w = windows[i];
            bool isCurrent = w.Handle == state.Current;
            // Non-current windows still get a placement record so the controller knows the engine is aware of
            // them. Visible=false means "do not OP_SHOW this frame".
            result.Add(new WindowPlacement(
                w.Handle,
                isCurrent ? area : Rect.Empty,
                isCurrent ? 1 : 0,
                isCurrent || !hideOthers,
                isCurrent ? border : BorderSpec.None));
        }
        return result;
    }

    /// <summary>
    /// Reorder the focused window within the monocle z-stack: <c>Left</c>/<c>Up</c>/<c>Prev</c>
    /// swap with the previous slot; <c>Right</c>/<c>Down</c>/<c>Next</c> swap with the next.
    /// Returns <c>false</c> at the edges, on unknown handles, or when the engine has never seen
    /// the window before.
    /// </summary>
    public bool MoveFocused(
        IntPtr output,
        IntPtr focused,
        FocusDirection dir,
        ref object? perOutputState)
    {
        if (perOutputState is not State s)
        {
            return false;
        }

        int i = s.Order.IndexOf(focused);
        if (i < 0)
        {
            return false;
        }

        int j = dir switch
        {
            FocusDirection.Left or FocusDirection.Up or FocusDirection.Prev   => i - 1,
            FocusDirection.Right or FocusDirection.Down or FocusDirection.Next => i + 1,
            _ => i
        };

        if (j < 0 || j >= s.Order.Count || j == i)
        {
            return false;
        }

        (s.Order[i], s.Order[j]) = (s.Order[j], s.Order[i]);
        return true;
    }
}

public sealed class MonocleLayoutFactory : ILayoutFactory
{
    private readonly MonocleLayout _shared = new();
    public string Id => "monocle";
    public string DisplayName => "Monocle (One-at-a-time)";
    public ILayoutEngine Create() => _shared;
}
