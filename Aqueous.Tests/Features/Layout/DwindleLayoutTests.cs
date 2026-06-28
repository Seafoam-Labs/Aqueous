using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Aqueous.Features.Layout.Builtin;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Engine-level tests for <see cref="DwindleLayout"/>: registry discoverability, the spiral
/// geometry (alternating axis, <c>master_ratio</c>, <c>split_ratio</c>, gaps), coverage / non-overlap
/// invariants, order stability across re-arranges, the config knobs, and the focus / move helpers.
/// </summary>
public class DwindleLayoutTests
{
    private static readonly Rect UA = new(0, 0, 1000, 1000);

    // ----- Helpers -----------------------------------------------------------

    private static WindowEntryView View(int handle)
        => new(
            Handle: new IntPtr(handle),
            MinW: 0, MinH: 0, MaxW: 0, MaxH: 0,
            Floating: false, Fullscreen: false, Tags: 1u);

    /// <summary>No-gap options with a clean 0.5 first-split ratio for exact-rect assertions.</summary>
    private static LayoutOptions Opts(
        int gapsOuter = 0,
        int gapsInner = 0,
        double masterRatio = 0.5,
        params (string Key, string Value)[] extra)
    {
        var dict = new Dictionary<string, string>();
        foreach (var (k, v) in extra)
        {
            dict[k] = v;
        }

        return new LayoutOptions(gapsOuter, gapsInner, masterRatio, 1, dict);
    }

    private static List<WindowEntryView> Views(params int[] handles)
    {
        var list = new List<WindowEntryView>(handles.Length);
        foreach (var h in handles)
        {
            list.Add(View(h));
        }

        return list;
    }

    // ----- Registry / discoverability ----------------------------------------

    [Fact]
    public void Registry_ContainsDwindleFactory_ById()
    {
        var reg = new LayoutRegistry();
        Assert.True(reg.Contains("dwindle"));
        Assert.True(reg.Contains("DWINDLE")); // case-insensitive
        var engine = reg.Create("dwindle");
        Assert.IsType<DwindleLayout>(engine);
        Assert.Equal("dwindle", engine.Id);
    }

    // ----- Empty / single ----------------------------------------------------

    [Fact]
    public void Arrange_Empty_ReturnsEmpty()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, new List<WindowEntryView>(), IntPtr.Zero, Opts(), ref state);
        Assert.Empty(result);
    }

    [Fact]
    public void Arrange_Single_FillsUsableArea()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1), IntPtr.Zero, Opts(), ref state);

        Assert.Single(result);
        Assert.Equal(new IntPtr(1), result[0].Handle);
        Assert.Equal(UA, result[0].Geometry);
        Assert.True(result[0].Visible);
        Assert.Equal(0, result[0].ZOrder);
    }

    [Fact]
    public void Arrange_Single_RespectsOuterGaps()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1), IntPtr.Zero, Opts(gapsOuter: 10), ref state);

        Assert.Single(result);
        Assert.Equal(new Rect(10, 10, 980, 980), result[0].Geometry);
    }

    // ----- Two / three / four windows: exact spiral geometry -----------------

    [Fact]
    public void Arrange_Two_VerticalSplitByMasterRatio()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1, 2), IntPtr.Zero, Opts(masterRatio: 0.5), ref state);

        Assert.Equal(2, result.Count);
        Assert.Equal(new Rect(0, 0, 500, 1000), result[0].Geometry);
        Assert.Equal(new Rect(500, 0, 500, 1000), result[1].Geometry);
    }

    [Fact]
    public void Arrange_Two_MasterRatioControlsFirstSplit()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1, 2), IntPtr.Zero, Opts(masterRatio: 0.7), ref state);

        Assert.Equal(new Rect(0, 0, 700, 1000), result[0].Geometry);
        Assert.Equal(new Rect(700, 0, 300, 1000), result[1].Geometry);
    }

    [Fact]
    public void Arrange_Three_AlternatesToHorizontalSplit()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1, 2, 3), IntPtr.Zero, Opts(masterRatio: 0.5), ref state);

        Assert.Equal(3, result.Count);
        Assert.Equal(new Rect(0, 0, 500, 1000), result[0].Geometry);   // first window, left half
        Assert.Equal(new Rect(500, 0, 500, 500), result[1].Geometry);  // horizontal split top
        Assert.Equal(new Rect(500, 500, 500, 500), result[2].Geometry); // remainder fills bottom
    }

    [Fact]
    public void Arrange_Four_SpiralsWithAlternatingAxis()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1, 2, 3, 4), IntPtr.Zero, Opts(masterRatio: 0.5), ref state);

        Assert.Equal(4, result.Count);
        Assert.Equal(new Rect(0, 0, 500, 1000), result[0].Geometry);
        Assert.Equal(new Rect(500, 0, 500, 500), result[1].Geometry);
        Assert.Equal(new Rect(500, 500, 250, 500), result[2].Geometry); // vertical split, primary
        Assert.Equal(new Rect(750, 500, 250, 500), result[3].Geometry); // remainder
    }

    // ----- Gaps --------------------------------------------------------------

    [Fact]
    public void Arrange_Two_HonoursOuterAndInnerGaps()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1, 2), IntPtr.Zero,
            Opts(gapsOuter: 10, gapsInner: 4, masterRatio: 0.5), ref state);

        // Usable shrinks to (10,10,980,980); inner gap of 4 separates the two cells.
        Assert.Equal(new Rect(10, 10, 488, 980), result[0].Geometry);
        Assert.Equal(new Rect(502, 10, 488, 980), result[1].Geometry);
        // primary right (498) + inner gap (4) == remainder left (502).
        Assert.Equal(result[0].Geometry.Right + 4, result[1].Geometry.X);
    }

    // ----- Coverage / non-overlap invariants ---------------------------------

    [Fact]
    public void Arrange_ManyWindows_NonOverlappingAndWithinUsable()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var windows = Views(1, 2, 3, 4, 5, 6);
        var result = engine.Arrange(UA, windows, IntPtr.Zero, Opts(masterRatio: 0.5), ref state);

        Assert.Equal(6, result.Count);
        foreach (var p in result)
        {
            Assert.True(p.Geometry.W >= 1 && p.Geometry.H >= 1);
            Assert.True(p.Geometry.X >= UA.X && p.Geometry.Y >= UA.Y);
            Assert.True(p.Geometry.Right <= UA.Right && p.Geometry.Bottom <= UA.Bottom);
        }

        for (int i = 0; i < result.Count; i++)
        {
            for (int j = i + 1; j < result.Count; j++)
            {
                var overlap = LayoutMath.Intersect(result[i].Geometry, result[j].Geometry);
                Assert.Equal(Rect.Empty, overlap);
            }
        }
    }

    [Fact]
    public void Arrange_Tiny_NoExceptionsAndPositiveCells()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var tiny = new Rect(0, 0, 3, 3);
        var result = engine.Arrange(tiny, Views(1, 2, 3, 4), IntPtr.Zero,
            Opts(gapsOuter: 2, gapsInner: 2, masterRatio: 0.5), ref state);

        Assert.Equal(4, result.Count);
        foreach (var p in result)
        {
            Assert.True(p.Geometry.W >= 1 && p.Geometry.H >= 1);
        }
    }

    // ----- Config knobs ------------------------------------------------------

    [Fact]
    public void Arrange_StartAxisHorizontal_FlipsFirstSplit()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1, 2), IntPtr.Zero,
            Opts(masterRatio: 0.5, extra: ("dwindle.start_axis", "horizontal")), ref state);

        Assert.Equal(new Rect(0, 0, 1000, 500), result[0].Geometry);
        Assert.Equal(new Rect(0, 500, 1000, 500), result[1].Geometry);
    }

    [Fact]
    public void Arrange_CustomSplitRatio_AffectsSubsequentSplits()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var result = engine.Arrange(UA, Views(1, 2, 3), IntPtr.Zero,
            Opts(masterRatio: 0.5, extra: ("dwindle.split_ratio", "0.25")), ref state);

        // First split unchanged (master_ratio 0.5); second (horizontal) split uses 0.25.
        Assert.Equal(new Rect(0, 0, 500, 1000), result[0].Geometry);
        Assert.Equal(new Rect(500, 0, 500, 250), result[1].Geometry);
        Assert.Equal(new Rect(500, 250, 500, 750), result[2].Geometry);
    }

    // ----- Order stability ---------------------------------------------------

    [Fact]
    public void Arrange_OrderIsStable_PrunesRemovedAndAppendsNew()
    {
        var engine = new DwindleLayout();
        object? state = null;

        var first = engine.Arrange(UA, Views(1, 2, 3), IntPtr.Zero, Opts(), ref state);
        Assert.Equal(new IntPtr(1), first[0].Handle);
        Assert.Equal(new IntPtr(2), first[1].Handle);
        Assert.Equal(new IntPtr(3), first[2].Handle);

        // Remove the middle handle: remaining order stays [1,3].
        var pruned = engine.Arrange(UA, Views(1, 3), IntPtr.Zero, Opts(), ref state);
        Assert.Equal(new IntPtr(1), pruned[0].Handle);
        Assert.Equal(new IntPtr(3), pruned[1].Handle);

        // Add a new handle: it is appended last.
        var appended = engine.Arrange(UA, Views(1, 3, 4), IntPtr.Zero, Opts(), ref state);
        Assert.Equal(new IntPtr(1), appended[0].Handle);
        Assert.Equal(new IntPtr(3), appended[1].Handle);
        Assert.Equal(new IntPtr(4), appended[2].Handle);
    }

    // ----- FocusNeighbor -----------------------------------------------------

    [Fact]
    public void FocusNeighbor_NextAndPrev_StepOneSlot()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var windows = Views(1, 2, 3, 4);
        engine.Arrange(UA, windows, IntPtr.Zero, Opts(), ref state);

        Assert.Equal(new IntPtr(2),
            engine.FocusNeighbor(IntPtr.Zero, new IntPtr(1), FocusDirection.Next, windows, ref state));
        Assert.Equal(new IntPtr(1),
            engine.FocusNeighbor(IntPtr.Zero, new IntPtr(2), FocusDirection.Prev, windows, ref state));
    }

    [Fact]
    public void FocusNeighbor_AtEnds_ReturnsNull()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var windows = Views(1, 2, 3);
        engine.Arrange(UA, windows, IntPtr.Zero, Opts(), ref state);

        Assert.Null(engine.FocusNeighbor(IntPtr.Zero, new IntPtr(1), FocusDirection.Prev, windows, ref state));
        Assert.Null(engine.FocusNeighbor(IntPtr.Zero, new IntPtr(3), FocusDirection.Next, windows, ref state));
    }

    // ----- MoveFocused -------------------------------------------------------

    [Fact]
    public void MoveFocused_Next_SwapsWithNeighbour()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var windows = Views(1, 2, 3);
        engine.Arrange(UA, windows, IntPtr.Zero, Opts(), ref state);

        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Next, ref state));

        var after = engine.Arrange(UA, windows, IntPtr.Zero, Opts(), ref state);
        Assert.Equal(new IntPtr(2), after[0].Handle);
        Assert.Equal(new IntPtr(1), after[1].Handle);
        Assert.Equal(new IntPtr(3), after[2].Handle);
    }

    [Fact]
    public void MoveFocused_AtEnds_ReturnsFalse()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var windows = Views(1, 2, 3);
        engine.Arrange(UA, windows, IntPtr.Zero, Opts(), ref state);

        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Prev, ref state));
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(3), FocusDirection.Next, ref state));
    }

    [Fact]
    public void MoveFocused_NoStateOrSingleWindow_ReturnsFalse()
    {
        var engine = new DwindleLayout();
        object? state = null;
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Next, ref state));

        engine.Arrange(UA, Views(1), IntPtr.Zero, Opts(), ref state);
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Next, ref state));
    }
}
