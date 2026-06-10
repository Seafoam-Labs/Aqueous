using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Rules;

/// <summary>
/// Coverage for the per-window <c>blur</c> matcher field added for blur exclusion
/// (e.g. games). Tri-state: omit = inherit global default (null), false = exclude,
/// true = force-include.
/// </summary>
public class RuleBlurTests
{
    [Fact]
    public void OmittedBlur_IsNull_InheritsGlobalDefault()
    {
        var cfg = RulesTomlReader.Parse("""
            [[window]]
            app_id = "dota2"
            """);

        var rule = Assert.Single(cfg.Windows);
        Assert.Null(rule.Blur);
        Assert.Null(new RulePlacement(rule).BlurOverride);
    }

    [Fact]
    public void BlurFalse_ForceExcludes()
    {
        var cfg = RulesTomlReader.Parse("""
            [[window]]
            app_id = "steam_app_570"
            blur   = false
            """);

        var rule = Assert.Single(cfg.Windows);
        Assert.False(rule.Blur);
        Assert.False(new RulePlacement(rule).BlurOverride);
    }

    [Fact]
    public void BlurTrue_ForceIncludes()
    {
        var cfg = RulesTomlReader.Parse("""
            [[window]]
            app_id = "Alacritty"
            blur   = true
            """);

        var rule = Assert.Single(cfg.Windows);
        Assert.True(rule.Blur);
        Assert.True(new RulePlacement(rule).BlurOverride);
    }
}
