using Aqueous.Features.Layout;
using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Exhaustive coverage for the pure <see cref="GameModeGeometry"/> kernel: anchor
/// placement + size resolution + clamping + band-remainder selection (including the
/// explicit zero-area exclusion that makes the 7680×2160 + 3840×2160 ultrawide case
/// "skip top/bottom" by design, not by accident).
/// </summary>
public class GameModeGeometryTests
{
    private static readonly Rect UA2560 = new(0, 0, 2560, 1440);
    private static readonly Rect UA7680 = new(0, 0, 7680, 2160);

    // ---------------------------------------------------------------------
    // ResolveAnchor — size resolution
    // ---------------------------------------------------------------------

    [Fact]
    public void ResolveAnchor_Native_Centered_OnSymmetricOutput()
    {
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 1920, 1080, SizeSpec.Native.Instance, AnchorKind.Center, 1.0);

        Assert.Equal(new Rect(320, 180, 1920, 1080), r);
    }

    [Fact]
    public void ResolveAnchor_Pixels_OverridesBuffer()
    {
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 1920, 1080, new SizeSpec.Pixels(1280, 720), AnchorKind.Center, 1.0);

        Assert.Equal(new Rect(640, 360, 1280, 720), r);
    }

    [Fact]
    public void ResolveAnchor_Fraction_UsesUsableArea_Truncated()
    {
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 1920, 1080, new SizeSpec.Fraction(0.5, 0.5), AnchorKind.Center, 1.0);

        // 2560 * 0.5 = 1280, 1440 * 0.5 = 720. Centered → (640, 360, 1280, 720).
        Assert.Equal(new Rect(640, 360, 1280, 720), r);
    }

    [Fact]
    public void ResolveAnchor_Scale_AppliedBeforeClamp()
    {
        // 1920*2 = 3840 → clamped to 2560. 1080*2 = 2160 → clamped to 1440.
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 1920, 1080, SizeSpec.Native.Instance, AnchorKind.Center, 2.0);

        Assert.Equal(new Rect(0, 0, 2560, 1440), r);
    }

    [Fact]
    public void ResolveAnchor_BufferLargerThanOutput_Clamped()
    {
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 4096, 2160, SizeSpec.Native.Instance, AnchorKind.Center, 1.0);

        Assert.Equal(new Rect(0, 0, 2560, 1440), r);
    }

    // ---------------------------------------------------------------------
    // ResolveAnchor — placement by AnchorKind
    // ---------------------------------------------------------------------

    [Fact]
    public void ResolveAnchor_AnchorTop_KeepsYAtUsableTop()
    {
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 1920, 1080, SizeSpec.Native.Instance, AnchorKind.Top, 1.0);

        Assert.Equal(UA2560.Y, r.Y);
        // Horizontally centered.
        Assert.Equal(320, r.X);
        Assert.Equal(1920, r.W);
        Assert.Equal(1080, r.H);
    }

    [Theory]
    [InlineData(AnchorKind.Bottom, 320, 360, 1920, 1080)]
    [InlineData(AnchorKind.Left, 0, 180, 1920, 1080)]
    [InlineData(AnchorKind.Right, 640, 180, 1920, 1080)]
    public void ResolveAnchor_EdgeAnchors_PositionedCorrectly(
        AnchorKind anchor, int x, int y, int w, int h)
    {
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 1920, 1080, SizeSpec.Native.Instance, anchor, 1.0);

        Assert.Equal(new Rect(x, y, w, h), r);
    }

    // ---------------------------------------------------------------------
    // ResolveRemainder
    // ---------------------------------------------------------------------

    [Fact]
    public void ResolveRemainder_CenteredAnchor_PicksTopByTieOrder()
    {
        // 2560×1440 with 1920×1080 centered: all four bands area = 460,800. Top wins.
        var anchor = new Rect(320, 180, 1920, 1080);
        var r = GameModeGeometry.ResolveRemainder(UA2560, anchor);

        Assert.Equal(new Rect(0, 0, 2560, 180), r);
    }

    [Fact]
    public void ResolveRemainder_TopAnchored_PicksBottomBand()
    {
        // Anchor touches y=0 → top.H = 0, excluded. Bottom wins (largest survivor).
        var anchor = new Rect(320, 0, 1920, 1080);
        var r = GameModeGeometry.ResolveRemainder(UA2560, anchor);

        Assert.Equal(new Rect(0, 1080, 2560, 360), r);
    }

    [Fact]
    public void ResolveRemainder_AnchorEqualsUsable_ReturnsEmpty()
    {
        var r = GameModeGeometry.ResolveRemainder(UA2560, UA2560);

        Assert.Equal(Rect.Empty, r);
    }

    [Fact]
    public void ResolveRemainder_FullHeightCenteredAnchor_PicksLeftBandByTieOrder()
    {
        // 7680×2160 + 3840×2160 centered: top.H = bottom.H = 0, both excluded.
        // Left and right each 1920×2160 = 4,147,200. Left wins on tie-break.
        var anchor = new Rect(1920, 0, 3840, 2160);
        var r = GameModeGeometry.ResolveRemainder(UA7680, anchor);

        Assert.Equal(new Rect(0, 0, 1920, 2160), r);
    }

    [Fact]
    public void ResolveRemainder_FullWidthCenteredAnchor_PicksTopBandByTieOrder()
    {
        // 2560×1440 + 2560×720 centered: left.W = right.W = 0, both excluded.
        // Top and bottom each 2560×360 = 921,600. Top wins on tie-break.
        var anchor = new Rect(0, 360, 2560, 720);
        var r = GameModeGeometry.ResolveRemainder(UA2560, anchor);

        Assert.Equal(new Rect(0, 0, 2560, 360), r);
    }

    [Fact]
    public void ResolveRemainder_WideShortTopAnchor_PicksBottomBand()
    {
        // 2400×600 anchor pinned to top of 2560×1440: top excluded (zero height),
        // bottom = 2560×840 = 2,150,400 dwarfs the 80×600 side bands.
        var anchor = new Rect(80, 0, 2400, 600);
        var r = GameModeGeometry.ResolveRemainder(UA2560, anchor);

        Assert.Equal(new Rect(0, 600, 2560, 840), r);
    }

    // ---------------------------------------------------------------------
    // ResolveSideColumns (v1.5: anchor + left column + right column)
    // ---------------------------------------------------------------------

    [Fact]
    public void ResolveSideColumns_CenteredAnchor_ProducesEqualLeftRight()
    {
        // 2560×1440 with 1920×1080 centered at (320, 180): left/right bands are
        // each 320 wide and full-height (1440).
        var anchor = new Rect(320, 180, 1920, 1080);
        var (left, right) = GameModeGeometry.ResolveSideColumns(UA2560, anchor);

        Assert.Equal(new Rect(0, 0, 320, 1440), left);
        Assert.Equal(new Rect(2240, 0, 320, 1440), right);
    }

    [Fact]
    public void ResolveSideColumns_LeftEdgeAnchor_LeftIsEmpty()
    {
        // Anchor flush against the left edge: left band collapses to zero width.
        var anchor = new Rect(0, 180, 1920, 1080);
        var (left, right) = GameModeGeometry.ResolveSideColumns(UA2560, anchor);

        Assert.Equal(Rect.Empty, left);
        Assert.Equal(new Rect(1920, 0, 640, 1440), right);
    }

    [Fact]
    public void ResolveSideColumns_RightEdgeAnchor_RightIsEmpty()
    {
        // Anchor flush against the right edge: right band collapses to zero width.
        var anchor = new Rect(640, 180, 1920, 1080);
        var (left, right) = GameModeGeometry.ResolveSideColumns(UA2560, anchor);

        Assert.Equal(new Rect(0, 0, 640, 1440), left);
        Assert.Equal(Rect.Empty, right);
    }

    [Fact]
    public void ResolveSideColumns_FullWidthAnchor_BothEmpty()
    {
        // Anchor spans the full width: both side bands collapse to zero width.
        var anchor = new Rect(0, 360, 2560, 720);
        var (left, right) = GameModeGeometry.ResolveSideColumns(UA2560, anchor);

        Assert.Equal(Rect.Empty, left);
        Assert.Equal(Rect.Empty, right);
    }

    [Fact]
    public void ResolveSideColumns_SumOfWidthsPlusAnchor_EqualsUsableWidth()
    {
        // Invariant: leftW + anchor.W + rightW == usableArea.W exactly (no rounding
        // loss because no division is performed). Use the 7680×2160 ultrawide case
        // with a 3840×2160 centered anchor — the natural target of this feature.
        var anchor = new Rect(1920, 0, 3840, 2160);
        var (left, right) = GameModeGeometry.ResolveSideColumns(UA7680, anchor);

        Assert.Equal(new Rect(0, 0, 1920, 2160), left);
        Assert.Equal(new Rect(5760, 0, 1920, 2160), right);
        Assert.Equal(UA7680.W, left.W + anchor.W + right.W);
    }

    // ---------------------------------------------------------------------
    // Cross-cutting invariants
    // ---------------------------------------------------------------------

    [Theory]
    [InlineData(AnchorKind.Center)]
    [InlineData(AnchorKind.Top)]
    [InlineData(AnchorKind.Bottom)]
    [InlineData(AnchorKind.Left)]
    [InlineData(AnchorKind.Right)]
    public void Roundtrip_AnchorInsideUsable_ForAllAnchorKinds(AnchorKind anchor)
    {
        var r = GameModeGeometry.ResolveAnchor(
            UA2560, 1920, 1080, SizeSpec.Native.Instance, anchor, 1.0);

        Assert.True(r.X >= UA2560.X);
        Assert.True(r.Y >= UA2560.Y);
        Assert.True(r.Right <= UA2560.Right);
        Assert.True(r.Bottom <= UA2560.Bottom);
    }
}
