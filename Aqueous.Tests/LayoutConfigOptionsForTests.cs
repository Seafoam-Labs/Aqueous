using System.Collections.Generic;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Phase 3 — coverage tests for <see cref="LayoutConfig.OptionsFor(string)"/>
/// and the public construction surface (defaults, slots, border). The
/// loader has its own dedicated tests; here we pin the merge semantics
/// only.
/// </summary>
public class LayoutConfigOptionsForTests
{
    [Fact]
    public void OptionsFor_UnknownLayout_ReturnsDefaults()
    {
        var cfg = new LayoutConfig
        {
            Defaults = new LayoutOptions(11, 5, 0.66, 2, new Dictionary<string, string>()),
        };
        var opts = cfg.OptionsFor("does-not-exist");
        Assert.Equal(11, opts.GapsOuter);
        Assert.Equal(5, opts.GapsInner);
        Assert.Equal(0.66, opts.MasterRatio);
        Assert.Equal(2, opts.MasterCount);
    }

    [Fact]
    public void OptionsFor_PerLayout_OverridesDefaultsWhereSet()
    {
        var perExtra = new Dictionary<string, string> { ["column_width"] = "0.3" };
        var cfg = new LayoutConfig
        {
            Defaults = new LayoutOptions(8, 4, 0.55, 1, new Dictionary<string, string>()),
            PerLayoutOpts = new Dictionary<string, LayoutOptions>
            {
                // Only outer set; inner=0 => fall back to defaults' 4.
                ["scrolling"] = new(20, 0, 0, 0, perExtra),
            },
        };
        var opts = cfg.OptionsFor("scrolling");
        Assert.Equal(20, opts.GapsOuter);
        Assert.Equal(4, opts.GapsInner);
        Assert.Equal(0.55, opts.MasterRatio);
        Assert.Equal(1, opts.MasterCount);
        Assert.Same(perExtra, opts.Extra);
    }

    [Fact]
    public void OptionsFor_LayoutId_DelegatesToStringOverload()
    {
        var cfg = new LayoutConfig
        {
            PerLayoutOpts = new Dictionary<string, LayoutOptions>
            {
                ["tile"] = new(99, 0, 0, 0, new Dictionary<string, string>()),
            },
        };
        Assert.Equal(99, cfg.OptionsFor(new LayoutId("tile")).GapsOuter);
    }

    [Fact]
    public void Default_HasExpectedSlotMapping()
    {
        var cfg = LayoutConfig.Default;
        Assert.Equal("tile", cfg.DefaultLayout);
        Assert.Equal("tile", cfg.Slots["primary"]);
        Assert.Equal("float", cfg.Slots["secondary"]);
        Assert.Equal("monocle", cfg.Slots["tertiary"]);
        Assert.Equal("grid", cfg.Slots["quaternary"]);
    }

    [Fact]
    public void Default_ExposesNonZeroBorder()
    {
        Assert.True(LayoutConfig.Default.Border.Width > 0);
    }
}
