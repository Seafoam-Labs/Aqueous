using System;
using System.Collections.Generic;
using System.IO;
using Aqueous.WM.Features.Layout;
using Aqueous.WM.Features.Layout.Builtin;
using Xunit;

namespace Aqueous.WM.Tests;

/// <summary>
/// Acceptance tests from Phase 1.1 plan section F. Engines are pure
/// functions, so these tests require neither a Wayland fixture nor a
/// running compositor — exactly the property the architecture aims for.
/// </summary>
public class LayoutTests
{
    private static WindowEntryView MakeWin(int handle, int minW = 0, int minH = 0, int maxW = 0, int maxH = 0)
        => new(new IntPtr(handle), minW, minH, maxW, maxH, false, false, 0u);

    private static LayoutOptions Opts(int outer = 0, int inner = 0, double ratio = 0.55, int masterCount = 1,
                                      Dictionary<string, string>? extra = null)
        => new(outer, inner, ratio, masterCount, extra ?? new Dictionary<string, string>());

    private static readonly Rect Area = new(0, 0, 1000, 800);

    // ---- TileLayout ---------------------------------------------------

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
            Assert.True(p.Geometry.Right  <= 990);
            Assert.True(p.Geometry.Bottom <= 790);
        }
    }

    // ---- MonocleLayout -----------------------------------------------

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
            if (p.Visible) { visibleCount++; visible = p; }

        Assert.Equal(1, visibleCount);
        Assert.Equal(w2.Handle, visible.Handle);
        // Fills usable area minus outer gaps.
        Assert.Equal(5, visible.Geometry.X);
        Assert.Equal(990, visible.Geometry.W);
    }

    // ---- ScrollingLayout ---------------------------------------------

    [Fact]
    public void ScrollingLayout_ViewportClampedAtLeftEdge()
    {
        var engine = new ScrollingLayout();
        var w1 = MakeWin(1); var w2 = MakeWin(2);
        var wins = new List<WindowEntryView> { w1, w2 };
        object? state = null;
        var opts = Opts(extra: new Dictionary<string, string> {
            ["column_width"] = "0.5", ["center_focused"] = "true", ["snap_to_columns"] = "false"
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
        for (int i = 1; i <= 6; i++) wins.Add(MakeWin(i));
        object? state = null;
        var opts = Opts(extra: new Dictionary<string, string> {
            ["column_width"] = "0.5", ["center_focused"] = "false", ["snap_to_columns"] = "false"
        });

        var result = engine.Arrange(Area, wins, IntPtr.Zero, opts, ref state);

        int hidden = 0, visible = 0;
        foreach (var p in result) { if (p.Visible) visible++; else hidden++; }
        Assert.True(hidden > 0, "at least one column must be hidden off-screen");
        Assert.True(visible > 0, "at least one column must be visible");
    }

    // ---- FloatingLayout ----------------------------------------------

    [Fact]
    public void FloatingLayout_RememberedRectAcrossArrange()
    {
        var engine = new FloatingLayout();
        var w = MakeWin(1);
        var wins = new List<WindowEntryView> { w };
        object? state = null;

        var first  = engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);
        var second = engine.Arrange(Area, wins, IntPtr.Zero, Opts(), ref state);

        Assert.Equal(first[0].Geometry, second[0].Geometry);
    }

    // ---- LayoutConfig ------------------------------------------------

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
        var engine   = registry.Create(cfg.Slots["secondary"]);
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
        Assert.Equal("monocle",   cfg.PerOutput["HDMI-A-1"]);
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
        Assert.Equal("0.4",  opts.GetExtra("column_width"));
        Assert.True(opts.GetExtraBool("center_focused", false));
    }

    // ---- LayoutController --------------------------------------------

    [Fact]
    public void Controller_HonorsMinMaxClamp()
    {
        // Tile would naturally give one window the whole 100x100 area, but
        // the window's MinW=300 must be enforced by the controller.
        var registry = new LayoutRegistry();
        var ctrl     = new LayoutController(registry, LayoutConfig.Default);
        var output   = new IntPtr(0xAA);
        var wins = new List<WindowEntryView> { MakeWin(1, minW: 300) };

        var result = ctrl.Arrange(output, "X-1", new Rect(0, 0, 100, 100), wins, IntPtr.Zero);
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
        Assert.Equal("tile",    ctrl.ResolveLayoutId(new IntPtr(2), "OTHER"));
    }

    [Fact]
    public void Controller_ReloadDropsEngineState()
    {
        var registry = new LayoutRegistry();
        var ctrl     = new LayoutController(registry, LayoutConfig.Default);
        var output   = new IntPtr(0xAA);
        var wins = new List<WindowEntryView> { MakeWin(1) };

        // First arrange picks an engine for the output.
        ctrl.Arrange(output, null, new Rect(0, 0, 200, 200), wins, IntPtr.Zero);
        long before = ctrl.Epoch;

        ctrl.ReplaceConfig(LayoutConfig.Default);
        Assert.Equal(before + 1, ctrl.Epoch);

        // After reload, arrange must still succeed.
        var result = ctrl.Arrange(output, null, new Rect(0, 0, 200, 200), wins, IntPtr.Zero);
        Assert.Single(result);
    }
}
