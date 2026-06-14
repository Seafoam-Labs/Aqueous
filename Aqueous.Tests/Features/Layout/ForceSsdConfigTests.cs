using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Coverage for the <c>[layout].force_ssd</c> scalar parsed into <see cref="LayoutConfig.ForceSsd"/>.
/// </summary>
public class ForceSsdConfigTests
{
    [Fact]
    public void Parse_NoKey_DefaultsToFalse()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [layout]
            default = "tile"
            """);

        Assert.False(cfg.ForceSsd);
    }

    [Fact]
    public void Parse_ForceSsdTrue_ReadsTrue()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [layout]
            default   = "tile"
            force_ssd = true
            """);

        Assert.True(cfg.ForceSsd);
    }

    [Fact]
    public void Parse_ForceSsdFalse_ReadsFalse()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [layout]
            force_ssd = false
            """);

        Assert.False(cfg.ForceSsd);
    }
}
