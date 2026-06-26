using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Coverage for the global <c>[workspace_transition]</c> section parsed into
/// <see cref="LayoutConfig.WorkspaceTransition"/>.
/// </summary>
public class WorkspaceTransitionConfigTests
{
    [Fact]
    public void Parse_NoSection_UsesDefault()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [layout]
            default = "tile"
            """);

        Assert.Equal(WorkspaceTransitionSpec.Default, cfg.WorkspaceTransition);
        Assert.True(cfg.WorkspaceTransition.Enabled);
    }

    [Fact]
    public void Parse_Disabled_TogglesOff()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [workspace_transition]
            enabled = false
            """);

        Assert.False(cfg.WorkspaceTransition.Enabled);
        // Rate keeps its default when not overridden.
        Assert.Equal(WorkspaceTransitionSpec.Default.Rate, cfg.WorkspaceTransition.Rate);
    }

    [Fact]
    public void Parse_CustomRate_IsRead()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [workspace_transition]
            enabled = true
            rate    = 12.5
            """);

        Assert.True(cfg.WorkspaceTransition.Enabled);
        Assert.Equal(12.5, cfg.WorkspaceTransition.Rate);
    }

    [Fact]
    public void Parse_NegativeRate_ClampedToZero()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [workspace_transition]
            rate = -4.0
            """);

        Assert.Equal(0.0, cfg.WorkspaceTransition.Rate);
    }
}
