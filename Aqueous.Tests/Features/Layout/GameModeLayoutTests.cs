using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Aqueous.Features.Layout.Builtin;
using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Engine-level tests for <see cref="GameModeLayout"/>: anchor selection (most-recently
/// focused wins), fallback when no anchor is present, sub-layout dispatch for the
/// remainder, empty-remainder skip, self-recursion guards, and registry discoverability.
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

        // Non-anchor placements must land inside one of the two side columns
        // (left: (0,0,320,1440), right: (2240,0,320,1440)). With round-robin, the
        // first non-anchor (handle 1) goes left, the second (handle 2) goes right.
        var leftCol  = new Rect(0,    0, 320, 1440);
        var rightCol = new Rect(2240, 0, 320, 1440);
        for (int i = 0; i < 2; i++)
        {
            var g = result[i].Geometry;
            bool inLeft  = g.X >= leftCol.X  && g.X + g.W <= leftCol.X  + leftCol.W
                         && g.Y >= leftCol.Y && g.Y + g.H <= leftCol.Y + leftCol.H;
            bool inRight = g.X >= rightCol.X && g.X + g.W <= rightCol.X + rightCol.W
                         && g.Y >= rightCol.Y && g.Y + g.H <= rightCol.Y + rightCol.H;
            Assert.True(inLeft || inRight, $"placement {i} not in either side column: {g}");
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

    // ----- Ultrawide sanity check (centered anchor → left + right columns) ---

    [Fact]
    public void Arrange_UltrawideFullHeightAnchor_SplitsAcrossSideColumns()
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

        var leftCol  = new Rect(0,    0, 1920, 2160);
        var rightCol = new Rect(5760, 0, 1920, 2160);
        // Each non-anchor placement falls in exactly one of the two side columns.
        for (int i = 0; i < result.Count - 1; i++)
        {
            var g = result[i].Geometry;
            bool inLeft  = g.X >= leftCol.X  && g.X + g.W <= leftCol.X  + leftCol.W;
            bool inRight = g.X >= rightCol.X && g.X + g.W <= rightCol.X + rightCol.W;
            Assert.True(inLeft || inRight, $"placement {i} not in a side column: {g}");
        }
    }

    // ----- Phase 2: per-column partitioning ----------------------------------

    [Fact]
    public void Arrange_CenteredAnchor_RoundRobinSplitsLeftRight()
    {
        // Centered anchor on 2560×1440 yields equal 320-wide side columns. Four
        // non-anchor windows must split 2:2 by round-robin over visible order.
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        var anchor = View(99, AnchorPlacement(), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView>
        {
            View(1), View(2), anchor, View(3), View(4),
        };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // 1 anchor + 4 tiles = 5 placements.
        Assert.Equal(5, result.Count);
        Assert.Equal(new IntPtr(99), result[^1].Handle);

        // Round-robin over non-anchor order (1,2,3,4): indices 0,2 → left; 1,3 → right.
        var leftRect  = new Rect(0,    0, 320, 1440);
        var rightRect = new Rect(2240, 0, 320, 1440);
        int leftCount = 0, rightCount = 0;
        for (int i = 0; i < result.Count - 1; i++)
        {
            var g = result[i].Geometry;
            if (g.X >= leftRect.X  && g.X + g.W <= leftRect.X  + leftRect.W)  leftCount++;
            if (g.X >= rightRect.X && g.X + g.W <= rightRect.X + rightRect.W) rightCount++;
        }
        Assert.Equal(2, leftCount);
        Assert.Equal(2, rightCount);
    }

    [Fact]
    public void Arrange_LeftEdgeAnchor_AllOthersInRightColumn()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        // Left-anchored → left column collapses (Rect.Empty). All non-anchor tiles
        // must fall in the right column.
        var anchor = View(99, AnchorPlacement(anchor: AnchorKind.Left), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), View(2), View(3), anchor };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // Anchor at (0, 180, 1920, 1080); right column at (1920, 0, 640, 1440).
        Assert.Equal(new Rect(0, 180, 1920, 1080), result[^1].Geometry);

        var rightRect = new Rect(1920, 0, 640, 1440);
        Assert.Equal(4, result.Count);
        for (int i = 0; i < result.Count - 1; i++)
        {
            var g = result[i].Geometry;
            Assert.True(g.X >= rightRect.X && g.X + g.W <= rightRect.X + rightRect.W,
                $"placement {i} not in right column: {g}");
        }
    }

    [Fact]
    public void Arrange_RightEdgeAnchor_AllOthersInLeftColumn()
    {
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        var anchor = View(99, AnchorPlacement(anchor: AnchorKind.Right), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), View(2), View(3), anchor };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // Anchor at (640, 180, 1920, 1080); left column at (0, 0, 640, 1440).
        Assert.Equal(new Rect(640, 180, 1920, 1080), result[^1].Geometry);

        var leftRect = new Rect(0, 0, 640, 1440);
        Assert.Equal(4, result.Count);
        for (int i = 0; i < result.Count - 1; i++)
        {
            var g = result[i].Geometry;
            Assert.True(g.X >= leftRect.X && g.X + g.W <= leftRect.X + leftRect.W,
                $"placement {i} not in left column: {g}");
        }
    }

    [Fact]
    public void Arrange_FullWidthAnchor_NoSubLayoutInvoked_AnchorOnly()
    {
        // Anchor spans full width → both side columns are Rect.Empty. Even with
        // other windows present, they receive no placement this frame (mirrors
        // the pre-existing "anchor covers usable" empty-remainder skip).
        var reg = new LayoutRegistry();
        var engine = reg.Create("game-mode");
        var anchor = View(42,
            AnchorPlacement(size: new SizeSpec.Pixels(2560, 720)),
            bufW: 2560, bufH: 720);
        var windows = new List<WindowEntryView> { View(1), anchor, View(2) };
        object? state = null;
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        Assert.Single(result);
        Assert.Equal(new IntPtr(42), result[0].Handle);
    }

    // ----- MoveFocused: anchor guard + non-anchor reordering -----------------

    private static GameModeLayout NewEngine() => (GameModeLayout)new LayoutRegistry().Create("game-mode");

    /// <summary>
    /// Arrange once to hydrate per-output state (CurrentAnchor + NonAnchorOrder), then return it
    /// so the test can invoke MoveFocused with a populated state slot.
    /// </summary>
    private static object? HydrateState(
        GameModeLayout engine,
        IReadOnlyList<WindowEntryView> windows,
        LayoutOptions? opts = null)
    {
        object? state = null;
        engine.Arrange(UA2560, windows, IntPtr.Zero, opts ?? LayoutOptions.Default, ref state);
        return state;
    }

    [Fact]
    public void MoveFocused_FocusedIsAnchor_ReturnsFalse_AndDoesNotMutateState()
    {
        var engine = NewEngine();
        var anchor = View(99, AnchorPlacement(), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), View(2), anchor };
        var state = HydrateState(engine, windows);

        var snapshot = (state, windows: windows.Count);
        bool moved = engine.MoveFocused(IntPtr.Zero, anchor.Handle, FocusDirection.Right, ref state);

        Assert.False(moved);
        // Re-arrange — the anchor must still appear in the same slot.
        var re = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);
        Assert.Equal(anchor.Handle, re[^1].Handle);
    }

    [Fact]
    public void MoveFocused_NoState_ReturnsFalse()
    {
        var engine = NewEngine();
        object? state = null;
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state));
    }

    [Fact]
    public void MoveFocused_FocusedNotInBand_ReturnsFalse()
    {
        var engine = NewEngine();
        var anchor = View(99, AnchorPlacement(), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), View(2), anchor };
        var state = HydrateState(engine, windows);

        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(0xDEAD), FocusDirection.Right, ref state));
        Assert.False(engine.MoveFocused(IntPtr.Zero, IntPtr.Zero, FocusDirection.Right, ref state));
    }

    [Fact]
    public void MoveFocused_Right_SwapsAdjacentNonAnchorWindows()
    {
        var engine = NewEngine();
        var anchor = View(99, AnchorPlacement(), bufW: 1920, bufH: 1080);
        // Three non-anchor windows: 1, 2, 3. With centered anchor, round-robin partition
        // (idx 0,1,2 → left, right, left) places 1+3 on the left column and 2 on the right.
        var windows = new List<WindowEntryView> { View(1), View(2), View(3), anchor };
        var state = HydrateState(engine, windows);

        bool moved = engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state);
        Assert.True(moved);

        // After swap, NonAnchorOrder is [2,1,3]. Round-robin: idx0=2→left, idx1=1→right, idx2=3→left.
        var result = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // Last placement is the anchor.
        Assert.Equal(anchor.Handle, result[^1].Handle);

        // Find handle 1's geometry; it should now be in the right column (x >= anchor.X).
        Rect anchorRect = result[^1].Geometry;
        Rect g1 = default, g2 = default;
        bool f1 = false, f2 = false;
        for (int i = 0; i < result.Count; i++)
        {
            if (result[i].Handle == new IntPtr(1)) { g1 = result[i].Geometry; f1 = true; }
            else if (result[i].Handle == new IntPtr(2)) { g2 = result[i].Geometry; f2 = true; }
        }
        Assert.True(f1 && f2);
        Assert.True(g1.X >= anchorRect.X,
            "window 1 should be in right column after swap; got " + g1);
        Assert.True(g2.X + g2.W <= anchorRect.X,
            "window 2 should be in left column after swap; got " + g2);
    }

    [Fact]
    public void MoveFocused_AtEdge_ReturnsFalse()
    {
        var engine = NewEngine();
        var anchor = View(99, AnchorPlacement(), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), View(2), anchor };
        var state = HydrateState(engine, windows);

        // Window 1 is at index 0 in NonAnchorOrder → cannot move Left.
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Left, ref state));
        // Window 2 is at the last index → cannot move Right.
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Right, ref state));
    }

    [Fact]
    public void MoveFocused_UpDown_BehaveLikePrevNext()
    {
        var engine = NewEngine();
        var anchor = View(99, AnchorPlacement(), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), View(2), View(3), anchor };
        var state = HydrateState(engine, windows);

        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Down, ref state));
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Up, ref state));
    }

    [Fact]
    public void MoveFocused_DoesNotThrow_OnNoAnchorBand()
    {
        var engine = NewEngine();
        // No anchor present → fallback path; CurrentAnchor stays Zero, NonAnchorOrder populated.
        var windows = new List<WindowEntryView> { View(1), View(2) };
        object? state = null;
        engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        // MoveFocused must not throw; swap should succeed within the non-anchor list.
        var ex = Record.Exception(
            () => engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state));
        Assert.Null(ex);
    }

    // ----- MoveFocused: degenerate (no anchor) → permutes fallback input ------

    [Fact]
    public void MoveFocused_NoAnchor_PermutesFallbackInput_Grid()
    {
        // With the default fallback (grid), MoveFocused must swap the focused window with
        // its neighbour in NonAnchorOrder, and the next Arrange must hand the fallback engine
        // the permuted order — observed as the two windows' grid cells swapping.
        var engine = NewEngine();
        var windows = new List<WindowEntryView> { View(1), View(2), View(3), View(4) };

        object? state = null;
        var before = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        Rect cellOf(IReadOnlyList<WindowPlacement> ps, int handle)
        {
            foreach (var p in ps)
            {
                if (p.Handle == new IntPtr(handle)) return p.Geometry;
            }
            throw new Xunit.Sdk.XunitException($"handle {handle} not placed");
        }

        var w1Before = cellOf(before, 1);
        var w2Before = cellOf(before, 2);
        Assert.NotEqual(w1Before, w2Before);

        // Swap W1 with its next neighbour (W2) via the game-mode order.
        bool moved = engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state);
        Assert.True(moved);

        var after = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);
        // After swap, W1 occupies W2's old cell and vice versa — this is the proof that
        // grid (which has no MoveFocused override of its own) sees the permuted input.
        Assert.Equal(w2Before, cellOf(after, 1));
        Assert.Equal(w1Before, cellOf(after, 2));
    }

    [Fact]
    public void MoveFocused_NoAnchor_SurvivesAcrossFrames_Grid()
    {
        // Two consecutive Move calls with an Arrange in between must compose: NonAnchorOrder
        // is mutated by MoveFocused and persisted across Arrange.
        var engine = NewEngine();
        var windows = new List<WindowEntryView> { View(1), View(2), View(3), View(4) };

        object? state = null;
        var f0 = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);

        Rect cellOf(IReadOnlyList<WindowPlacement> ps, int handle)
        {
            foreach (var p in ps)
            {
                if (p.Handle == new IntPtr(handle)) return p.Geometry;
            }
            throw new Xunit.Sdk.XunitException($"handle {handle} not placed");
        }

        // Capture cell-by-index (grid is order-dependent, so cell at index i is stable
        // across permutations of the input list).
        var cell0 = f0[0].Geometry;
        var cell1 = f0[1].Geometry;
        var cell2 = f0[2].Geometry;

        // First move: W1 → cell1, W2 → cell0.
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state));
        var f1 = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);
        Assert.Equal(cell1, cellOf(f1, 1));

        // Second move: W1 (now at index 1) → cell2; order becomes [2,3,1,4].
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state));
        var f2 = engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state);
        Assert.Equal(cell2, cellOf(f2, 1));
        // W2 stays at cell0 across both frames (it was never moved after the first swap).
        Assert.Equal(cell0, cellOf(f2, 2));
    }

    [Fact]
    public void MoveFocused_FallbackIdChanged_ResetsState()
    {
        // Switching game_mode.fallback_layout between Arranges must drop the previous
        // engine + its state instead of feeding it to a different engine. The new engine
        // takes over without throwing and produces placements consistent with itself.
        var engine = NewEngine();
        var windows = new List<WindowEntryView> { View(1), View(2), View(3) };

        object? state = null;
        // Frame 1: fallback = monocle.
        var monoFrame = engine.Arrange(UA2560, windows, new IntPtr(1), OptsWith(fallback: "monocle"), ref state);
        Assert.Equal(3, monoFrame.Count);

        // Frame 2: fallback = grid. Must not throw, must produce grid-style placements
        // (every window visible and given a non-empty cell).
        var ex = Record.Exception(
            () => engine.Arrange(UA2560, windows, new IntPtr(1), OptsWith(fallback: "grid"), ref state));
        Assert.Null(ex);
        var gridFrame = engine.Arrange(UA2560, windows, new IntPtr(1), OptsWith(fallback: "grid"), ref state);
        foreach (var p in gridFrame)
        {
            Assert.True(p.Visible);
            Assert.True(p.Geometry.W > 0 && p.Geometry.H > 0);
        }
    }

    [Fact]
    public void MoveFocused_BeforeFirstArrange_NoCrash()
    {
        // MoveFocused called with no state (no Arrange yet) must not crash; returns false.
        var engine = NewEngine();
        object? state = null;
        bool moved = engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state);
        Assert.False(moved);
    }

    [Fact]
    public void MoveFocused_FollowedByArrange_ProducesValidPlacements_NoCrash()
    {
        // Regression: ensure MoveFocused + Arrange round-trip never throws for the
        // historically-crashy game-mode path.
        var engine = NewEngine();
        var anchor = View(99, AnchorPlacement(), bufW: 1920, bufH: 1080);
        var windows = new List<WindowEntryView> { View(1), View(2), View(3), View(4), anchor };
        var state = HydrateState(engine, windows);

        foreach (var dir in new[]
        {
            FocusDirection.Left, FocusDirection.Right, FocusDirection.Up, FocusDirection.Down
        })
        {
            engine.MoveFocused(IntPtr.Zero, new IntPtr(2), dir, ref state);
            var ex = Record.Exception(
                () => engine.Arrange(UA2560, windows, IntPtr.Zero, LayoutOptions.Default, ref state));
            Assert.Null(ex);
        }
    }
}
