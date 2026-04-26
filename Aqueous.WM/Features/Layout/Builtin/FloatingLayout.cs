using System;
using System.Collections.Generic;

namespace Aqueous.WM.Features.Layout.Builtin;

/// <summary>
/// "Float-as-layout": every window keeps its remembered <c>FloatRect</c>;
/// brand-new windows get a centred <c>min(800, area.W*0.6) × min(600, area.H*0.6)</c>
/// initial rect. The rect is stored per-window in the layout's per-output
/// state so it survives across <c>Arrange</c> calls (and is reused by the
/// future toggle-float feature).
/// </summary>
public sealed class FloatingLayout : ILayoutEngine
{
    public string Id => "float";

    private sealed class State
    {
        public readonly Dictionary<IntPtr, Rect> Rects = new();
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

        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        var result = new List<WindowPlacement>(windows.Count);

        int initW = Math.Min(800, (int)(area.W * 0.6));
        int initH = Math.Min(600, (int)(area.H * 0.6));
        int initX = area.X + (area.W - initW) / 2;
        int initY = area.Y + (area.H - initH) / 2;

        for (int i = 0; i < windows.Count; i++)
        {
            var w = windows[i];
            if (!state.Rects.TryGetValue(w.Handle, out var r))
            {
                r = new Rect(initX, initY, initW, initH);
                state.Rects[w.Handle] = r;
            }
            int z = (w.Handle == focusedWindow) ? 1 : 0;
            result.Add(new WindowPlacement(w.Handle, r, z, true, BorderSpec.None));
        }

        // Garbage-collect rectangles for windows that disappeared.
        if (state.Rects.Count > windows.Count)
        {
            var live = new HashSet<IntPtr>();
            for (int i = 0; i < windows.Count; i++) live.Add(windows[i].Handle);
            var stale = new List<IntPtr>();
            foreach (var k in state.Rects.Keys)
                if (!live.Contains(k)) stale.Add(k);
            foreach (var k in stale) state.Rects.Remove(k);
        }
        return result;
    }
}

public sealed class FloatingLayoutFactory : ILayoutFactory
{
    private readonly FloatingLayout _shared = new();
    public string Id => "float";
    public string DisplayName => "Floating";
    public ILayoutEngine Create() => _shared;
}
