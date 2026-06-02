using Aqueous.Features.Input;
using Xunit;

namespace Aqueous.Tests.Features.Input;

/// <summary>
/// Covers the standalone <see cref="InputConfigParser"/> extracted out of the layout loader:
/// scalar knobs, XKB keys, per-device sub-tables, dash/underscore key normalisation, and the
/// permissive posture (unknown keys/sections ignored, defaults when absent).
/// </summary>
public class InputConfigParserTests
{
    [Fact]
    public void Empty_ReturnsDefaults()
    {
        var cfg = InputConfigParser.Parse("");
        var d = InputConfig.Default;

        Assert.Equal(d.FocusFollowsMouse, cfg.FocusFollowsMouse);
        Assert.Equal(d.PointerAcceleration, cfg.PointerAcceleration);
        Assert.Equal(d.PointerAccelerationFactor, cfg.PointerAccelerationFactor);
        Assert.Null(cfg.XkbLayout);
        Assert.Null(cfg.XkbVariant);
        Assert.Null(cfg.XkbOptions);
    }

    [Fact]
    public void Input_ScalarsAndXkb_Parsed()
    {
        const string toml = """
            [input]
            focus_follows_mouse = true
            pointer_acceleration = true
            pointer_acceleration_factor = 0.5
            xkb_layout = "us"
            xkb_variant = "dvorak"
            xkb_options = "caps:escape"
            """;

        var cfg = InputConfigParser.Parse(toml);

        Assert.True(cfg.FocusFollowsMouse);
        Assert.True(cfg.PointerAcceleration);
        Assert.Equal(0.5, cfg.PointerAccelerationFactor);
        Assert.Equal("us", cfg.XkbLayout);
        Assert.Equal("dvorak", cfg.XkbVariant);
        Assert.Equal("caps:escape", cfg.XkbOptions);
    }

    [Fact]
    public void PerDevice_Touchpad_Parsed()
    {
        const string toml = """
            [input.touchpad]
            natural_scroll = true
            tap = true
            accel_speed = 0.3
            click_method = "clickfinger"
            """;

        var cfg = InputConfigParser.Parse(toml);

        Assert.True(cfg.Touchpad.NaturalScroll);
        Assert.True(cfg.Touchpad.Tap);
        Assert.Equal(0.3, cfg.Touchpad.AccelSpeed);
        Assert.Equal("clickfinger", cfg.Touchpad.ClickMethod);
        // Untouched devices stay at their nullable defaults.
        Assert.Null(cfg.Mouse.NaturalScroll);
        Assert.Null(cfg.Trackpoint.Tap);
    }

    [Fact]
    public void PerDevice_DashKeys_NormalisedToUnderscore()
    {
        const string toml = """
            [input.mouse]
            accel-speed = 0.7
            natural-scroll = true
            """;

        var cfg = InputConfigParser.Parse(toml);

        Assert.Equal(0.7, cfg.Mouse.AccelSpeed);
        Assert.True(cfg.Mouse.NaturalScroll);
    }

    [Fact]
    public void NonInputSectionsAndUnknownKeys_Ignored()
    {
        const string toml = """
            [layout]
            default = "tile"
            gaps_outer = 99

            [[output]]
            name = "DP-1"
            layout = "tile"

            [input]
            focus_follows_mouse = true
            bogus_key = "ignored"
            """;

        var cfg = InputConfigParser.Parse(toml);

        Assert.True(cfg.FocusFollowsMouse);
        // Defaults preserved for everything the [input] block didn't set.
        Assert.Null(cfg.XkbOptions);
        Assert.Equal(InputConfig.Default.PointerAcceleration, cfg.PointerAcceleration);
    }

    [Fact]
    public void InlineComment_Stripped()
    {
        const string toml = """
            [input]
            xkb_options = "caps:escape"  # remap caps lock
            """;

        var cfg = InputConfigParser.Parse(toml);

        Assert.Equal("caps:escape", cfg.XkbOptions);
    }
}
