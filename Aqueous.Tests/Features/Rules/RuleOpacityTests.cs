using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Rules;

/// <summary>
/// Coverage for the per-window <c>opacity</c> rule field. Tri-state: omit = inherit
/// global default (null), otherwise a 0..1 fraction applied to the window's content.
/// </summary>
public class RuleOpacityTests
{
    [Fact]
    public void OmittedOpacity_IsNull_InheritsGlobalDefault()
    {
        var cfg = RulesTomlReader.Parse("""
            [[window]]
            app_id = "dota2"
            """);

        var rule = Assert.Single(cfg.Windows);
        Assert.Null(rule.Opacity);
        Assert.Null(new RulePlacement(rule).OpacityOverride);
    }

    [Fact]
    public void ExplicitOpacity_Overrides()
    {
        var cfg = RulesTomlReader.Parse("""
            [[window]]
            app_id  = "Alacritty"
            opacity = 0.85
            """);

        var rule = Assert.Single(cfg.Windows);
        Assert.Equal(0.85, rule.Opacity);
        Assert.Equal(0.85, new RulePlacement(rule).OpacityOverride);
    }

    [Fact]
    public void OutOfRangeOpacity_ClampedToUnitInterval()
    {
        var cfg = RulesTomlReader.Parse("""
            [[window]]
            app_id  = "foo"
            opacity = 1.5

            [[window]]
            app_id  = "bar"
            opacity = -0.25
            """);

        Assert.Equal(2, cfg.Windows.Count);
        Assert.Equal(1.0, cfg.Windows[0].Opacity);
        Assert.Equal(0.0, cfg.Windows[1].Opacity);
    }
}
