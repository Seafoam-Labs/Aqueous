using Aqueous.Features.Layout;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch.Services;
using Aqueous.Features.Rules;
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
        Assert.False(cfg.Opacity.FocusSensitive);
        Assert.Equal(1.0, cfg.Opacity.Focused);
        Assert.Equal(1.0, cfg.Opacity.Unfocused);
    }

    [Fact]
    public void Parse_OpacitySection_ReadsAllScalars()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [opacity]
            enabled         = true
            value           = 0.85
            focus_sensitive = true
            focused         = 1.0
            unfocused       = 0.75
            """);

        Assert.True(cfg.Opacity.Enabled);
        Assert.Equal(0.85, cfg.Opacity.Value);
        Assert.True(cfg.Opacity.FocusSensitive);
        Assert.Equal(1.0, cfg.Opacity.Focused);
        Assert.Equal(0.75, cfg.Opacity.Unfocused);
    }

    [Fact]
    public void Parse_StableOpacitySection_LeavesFocusSensitivityDisabled()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [opacity]
            enabled = true
            value   = 0.85
            """);

        Assert.True(cfg.Opacity.Enabled);
        Assert.Equal(0.85, cfg.Opacity.Value);
        Assert.False(cfg.Opacity.FocusSensitive);
        Assert.Equal(1.0, cfg.Opacity.Focused);
        Assert.Equal(1.0, cfg.Opacity.Unfocused);
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
            focused = 2.0
            unfocused = 1.5
            """);

        Assert.Equal(0.0, low.Opacity.Value);
        Assert.Equal(1.0, high.Opacity.Value);
        Assert.Equal(1.0, high.Opacity.Focused);
        Assert.Equal(1.0, high.Opacity.Unfocused);
    }

    [Fact]
    public void Parse_FocusSensitiveOutOfRangeValues_ClampedToUnitInterval()
    {
        var cfg = LayoutConfigLoader.Parse("""
            [opacity]
            enabled = true
            focus_sensitive = true
            focused = 2.0
            unfocused = -0.5
            """);

        Assert.True(cfg.Opacity.FocusSensitive);
        Assert.Equal(1.0, cfg.Opacity.Focused);
        Assert.Equal(0.0, cfg.Opacity.Unfocused);
    }

    [Fact]
    public void ResolveWindowOpacity_StableOpacity_IgnoresFocus()
    {
        var window = new WindowEntry();
        var cfg = new OpacitySpec(true, 0.85, false, 1.0, 0.75);

        Assert.Equal(0.85, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, (IntPtr)1, cfg));
        Assert.Equal(0.85, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, (IntPtr)2, cfg));
        Assert.Equal(0.85, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, IntPtr.Zero, cfg));
    }

    [Fact]
    public void ResolveWindowOpacity_FocusSensitive_UsesFocusedAndUnfocusedValues()
    {
        var window = new WindowEntry();
        var cfg = new OpacitySpec(true, 0.85, true, 1.0, 0.75);

        Assert.Equal(1.0, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, (IntPtr)1, cfg));
        Assert.Equal(0.75, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, (IntPtr)2, cfg));
        Assert.Equal(0.75, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, IntPtr.Zero, cfg));
    }

    [Fact]
    public void ResolveWindowOpacity_RuleOverrideWinsOverFocusSensitiveConfig()
    {
        var window = new WindowEntry
        {
            Placement = new RulePlacement(new WindowRule(
                AppId: "foot",
                Class: null,
                Title: null,
                Layout: "tile",
                Anchor: AnchorKind.Center,
                Size: SizeSpec.Native.Instance,
                Scale: 1.0,
                Tag: null,
                Fullscreen: false,
                Opacity: 0.65)),
        };
        var cfg = new OpacitySpec(true, 0.85, true, 1.0, 0.75);

        Assert.Equal(0.65, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, (IntPtr)1, cfg));
        Assert.Equal(0.65, ManagerEventService.ResolveWindowOpacity(window, (IntPtr)1, IntPtr.Zero, cfg));
    }
}
