using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Aqueous.Features.SnapZones;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Pure-data tests for the SnapZones subsystem: <see cref="SnapZoneLayout.Resolve"/>,
/// <see cref="SnapZoneLayout.Hit"/>, <see cref="SnapZoneStore"/> wildcard
/// fallback, and <see cref="LayoutConfigLoader"/> parsing of the
/// <c>[[snapzones]]</c> / <c>[[snapzones.zone]]</c> arrays-of-tables.
///
/// These functions are the entire feature outside the drag pipeline,
/// so high coverage here is cheap and gives us strong confidence that
/// a config typo or output rename can never break window placement at
/// runtime.
/// </summary>
public class SnapZoneTests
{
    private static readonly Rect Output1080p = new(0, 0, 1920, 1080);

    [Fact]
    public void Resolve_HalfWidth_PicksLeftHalf()
    {
        var z = new SnapZone("left-half", 0.0, 0.0, 0.5, 1.0);
        Assert.Equal(new Rect(0, 0, 960, 1080), SnapZoneLayout.Resolve(z, Output1080p));
    }

    [Fact]
    public void Resolve_OffsetOutput_TranslatesByOrigin()
    {
        // Second monitor on the right of the first.
        var output2 = new Rect(1920, 0, 1280, 1024);
        var z = new SnapZone("right-half", 0.5, 0.0, 0.5, 1.0);
        var r = SnapZoneLayout.Resolve(z, output2);
        Assert.Equal(1920 + 640, r.X);
        Assert.Equal(0, r.Y);
        Assert.Equal(640, r.W);
        Assert.Equal(1024, r.H);
    }

    [Fact]
    public void Resolve_DegenerateZone_ReturnsEmpty()
    {
        var z = new SnapZone("zero-w", 0.0, 0.0, 0.0, 1.0);
        Assert.Equal(Rect.Empty, SnapZoneLayout.Resolve(z, Output1080p));
    }

    [Fact]
    public void Resolve_OutOfRangeNorm_ClampsTo01()
    {
        var z = new SnapZone("oversized", -0.5, -0.5, 2.0, 2.0);
        var r = SnapZoneLayout.Resolve(z, Output1080p);
        // After clamp: nx=0, ny=0, nw=1, nh=1 → full output rect.
        Assert.Equal(Output1080p, r);
    }

    [Fact]
    public void Hit_FirstMatchWins_OnOverlap()
    {
        // Two zones; left-half fully overlaps top-right of layout.
        var layout = new SnapZoneLayout
        {
            Zones = new[]
            {
                new SnapZone("a", 0.0, 0.0, 1.0, 1.0), // full screen
                new SnapZone("b", 0.5, 0.0, 0.5, 0.5), // top-right quad
            },
        };
        Assert.Equal("a", layout.Hit(1500, 100, Output1080p)?.Name);
    }

    [Fact]
    public void Hit_OutsideAnyZone_ReturnsNull()
    {
        var layout = new SnapZoneLayout
        {
            Zones = new[] { new SnapZone("left", 0.0, 0.0, 0.5, 1.0) },
        };
        Assert.Null(layout.Hit(1000, 500, Output1080p)); // pointer in right half
    }

    [Fact]
    public void Hit_SkipsDegenerateZones()
    {
        var layout = new SnapZoneLayout
        {
            Zones = new[]
            {
                new SnapZone("zero", 0.0, 0.0, 0.0, 1.0), // degenerate
                new SnapZone("right", 0.5, 0.0, 0.5, 1.0),
            },
        };
        Assert.Equal("right", layout.Hit(1500, 500, Output1080p)?.Name);
    }

    [Fact]
    public void Store_WildcardFallback_AppliesToAllOutputs()
    {
        var dict = new Dictionary<string, IReadOnlyList<SnapZoneLayout>>
        {
            [SnapZoneStore.Wildcard] = new[]
            {
                new SnapZoneLayout
                {
                    Name = "default",
                    Zones = new[] { new SnapZone("full", 0.0, 0.0, 1.0, 1.0) },
                },
            },
        };
        var store = new SnapZoneStore(dict);
        var l = store.ActiveLayoutFor(new IntPtr(1), "DP-1");
        Assert.NotNull(l);
        Assert.Single(l!.Zones);
    }

    [Fact]
    public void Store_OutputSpecific_WinsOverWildcard()
    {
        var perDp1 = new SnapZoneLayout
        {
            Name = "thirds",
            Zones = new[]
            {
                new SnapZone("l", 0.0, 0.0, 1.0 / 3.0, 1.0),
                new SnapZone("c", 1.0 / 3.0, 0.0, 1.0 / 3.0, 1.0),
                new SnapZone("r", 2.0 / 3.0, 0.0, 1.0 / 3.0, 1.0),
            },
        };
        var wild = new SnapZoneLayout
        {
            Zones = new[] { new SnapZone("full", 0.0, 0.0, 1.0, 1.0) },
        };
        var dict = new Dictionary<string, IReadOnlyList<SnapZoneLayout>>
        {
            ["DP-1"] = new[] { perDp1 },
            [SnapZoneStore.Wildcard] = new[] { wild },
        };
        var store = new SnapZoneStore(dict);

        Assert.Equal("thirds", store.ActiveLayoutFor(new IntPtr(1), "DP-1")!.Name);
        Assert.Equal("default", store.ActiveLayoutFor(new IntPtr(2), "HDMI-A-1")!.Name);
    }

    [Fact]
    public void Store_EmptyByDefault_NoLayouts()
    {
        Assert.True(SnapZoneStore.Empty.IsEmpty);
        Assert.Null(SnapZoneStore.Empty.ActiveLayoutFor(new IntPtr(1), "DP-1"));
    }

    [Fact]
    public void Store_CycleLayout_WrapsAround()
    {
        var dict = new Dictionary<string, IReadOnlyList<SnapZoneLayout>>
        {
            [SnapZoneStore.Wildcard] = new[]
            {
                new SnapZoneLayout { Name = "a" },
                new SnapZoneLayout { Name = "b" },
            },
        };
        var store = new SnapZoneStore(dict);
        var output = new IntPtr(7);

        Assert.Equal("a", store.ActiveLayoutFor(output, null)!.Name);
        store.CycleLayout(output, null);
        Assert.Equal("b", store.ActiveLayoutFor(output, null)!.Name);
        store.CycleLayout(output, null);
        Assert.Equal("a", store.ActiveLayoutFor(output, null)!.Name);
    }

    [Fact]
    public void Loader_ParsesSnapZonesArrayOfTables()
    {
        const string toml = """
            [[snapzones]]
            output = "DP-1"
            layout = "halves"

            [[snapzones.zone]]
            name = "left"
            x = 0.0
            y = 0.0
            w = 0.5
            h = 1.0

            [[snapzones.zone]]
            name = "right"
            x = 0.5
            y = 0.0
            w = 0.5
            h = 1.0
            """;

        var cfg = LayoutConfig.Parse(toml);
        var layouts = cfg.SnapZones.LayoutsFor("DP-1");
        Assert.Single(layouts);
        Assert.Equal("halves", layouts[0].Name);
        Assert.Equal(2, layouts[0].Zones.Count);
        Assert.Equal("left", layouts[0].Zones[0].Name);
        Assert.Equal(0.5, layouts[0].Zones[1].NX);
    }

    [Fact]
    public void Loader_WildcardOutput_DefaultsToStar()
    {
        // omit `output` → defaults to wildcard
        const string toml = """
            [[snapzones]]
            layout = "default"

            [[snapzones.zone]]
            name = "full"
            x = 0.0
            y = 0.0
            w = 1.0
            h = 1.0
            """;

        var cfg = LayoutConfig.Parse(toml);
        var l = cfg.SnapZones.ActiveLayoutFor(new IntPtr(99), "any-output-name");
        Assert.NotNull(l);
        Assert.Equal("full", l!.Zones[0].Name);
    }

    [Fact]
    public void Loader_MultipleBuckets_KeptSeparately()
    {
        const string toml = """
            [[snapzones]]
            output = "DP-1"

            [[snapzones.zone]]
            name = "z1"
            x = 0.0
            y = 0.0
            w = 1.0
            h = 1.0

            [[snapzones]]
            output = "HDMI-A-1"

            [[snapzones.zone]]
            name = "z2"
            x = 0.0
            y = 0.0
            w = 0.5
            h = 0.5
            """;

        var cfg = LayoutConfig.Parse(toml);
        Assert.Equal("z1", cfg.SnapZones.LayoutsFor("DP-1")[0].Zones[0].Name);
        Assert.Equal("z2", cfg.SnapZones.LayoutsFor("HDMI-A-1")[0].Zones[0].Name);
    }

    [Fact]
    public void Loader_MissingSnapzonesSection_StoreIsEmpty()
    {
        var cfg = LayoutConfig.Parse("[layout]\ndefault = \"tile\"\n");
        Assert.True(cfg.SnapZones.IsEmpty);
    }

    [Fact]
    public void Loader_OtherSectionAfterSnapzones_FlushesBucket()
    {
        // A [keybinds] section after the snapzones bucket should still
        // produce a parsed snap zone — the bucket is flushed cleanly
        // when a non-snapzones table opens.
        const string toml = """
            [[snapzones]]
            output = "*"

            [[snapzones.zone]]
            name = "full"
            x = 0.0
            y = 0.0
            w = 1.0
            h = 1.0

            [keybinds]
            """;
        var cfg = LayoutConfig.Parse(toml);
        Assert.False(cfg.SnapZones.IsEmpty);
        Assert.Equal("full", cfg.SnapZones.LayoutsFor("*")[0].Zones[0].Name);
    }

    [Fact]
    public void Loader_DefaultActivator_IsAlways()
    {
        const string toml = """
            [[snapzones]]
            output = "*"

            [[snapzones.zone]]
            name = "z"
            x = 0.0
            y = 0.0
            w = 1.0
            h = 1.0
            """;
        var cfg = LayoutConfig.Parse(toml);
        var l = cfg.SnapZones.LayoutsFor("*")[0];
        Assert.Equal(SnapActivator.Always, l.Activator);
    }

    [Theory]
    [InlineData("Shift", SnapActivator.Shift)]
    [InlineData("shift", SnapActivator.Shift)]
    [InlineData("Ctrl", SnapActivator.Ctrl)]
    [InlineData("control", SnapActivator.Ctrl)]
    [InlineData("Alt", SnapActivator.Alt)]
    [InlineData("Super", SnapActivator.Super)]
    [InlineData("meta", SnapActivator.Super)]
    [InlineData("logo", SnapActivator.Super)]
    [InlineData("none", SnapActivator.Always)]
    [InlineData("always", SnapActivator.Always)]
    [InlineData("nonsense", SnapActivator.Always)]
    public void Loader_ParsesActivatorKey(string raw, SnapActivator expected)
    {
        string toml = $$"""
            [[snapzones]]
            output = "*"
            activator = "{{raw}}"

            [[snapzones.zone]]
            name = "z"
            x = 0.0
            y = 0.0
            w = 1.0
            h = 1.0
            """;
        var cfg = LayoutConfig.Parse(toml);
        var l = cfg.SnapZones.LayoutsFor("*")[0];
        Assert.Equal(expected, l.Activator);
    }
}
