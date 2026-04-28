using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout.Builtin;

/// <summary>
/// Standard NxM grid: <c>cols = ceil(sqrt(N))</c>, <c>rows = ceil(N/cols)</c>.
/// The last row may be short; it is centred horizontally.
/// </summary>
public sealed class GridLayout : ILayoutEngine
{
    public string Id => "grid";

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
                windows[i].Handle, new Rect(x, y, cellW, cellH),
                0, true, BorderSpec.None));
        }
        return result;
    }
}

public sealed class GridLayoutFactory : ILayoutFactory
{
    private readonly GridLayout _shared = new();
    public string Id => "grid";
    public string DisplayName => "Grid";
    public ILayoutEngine Create() => _shared;
}
