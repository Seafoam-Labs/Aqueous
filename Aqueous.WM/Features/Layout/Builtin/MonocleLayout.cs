using System;
using System.Collections.Generic;

namespace Aqueous.WM.Features.Layout.Builtin;

/// <summary>
/// One window at a time fills the usable area; every other visible
/// window has <c>Visible = false</c> so the controller skips its
/// <c>OP_SHOW</c>. The "current" handle is remembered per-output and
/// falls back to <see cref="ILayoutEngine.Arrange"/>'s
/// <c>focusedWindow</c> if the previously-current one disappears.
/// </summary>
public sealed class MonocleLayout : ILayoutEngine
{
    public string Id => "monocle";

    private sealed class State { public IntPtr Current; }

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var state = perOutputState as State ?? new State();
        perOutputState = state;

        var result = new List<WindowPlacement>(windows.Count);
        if (windows.Count == 0) { state.Current = IntPtr.Zero; return result; }

        // Validate Current; fall back to focused, then first.
        bool stillThere = false;
        for (int i = 0; i < windows.Count; i++)
            if (windows[i].Handle == state.Current) { stillThere = true; break; }

        if (!stillThere)
        {
            state.Current = focusedWindow != IntPtr.Zero ? focusedWindow : windows[0].Handle;
            // If even focused isn't in the visible set, pick the first one.
            bool focusedHere = false;
            for (int i = 0; i < windows.Count; i++)
                if (windows[i].Handle == state.Current) { focusedHere = true; break; }
            if (!focusedHere) state.Current = windows[0].Handle;
        }

        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        bool hideOthers  = opts.GetExtraBool("hide_others", true);
        bool showBorders = opts.GetExtraBool("show_borders", false);
        var border = showBorders ? new BorderSpec(2, 0, 0, 0) : BorderSpec.None;

        for (int i = 0; i < windows.Count; i++)
        {
            var w = windows[i];
            bool isCurrent = w.Handle == state.Current;
            // Non-current windows still get a placement record so the
            // controller knows the engine is aware of them. Visible=false
            // means "do not OP_SHOW this frame".
            result.Add(new WindowPlacement(
                w.Handle,
                isCurrent ? area : Rect.Empty,
                isCurrent ? 1 : 0,
                isCurrent || !hideOthers,
                isCurrent ? border : BorderSpec.None));
        }
        return result;
    }
}

public sealed class MonocleLayoutFactory : ILayoutFactory
{
    private readonly MonocleLayout _shared = new();
    public string Id => "monocle";
    public string DisplayName => "Monocle (One-at-a-time)";
    public ILayoutEngine Create() => _shared;
}
