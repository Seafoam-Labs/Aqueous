using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Aqueous.Features.Layout.Builtin;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Phase 3 — coverage tests for <see cref="ScrollingLayout"/>. The engine
/// is pure (state lives in the <c>perOutputState</c> bag passed in by
/// reference) so these tests need no compositor fixture.
/// </summary>
public class ScrollingLayoutTests
{
    private static WindowEntryView MakeWin(int handle, int minW = 0)
        => new(new IntPtr(handle), minW, 0, 0, 0, false, false, 0u);

    private static LayoutOptions Opts(
        int inner = 0,
        int outer = 0,
        Dictionary<string, string>? extra = null)
        => new(outer, inner, 0.55, 1, extra ?? new Dictionary<string, string>());

    private static readonly Rect Area = new(0, 0, 1000, 800);

    // covers Arrange empty-input fast-path
    [Fact]
    public void Arrange_NoWindows_ReturnsEmpty_AndResetsState()
    {
        var engine = new ScrollingLayout();
        object? state = null;
        var r = engine.Arrange(Area, Array.Empty<WindowEntryView>(), IntPtr.Zero, Opts(), ref state);
        Assert.Empty(r);
        Assert.NotNull(state);
    }

    // covers normal arrange path: column width derived from "column_width"
    // extra and centering on focused window.
    [Fact]
    public void Arrange_AssignsColumnWidth_FromExtra()
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        var extra = new Dictionary<string, string> { ["column_width"] = "0.4" };
        object? state = null;
        var r = engine.Arrange(Area, wins, new IntPtr(1), Opts(extra: extra), ref state);
        Assert.Equal(3, r.Count);
        // column width = 1000 * 0.4 = 400
        Assert.All(r, p => Assert.Equal(400, p.Geometry.W));
        // focused window (handle 1) is at idx 0 and gets ZOrder 1
        Assert.Equal(1, r[0].ZOrder);
        Assert.Equal(0, r[1].ZOrder);
    }

    // covers MinW override: a window whose MinW exceeds colW gets its MinW.
    [Fact]
    public void Arrange_RespectsMinWOverride()
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2, minW: 700) };
        object? state = null;
        var r = engine.Arrange(Area, wins, new IntPtr(1), Opts(), ref state);
        Assert.Equal(700, r[1].Geometry.W);
    }

    // covers reconciliation path: removed handles drop out of the column
    // ordering on the next Arrange.
    [Fact]
    public void Arrange_DropsRemovedHandles_OnReconcile()
    {
        var engine = new ScrollingLayout();
        object? state = null;
        var first = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        engine.Arrange(Area, first, new IntPtr(1), Opts(), ref state);

        var second = new List<WindowEntryView> { MakeWin(1), MakeWin(3) };
        var r = engine.Arrange(Area, second, new IntPtr(1), Opts(), ref state);
        Assert.Equal(2, r.Count);
        Assert.Contains(r, p => p.Handle == new IntPtr(1));
        Assert.Contains(r, p => p.Handle == new IntPtr(3));
    }

    // covers FocusNeighbor null-state guard
    [Fact]
    public void FocusNeighbor_ReturnsNull_WhenStateMissing()
    {
        var engine = new ScrollingLayout();
        object? state = null;
        var r = engine.FocusNeighbor(IntPtr.Zero, IntPtr.Zero, FocusDirection.Right,
            Array.Empty<WindowEntryView>(), ref state);
        Assert.Null(r);
    }

    // covers FocusNeighbor left/right/prev/next stepping
    [Theory]
    [InlineData(FocusDirection.Right, 2, 3)]
    [InlineData(FocusDirection.Next, 2, 3)]
    [InlineData(FocusDirection.Left, 2, 1)]
    [InlineData(FocusDirection.Prev, 2, 1)]
    public void FocusNeighbor_StepsHorizontally(FocusDirection dir, int from, int expected)
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        object? state = null;
        engine.Arrange(Area, wins, new IntPtr(from), Opts(), ref state);
        var r = engine.FocusNeighbor(IntPtr.Zero, new IntPtr(from), dir, wins, ref state);
        Assert.Equal(new IntPtr(expected), r);
    }

    // covers FocusNeighbor vertical/edge null returns
    [Theory]
    [InlineData(FocusDirection.Up)]
    [InlineData(FocusDirection.Down)]
    public void FocusNeighbor_VerticalDirections_ReturnNull(FocusDirection dir)
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;
        engine.Arrange(Area, wins, new IntPtr(1), Opts(), ref state);
        var r = engine.FocusNeighbor(IntPtr.Zero, new IntPtr(1), dir, wins, ref state);
        Assert.Null(r);
    }

    // covers FocusNeighbor falling off the right edge
    [Fact]
    public void FocusNeighbor_OffEnd_ReturnsNull()
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;
        engine.Arrange(Area, wins, new IntPtr(2), Opts(), ref state);
        var r = engine.FocusNeighbor(IntPtr.Zero, new IntPtr(2), FocusDirection.Right, wins, ref state);
        Assert.Null(r);
    }

    // covers MoveFocused swap + early-out when fewer than 2 columns
    [Fact]
    public void MoveFocused_SwapsAdjacentColumns()
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        object? state = null;
        engine.Arrange(Area, wins, new IntPtr(2), Opts(), ref state);
        var moved = engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Right, ref state);
        Assert.True(moved);
        // After swap, re-arranging keeps the new order; col index of 2 is now 2.
        var r = engine.Arrange(Area, wins, new IntPtr(2), Opts(), ref state);
        Assert.Equal(new IntPtr(1), r[0].Handle);
        Assert.Equal(new IntPtr(3), r[1].Handle);
        Assert.Equal(new IntPtr(2), r[2].Handle);
    }

    [Fact]
    public void MoveFocused_NoState_ReturnsFalse()
    {
        var engine = new ScrollingLayout();
        object? state = null;
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state));
    }

    [Fact]
    public void MoveFocused_VerticalDir_ReturnsFalse()
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;
        engine.Arrange(Area, wins, new IntPtr(1), Opts(), ref state);
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Up, ref state));
    }

    [Fact]
    public void MoveFocused_OffEnd_ReturnsFalse()
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;
        engine.Arrange(Area, wins, new IntPtr(2), Opts(), ref state);
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Right, ref state));
    }

    // covers ScrollViewport clamping to [0, count-1]
    [Fact]
    public void ScrollViewport_ClampsFocusedIndex()
    {
        var engine = new ScrollingLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        object? state = null;
        engine.Arrange(Area, wins, new IntPtr(1), Opts(), ref state);

        engine.ScrollViewport(IntPtr.Zero, +99, ref state);
        // After re-arrange the focused index should clamp to last column (3).
        var r = engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);
        Assert.Equal(1, r[2].ZOrder);

        engine.ScrollViewport(IntPtr.Zero, -99, ref state);
        r = engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);
        Assert.Equal(1, r[0].ZOrder);
    }

    [Fact]
    public void ScrollViewport_NoState_NoThrow()
    {
        var engine = new ScrollingLayout();
        object? state = null;
        engine.ScrollViewport(IntPtr.Zero, 1, ref state);
        Assert.Null(state);
    }

    [Fact]
    public void Factory_CreatesSharedSingleton()
    {
        var f = new ScrollingLayoutFactory();
        Assert.Equal("scrolling", f.Id);
        Assert.Equal("Scrolling (PaperWM)", f.DisplayName);
        Assert.Same(f.Create(), f.Create());
    }
}
