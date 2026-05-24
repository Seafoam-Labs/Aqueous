using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Aqueous.Features.Layout.Builtin;
using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// PR #4 (step 1) — engine-level tests for <see cref="GameModeLayout"/>.
/// Pins: no-anchor fallback path, single-anchor centered placement + remainder dispatch,
/// most-recently-focused anchor selection, empty-remainder skip, self-recursion guard,
/// and registry registration / discoverability.
/// </summary>
public class GameModeLayoutTests
{
    private static readonly Rect UA2560 = new(0, 0, 2560, 1440);

    // ----- Helpers -----------------------------------------------------------

    private static WindowEntryView View(
        int handle,
        RulePlacement? placement = null,
        int bufW = 1920,
        int bufH = 1080,
        long lastFocusTick = 0)
        => new(
            Handle: new IntPtr(handle),
            MinW: 0, MinH: 0, MaxW: 0, MaxH: 0,
            Floating: false, Fullscreen: false, Tags: 1u,
            Placement: placement,
            RequestedBufferW: bufW,
            RequestedBufferH: bufH,
            LastFocusTick: lastFocusTick);

    private static RulePlacement AnchorPlacement(
        AnchorKind anchor = AnchorKind.Center,
        SizeSpec? size = null,
        double scale = 1.0)
        => new(new WindowRule(
            AppId: "dota2", Class: null, Title: null,
            Layout: "game-mode",
            Anchor: anchor,
            Size: size ?? SizeSpec.Native.Instance,
            Scale: scale,
            Tag: null,
            Fullscreen: false));

    private static LayoutOptions OptsWith(
        string? remainder = null, string? fallback = null)
    {
        var extra = new Dictionary<string, string>();
        if (remainder is not null) extra["game_mode.remainder_layout"] = remainder;
        if (fallback is not null)  extra["game_mode.fallback_layout"]  = fallback;
        return LayoutOptions.Default with { Extra = extra };
    }

    // ----- Registry / discoverability ----------------------------------------

    [Fact]
    public void Registry_ContainsGameModeFactory_ById()
    {
        var reg = new LayoutRegistry();
        Assert.True(reg.Contains("game-mode"));
        Assert.True(reg.Contains("GAME-MODE")); // case-insensitive
        var engine = reg.Create("game-mode");
        Assert.IsType<GameModeLayout>(engine);
        Assert.Equal("game-mode", engine.Id);
    }

    // ----- No-anchor fallback path -------------------------------------------

    [Fact]
    public void Arrange_NoAnchors_FallsBackToGridByDefault()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");

        // Two ordinary tiled windows, no Placement.
        var windows = new List<WindowEntryView> { View(1), View(2) };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // Compare against running grid directly with the same input.
        var grid = reg.Create("grid");
        object? gridState = null;
        var expected = grid.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref gridState);

        Assert.Equal(expected.Count, result.Count);
        for (int i = 0; i < expected.Count; i++)
        {
            Assert.Equal(expected[i].Handle, result[i].Handle);
            Assert.Equal(expected[i].Geometry, result[i].Geometry);
        }
    }

    [Fact]
    public void Arrange_NoAnchors_HonoursConfiguredFallback()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        var opts = OptsWith(fallback: "monocle");

        var windows = new List<WindowEntryView> { View(1), View(2) };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, opts, ref state);

        // Monocle gives every visible window the same rect; cross-check by computing it
        // directly via the monocle engine.
        var monocle = reg.Create("monocle");
        object? ms = null;
        var expected = monocle.Arrange(UA2560, windows, IntPtr.Zero, opts, ref ms);

        Assert.Equal(expected.Count, result.Count);
    }

    // ----- Single-anchor placement & remainder dispatch ----------------------

    [Fact]
    public void Arrange_SingleAnchor_CenteredAtRequestedBuffer()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");

        var anchor = View(42, AnchorPlacement(), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), anchor, View(2) };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // Anchor placement is appended last; geometry is the centered (320,180,1920,1080) rect.
        var anchorPlacement = result[^1];
        Assert.Equal(new IntPtr(42), anchorPlacement.Handle);
        Assert.Equal(new Rect(320, 180, 1920, 1080), anchorPlacement.Geometry);
        Assert.True(anchorPlacement.Visible);

        // Remaining placements correspond to the two non-anchor windows.
        Assert.Equal(3, result.Count);
        var nonAnchorHandles = new HashSet<IntPtr>
            { result[0].Handle, result[1].Handle };
        Assert.Contains(new IntPtr(1), nonAnchorHandles);
        Assert.Contains(new IntPtr(2), nonAnchorHandles);

        // Non-anchor placements must land inside the band remainder (top band:
        // (0, 0, 2560, 180) wins by tie-break for this centered-anchor case).
        var band = new Rect(0, 0, 2560, 180);
        for (int i = 0; i < 2; i++)
        {
            var g = result[i].Geometry;
            Assert.True(g.X >= band.X && g.X + g.W <= band.X + band.W,
                $"placement {i} x out of band: {g}");
            Assert.True(g.Y >= band.Y && g.Y + g.H <= band.Y + band.H,
                $"placement {i} y out of band: {g}");
        }
    }

    // ----- Anchor selection: most-recently-focused wins ----------------------

    [Fact]
    public void Arrange_MultipleAnchorCandidates_PicksMostRecentlyFocused()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");

        var older = View(10, AnchorPlacement(), lastFocusTick: 5);
        var newer = View(20, AnchorPlacement(), lastFocusTick: 100);
        var windows = new List<WindowEntryView> { older, newer };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // The winning anchor is appended last; it must be the newer one. The older one
        // is demoted to a regular tile in the remainder band.
        Assert.Equal(new IntPtr(20), result[^1].Handle);
        Assert.Equal(new Rect(320, 180, 1920, 1080), result[^1].Geometry);

        // The other (older) anchor candidate appears as a remainder tile.
        bool foundOlderInBand = false;
        for (int i = 0; i < result.Count - 1; i++)
        {
            if (result[i].Handle == new IntPtr(10)) foundOlderInBand = true;
        }
        Assert.True(foundOlderInBand,
            "older anchor candidate should be demoted to a regular remainder tile");
    }

    // ----- Empty-remainder skip path -----------------------------------------

    [Fact]
    public void Arrange_AnchorCoversUsable_SkipsSubLayout_AnchorOnly()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");

        // Pixels(2560,1440) on a 2560×1440 output → anchor fills everything; remainder
        // is Rect.Empty. The other window must NOT receive a placement this frame.
        var anchor = View(42, AnchorPlacement(size: new SizeSpec.Pixels(2560, 1440)));
        var windows = new List<WindowEntryView> { View(1), anchor };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        Assert.Single(result);
        Assert.Equal(new IntPtr(42), result[0].Handle);
        Assert.Equal(UA2560, result[0].Geometry);
    }

    [Fact]
    public void Arrange_AnchorWithNoOtherWindows_ReturnsAnchorOnly()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");

        var windows = new List<WindowEntryView> { View(42, AnchorPlacement()) };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        Assert.Single(result);
        Assert.Equal(new IntPtr(42), result[0].Handle);
    }

    // ----- Self-recursion guard ---------------------------------------------

    [Fact]
    public void Arrange_SelfReferentialRemainder_Throws()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        var opts = OptsWith(remainder: "game-mode");

        var windows = new List<WindowEntryView> { View(1) };
        object? state = null;
        Assert.Throws<InvalidOperationException>(() =>
            engine.Arrange(UA2560, windows, IntPtr.Zero, opts, ref state));
    }

    [Fact]
    public void Arrange_SelfReferentialFallback_Throws()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        var opts = OptsWith(fallback: "game-mode");

        var windows = new List<WindowEntryView> { View(1) };
        object? state = null;
        Assert.Throws<InvalidOperationException>(() =>
            engine.Arrange(UA2560, windows, IntPtr.Zero, opts, ref state));
    }

    // ----- Ultrawide sanity check (mirrors GameModeGeometryTests #12) --------

    [Fact]
    public void Arrange_UltrawideFullHeightAnchor_RemainderIsLeftBand()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        var usable = new Rect(0, 0, 7680, 2160);

        var anchor = View(42, AnchorPlacement(), bufW: 3840, bufH: 2160);
        var windows = new List<WindowEntryView> { anchor, View(1), View(2) };
        object? state = null;
        var result = engine.Arrange(usable, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // Anchor placed at (1920, 0, 3840, 2160).
        Assert.Equal(new Rect(1920, 0, 3840, 2160), result[^1].Geometry);

        // Remainder tiles fall into the left band (0, 0, 1920, 2160).
        var band = new Rect(0, 0, 1920, 2160);
        for (int i = 0; i < result.Count - 1; i++)
        {
            var g = result[i].Geometry;
            Assert.True(g.X >= band.X && g.X + g.W <= band.X + band.W);
            Assert.True(g.Y >= band.Y && g.Y + g.H <= band.Y + band.H);
        }
    }
}
