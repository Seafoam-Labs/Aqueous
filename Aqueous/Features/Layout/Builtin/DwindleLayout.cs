using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout.Builtin;

/// <summary>
/// Dwindle (spiral / Fibonacci) layout. Windows recursively subdivide the usable area: each window
/// except the last takes the primary cell of a split whose axis alternates every step (default
/// first split = vertical → left/right), and the rest recurse into the secondary cell. The last
/// window fills whatever remains. Outer gaps shrink the usable area once; inner gaps separate the
/// two cells at every split.
/// </summary>
public sealed class DwindleLayout : ILayoutEngine
{
    public string Id => "dwindle";

    internal sealed class DwindleState
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
        var state = perOutputState as DwindleState ?? new DwindleState();
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

        int n = state.Order.Count;
        if (n == 0)
        {
            return result;
        }

        var border = opts.Border;
        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        int gap = opts.GapsInner;
        bool vertical = !string.Equals(opts.GetExtra("dwindle.start_axis"), "horizontal",
            StringComparison.OrdinalIgnoreCase);
        double firstRatio = opts.MasterRatio;
        double restRatio = opts.GetExtraDouble("dwindle.split_ratio", 0.5);

        for (int i = 0; i < n; i++)
        {
            if (i == n - 1)
            {
                result.Add(new WindowPlacement(state.Order[i], area, 0, true, border));
                break;
            }

            double ratio = i == 0 ? firstRatio : restRatio;
            var (primary, remainder) = Split(area, vertical, ratio, gap);
            result.Add(new WindowPlacement(state.Order[i], primary, 0, true, border));
            area = remainder;
            vertical = !vertical;
        }

        return result;
    }

    public bool MoveFocused(
        IntPtr output,
        IntPtr focused,
        FocusDirection dir,
        ref object? perOutputState)
    {
        var state = perOutputState as DwindleState;
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
        int target = dir switch
        {
            FocusDirection.Up or FocusDirection.Left or FocusDirection.Prev => idx - 1,
            FocusDirection.Down or FocusDirection.Right or FocusDirection.Next => idx + 1,
            _ => idx,
        };

        if (target < 0 || target >= n || target == idx)
        {
            return false;
        }

        (state.Order[idx], state.Order[target]) = (state.Order[target], state.Order[idx]);
        return true;
    }

    public bool SwapWindows(
        IntPtr output,
        IntPtr a,
        IntPtr b,
        ref object? perOutputState)
    {
        var state = perOutputState as DwindleState;
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

    public IntPtr? FocusNeighbor(
        IntPtr output,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        ref object? perOutputState)
    {
        var state = perOutputState as DwindleState;
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
        int target = dir switch
        {
            FocusDirection.Up or FocusDirection.Left or FocusDirection.Prev => idx - 1,
            FocusDirection.Down or FocusDirection.Right or FocusDirection.Next => idx + 1,
            _ => idx,
        };

        if (target < 0 || target >= n || target == idx)
        {
            return null;
        }

        var h = state.Order[target];
        return live.Contains(h) ? h : (IntPtr?)null;
    }

    /// <summary>
    /// Splits <paramref name="area"/> into a primary cell and a remainder along the requested axis,
    /// reserving <paramref name="gap"/> pixels between them. The primary cell takes
    /// <paramref name="ratio"/> of the gap-adjusted extent. Both cells are floored to W/H ≥ 1 for
    /// degenerate inputs.
    /// </summary>
    private static (Rect Primary, Rect Remainder) Split(Rect area, bool vertical, double ratio, int gap)
    {
        if (vertical)
        {
            int avail = Math.Max(1, area.W - gap);
            int primaryW = Math.Max(1, (int)Math.Round(avail * ratio));
            primaryW = Math.Min(primaryW, avail);
            int remainderW = Math.Max(1, avail - primaryW);
            var primary = new Rect(area.X, area.Y, primaryW, area.H);
            var remainder = new Rect(area.X + primaryW + gap, area.Y, remainderW, area.H);
            return (primary, remainder);
        }
        else
        {
            int avail = Math.Max(1, area.H - gap);
            int primaryH = Math.Max(1, (int)Math.Round(avail * ratio));
            primaryH = Math.Min(primaryH, avail);
            int remainderH = Math.Max(1, avail - primaryH);
            var primary = new Rect(area.X, area.Y, area.W, primaryH);
            var remainder = new Rect(area.X, area.Y + primaryH + gap, area.W, remainderH);
            return (primary, remainder);
        }
    }
}

public sealed class DwindleLayoutFactory : ILayoutFactory
{
    private readonly DwindleLayout _shared = new();
    public string Id => "dwindle";
    public string DisplayName => "Dwindle (Spiral)";
    public ILayoutEngine Create() => _shared;
}
