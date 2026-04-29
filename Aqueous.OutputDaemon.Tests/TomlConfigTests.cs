using System.Linq;
using Aqueous.OutputDaemon;
using Xunit;

namespace Aqueous.OutputDaemon.Tests;

public class TomlConfigTests
{
    [Fact]
    public void Parses_display_section_and_outputs()
    {
        var toml = """
        [display]
        apply_on_start = false
        apply_on_reload = true
        identify_by = "name"
        rollback_seconds = 15
        fallback_profile = "safe"

        [[output]]
        name = "DP-1"
        mode = "2560x1440@144"
        scale = 1.25
        position = [0, 0]
        adaptive_sync = true
        primary = true
        enabled = true

        [[output]]
        edid = "sha256:deadbeef"
        transform = "90"
        """;

        var cfg = TomlConfig.Parse(toml);
        Assert.False(cfg.Display.ApplyOnStart);
        Assert.True(cfg.Display.ApplyOnReload);
        Assert.Equal("name", cfg.Display.IdentifyBy);
        Assert.Equal(15, cfg.Display.RollbackSeconds);
        Assert.Equal("safe", cfg.Display.FallbackProfile);

        Assert.Equal(2, cfg.Outputs.Count);
        var o1 = cfg.Outputs[0];
        Assert.Equal("DP-1", o1.Name);
        Assert.Equal("2560x1440@144", o1.Mode);
        Assert.Equal(1.25, o1.Scale);
        Assert.Equal((0, 0), o1.Position);
        Assert.True(o1.AdaptiveSync);
        Assert.True(o1.Primary);
        Assert.True(o1.Enabled);

        var o2 = cfg.Outputs[1];
        Assert.Equal("sha256:deadbeef", o2.Edid);
        Assert.Equal("90", o2.Transform);
    }

    [Fact]
    public void Parses_profiles_with_nested_outputs()
    {
        var toml = """
        [[display.profile]]
        name = "docked"

        [[display.profile.output]]
        name = "DP-1"
        mode = "3840x2160@60"
        scale = 1.5

        [[display.profile.output]]
        name = "eDP-1"
        enabled = false

        [[display.profile]]
        name = "safe"

        [[display.profile.output]]
        name = "*"
        mode = "1920x1080@60"
        """;

        var cfg = TomlConfig.Parse(toml);
        Assert.Equal(2, cfg.Profiles.Count);

        var docked = cfg.Profiles.First(p => p.Name == "docked");
        Assert.Equal(2, docked.Outputs.Count);
        Assert.Equal("3840x2160@60", docked.Outputs[0].Mode);
        Assert.Equal(1.5, docked.Outputs[0].Scale);
        Assert.False(docked.Outputs[1].Enabled);

        var safe = cfg.Profiles.First(p => p.Name == "safe");
        Assert.Single(safe.Outputs);
        Assert.Equal("*", safe.Outputs[0].Name);
    }

    [Fact]
    public void Unknown_keys_are_ignored()
    {
        var toml = """
        [display]
        apply_on_start = true
        weird_unknown_key = "abc"

        [[output]]
        name = "DP-1"
        future_field = 42
        """;
        var cfg = TomlConfig.Parse(toml);
        Assert.True(cfg.Display.ApplyOnStart);
        Assert.Single(cfg.Outputs);
        Assert.Equal("DP-1", cfg.Outputs[0].Name);
    }

    [Fact]
    public void Comments_and_blank_lines_skipped()
    {
        var toml = """
        # leading comment
        [display]
        # inner comment
        apply_on_start = false  # trailing

        [[output]]
        name = "X"   # inline
        """;
        var cfg = TomlConfig.Parse(toml);
        Assert.False(cfg.Display.ApplyOnStart);
        Assert.Equal("X", cfg.Outputs[0].Name);
    }

    [Fact]
    public void Empty_input_returns_defaults()
    {
        var cfg = TomlConfig.Parse("");
        Assert.True(cfg.Display.ApplyOnStart);
        Assert.Equal("edid", cfg.Display.IdentifyBy);
        Assert.Empty(cfg.Outputs);
        Assert.Empty(cfg.Profiles);
    }

    [Fact]
    public void OutputSpec_ToDict_includes_only_set_fields()
    {
        var spec = new TomlConfig.OutputSpec
        {
            Name = "DP-1",
            Mode = "1920x1080@60",
            Scale = 1.0,
        };
        var d = spec.ToDict();
        Assert.Equal("DP-1", d["name"]);
        Assert.Equal("1920x1080@60", d["mode"]);
        Assert.Equal(1.0, d["scale"]);
        Assert.False(d.ContainsKey("transform"));
        Assert.False(d.ContainsKey("adaptive_sync"));
        Assert.False(d.ContainsKey("position"));
    }

    [Fact]
    public void Load_missing_file_returns_null()
    {
        Assert.Null(TomlConfig.Load("/no/such/path/aqueous-test-missing.toml"));
    }
}
