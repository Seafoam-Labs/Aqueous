using System;
using System.Collections.Generic;
using System.IO;
using Aqueous.Features.Layout;
using Aqueous.Features.Layout.Builtin;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Acceptance tests from.1 plan section F. Engines are pure functions, so these tests require
/// neither a Wayland fixture nor a running compositor — exactly the property the architecture aims
/// for.
/// </summary>
public class LayoutTests
{
    private static WindowEntryView MakeWin(int handle, int minW = 0, int minH = 0, int maxW = 0, int maxH = 0)
        => new(new IntPtr(handle), minW, minH, maxW, maxH, false, false, 0u);

    private static LayoutOptions Opts(int outer = 0, int inner = 0, double ratio = 0.55, int masterCount = 1,
                                      Dictionary<string, string>? extra = null)
        => new(outer, inner, ratio, masterCount, extra ?? new Dictionary<string, string>());

    private static readonly Rect Area = new(0, 0, 1000, 800);

    // -- TileLayout ---------------------------------------------------

    [Fact]
    public void TileLayout_FourWindows_MasterCount1()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3), MakeWin(4) };
        object? state = null;

        var result = engine.Arrange(Area, wins, IntPtr.Zero, Opts(ratio: 0.5), ref state);

        Assert.Equal(4, result.Count);
        // Master takes ratio*W
        Assert.Equal(500, result[0].Geometry.W);
        Assert.Equal(800, result[0].Geometry.H);
        // Stack: 3 windows splitting 800h equally on the right side.
        Assert.Equal(500, result[1].Geometry.W);
        Assert.Equal(500, result[2].Geometry.W);
        Assert.Equal(500, result[3].Geometry.W);
        // Heights of 3 stack windows sum to total (no inner gap)
        var totalStackH = result[1].Geometry.H + result[2].Geometry.H + result[3].Geometry.H;
        Assert.Equal(800, totalStackH);
    }

    [Fact]
    public void TileLayout_RespectsOuterGaps()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;

        var result = engine.Arrange(Area, wins, IntPtr.Zero, Opts(outer: 10), ref state);

        foreach (var p in result)
        {
            Assert.True(p.Geometry.X >= 10);
            Assert.True(p.Geometry.Y >= 10);
            Assert.True(p.Geometry.Right <= 990);
            Assert.True(p.Geometry.Bottom <= 790);
        }
    }

    [Fact]
    public void TileLayout_SingleWindow_FillsArea()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1) };
        object? state = null;

        var result = engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        Assert.Single(result);
        Assert.Equal(new IntPtr(1), result[0].Handle);
        Assert.Equal(Area, result[0].Geometry);
    }

    [Fact]
    public void TileLayout_RespectsInnerGapBetweenMasterAndStack()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;

        var result = engine.Arrange(Area, wins, IntPtr.Zero, Opts(inner: 20, ratio: 0.5), ref state);

        var master = result[0].Geometry;
        var stack = result[1].Geometry;
        // The stack column starts one inner gap to the right of the master's right edge.
        Assert.Equal(master.Right + 20, stack.X);
    }

    [Fact]
    public void TileLayout_MasterCount2_PutsTwoWindowsInMasterColumn()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3), MakeWin(4) };
        object? state = null;

        var result = engine.Arrange(Area, wins, IntPtr.Zero, Opts(ratio: 0.5, masterCount: 2), ref state);

        Assert.Equal(4, result.Count);
        var byHandle = new Dictionary<IntPtr, Rect>();
        foreach (var p in result)
        {
            byHandle[p.Handle] = p.Geometry;
        }

        // Windows 1 & 2 share the master column (same X, masterW), windows 3 & 4 the stack column.
        Assert.Equal(byHandle[new IntPtr(1)].X, byHandle[new IntPtr(2)].X);
        Assert.Equal(byHandle[new IntPtr(1)].W, byHandle[new IntPtr(2)].W);
        Assert.Equal(byHandle[new IntPtr(3)].X, byHandle[new IntPtr(4)].X);
        Assert.Equal(byHandle[new IntPtr(3)].W, byHandle[new IntPtr(4)].W);
        Assert.NotEqual(byHandle[new IntPtr(1)].X, byHandle[new IntPtr(3)].X);
    }

    [Fact]
    public void TileLayout_MoveFocused_SwapsAdjacentInColumn()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3), MakeWin(4) };
        object? state = null;

        var first = engine.Arrange(Area, wins, IntPtr.Zero, Opts(ratio: 0.5), ref state);
        Rect cellOf(IReadOnlyList<WindowPlacement> ps, int handle)
        {
            foreach (var p in ps)
            {
                if (p.Handle == new IntPtr(handle)) return p.Geometry;
            }
            throw new Xunit.Sdk.XunitException($"handle {handle} not placed");
        }

        var stackSlot1 = cellOf(first, 2); // window 2 is first stack slot (index 1)

        // Move window 2 down → swaps with window 3 (index 1 ↔ 2).
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Down, ref state));

        var second = engine.Arrange(Area, wins, IntPtr.Zero, Opts(ratio: 0.5), ref state);
        // Window 3 now occupies what was window 2's slot.
        Assert.Equal(stackSlot1, cellOf(second, 3));
    }

    [Fact]
    public void TileLayout_MoveFocused_CrossesMasterStackBoundary()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        object? state = null;

        var first = engine.Arrange(Area, wins, IntPtr.Zero, Opts(ratio: 0.5, masterCount: 1), ref state);
        var masterX = first[0].Geometry.X;

        // Move window 2 (stack) Left by masterCount(=1) → into the master slot (index 1 → 0).
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Left, ref state));

        var second = engine.Arrange(Area, wins, IntPtr.Zero, Opts(ratio: 0.5, masterCount: 1), ref state);
        // Window 2 now sits in the master column.
        Rect cellOf(IReadOnlyList<WindowPlacement> ps, int handle)
        {
            foreach (var p in ps)
            {
                if (p.Handle == new IntPtr(handle)) return p.Geometry;
            }
            throw new Xunit.Sdk.XunitException($"handle {handle} not placed");
        }
        Assert.Equal(masterX, cellOf(second, 2).X);
    }

    [Fact]
    public void TileLayout_MoveFocused_RejectsOutOfRange()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        object? state = null;
        engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        // First slot cannot move further up/prev.
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Up, ref state));
        // Unknown handle.
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(999), FocusDirection.Down, ref state));
    }

    [Fact]
    public void TileLayout_MoveFocused_FalseWithFewerThanTwoWindows()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1) };
        object? state = null;
        engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Down, ref state));
    }

    [Fact]
    public void TileLayout_HoldsPositionAcrossReorderedArrange()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3), MakeWin(4) };
        object? state = null;

        var first = engine.Arrange(Area, wins, IntPtr.Zero, Opts(ratio: 0.5), ref state);
        Rect cellOf(IReadOnlyList<WindowPlacement> ps, int handle)
        {
            foreach (var p in ps)
            {
                if (p.Handle == new IntPtr(handle)) return p.Geometry;
            }
            throw new Xunit.Sdk.XunitException($"handle {handle} not placed");
        }

        var before = new Dictionary<int, Rect>();
        for (int h = 1; h <= 4; h++)
        {
            before[h] = cellOf(first, h);
        }

        // Controller hands the windows in a different order; stored Order must keep slots stable.
        var reordered = new List<WindowEntryView> { MakeWin(4), MakeWin(2), MakeWin(1), MakeWin(3) };
        var second = engine.Arrange(Area, reordered, IntPtr.Zero, Opts(ratio: 0.5), ref state);

        for (int h = 1; h <= 4; h++)
        {
            Assert.Equal(before[h], cellOf(second, h));
        }
    }

    [Fact]
    public void TileLayout_DropsClosedAndAppendsNewWindows()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        object? state = null;
        engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        // Window 2 closes, window 4 opens.
        var next = new List<WindowEntryView> { MakeWin(1), MakeWin(3), MakeWin(4) };
        var result = engine.Arrange(Area, next, IntPtr.Zero, Opts(), ref state);

        Assert.Equal(3, result.Count);
        var handles = new HashSet<IntPtr>();
        foreach (var p in result)
        {
            handles.Add(p.Handle);
        }
        Assert.Contains(new IntPtr(1), handles);
        Assert.Contains(new IntPtr(3), handles);
        Assert.Contains(new IntPtr(4), handles);
        Assert.DoesNotContain(new IntPtr(2), handles);
    }

    [Fact]
    public void TileLayout_FocusNeighbor_ReturnsAdjacentInColumn()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };
        object? state = null;
        engine.Arrange(Area, wins, IntPtr.Zero, Opts(masterCount: 1), ref state);

        // Stack column holds 2 & 3 at indices 1 & 2; Down from 2 → 3.
        var neighbor = engine.FocusNeighbor(IntPtr.Zero, new IntPtr(2), FocusDirection.Down, wins, ref state);
        Assert.Equal(new IntPtr(3), neighbor);
    }

    [Fact]
    public void TileLayout_FocusNeighbor_NullAtEdge()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;
        engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        Assert.Null(engine.FocusNeighbor(IntPtr.Zero, new IntPtr(1), FocusDirection.Up, wins, ref state));
        Assert.Null(engine.FocusNeighbor(IntPtr.Zero, new IntPtr(999), FocusDirection.Down, wins, ref state));
    }

    [Fact]
    public void TileLayout_EmptyWindows_ClearsOrder()
    {
        var engine = new TileLayout();
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        object? state = null;
        engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        var result = engine.Arrange(Area, new List<WindowEntryView>(), IntPtr.Zero, Opts(), ref state);
        Assert.Empty(result);
        // Moving in an empty layout is a no-op.
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Down, ref state));
    }

    // -- MonocleLayout -----------------------------------------------

    [Fact]
    public void MonocleLayout_OnlyFocusedVisible()
    {
        var engine = new MonocleLayout();
        var w1 = MakeWin(1); var w2 = MakeWin(2); var w3 = MakeWin(3);
        var wins = new List<WindowEntryView> { w1, w2, w3 };
        object? state = null;

        var result = engine.Arrange(Area, wins, w2.Handle, Opts(outer: 5), ref state);

        int visibleCount = 0;
        WindowPlacement visible = default;
        foreach (var p in result)
        {
            if (p.Visible) { visibleCount++; visible = p; }
        }

        Assert.Equal(1, visibleCount);
        Assert.Equal(w2.Handle, visible.Handle);
        // Fills usable area minus outer gaps.
        Assert.Equal(5, visible.Geometry.X);
        Assert.Equal(990, visible.Geometry.W);
    }

    // -- ScrollingLayout ---------------------------------------------

    [Fact]
    public void ScrollingLayout_ViewportClampedAtLeftEdge()
    {
        var engine = new ScrollingLayout();
        var w1 = MakeWin(1); var w2 = MakeWin(2);
        var wins = new List<WindowEntryView> { w1, w2 };
        object? state = null;
        var opts = Opts(extra: new Dictionary<string, string>
        {
            ["column_width"] = "0.5",
            ["center_focused"] = "true",
            ["allow_overscroll"] = "false",
            ["snap_to_columns"] = "false"
        });

        // Focus leftmost — viewport must clamp at 0, never negative.
        engine.Arrange(Area, wins, w1.Handle, opts, ref state);
        var s = (ScrollingLayout.ScrollState)state!;
        Assert.True(s.ViewportX >= 0);
    }

    [Fact]
    public void ScrollingLayout_OffscreenColumnsHidden()
    {
        var engine = new ScrollingLayout();
        // 6 columns of 500px each on a 1000px area → only ~2 visible at once.
        var wins = new List<WindowEntryView>();
        for (int i = 1; i <= 6; i++)
        {
            wins.Add(MakeWin(i));
        }

        object? state = null;
        var opts = Opts(extra: new Dictionary<string, string>
        {
            ["column_width"] = "0.5",
            ["center_focused"] = "false",
            ["snap_to_columns"] = "false"
        });

        var result = engine.Arrange(Area, wins, IntPtr.Zero, opts, ref state);

        int hidden = 0, visible = 0;
        foreach (var p in result) { if (p.Visible)
            {
                visible++;
            }
            else
            {
                hidden++;
            }
        }
        Assert.True(hidden > 0, "at least one column must be hidden off-screen");
        Assert.True(visible > 0, "at least one column must be visible");
    }

    // -- FloatingLayout ----------------------------------------------

    [Fact]
    public void FloatingLayout_RememberedRectAcrossArrange()
    {
        var engine = new FloatingLayout();
        var w = MakeWin(1);
        var wins = new List<WindowEntryView> { w };
        object? state = null;

        var first = engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);
        var second = engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        Assert.Equal(first[0].Geometry, second[0].Geometry);
    }

    // -- LayoutConfig ------------------------------------------------

    [Fact]
    public void LayoutConfig_SecondarySlotSwap()
    {
        const string toml = """
            [layout]
            default = "tile"
            [layout.slots]
            secondary = "scrolling"
            """;
        var cfg = LayoutConfig.Parse(toml);
        Assert.Equal("scrolling", cfg.Slots["secondary"]);

        var registry = new LayoutRegistry();
        var engine = registry.Create(cfg.Slots["secondary"]);
        Assert.Equal("scrolling", engine.Id);
    }

    [Fact]
    public void LayoutConfig_DefaultLayoutResolves()
    {
        const string toml = """
            [layout]
            default = "monocle"
            """;
        var cfg = LayoutConfig.Parse(toml);
        Assert.Equal("monocle", cfg.DefaultLayout);
    }

    [Fact]
    public void LayoutConfig_PerOutputOverride()
    {
        const string toml = """
            [layout]
            default = "tile"
            [[output]]
            name   = "DP-1"
            layout = "scrolling"
            [[output]]
            name   = "HDMI-A-1"
            layout = "monocle"
            """;
        var cfg = LayoutConfig.Parse(toml);
        Assert.Equal("scrolling", cfg.PerOutput["DP-1"]);
        Assert.Equal("monocle", cfg.PerOutput["HDMI-A-1"]);
    }

    [Fact]
    public void LayoutConfig_PerLayoutOptions()
    {
        const string toml = """
            [layout.options.scrolling]
            column_width    = 0.4
            center_focused  = true
            """;
        var cfg = LayoutConfig.Parse(toml);
        var opts = cfg.OptionsFor("scrolling");
        Assert.Equal("0.4", opts.GetExtra("column_width"));
        Assert.True(opts.GetExtraBool("center_focused", false));
    }

    // -- LayoutController --------------------------------------------

    [Fact]
    public void Controller_HonorsMinMaxClamp()
    {
        // Tile would naturally give one window the whole 100x100 area, but the window's MinW=300 must be
        // enforced by the controller.
        var registry = new LayoutRegistry();
        var ctrl = new LayoutController(registry, LayoutConfig.Default);
        var output = new IntPtr(0xAA);
        var wins = new List<WindowEntryView> { MakeWin(1, minW: 300) };

        var result = ctrl.Arrange(output, "X-1", new Rect(0, 0, 100, 100), wins, IntPtr.Zero,
            visibleTags: 0xFFFFFFFFu);
        Assert.Single(result);
        Assert.Equal(300, result[0].Geometry.W);
    }

    [Fact]
    public void Controller_ResolvesPerOutputLayout()
    {
        var registry = new LayoutRegistry();
        var cfg = LayoutConfig.Parse("""
            [layout]
            default = "tile"
            [[output]]
            name   = "DP-1"
            layout = "monocle"
            """);
        var ctrl = new LayoutController(registry, cfg);
        Assert.Equal("monocle", ctrl.ResolveLayoutId(new IntPtr(1), "DP-1"));
        Assert.Equal("tile", ctrl.ResolveLayoutId(new IntPtr(2), "OTHER"));
    }

    [Fact]
    public void Controller_ArrangeByWorkspaceNumber_SelectsConfiguredEngine()
    {
        var registry = new LayoutRegistry();
        var cfg = LayoutConfig.Parse("""
            [layout]
            default = "tile"
            master_ratio = 0.5

            [[workspace]]
            workspace = 2
            layout    = "monocle"
            """);
        var ctrl = new LayoutController(registry, cfg);
        var output = new IntPtr(0xAC);
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2) };
        var area = new Rect(0, 0, 1000, 800);

        var ws2 = ctrl.Arrange(output, "DP-1", area, wins, IntPtr.Zero, workspaceNumber: 2);
        Assert.True(ws2[0].Geometry.W > 900);

        var ws3 = ctrl.Arrange(output, "DP-1", area, wins, IntPtr.Zero, workspaceNumber: 3);
        Assert.True(ws3[0].Geometry.W < 600);
        Assert.True(ws2[0].Geometry.W > ws3[0].Geometry.W);
    }

    [Fact]
    public void Controller_ArrangeByWorkspaceNumber_MatchesTagMaskOverload()
    {
        var registry = new LayoutRegistry();
        var cfg = LayoutConfig.Parse("""
            [layout]
            default = "tile"

            [[workspace]]
            workspace = 3
            layout    = "monocle"
            """);
        var byNumber = new LayoutController(registry, cfg);
        var byMask = new LayoutController(new LayoutRegistry(), cfg);
        var area = new Rect(0, 0, 1000, 800);
        var wins = new List<WindowEntryView> { MakeWin(1), MakeWin(2), MakeWin(3) };

        var a = byNumber.Arrange(new IntPtr(0xAD), "DP-1", area, wins, IntPtr.Zero, workspaceNumber: 3);
        var b = byMask.Arrange(new IntPtr(0xAD), "DP-1", area, wins, IntPtr.Zero, visibleTags: 1u << 2);

        Assert.Equal(b.Count, a.Count);
        for (int i = 0; i < a.Count; i++)
        {
            Assert.Equal(b[i].Handle, a[i].Handle);
            Assert.Equal(b[i].Geometry, a[i].Geometry);
        }
    }

    [Fact]
    public void Controller_ReloadPreservesGridOrder_WhenResolvedIdUnchanged()
    {
        // Layout-order memory: reloading the config (e.g. on file change) must NOT reset a grid
        // workspace's slot order when the resolved layout id is unchanged. A move performed before
        // the reload must still be visible after it.
        var registry = new LayoutRegistry();
        var cfg = LayoutConfig.Parse("""
            [layout]
            default = "grid"
            """);
        var ctrl = new LayoutController(registry, cfg);
        var output = new IntPtr(0xAB);
        const uint tags = 0xFFFFFFFFu;
        var wins = new List<WindowEntryView>
        {
            MakeWin(1), MakeWin(2), MakeWin(3), MakeWin(4)
        };

        Rect cellOf(IReadOnlyList<WindowPlacement> ps, int handle)
        {
            foreach (var p in ps)
            {
                if (p.Handle == new IntPtr(handle)) return p.Geometry;
            }
            throw new Xunit.Sdk.XunitException($"handle {handle} not placed");
        }

        var f0 = ctrl.Arrange(output, null, new Rect(0, 0, 1000, 800), wins, IntPtr.Zero, tags);
        var cell1 = f0[1].Geometry; // grid cell at index 1

        // Swap window 1 with its neighbour → order [2,1,3,4]; window 1 now sits at cell index 1.
        Assert.True(ctrl.MoveFocused(output, null, new IntPtr(1), FocusDirection.Right, tags));
        var f1 = ctrl.Arrange(output, null, new Rect(0, 0, 1000, 800), wins, IntPtr.Zero, tags);
        Assert.Equal(cell1, cellOf(f1, 1));

        // Reload an equivalent config: the resolved id stays "grid", so the slot order must survive.
        ctrl.ReplaceConfig(LayoutConfig.Parse("""
            [layout]
            default = "grid"
            """));

        var f2 = ctrl.Arrange(output, null, new Rect(0, 0, 1000, 800), wins, IntPtr.Zero, tags);
        Assert.Equal(cell1, cellOf(f2, 1));
    }

    [Fact]
    public void Controller_ReloadDropsEngineState()
    {
        var registry = new LayoutRegistry();
        var ctrl = new LayoutController(registry, LayoutConfig.Default);
        var output = new IntPtr(0xAA);
        var wins = new List<WindowEntryView> { MakeWin(1) };

        // First arrange picks an engine for the output.
        ctrl.Arrange(output, null, new Rect(0, 0, 200, 200), wins, IntPtr.Zero,
            visibleTags: 0xFFFFFFFFu);
        long before = ctrl.Epoch;

        ctrl.ReplaceConfig(LayoutConfig.Default);
        Assert.Equal(before + 1, ctrl.Epoch);

        // After reload, arrange must still succeed.
        var result = ctrl.Arrange(output, null, new Rect(0, 0, 200, 200), wins, IntPtr.Zero,
            visibleTags: 0xFFFFFFFFu);
        Assert.Single(result);
    }
}
