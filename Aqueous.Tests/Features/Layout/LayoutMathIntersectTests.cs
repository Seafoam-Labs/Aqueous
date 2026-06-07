using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Coverage for the pure <see cref="LayoutMath.Intersect"/> helper used by Phase D of the
/// <c>river-layer-shell-v1</c> migration to fold a per-output <c>non_exclusive_area</c> hint into
/// the strut-derived usable rect.
/// </summary>
public class LayoutMathIntersectTests
{
    [Fact]
    public void Overlapping_returns_common_region()
    {
        var a = new Rect(0, 0, 1920, 1080);
        var b = new Rect(0, 30, 1920, 1050); // a 30px top panel removed

        var r = LayoutMath.Intersect(a, b);

        Assert.Equal(new Rect(0, 30, 1920, 1050), r);
    }

    [Fact]
    public void Contained_rect_returns_itself()
    {
        var output = new Rect(0, 0, 2560, 1440);
        var inner = new Rect(100, 50, 2000, 1200);

        Assert.Equal(inner, LayoutMath.Intersect(output, inner));
    }

    [Fact]
    public void Honors_global_offset_for_second_output()
    {
        // Second monitor placed at x=1920; layer area in global coords.
        var output = new Rect(1920, 0, 1920, 1080);
        var layer = new Rect(1920, 40, 1920, 1040);

        Assert.Equal(new Rect(1920, 40, 1920, 1040), LayoutMath.Intersect(output, layer));
    }

    [Fact]
    public void NonOverlapping_returns_empty()
    {
        var a = new Rect(0, 0, 100, 100);
        var b = new Rect(500, 500, 100, 100);

        Assert.Equal(Rect.Empty, LayoutMath.Intersect(a, b));
    }

    [Theory]
    [InlineData(0, 0, 0, 100)]
    [InlineData(0, 0, 100, 0)]
    [InlineData(0, 0, -5, 100)]
    public void Degenerate_input_returns_empty(int x, int y, int w, int h)
    {
        var valid = new Rect(0, 0, 100, 100);
        var degenerate = new Rect(x, y, w, h);

        Assert.Equal(Rect.Empty, LayoutMath.Intersect(valid, degenerate));
        Assert.Equal(Rect.Empty, LayoutMath.Intersect(degenerate, valid));
    }
}
