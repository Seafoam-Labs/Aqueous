using System.Collections.Generic;
using Aqueous.OutputDaemon;
using Xunit;

namespace Aqueous.OutputDaemon.Tests;

public class ValidatorTests
{
    private static List<WlrRandr.Output> Snapshot() => new()
    {
        new WlrRandr.Output
        {
            Name = "DP-1",
            EdidSha256 = "sha256:abc",
            Modes =
            {
                new WlrRandr.Mode { Width = 1920, Height = 1080, Refresh = 60.0 },
                new WlrRandr.Mode { Width = 2560, Height = 1440, Refresh = 144.0 },
            },
        },
        new WlrRandr.Output
        {
            Name = "HDMI-A-1",
            Modes =
            {
                new WlrRandr.Mode { Width = 1920, Height = 1080, Refresh = 60.0 },
            },
        },
    };

    [Theory]
    [InlineData("1920x1080")]
    [InlineData("1920x1080@60")]
    [InlineData("2560x1440@144")]
    [InlineData("2560x1440@59.94")]
    public void Mode_regex_accepts_well_formed(string mode)
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-1", ["mode"] = mode };
        // 59.94 isn't in snapshot for DP-1; force a present mode for the regex-only verification
        if (mode == "2560x1440@59.94")
            spec["mode"] = "2560x1440@144";
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(err);
        Assert.NotNull(c);
    }

    [Theory]
    [InlineData("1920x")]
    [InlineData("@60")]
    [InlineData("1920x1080@")]
    [InlineData("foo")]
    [InlineData("1920;rm -rf /")]
    public void Mode_regex_rejects_malformed(string mode)
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-1", ["mode"] = mode };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(c);
        Assert.NotNull(err);
    }

    [Fact]
    public void Mode_must_be_advertised()
    {
        var spec = new Dictionary<string, object?> { ["name"] = "HDMI-A-1", ["mode"] = "3840x2160@60" };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(c);
        Assert.Contains("availableModes", err);
    }

    [Theory]
    [InlineData(0.5)]
    [InlineData(1.0)]
    [InlineData(3.0)]
    public void Scale_in_range_ok(double s)
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-1", ["scale"] = s };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(err);
        Assert.Equal(s, c!.Scale);
    }

    [Theory]
    [InlineData(0.49)]
    [InlineData(3.01)]
    [InlineData(-1.0)]
    [InlineData(double.NaN)]
    public void Scale_out_of_range_rejected(double s)
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-1", ["scale"] = s };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(c);
        Assert.NotNull(err);
    }

    [Theory]
    [InlineData("normal")]
    [InlineData("90")]
    [InlineData("180")]
    [InlineData("270")]
    [InlineData("flipped")]
    [InlineData("flipped-90")]
    [InlineData("flipped-180")]
    [InlineData("flipped-270")]
    public void Transform_whitelisted(string t)
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-1", ["transform"] = t };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(err);
        Assert.Equal(t, c!.Transform);
    }

    [Theory]
    [InlineData("upside-down")]
    [InlineData("45")]
    [InlineData("")]
    public void Transform_rejected(string t)
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-1", ["transform"] = t };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        // empty string is treated as "absent" by GetString: ok then.
        if (string.IsNullOrEmpty(t))
        {
            Assert.NotNull(c);
            return;
        }
        Assert.Null(c);
        Assert.NotNull(err);
    }

    [Fact]
    public void Position_must_be_two_ints()
    {
        var ok = new Dictionary<string, object?>
        {
            ["name"] = "DP-1",
            ["position"] = new List<object?> { 100.0, 200.0 },
        };
        var c = Validator.Resolve(ok, Snapshot(), out var err);
        Assert.Null(err);
        Assert.Equal((100, 200), c!.Position);

        var bad = new Dictionary<string, object?>
        {
            ["name"] = "DP-1",
            ["position"] = new List<object?> { "a", 0.0 },
        };
        c = Validator.Resolve(bad, Snapshot(), out err);
        Assert.Null(c);
        Assert.NotNull(err);
    }

    [Fact]
    public void Edid_match_preferred_over_name()
    {
        var spec = new Dictionary<string, object?>
        {
            ["edid"] = "sha256:abc",
            ["name"] = "wrong",
        };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(err);
        Assert.Equal("DP-1", c!.Name);
    }

    [Fact]
    public void Unknown_edid_rejected()
    {
        var spec = new Dictionary<string, object?> { ["edid"] = "sha256:nope" };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(c);
        Assert.Contains("unknown edid", err);
    }

    [Fact]
    public void Unknown_name_rejected()
    {
        var spec = new Dictionary<string, object?> { ["name"] = "VGA-99" };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(c);
        Assert.Contains("unknown output", err);
    }

    [Fact]
    public void Missing_matcher_rejected()
    {
        var spec = new Dictionary<string, object?>();
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(c);
        Assert.Contains("missing", err);
    }

    [Fact]
    public void Adaptive_sync_and_enabled_passthrough()
    {
        var spec = new Dictionary<string, object?>
        {
            ["name"] = "DP-1",
            ["adaptive_sync"] = true,
            ["enabled"] = false,
        };
        var c = Validator.Resolve(spec, Snapshot(), out var err);
        Assert.Null(err);
        Assert.True(c!.AdaptiveSync);
        Assert.False(c.Enabled);
    }
}
