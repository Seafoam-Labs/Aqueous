using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Coverage for the global <c>[opacity]</c> section parsed into <see cref="LayoutConfig.Opacity"/>.
/// </summary>
public class OpacityConfigTests
{
    [Fact]
    public void Parse_NoOpacitySection_UsesDefault()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [layout]
            default = "tile"
            """);

        Assert.Equal(OpacitySpec.Default, cfg.Opacity);
        Assert.False(cfg.Opacity.Enabled);
        Assert.Equal(1.0, cfg.Opacity.Value);
    }

    [Fact]
    public void Parse_OpacitySection_ReadsAllScalars()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [opacity]
            enabled = true
            value   = 0.85
            """);

        Assert.True(cfg.Opacity.Enabled);
        Assert.Equal(0.85, cfg.Opacity.Value);
    }

    [Fact]
    public void Parse_OutOfRangeValues_ClampedToUnitInterval()
    {
        var low = LayoutConfigLoader.Parse("""
            [opacity]
            enabled = true
            value   = -0.5
            """);
        var high = LayoutConfigLoader.Parse("""
            [opacity]
            enabled = true
            value   = 1.7
            """);

        Assert.Equal(0.0, low.Opacity.Value);
        Assert.Equal(1.0, high.Opacity.Value);
    }
}
