using System.Collections.Generic;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Coverage for the EDID-aware TOML selectors introduced in <see cref="OutputSelector"/>: the
/// daemon-style <c>edid</c> hash, <c>make</c>/<c>model</c>/<c>serial</c>, and the <c>name</c>
/// fallback all parse out of <c>[[output]]</c> and resolve at lookup time. Mirrors the rule in
/// <c>Aqueous.OutputDaemon/Validator.cs</c>: EDID wins, then make/model/serial (intersection),
/// then connector name.
/// </summary>
public class OutputSelectorTests
{
    private const string Edid = "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

    // ---- OutputSelector ----------------------------------------------------

    [Fact]
    public void OutputSelector_EdidWins_OverNameMismatch()
    {
        var sel = new OutputSelector(Edid: Edid);
        Assert.True(sel.Matches(name: "DP-3", edid: Edid, make: null, model: null, serial: null));
        Assert.False(sel.Matches(name: "DP-3", edid: "sha256:other", make: null, model: null, serial: null));
    }

    [Fact]
    public void OutputSelector_MakeModelSerial_AllMustMatch()
    {
        var sel = new OutputSelector(Make: "Dell Inc.", Model: "U2723QE");
        Assert.True(sel.Matches("DP-1", null, "Dell Inc.", "U2723QE", "ABC"));
        Assert.True(sel.Matches("DP-1", null, "dell inc.", "u2723qe", "ABC")); // case-insensitive
        Assert.False(sel.Matches("DP-1", null, "Dell Inc.", "U2723QF", "ABC")); // model differs
    }

    [Fact]
    public void OutputSelector_NameFallback_OnlyWhenNoEdidOrMms()
    {
        var sel = new OutputSelector(Name: "DP-1");
        Assert.True(sel.Matches("DP-1", null, null, null, null));
        Assert.False(sel.Matches("DP-2", null, null, null, null));
    }

    [Fact]
    public void OutputSelector_Empty_MatchesNothing()
    {
        var sel = new OutputSelector();
        Assert.True(sel.IsEmpty);
        Assert.False(sel.Matches("DP-1", Edid, "Dell", "U2723QE", "ABC"));
    }

    // ---- TOML loader: [[output]] with EDID/make/model/serial ---------------

    [Fact]
    public void LayoutConfig_OutputBlock_ParsesEdidSelector()
    {
        var cfg = LayoutConfig.Parse($$"""
            [layout]
            default = "tile"
            [[output]]
            edid   = "{{Edid}}"
            layout = "scrolling"
            """);

        // No name → not in PerOutput.
        Assert.False(cfg.PerOutput.ContainsKey("DP-1"));
        Assert.Single(cfg.PerOutputSelectors);

        // Resolves whichever connector currently carries that EDID.
        Assert.Equal("scrolling", cfg.ResolveLayoutForOutput("DP-1", edidSha256: Edid));
        Assert.Equal("scrolling", cfg.ResolveLayoutForOutput("DP-7", edidSha256: Edid));
        Assert.Null(cfg.ResolveLayoutForOutput("DP-1", edidSha256: "sha256:other"));
    }

    [Fact]
    public void LayoutConfig_OutputBlock_ParsesMakeModelSerialSelector()
    {
        var cfg = LayoutConfig.Parse("""
            [[output]]
            make   = "Dell Inc."
            model  = "U2723QE"
            serial = "ABC123"
            layout = "monocle"
            """);

        Assert.Single(cfg.PerOutputSelectors);
        Assert.Equal(
            "monocle",
            cfg.ResolveLayoutForOutput("DP-1", make: "Dell Inc.", model: "U2723QE", serial: "ABC123"));
        Assert.Null(cfg.ResolveLayoutForOutput("DP-1", make: "Dell Inc.", model: "U2723QE", serial: "XXX"));
    }

    [Fact]
    public void LayoutConfig_NameKeyedBlocks_StillWork_Unchanged()
    {
        // Regression: existing TOML with `name =` keeps populating PerOutput as before.
        var cfg = LayoutConfig.Parse("""
            [[output]]
            name   = "DP-1"
            layout = "scrolling"
            """);
        Assert.Equal("scrolling", cfg.PerOutput["DP-1"]);
        Assert.Empty(cfg.PerOutputSelectors);
        Assert.Equal("scrolling", cfg.ResolveLayoutForOutput("DP-1"));
    }

    [Fact]
    public void LayoutConfig_NameWinsOverSelector_AtResolveTime()
    {
        // Both a name-keyed and a selector-keyed entry are present; the name dict is checked first.
        var cfg = LayoutConfig.Parse($$"""
            [[output]]
            name   = "DP-1"
            layout = "tile"
            [[output]]
            edid   = "{{Edid}}"
            layout = "monocle"
            """);

        // DP-1 matched by name → "tile" even though its EDID would map to "monocle".
        Assert.Equal("tile", cfg.ResolveLayoutForOutput("DP-1", edidSha256: Edid));
        // DP-2 with that EDID → falls through to selector → "monocle".
        Assert.Equal("monocle", cfg.ResolveLayoutForOutput("DP-2", edidSha256: Edid));
    }

}
