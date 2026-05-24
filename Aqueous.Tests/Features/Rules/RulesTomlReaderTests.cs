using System;
using System.IO;
using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Rules;

/// <summary>
/// Parser + discovery tests for <see cref="RulesTomlReader"/> (TOML shape, size variants,
/// XDG / env path precedence).
/// </summary>
public class RulesTomlReaderTests
{
    // -----------------------------------------------------------------------------------------
    // Parse() — pure, no I/O
    // -----------------------------------------------------------------------------------------

    [Fact]
    public void EmptyInput_ProducesEmptyConfig()
    {
        var cfg = RulesTomlReader.Parse(string.Empty);

        Assert.Empty(cfg.Windows);
        Assert.Equal(GameModeOptions.Default, cfg.GameMode);
    }

    [Fact]
    public void GameModeSection_OverridesDefaults()
    {
        var toml = """
            [game_mode]
            remainder_layout = "tile"
            gaps_inner       = 16
            fallback_layout  = "monocle"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        Assert.Equal("tile", cfg.GameMode.RemainderLayout);
        Assert.Equal(16, cfg.GameMode.GapsInner);
        Assert.Equal("monocle", cfg.GameMode.FallbackLayout);
        Assert.Empty(cfg.Windows);
    }

    [Fact]
    public void FullWindowRule_RoundTripsAllFields()
    {
        var toml = """
            [[window]]
            app_id     = "dota2"
            layout     = "game-mode"
            anchor     = "center"
            size       = "native"
            scale      = 1.0
            tag        = 9
            fullscreen = false
            """;

        var cfg = RulesTomlReader.Parse(toml);

        var rule = Assert.Single(cfg.Windows);
        Assert.Equal("dota2", rule.AppId);
        Assert.Null(rule.Class);
        Assert.Null(rule.Title);
        Assert.Equal("game-mode", rule.Layout);
        Assert.Equal(AnchorKind.Center, rule.Anchor);
        Assert.IsType<SizeSpec.Native>(rule.Size);
        Assert.Equal(1.0, rule.Scale);
        Assert.Equal(9, rule.Tag);
        Assert.False(rule.Fullscreen);
    }

    [Fact]
    public void WindowRuleWithNoMatcher_IsDropped()
    {
        var toml = """
            [[window]]
            layout = "game-mode"
            anchor = "center"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        Assert.Empty(cfg.Windows);
    }

    [Fact]
    public void SizePixels_ParsesAsExplicitDimensions()
    {
        var toml = """
            [[window]]
            class = "steam_app_570"
            size  = "1920x1080"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        var rule = Assert.Single(cfg.Windows);
        var pixels = Assert.IsType<SizeSpec.Pixels>(rule.Size);
        Assert.Equal(1920, pixels.W);
        Assert.Equal(1080, pixels.H);
    }

    [Fact]
    public void SizeFraction_ParsesAsFractionOfUsableArea()
    {
        var toml = """
            [[window]]
            app_id = "dota2"
            size   = "0.75x0.6"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        var rule = Assert.Single(cfg.Windows);
        var frac = Assert.IsType<SizeSpec.Fraction>(rule.Size);
        Assert.Equal(0.75, frac.W);
        Assert.Equal(0.6, frac.H);
    }

    [Fact]
    public void SizeInvalid_FallsBackToNative()
    {
        var toml = """
            [[window]]
            app_id = "dota2"
            size   = "garbage"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        var rule = Assert.Single(cfg.Windows);
        Assert.IsType<SizeSpec.Native>(rule.Size);
    }

    [Fact]
    public void AnchorVariants_ParseToExpectedEnum()
    {
        var toml = """
            [[window]]
            app_id = "a"
            anchor = "top"

            [[window]]
            app_id = "b"
            anchor = "bottom"

            [[window]]
            app_id = "c"
            anchor = "left"

            [[window]]
            app_id = "d"
            anchor = "right"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        Assert.Equal(4, cfg.Windows.Count);
        Assert.Equal(AnchorKind.Top, cfg.Windows[0].Anchor);
        Assert.Equal(AnchorKind.Bottom, cfg.Windows[1].Anchor);
        Assert.Equal(AnchorKind.Left, cfg.Windows[2].Anchor);
        Assert.Equal(AnchorKind.Right, cfg.Windows[3].Anchor);
    }

    [Fact]
    public void MultipleWindowRules_PreserveDeclarationOrder()
    {
        var toml = """
            [[window]]
            app_id = "first"

            [[window]]
            class = "second"

            [[window]]
            title = "third"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        Assert.Equal(3, cfg.Windows.Count);
        Assert.Equal("first", cfg.Windows[0].AppId);
        Assert.Equal("second", cfg.Windows[1].Class);
        Assert.Equal("third", cfg.Windows[2].Title);
    }

    [Fact]
    public void TagOutOfRange_IsDropped()
    {
        var toml = """
            [[window]]
            app_id = "x"
            tag    = 42
            """;

        var cfg = RulesTomlReader.Parse(toml);

        var rule = Assert.Single(cfg.Windows);
        Assert.Null(rule.Tag);
    }

    [Fact]
    public void CommentsAndBlankLines_AreIgnored()
    {
        var toml = """
            # leading comment

            [game_mode]
            # inner comment
            remainder_layout = "grid"  # trailing comment

            [[window]]
            # rule comment
            app_id = "dota2"
            """;

        var cfg = RulesTomlReader.Parse(toml);

        Assert.Equal("grid", cfg.GameMode.RemainderLayout);
        var rule = Assert.Single(cfg.Windows);
        Assert.Equal("dota2", rule.AppId);
    }

    // -----------------------------------------------------------------------------------------
    // Load() — file I/O + missing-file tolerance
    // -----------------------------------------------------------------------------------------

    [Fact]
    public void Load_MissingFile_ReturnsEmptyConfig()
    {
        using var env = new ScopedEnv("AQUEOUS_RULES", "/nonexistent/path/that/does/not/exist.toml");

        var cfg = RulesTomlReader.Load();

        Assert.Same(RulesConfig.Empty, cfg);
    }

    [Fact]
    public void Load_FromConfiguredPath_ParsesFile()
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, """
                [[window]]
                app_id = "dota2"
                """);

            // Ensure the env override does not shadow the configuredPath argument.
            using var env = new ScopedEnv("AQUEOUS_RULES", null);

            var cfg = RulesTomlReader.Load(path);

            var rule = Assert.Single(cfg.Windows);
            Assert.Equal("dota2", rule.AppId);
        }
        finally
        {
            File.Delete(path);
        }
    }

    // -----------------------------------------------------------------------------------------
    // ResolvePath() — discovery order
    // -----------------------------------------------------------------------------------------

    [Fact]
    public void ResolvePath_EnvOverride_WinsOverConfiguredPath()
    {
        using var env = new ScopedEnv("AQUEOUS_RULES", "/env/path/rules.toml");

        var resolved = RulesTomlReader.ResolvePath("/configured/path/rules.toml");

        Assert.Equal("/env/path/rules.toml", resolved);
    }

    [Fact]
    public void ResolvePath_ConfiguredPath_UsedWhenEnvUnset()
    {
        using var env = new ScopedEnv("AQUEOUS_RULES", null);

        var resolved = RulesTomlReader.ResolvePath("/configured/path/rules.toml");

        Assert.Equal("/configured/path/rules.toml", resolved);
    }

    [Fact]
    public void ResolvePath_ExpandsTildeInEnvOverride()
    {
        using var home = new ScopedEnv("HOME", "/home/tester");
        using var env = new ScopedEnv("AQUEOUS_RULES", "~/custom/rules.toml");

        var resolved = RulesTomlReader.ResolvePath(null);

        Assert.Equal("/home/tester/custom/rules.toml", resolved);
    }

    [Fact]
    public void ResolvePath_NoCandidatesExist_ReturnsNull()
    {
        // Drive all four candidates to non-existent paths.
        using var env = new ScopedEnv("AQUEOUS_RULES", null);
        using var xdg = new ScopedEnv("XDG_CONFIG_HOME", "/no/such/xdg/dir");
        using var home = new ScopedEnv("HOME", "/no/such/home/dir");

        var resolved = RulesTomlReader.ResolvePath(null);

        Assert.Null(resolved);
    }

    /// <summary>
    /// Minimal scoped env-var helper. Restores the original value on dispose so tests don't
    /// leak state into each other. Hand-rolled to avoid pulling in a test-only dependency.
    /// </summary>
    private sealed class ScopedEnv : IDisposable
    {
        private readonly string _key;
        private readonly string? _previous;

        public ScopedEnv(string key, string? value)
        {
            _key = key;
            _previous = Environment.GetEnvironmentVariable(key);
            Environment.SetEnvironmentVariable(key, value);
        }

        public void Dispose() => Environment.SetEnvironmentVariable(_key, _previous);
    }
}
