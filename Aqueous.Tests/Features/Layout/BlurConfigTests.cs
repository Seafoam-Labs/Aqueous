using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Coverage for the global <c>[blur]</c> section parsed into <see cref="LayoutConfig.Blur"/>.
/// </summary>
public class BlurConfigTests
{
    [Fact]
    public void Parse_NoBlurSection_UsesDefault()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [layout]
            default = "tile"
            """);

        Assert.Equal(BlurSpec.Default, cfg.Blur);
        Assert.False(cfg.Blur.Enabled);
    }

    [Fact]
    public void Parse_BlurSection_ReadsAllScalars()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [blur]
            enabled = true
            radius  = 9
            passes  = 4
            """);

        Assert.True(cfg.Blur.Enabled);
        Assert.Equal(9, cfg.Blur.Radius);
        Assert.Equal(4, cfg.Blur.Passes);
    }

    [Fact]
    public void Parse_NegativeValues_ClampedToZero()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [blur]
            enabled = true
            radius  = -3
            passes  = -1
            """);

        Assert.Equal(0, cfg.Blur.Radius);
        Assert.Equal(0, cfg.Blur.Passes);
    }
}
