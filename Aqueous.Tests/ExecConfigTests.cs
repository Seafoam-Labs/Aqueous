using System.Linq;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Phase B1f — pinning tests for the <c>[[exec]]</c> array-of-tables
/// parser inside <see cref="LayoutConfigLoader"/>.
/// </summary>
public class ExecConfigTests
{
    [Fact]
    public void FullEntry_RoundTripsAllFields()
    {
        var toml = """
            [[exec]]
            name    = "noctalia"
            command = "qs -c noctalia-shell"
            when    = "startup"
            once    = true
            restart = false
            log     = "/tmp/noctalia.log"
            env     = { QT_QPA_PLATFORM = "wayland", FOO = "bar" }
            """;
        var cfg = LayoutConfigLoader.Parse(toml);

        var entry = Assert.Single(cfg.Exec.Entries);
        Assert.Equal("noctalia", entry.Name);
        Assert.Equal("qs -c noctalia-shell", entry.Command);
        Assert.Equal(ExecWhen.Startup, entry.When);
        Assert.True(entry.Once);
        Assert.False(entry.Restart);
        Assert.Equal("/tmp/noctalia.log", entry.LogPath);
        Assert.Equal("wayland", entry.Env["QT_QPA_PLATFORM"]);
        Assert.Equal("bar", entry.Env["FOO"]);
    }

    [Fact]
    public void MinimalEntry_AppliesDefaults()
    {
        var toml = """
            [[exec]]
            name    = "bar"
            command = "qs -c noctalia-shell"
            """;
        var cfg = LayoutConfigLoader.Parse(toml);

        var entry = Assert.Single(cfg.Exec.Entries);
        Assert.Equal(ExecWhen.Startup, entry.When);
        Assert.True(entry.Once);
        Assert.False(entry.Restart);
        Assert.Null(entry.LogPath);
        Assert.Empty(entry.Env);
    }

    [Fact]
    public void MissingCommand_DropsEntry()
    {
        var toml = """
            [[exec]]
            name = "broken"
            # no command

            [[exec]]
            name    = "ok"
            command = "echo hi"
            """;
        var cfg = LayoutConfigLoader.Parse(toml);

        var entry = Assert.Single(cfg.Exec.Entries);
        Assert.Equal("ok", entry.Name);
    }

    [Fact]
    public void MissingName_DropsEntry()
    {
        var toml = """
            [[exec]]
            command = "echo orphan"
            """;
        var cfg = LayoutConfigLoader.Parse(toml);
        Assert.Empty(cfg.Exec.Entries);
    }

    [Fact]
    public void DuplicateName_FirstWins()
    {
        var toml = """
            [[exec]]
            name    = "noctalia"
            command = "first"

            [[exec]]
            name    = "noctalia"
            command = "second"
            """;
        var cfg = LayoutConfigLoader.Parse(toml);

        var entry = Assert.Single(cfg.Exec.Entries);
        Assert.Equal("first", entry.Command);
    }

    [Fact]
    public void When_AllVariantsParse()
    {
        var toml = """
            [[exec]]
            name = "a"
            command = "x"
            when = "startup"

            [[exec]]
            name = "b"
            command = "x"
            when = "reload"

            [[exec]]
            name = "c"
            command = "x"
            when = "always"

            [[exec]]
            name = "d"
            command = "x"
            when = "garbage-falls-back-to-startup"
            """;
        var cfg = LayoutConfigLoader.Parse(toml);
        var byName = cfg.Exec.Entries.ToDictionary(e => e.Name);
        Assert.Equal(ExecWhen.Startup, byName["a"].When);
        Assert.Equal(ExecWhen.Reload, byName["b"].When);
        Assert.Equal(ExecWhen.Always, byName["c"].When);
        Assert.Equal(ExecWhen.Startup, byName["d"].When);
    }

    [Fact]
    public void NoExecSection_YieldsEmptyEntries()
    {
        var cfg = LayoutConfigLoader.Parse("[layout]\ndefault = \"tile\"\n");
        Assert.Empty(cfg.Exec.Entries);
    }

    [Fact]
    public void ExecSection_DoesNotLeakIntoFollowingSection()
    {
        // Regression guard: a [[exec]] block followed by a [section] must
        // flush cleanly and not capture the next section's keys.
        var toml = """
            [[exec]]
            name    = "bar"
            command = "qs -c noctalia-shell"

            [layout]
            default = "scrolling"
            """;
        var cfg = LayoutConfigLoader.Parse(toml);

        Assert.Single(cfg.Exec.Entries);
        Assert.Equal("scrolling", cfg.DefaultLayout);
    }
}
