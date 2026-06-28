using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout.Builtin;

/// <summary>
/// Standard NxM grid: <c>cols = ceil(sqrt(N))</c>, <c>rows = ceil(N/cols)</c>. The last row may be
/// short; it is centred horizontally.
/// </summary>
public sealed class GridLayout : ILayoutEngine
{
    public string Id => "grid";

    /// <summary>
    /// Per-output positional array: <c>Order[i]</c> is the window handle occupying grid cell
    /// <c>i</c>. This mirrors <see cref="ScrollingLayout.ScrollState.Columns"/> and is the single
    /// source of truth for which window sits in which cell, surviving across <c>Arrange</c> calls so
    /// <see cref="MoveFocused"/> can swap cells (e.g. position 2 ↔ position 4).
    /// </summary>
    internal sealed class GridState
    {
        public readonly List<IntPtr> Order = [];
    }

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var state = perOutputState as GridState ?? new GridState();
        perOutputState = state;

        var result = new List<WindowPlacement>(windows.Count);
        if (windows.Count == 0)
        {
            state.Order.Clear();
            return result;
        }

        // Reconcile positional array with current windows: keep existing order, drop gone, append new.
        var live = new HashSet<IntPtr>();
        foreach (var w in windows)
        {
            live.Add(w.Handle);
        }

        state.Order.RemoveAll(h => !live.Contains(h));
        var existing = new HashSet<IntPtr>(state.Order);
        foreach (var w in windows)
        {
            if (!existing.Contains(w.Handle))
            {
                state.Order.Add(w.Handle);
            }
        }

        // Index by handle for O(1) lookup of WindowEntryView during placement.
        var byHandle = new Dictionary<IntPtr, WindowEntryView>(windows.Count);
        foreach (var w in windows)
        {
            byHandle[w.Handle] = w;
        }

        // Defensive: prune any handle not in the current snapshot so placement never throws on the
        // manage thread (mirror ScrollingLayout's guard against concurrent-manage races).
        for (int i = state.Order.Count - 1; i >= 0; i--)
        {
            if (!byHandle.ContainsKey(state.Order[i]))
            {
                state.Order.RemoveAt(i);
            }
        }

        int n = state.Order.Count;
        if (n == 0)
        {
            return result;
        }

        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        int cols = (int)Math.Ceiling(Math.Sqrt(n));
        int rows = (int)Math.Ceiling((double)n / cols);
        int gap = opts.GapsInner;

        int cellW = Math.Max(1, (area.W - gap * (cols - 1)) / cols);
        int cellH = Math.Max(1, (area.H - gap * (rows - 1)) / rows);

        for (int i = 0; i < n; i++)
        {
            int r = i / cols;
            int c = i % cols;
            // Centre last (potentially short) row.
            int rowItems = (r == rows - 1) ? n - r * cols : cols;
            int rowOffset = (r == rows - 1)
                ? (area.W - (rowItems * cellW + gap * (rowItems - 1))) / 2
                : 0;

            int x = area.X + rowOffset + c * (cellW + gap);
            int y = area.Y + r * (cellH + gap);
            result.Add(new WindowPlacement(
                state.Order[i], new Rect(x, y, cellW, cellH),
                0, true, opts.Border));
        }
        return result;
    }

    /// <summary>
    /// Swap the focused cell with its grid neighbour: horizontal moves swap <c>idx ± 1</c>, vertical
    /// moves swap <c>idx ± cols</c> (the cell directly above/below). Returns true on a successful
    /// swap so <c>ViewportInteractionService.MoveFocusedWindow</c> schedules a manage cycle.
    /// </summary>
    public bool MoveFocused(
        IntPtr output,
        IntPtr focused,
        FocusDirection dir,
        ref object? perOutputState)
    {
        var state = perOutputState as GridState;
        if (state == null || state.Order.Count < 2)
        {
            return false;
        }

        int idx = state.Order.IndexOf(focused);
        if (idx < 0)
        {
            return false;
        }

        int n = state.Order.Count;
        int cols = (int)Math.Ceiling(Math.Sqrt(n));

        int target = dir switch
        {
            FocusDirection.Left or FocusDirection.Prev => idx - 1,
            FocusDirection.Right or FocusDirection.Next => idx + 1,
            FocusDirection.Up => idx - cols,
            FocusDirection.Down => idx + cols,
            _ => idx,
        };

        // Down into a missing cell of the short last row (e.g. top-right of a 3-window 2×2 grid,
        // where the bottom-right cell is empty and the last window is centred): clamp to the last
        // existing window instead of rejecting the move so the swap matches what is on screen.
        if (dir == FocusDirection.Down && target >= n && idx < n - 1)
        {
            target = n - 1;
        }

        if (target < 0 || target >= n || target == idx)
        {
            return false;
        }

        (state.Order[idx], state.Order[target]) = (state.Order[target], state.Order[idx]);
        return true;
    }

    /// <summary>
    /// Swap two explicit cells in the positional array. Used by pointer-driven tiling reorder
    /// (Super + drag). Returns <c>true</c> when both handles are present and were swapped.
    /// </summary>
    public bool SwapWindows(
        IntPtr output,
        IntPtr a,
        IntPtr b,
        ref object? perOutputState)
    {
        var state = perOutputState as GridState;
        if (state == null || a == b)
        {
            return false;
        }

        int ia = state.Order.IndexOf(a);
        int ib = state.Order.IndexOf(b);
        if (ia < 0 || ib < 0)
        {
            return false;
        }

        (state.Order[ia], state.Order[ib]) = (state.Order[ib], state.Order[ia]);
        return true;
    }

    /// <summary>
    /// Move focus by grid geometry so <c>focus_*</c> is consistent with <see cref="MoveFocused"/>:
    /// horizontal steps by <c>±1</c>, vertical by <c>±cols</c>. The returned handle is live-checked
    /// against the current snapshot.
    /// </summary>
    public IntPtr? FocusNeighbor(
        IntPtr output,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        ref object? perOutputState)
    {
        var state = perOutputState as GridState;
        if (state == null || state.Order.Count == 0)
        {
            return null;
        }

        var live = new HashSet<IntPtr>();
        foreach (var w in windows)
        {
            live.Add(w.Handle);
        }

        int idx = state.Order.IndexOf(current);
        if (idx < 0)
        {
            return null;
        }

        int n = state.Order.Count;
        int cols = (int)Math.Ceiling(Math.Sqrt(n));

        int target = dir switch
        {
            FocusDirection.Left or FocusDirection.Prev => idx - 1,
            FocusDirection.Right or FocusDirection.Next => idx + 1,
            FocusDirection.Up => idx - cols,
            FocusDirection.Down => idx + cols,
            _ => idx,
        };

        // Mirror MoveFocused: clamp a Down into the empty cell of a short last row to the last
        // existing window so focus movement stays consistent with the swap behaviour.
        if (dir == FocusDirection.Down && target >= n && idx < n - 1)
        {
            target = n - 1;
        }

        if (target < 0 || target >= n || target == idx)
        {
            return null;
        }

        var h = state.Order[target];
        return live.Contains(h) ? h : (IntPtr?)null;
    }
}

public sealed class GridLayoutFactory : ILayoutFactory
{
    private readonly GridLayout _shared = new();
    public string Id => "grid";
    public string DisplayName => "Grid";
    public ILayoutEngine Create() => _shared;
}
