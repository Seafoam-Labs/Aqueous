using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout.Builtin;

/// <summary>
/// Master / stack layout. Master area on the left of width <c>opts.MasterRatio * usableW</c>
/// stacks <c>opts.MasterCount</c> windows vertically; the remaining stack fills the right-hand
/// side. Outer gaps shrink the usable area once; inner gaps separate splits.
/// </summary>
public sealed class TileLayout : ILayoutEngine
{
    public string Id => "tile";

    internal sealed class TileState
    {
        public readonly List<IntPtr> Order = [];
        public int MasterCount = 1;
    }

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var state = perOutputState as TileState ?? new TileState();
        perOutputState = state;

        var result = new List<WindowPlacement>(windows.Count);
        if (windows.Count == 0)
        {
            state.Order.Clear();
            return result;
        }

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

        var byHandle = new Dictionary<IntPtr, WindowEntryView>(windows.Count);
        foreach (var w in windows)
        {
            byHandle[w.Handle] = w;
        }

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
        int masterCount = Math.Max(1, Math.Min(opts.MasterCount, n));
        state.MasterCount = masterCount;

        var border = opts.Border;

        if (n == 1)
        {
            result.Add(new WindowPlacement(byHandle[state.Order[0]].Handle, area, 0, true, border));
            return result;
        }

        int stackCount = n - masterCount;
        int masterW = stackCount == 0
            ? area.W
            : Math.Max(1, (int)Math.Round(area.W * opts.MasterRatio));
        int stackW = stackCount == 0 ? 0 : Math.Max(1, area.W - masterW - opts.GapsInner);

        SplitVertical(area.X, area.Y, masterW, area.H,
            masterCount, opts.GapsInner, state.Order, 0, result, border);

        if (stackCount > 0)
        {
            int stackX = area.X + masterW + opts.GapsInner;
            SplitVertical(stackX, area.Y, stackW, area.H,
                stackCount, opts.GapsInner, state.Order, masterCount, result, border);
        }
        return result;
    }

    public bool MoveFocused(
        IntPtr output,
        IntPtr focused,
        FocusDirection dir,
        ref object? perOutputState)
    {
        var state = perOutputState as TileState;
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
        int masterCount = Math.Max(1, Math.Min(state.MasterCount, n));

        int target = dir switch
        {
            FocusDirection.Up or FocusDirection.Prev => idx - 1,
            FocusDirection.Down or FocusDirection.Next => idx + 1,
            FocusDirection.Left => idx - masterCount,
            FocusDirection.Right => idx + masterCount,
            _ => idx,
        };

        if (target < 0 || target >= n || target == idx)
        {
            return false;
        }

        (state.Order[idx], state.Order[target]) = (state.Order[target], state.Order[idx]);
        return true;
    }

    public IntPtr? FocusNeighbor(
        IntPtr output,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        ref object? perOutputState)
    {
        var state = perOutputState as TileState;
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
        int masterCount = Math.Max(1, Math.Min(state.MasterCount, n));

        int target = dir switch
        {
            FocusDirection.Up or FocusDirection.Prev => idx - 1,
            FocusDirection.Down or FocusDirection.Next => idx + 1,
            FocusDirection.Left => idx - masterCount,
            FocusDirection.Right => idx + masterCount,
            _ => idx,
        };

        if (target < 0 || target >= n || target == idx)
        {
            return null;
        }

        var h = state.Order[target];
        return live.Contains(h) ? h : (IntPtr?)null;
    }

    private static void SplitVertical(
        int x, int y, int w, int totalH,
        int count, int gap,
        List<IntPtr> order, int offset,
        List<WindowPlacement> result, BorderSpec border)
    {
        var rows = LayoutMath.SplitAxis(totalH, count, gap);
        for (int i = 0; i < rows.Count; i++)
        {
            var (dy, h) = rows[i];
            var rect = new Rect(x, y + dy, w, h);
            result.Add(new WindowPlacement(order[offset + i], rect, 0, true, border));
        }
    }
}

public sealed class TileLayoutFactory : ILayoutFactory
{
    private readonly TileLayout _shared = new();
    public string Id => "tile";
    public string DisplayName => "Tile (Master / Stack)";
    public ILayoutEngine Create() => _shared;
}
