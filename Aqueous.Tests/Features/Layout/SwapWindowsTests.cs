using System;
using System.Collections.Generic;
using System.Linq;
using Aqueous.Features.Layout;
using Aqueous.Features.Layout.Builtin;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Coverage for the pointer-driven <c>SwapWindows</c> primitive added for Super+LMB tiling
/// reorder. Engines with an explicit ordering (tile / grid / scrolling / dwindle / monocle /
/// game-mode) must swap two explicit handles' slots and reflect the swap in the next arrange;
/// order-less engines (floating) keep the interface default no-op.
/// </summary>
public class SwapWindowsTests
{
    private static readonly Rect Area = new(0, 0, 1920, 1080);

    private static WindowEntryView View(int handle) => new(
        Handle: new IntPtr(handle),
        MinW: 0, MinH: 0, MaxW: 0, MaxH: 0,
        Floating: false, Fullscreen: false, Tags: 1u);

    private static List<WindowEntryView> Views(params int[] handles)
        => handles.Select(View).ToList();

    private static Rect GeometryOf(IReadOnlyList<WindowPlacement> placements, int handle)
        => placements.First(p => p.Handle == new IntPtr(handle)).Geometry;

    [Fact]
    public void Tile_SwapWindows_SwapsGeometryOfTwoHandles()
    {
        var engine = new TileLayout();
        object? state = null;
        var before = engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);
        var rect1 = GeometryOf(before, 1);
        var rect3 = GeometryOf(before, 3);

        Assert.True(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(3), ref state));

        var after = engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);
        Assert.Equal(rect3, GeometryOf(after, 1));
        Assert.Equal(rect1, GeometryOf(after, 3));
    }

    [Fact]
    public void Tile_SwapWindows_UnknownHandle_ReturnsFalse()
    {
        var engine = new TileLayout();
        object? state = null;
        engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);

        Assert.False(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(0xDEAD), ref state));
    }

    [Fact]
    public void Tile_SwapWindows_SameHandle_ReturnsFalse()
    {
        var engine = new TileLayout();
        object? state = null;
        engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);

        Assert.False(engine.SwapWindows(IntPtr.Zero, new IntPtr(2), new IntPtr(2), ref state));
    }

    [Fact]
    public void Tile_SwapWindows_NoState_ReturnsFalse()
    {
        var engine = new TileLayout();
        object? state = null;
        Assert.False(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(2), ref state));
    }

    [Fact]
    public void Grid_SwapWindows_SwapsGeometryOfTwoHandles()
    {
        var engine = new GridLayout();
        object? state = null;
        var before = engine.Arrange(Area, Views(1, 2, 3, 4), new IntPtr(1), LayoutOptions.Default, ref state);
        var rect1 = GeometryOf(before, 1);
        var rect4 = GeometryOf(before, 4);

        Assert.True(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(4), ref state));

        var after = engine.Arrange(Area, Views(1, 2, 3, 4), new IntPtr(1), LayoutOptions.Default, ref state);
        Assert.Equal(rect4, GeometryOf(after, 1));
        Assert.Equal(rect1, GeometryOf(after, 4));
    }

    [Fact]
    public void Scrolling_SwapWindows_SwapsColumnOrder()
    {
        var engine = new ScrollingLayout();
        object? state = null;
        // ScrollingLayout positions columns relative to a scrolling viewport, so exact rects are
        // not stable across a swap; assert the left-to-right *ordering* of the two columns flips.
        var before = engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);
        Assert.True(GeometryOf(before, 1).X < GeometryOf(before, 3).X);

        Assert.True(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(3), ref state));

        var after = engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);
        Assert.True(GeometryOf(after, 3).X < GeometryOf(after, 1).X);
    }

    [Fact]
    public void Dwindle_SwapWindows_SwapsGeometryOfTwoHandles()
    {
        var engine = new DwindleLayout();
        object? state = null;
        var before = engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);
        var rect1 = GeometryOf(before, 1);
        var rect3 = GeometryOf(before, 3);

        Assert.True(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(3), ref state));

        var after = engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);
        Assert.Equal(rect3, GeometryOf(after, 1));
        Assert.Equal(rect1, GeometryOf(after, 3));
    }

    [Fact]
    public void Monocle_SwapWindows_BothKnown_ReturnsTrue()
    {
        var engine = new MonocleLayout();
        object? state = null;
        engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);

        Assert.True(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(3), ref state));
        Assert.False(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(0xDEAD), ref state));
    }

    [Fact]
    public void Floating_SwapWindows_AlwaysReturnsFalse()
    {
        ILayoutEngine engine = new FloatingLayout();
        object? state = null;
        engine.Arrange(Area, Views(1, 2, 3), new IntPtr(1), LayoutOptions.Default, ref state);

        // FloatingLayout relies on the interface default no-op, only reachable via the interface.
        Assert.False(engine.SwapWindows(IntPtr.Zero, new IntPtr(1), new IntPtr(3), ref state));
    }
}
