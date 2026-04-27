using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout.Builtin;

/// <summary>
/// Master / stack layout. Master area on the left of width
/// <c>opts.MasterRatio * usableW</c> stacks <c>opts.MasterCount</c>
/// windows vertically; the remaining stack fills the right-hand side.
/// Outer gaps shrink the usable area once; inner gaps separate splits.
/// </summary>
public sealed class TileLayout : ILayoutEngine
{
    public string Id => "tile";

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var result = new List<WindowPlacement>(windows.Count);
        if (windows.Count == 0)
        {
            return result;
        }

        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        int n = windows.Count;
        int masterCount = Math.Max(1, Math.Min(opts.MasterCount, n));

        // Single window → fill.
        if (n == 1)
        {
            result.Add(new WindowPlacement(windows[0].Handle, area, 0, true, BorderSpec.None));
            return result;
        }

        int stackCount = n - masterCount;
        int masterW = stackCount == 0
            ? area.W
            : Math.Max(1, (int)Math.Round(area.W * opts.MasterRatio));
        int stackW = stackCount == 0 ? 0 : Math.Max(1, area.W - masterW - opts.GapsInner);

        // Master column.
        SplitVertical(area.X, area.Y, masterW, area.H,
            masterCount, opts.GapsInner, windows, 0, result);

        // Stack column.
        if (stackCount > 0)
        {
            int stackX = area.X + masterW + opts.GapsInner;
            SplitVertical(stackX, area.Y, stackW, area.H,
                stackCount, opts.GapsInner, windows, masterCount, result);
        }
        return result;
    }

    private static void SplitVertical(
        int x, int y, int w, int totalH,
        int count, int gap,
        IReadOnlyList<WindowEntryView> windows, int offset,
        List<WindowPlacement> result)
    {
        int totalGap = gap * (count - 1);
        int eachH = Math.Max(1, (totalH - totalGap) / count);
        int leftover = Math.Max(0, totalH - totalGap - eachH * count);
        int curY = y;
        for (int i = 0; i < count; i++)
        {
            int h = eachH + (i == count - 1 ? leftover : 0);
            var rect = new Rect(x, curY, w, h);
            result.Add(new WindowPlacement(windows[offset + i].Handle, rect, 0, true, BorderSpec.None));
            curY += h + gap;
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
