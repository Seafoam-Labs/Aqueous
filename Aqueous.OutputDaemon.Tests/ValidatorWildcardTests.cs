using System.Collections.Generic;
using System.Linq;
using Aqueous.OutputDaemon;
using Xunit;

namespace Aqueous.OutputDaemon.Tests;

public class ValidatorWildcardTests
{
    private static List<WlrRandr.Output> Snapshot() => new()
    {
        new WlrRandr.Output
        {
            Name = "DP-1",
            EdidSha256 = "sha256:dp1",
            Modes =
            {
                new WlrRandr.Mode { Width = 1920, Height = 1080, Refresh = 60.0 },
                new WlrRandr.Mode { Width = 2560, Height = 1440, Refresh = 144.0 },
            },
        },
        new WlrRandr.Output
        {
            Name = "DP-2",
            EdidSha256 = "sha256:dp2",
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
        new WlrRandr.Output
        {
            Name = "eDP-1",
            Modes =
            {
                new WlrRandr.Mode { Width = 1920, Height = 1080, Refresh = 60.0 },
            },
        },
    };

    [Fact]
    public void ResolveAll_NameGlob_MatchesAllConnectedOutputs()
    {
        var spec = new Dictionary<string, object?>
        {
            ["name"] = "DP-*",
            ["mode"] = "2560x1440@144",
            ["scale"] = 1.0,
        };
        var list = Validator.ResolveAll(spec, Snapshot(), out var err, out var warnings);
        Assert.Null(err);
        Assert.Empty(warnings);
        Assert.Equal(2, list.Count);
        Assert.Equal(new[] { "DP-1", "DP-2" }, list.Select(c => c.Name).ToArray());
        Assert.All(list, c => Assert.Equal("2560x1440@144", c.Mode));
        Assert.All(list, c => Assert.Equal(1.0, c.Scale));
    }

    [Fact]
    public void ResolveAll_NameGlob_NoMatches_ReturnsEmptyWithError()
    {
        var snap = new List<WlrRandr.Output>
        {
            new() { Name = "eDP-1" },
        };
        var spec = new Dictionary<string, object?> { ["name"] = "DP-*" };
        var list = Validator.ResolveAll(spec, snap, out var err, out var warnings);
        Assert.Empty(list);
        Assert.NotNull(err);
        Assert.Contains("DP-*", err);
    }

    [Fact]
    public void ResolveAll_NameGlob_PerOutputModeValidation()
    {
        // HDMI-A-1 doesn't advertise 2560x1440. With "*" wildcard, it should be skipped (warning),
        // not abort the whole spec.
        var spec = new Dictionary<string, object?>
        {
            ["name"] = "*",
            ["mode"] = "2560x1440@144",
        };
        var list = Validator.ResolveAll(spec, Snapshot(), out var err, out var warnings);
        Assert.Null(err);
        // DP-1 and DP-2 succeed; HDMI-A-1 and eDP-1 warn.
        Assert.Equal(new[] { "DP-1", "DP-2" }, list.Select(c => c.Name).ToArray());
        Assert.Equal(2, warnings.Count);
        Assert.Contains(warnings, w => w.StartsWith("HDMI-A-1"));
        Assert.Contains(warnings, w => w.StartsWith("eDP-1"));
    }

    [Fact]
    public void ResolveAll_NameGlob_WithPosition_Rejected()
    {
        var spec = new Dictionary<string, object?>
        {
            ["name"] = "DP-*",
            ["position"] = new List<object?> { 0.0, 0.0 },
        };
        var list = Validator.ResolveAll(spec, Snapshot(), out var err, out var warnings);
        Assert.Empty(list);
        Assert.NotNull(err);
        Assert.Contains("position", err);
    }

    [Fact]
    public void ResolveAll_Edid_NeverGlobs()
    {
        var spec = new Dictionary<string, object?> { ["edid"] = "DP-*" };
        var list = Validator.ResolveAll(spec, Snapshot(), out var err, out _);
        Assert.Empty(list);
        Assert.NotNull(err);
        Assert.Contains("unknown edid", err);
    }

    [Fact]
    public void ResolveAll_PlainName_BehavesAsBefore()
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-1", ["mode"] = "1920x1080@60" };
        var list = Validator.ResolveAll(spec, Snapshot(), out var err, out var warnings);
        Assert.Null(err);
        Assert.Empty(warnings);
        Assert.Single(list);
        Assert.Equal("DP-1", list[0].Name);
    }

    [Fact]
    public void ResolveAll_QuestionMarkGlob_MatchesSingleChar()
    {
        var spec = new Dictionary<string, object?> { ["name"] = "DP-?" };
        var list = Validator.ResolveAll(spec, Snapshot(), out var err, out _);
        Assert.Null(err);
        Assert.Equal(new[] { "DP-1", "DP-2" }, list.Select(c => c.Name).ToArray());
    }

    [Fact]
    public void Merge_WildcardThenSpecific_SpecificOverrides()
    {
        // Wildcard first, specifics override per-field.
        var wildcard = Validator.ResolveAll(
            new Dictionary<string, object?>
            {
                ["name"] = "DP-*",
                ["mode"] = "1920x1080@60",
                ["scale"] = 1.0,
            },
            Snapshot(), out _, out _);
        var specific = Validator.ResolveAll(
            new Dictionary<string, object?>
            {
                ["name"] = "DP-1",
                ["mode"] = "2560x1440@144",
            },
            Snapshot(), out _, out _);

        var merged = Validator.Merge(wildcard.Concat(specific));
        Assert.Equal(2, merged.Count);
        var dp1 = merged.First(c => c.Name == "DP-1");
        var dp2 = merged.First(c => c.Name == "DP-2");
        Assert.Equal("2560x1440@144", dp1.Mode); // overridden
        Assert.Equal(1.0, dp1.Scale);            // inherited from wildcard
        Assert.Equal("1920x1080@60", dp2.Mode);
        Assert.Equal(1.0, dp2.Scale);
    }

    [Fact]
    public void Resolve_Shim_StillReturnsFirstOrNull()
    {
        // Plain name path.
        var c = Validator.Resolve(
            new Dictionary<string, object?> { ["name"] = "DP-1" }, Snapshot(), out var err);
        Assert.Null(err);
        Assert.NotNull(c);
        Assert.Equal("DP-1", c!.Name);

        // Wildcard path: returns first match deterministically.
        var c2 = Validator.Resolve(
            new Dictionary<string, object?> { ["name"] = "DP-*" }, Snapshot(), out var err2);
        Assert.Null(err2);
        Assert.NotNull(c2);
        Assert.Equal("DP-1", c2!.Name);
    }
}
