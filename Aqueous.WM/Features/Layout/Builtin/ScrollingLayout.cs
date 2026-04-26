using System;
using System.Collections.Generic;

namespace Aqueous.WM.Features.Layout.Builtin;

/// <summary>
/// PaperWM-style horizontally-scrolling columns. Each window is one
/// column of width <c>area.W * options["column_width"]</c>; columns are
/// arranged left-to-right in a virtual strip and translated to screen
/// space by subtracting <c>viewportX</c>. Off-screen columns are returned
/// with <c>Visible=false</c>.
/// </summary>
public sealed class ScrollingLayout : ILayoutEngine
{
    public string Id => "scrolling";

    internal sealed class ScrollState
    {
        public readonly List<IntPtr> Columns = new();
        public int  ViewportX;
        public int  FocusedIdx;
    }

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var state = perOutputState as ScrollState ?? new ScrollState();
        perOutputState = state;

        var result = new List<WindowPlacement>(windows.Count);
        if (windows.Count == 0)
        {
            state.Columns.Clear();
            state.ViewportX = 0;
            state.FocusedIdx = 0;
            return result;
        }

        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);

        // Reconcile column order with current windows: keep existing order,
        // remove gone, append new.
        var live = new HashSet<IntPtr>();
        for (int i = 0; i < windows.Count; i++) live.Add(windows[i].Handle);
        state.Columns.RemoveAll(h => !live.Contains(h));
        var existing = new HashSet<IntPtr>(state.Columns);
        for (int i = 0; i < windows.Count; i++)
            if (!existing.Contains(windows[i].Handle))
                state.Columns.Add(windows[i].Handle);

        // Index by handle for O(1) lookup of WindowEntryView during placement.
        var byHandle = new Dictionary<IntPtr, WindowEntryView>(windows.Count);
        for (int i = 0; i < windows.Count; i++) byHandle[windows[i].Handle] = windows[i];

        double colFrac      = opts.GetExtraDouble("column_width", 0.5);
        bool   centerFocused = opts.GetExtraBool("center_focused", true);
        bool   snap          = opts.GetExtraBool("snap_to_columns", true);

        int colW = Math.Max(1, (int)Math.Round(area.W * colFrac));
        int gap  = opts.GapsInner;
        int step = colW + gap;

        // Defensive: prune any column whose handle is not in the
        // current snapshot. The reconciliation above already does this
        // for state.Columns, but a stale handle could re-enter via a
        // race with concurrent manage cycles. Use TryGetValue so a
        // missing handle is dropped instead of throwing
        // KeyNotFoundException (which would crash the manage thread).
        for (int i = state.Columns.Count - 1; i >= 0; i--)
            if (!byHandle.ContainsKey(state.Columns[i]))
                state.Columns.RemoveAt(i);
        if (state.Columns.Count == 0)
        {
            state.ViewportX = 0;
            state.FocusedIdx = 0;
            return result;
        }
        if (state.FocusedIdx >= state.Columns.Count) state.FocusedIdx = state.Columns.Count - 1;
        if (state.FocusedIdx < 0) state.FocusedIdx = 0;

        // Per-column width override for windows whose MinW exceeds colW.
        var colWidths = new int[state.Columns.Count];
        for (int i = 0; i < state.Columns.Count; i++)
        {
            if (!byHandle.TryGetValue(state.Columns[i], out var view))
            {
                colWidths[i] = colW;
                continue;
            }
            colWidths[i] = (view.MinW > colW) ? view.MinW : colW;
        }

        // Compute virtual X for each column accounting for per-column widths.
        var virtX = new int[state.Columns.Count];
        int cursor = 0;
        for (int i = 0; i < state.Columns.Count; i++)
        {
            virtX[i] = cursor;
            cursor += colWidths[i] + gap;
        }
        int totalW = cursor - gap; // last gap removed

        // Resolve focused index.
        for (int i = 0; i < state.Columns.Count; i++)
            if (state.Columns[i] == focusedWindow) { state.FocusedIdx = i; break; }
        if (state.FocusedIdx >= state.Columns.Count) state.FocusedIdx = state.Columns.Count - 1;
        if (state.FocusedIdx < 0) state.FocusedIdx = 0;

        if (centerFocused && state.Columns.Count > 0)
        {
            int focusCenter = virtX[state.FocusedIdx] + colWidths[state.FocusedIdx] / 2;
            state.ViewportX = focusCenter - area.W / 2;
        }

        // Snap.
        if (snap && step > 0)
            state.ViewportX = (int)Math.Round((double)state.ViewportX / step) * step;

        // Clamp.
        int maxViewport = Math.Max(0, totalW - area.W);
        if (state.ViewportX < 0)              state.ViewportX = 0;
        if (state.ViewportX > maxViewport)    state.ViewportX = maxViewport;

        for (int i = 0; i < state.Columns.Count; i++)
        {
            int screenX = area.X + virtX[i] - state.ViewportX;
            int w = colWidths[i];
            bool visible = (screenX + w > area.X) && (screenX < area.X + area.W);
            var rect = new Rect(screenX, area.Y, w, area.H);
            int z = (i == state.FocusedIdx) ? 1 : 0;
            result.Add(new WindowPlacement(state.Columns[i], rect, z, visible, BorderSpec.None));
        }
        return result;
    }

    public IntPtr? FocusNeighbor(
        IntPtr output,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        ref object? perOutputState)
    {
        var state = perOutputState as ScrollState;
        if (state == null || state.Columns.Count == 0) return null;

        // Live set so we don't return a handle that isn't in the snapshot.
        var live = new HashSet<IntPtr>();
        for (int i = 0; i < windows.Count; i++) live.Add(windows[i].Handle);

        int idx = state.Columns.IndexOf(current);
        if (idx < 0) idx = state.FocusedIdx;
        if (idx < 0 || idx >= state.Columns.Count) return null;

        int step = dir switch
        {
            FocusDirection.Left  or FocusDirection.Prev => -1,
            FocusDirection.Right or FocusDirection.Next => +1,
            _ => 0, // up/down: scrolling has no vertical ordering
        };
        if (step == 0) return null;

        int next = idx + step;
        if (next < 0 || next >= state.Columns.Count) return null;
        var h = state.Columns[next];
        return live.Contains(h) ? h : (IntPtr?)null;
    }

    public bool MoveFocused(
        IntPtr output,
        IntPtr focused,
        FocusDirection dir,
        ref object? perOutputState)
    {
        var state = perOutputState as ScrollState;
        if (state == null || state.Columns.Count < 2) return false;

        int idx = state.Columns.IndexOf(focused);
        if (idx < 0) return false;

        int step = dir switch
        {
            FocusDirection.Left  or FocusDirection.Prev => -1,
            FocusDirection.Right or FocusDirection.Next => +1,
            _ => 0,
        };
        if (step == 0) return false;

        int target = idx + step;
        if (target < 0 || target >= state.Columns.Count) return false;

        (state.Columns[idx], state.Columns[target]) = (state.Columns[target], state.Columns[idx]);
        state.FocusedIdx = target;
        return true;
    }

    public void ScrollViewport(
        IntPtr output,
        int deltaColumns,
        ref object? perOutputState)
    {
        var state = perOutputState as ScrollState;
        if (state == null || state.Columns.Count == 0) return;
        // We don't know colW here without the area + opts; use the
        // FocusedIdx as a coarse proxy: shift focused index by delta and
        // let the next Arrange recenter the viewport.
        int next = state.FocusedIdx + deltaColumns;
        if (next < 0) next = 0;
        if (next >= state.Columns.Count) next = state.Columns.Count - 1;
        state.FocusedIdx = next;
    }
}

public sealed class ScrollingLayoutFactory : ILayoutFactory
{
    private readonly ScrollingLayout _shared = new();
    public string Id => "scrolling";
    public string DisplayName => "Scrolling (PaperWM)";
    public ILayoutEngine Create() => _shared;
}
