using System.Collections.Generic;
using Aqueous.OutputDaemon;
using Xunit;

namespace Aqueous.OutputDaemon.Tests;

public class WlrRandrTests
{
    private const string TwoOutputs = """
    [
      {
        "name": "DP-1",
        "make": "Dell",
        "model": "U2723QE",
        "serial_number": "ABC123",
        "enabled": true,
        "position": {"x": 0, "y": 0},
        "scale": 1.0,
        "transform": "normal",
        "adaptive_sync": false,
        "modes": [
          {"width": 2560, "height": 1440, "refresh": 144000, "preferred": true, "current": true},
          {"width": 1920, "height": 1080, "refresh": 60000, "preferred": false, "current": false}
        ]
      },
      {
        "name": "HDMI-A-1",
        "enabled": false,
        "position": {"x": 2560, "y": 0},
        "scale": 1.0,
        "modes": []
      }
    ]
    """;

    [Fact]
    public void ParseJson_two_outputs()
    {
        var outs = WlrRandr.ParseJson(TwoOutputs);
        Assert.Equal(2, outs.Count);

        var dp = outs[0];
        Assert.Equal("DP-1", dp.Name);
        Assert.Equal("Dell", dp.Make);
        Assert.Equal("U2723QE", dp.Model);
        Assert.Equal("ABC123", dp.Serial);
        Assert.True(dp.Enabled);
        Assert.Equal(0, dp.X);
        Assert.Equal(0, dp.Y);
        Assert.Equal(1.0, dp.Scale);
        Assert.Equal("normal", dp.Transform);
        Assert.Equal(2, dp.Modes.Count);
        // refresh in mHz normalised to Hz
        Assert.Equal(144.0, dp.Modes[0].Refresh);
        Assert.True(dp.Modes[0].Current);
        Assert.NotNull(dp.CurrentMode);
        Assert.Equal(2560, dp.CurrentMode!.Width);
        Assert.NotNull(dp.EdidSha256);
        Assert.StartsWith("sha256:", dp.EdidSha256);

        var hdmi = outs[1];
        Assert.Equal("HDMI-A-1", hdmi.Name);
        Assert.False(hdmi.Enabled);
        Assert.Equal(2560, hdmi.X);
        Assert.Null(hdmi.EdidSha256); // no make/model/serial
    }

    [Fact]
    public void ComputeEdidHash_stable()
    {
        var o = new WlrRandr.Output { Make = "Dell", Model = "U2723QE", Serial = "ABC123" };
        var a = WlrRandr.ComputeEdidHash(o);
        var b = WlrRandr.ComputeEdidHash(o);
        Assert.Equal(a, b);
        Assert.NotNull(a);
        Assert.StartsWith("sha256:", a);
        // Length: 7 ("sha256:") + 64 hex chars = 71
        Assert.Equal(71, a!.Length);
    }

    [Fact]
    public void ComputeEdidHash_distinct_inputs_distinct_hashes()
    {
        var a = WlrRandr.ComputeEdidHash(new WlrRandr.Output { Make = "X", Model = "1", Serial = "a" });
        var b = WlrRandr.ComputeEdidHash(new WlrRandr.Output { Make = "X", Model = "1", Serial = "b" });
        Assert.NotEqual(a, b);
    }

    [Fact]
    public void ComputeEdidHash_null_when_empty()
    {
        Assert.Null(WlrRandr.ComputeEdidHash(new WlrRandr.Output()));
    }

    [Fact]
    public void ParseJson_handles_legacy_top_level_xy()
    {
        var json = """[ {"name":"X","x":100,"y":50,"enabled":true} ]""";
        var outs = WlrRandr.ParseJson(json);
        Assert.Single(outs);
        Assert.Equal(100, outs[0].X);
        Assert.Equal(50, outs[0].Y);
    }
}
