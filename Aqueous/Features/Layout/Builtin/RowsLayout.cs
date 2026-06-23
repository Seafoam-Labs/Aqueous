using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout.Builtin;

public sealed class RowsLayout : ILayoutEngine
{
    public string Id => "rows";

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var result = new List<WindowPlacement>(windows.Count);
        int n = windows.Count;
        if (n == 0)
        {
            return result;
        }

        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        var border = opts.Border;
        int gap = opts.GapsInner;

        int topCount = (n + 1) / 2;
        int bottomCount = n - topCount;

        if (topCount == 0 || bottomCount == 0)
        {
            PlaceRow(area, windows, 0, n, gap, border, result);
            return result;
        }

        var bands = LayoutMath.SplitAxis(area.H, 2, gap);
        var (topDy, topH) = bands[0];
        var (botDy, botH) = bands[1];

        var topArea = new Rect(area.X, area.Y + topDy, area.W, topH);
        var bottomArea = new Rect(area.X, area.Y + botDy, area.W, botH);

        PlaceRow(topArea, windows, 0, topCount, gap, border, result);
        PlaceRow(bottomArea, windows, topCount, bottomCount, gap, border, result);
        return result;
    }

    private static void PlaceRow(
        Rect row,
        IReadOnlyList<WindowEntryView> windows,
        int offset, int count,
        int gap, BorderSpec border,
        List<WindowPlacement> result)
    {
        if (count <= 0)
        {
            return;
        }

        var cols = LayoutMath.SplitAxis(row.W, count, gap);
        for (int i = 0; i < cols.Count; i++)
        {
            var (dx, w) = cols[i];
            var rect = new Rect(row.X + dx, row.Y, w, row.H);
            result.Add(new WindowPlacement(
                windows[offset + i].Handle, rect, 0, true, border));
        }
    }
}

public sealed class RowsLayoutFactory : ILayoutFactory
{
    private readonly RowsLayout _shared = new();
    public string Id => "rows";
    public string DisplayName => "Rows (max two horizontal bands)";
    public ILayoutEngine Create() => _shared;
}
