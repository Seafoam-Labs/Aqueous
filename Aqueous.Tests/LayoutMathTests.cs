using System;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Boundary tests for <see cref="LayoutMath"/>. These pin the contract
/// that custom plugin layouts will lean on, so every helper is verified
/// against degenerate input as well as the happy path.
/// </summary>
public class LayoutMathTests
{
    [Fact]
    public void Shrink_ZeroMargin_IsIdentity()
    {
        var r = new Rect(10, 20, 100, 80);
        Assert.Equal(r, LayoutMath.Shrink(r, 0));
        Assert.Equal(r, LayoutMath.Shrink(r, -5));
    }

    [Fact]
    public void Shrink_LargeMargin_FloorsToOne()
    {
        var r = new Rect(0, 0, 10, 10);
        var s = LayoutMath.Shrink(r, 1000);
        Assert.Equal(1, s.W);
        Assert.Equal(1, s.H);
    }

    [Fact]
    public void Shrink_PositiveMargin_ShrinksAllSides()
    {
        var r = new Rect(10, 20, 100, 80);
        var s = LayoutMath.Shrink(r, 5);
        Assert.Equal(new Rect(15, 25, 90, 70), s);
    }

    [Fact]
    public void SplitAxis_ZeroCount_ReturnsEmpty()
    {
        var cells = LayoutMath.SplitAxis(100, 0, 4);
        Assert.Empty(cells);
    }

    [Fact]
    public void SplitAxis_OneCell_FillsLength()
    {
        var cells = LayoutMath.SplitAxis(100, 1, 4);
        Assert.Single(cells);
        Assert.Equal((0, 100), cells[0]);
    }

    [Fact]
    public void SplitAxis_EvenSplit_DistributesLeftoverToLastCell()
    {
        // 100 - 2*4 (gaps) = 92; 92 / 3 = 30 remainder 2 → last cell 32.
        var cells = LayoutMath.SplitAxis(100, 3, 4);
        Assert.Equal(3, cells.Count);
        Assert.Equal((0, 30), cells[0]);
        Assert.Equal((34, 30), cells[1]);
        Assert.Equal((68, 32), cells[2]);
    }

    [Fact]
    public void SplitAxis_NoGap_CoversLengthExactly()
    {
        var cells = LayoutMath.SplitAxis(100, 4, 0);
        int sum = 0;
        for (int i = 0; i < cells.Count; i++)
        {
            sum += cells[i].Size;
        }

        Assert.Equal(100, sum);
    }

    [Fact]
    public void ClampToHints_HonoursMin()
    {
        var r = new Rect(0, 0, 50, 50);
        var w = MakeView(minW: 100, minH: 80);
        var c = LayoutMath.ClampToHints(r, w);
        Assert.Equal(100, c.W);
        Assert.Equal(80, c.H);
    }

    [Fact]
    public void ClampToHints_HonoursMax()
    {
        var r = new Rect(0, 0, 500, 500);
        var w = MakeView(maxW: 200, maxH: 150);
        var c = LayoutMath.ClampToHints(r, w);
        Assert.Equal(200, c.W);
        Assert.Equal(150, c.H);
    }

    [Fact]
    public void ClampToHints_ZeroHintsAreUnbounded()
    {
        var r = new Rect(0, 0, 500, 500);
        var w = MakeView();
        Assert.Equal(r, LayoutMath.ClampToHints(r, w));
    }

    private static WindowEntryView MakeView(int minW = 0, int minH = 0, int maxW = 0, int maxH = 0) =>
        new(new IntPtr(1), minW, minH, maxW, maxH, false, false, 0u);
}
