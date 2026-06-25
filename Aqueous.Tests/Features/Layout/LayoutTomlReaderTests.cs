using System;
using System.Collections.Generic;
using System.IO;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Coverage for the standalone <c>layout.toml</c> sidecar: path resolution order,
/// <c>[layout].path</c> extraction, and the layout-only overlay merge.
/// </summary>
[Collection(EnvironmentVariableTestCollection.Name)]
public class LayoutTomlReaderTests
{
    // -----------------------------------------------------------------------------------------
    // ExtractInlinePath()
    // -----------------------------------------------------------------------------------------

    [Fact]
    public void ExtractInlinePath_ReadsLayoutPathScalar()
    {
        var wm = """
            [layout]
            default = "tile"
            path = "layout.toml"

            [keybinds]
            """;

        Assert.Equal("layout.toml", LayoutTomlReader.ExtractInlinePath(wm));
    }

    [Fact]
    public void ExtractInlinePath_IgnoresPathOutsideLayoutSection()
    {
        var wm = """
            [scratchpad]
            path = "ignored"

            [layout]
            default = "tile"
            """;

        Assert.Null(LayoutTomlReader.ExtractInlinePath(wm));
    }

    [Fact]
    public void ExtractInlinePath_StripsTrailingComment()
    {
        var wm = """
            [layout]
            path = "layout.toml"  # sidecar
            """;

        Assert.Equal("layout.toml", LayoutTomlReader.ExtractInlinePath(wm));
    }

    [Fact]
    public void ExtractInlinePath_AbsentReturnsNull()
    {
        Assert.Null(LayoutTomlReader.ExtractInlinePath("[layout]\ndefault = \"tile\"\n"));
        Assert.Null(LayoutTomlReader.ExtractInlinePath(string.Empty));
    }

    // -----------------------------------------------------------------------------------------
    // ResolvePath() — discovery order
    // -----------------------------------------------------------------------------------------

    [Fact]
    public void ResolvePath_EnvOverride_WinsOverInlinePath()
    {
        using var home = new ScopedEnv("HOME", "/no/such/home/dir");
        using var env = new ScopedEnv("AQUEOUS_LAYOUT", "/env/path/layout.toml");

        var resolved = LayoutTomlReader.ResolvePath("/configured/layout.toml", "/etc");

        Assert.Equal("/env/path/layout.toml", resolved);
    }

    [Fact]
    public void ResolvePath_InlinePath_ResolvedRelativeToWmTomlDir()
    {
        using var home = new ScopedEnv("HOME", "/no/such/home/dir");
        using var env = new ScopedEnv("AQUEOUS_LAYOUT", null);

        var resolved = LayoutTomlReader.ResolvePath("layout.toml", "/home/user/.config/aqueous");

        Assert.Equal(Path.Combine("/home/user/.config/aqueous", "layout.toml"), resolved);
    }

    [Fact]
    public void ResolvePath_InlinePath_AbsoluteKeptVerbatim()
    {
        using var home = new ScopedEnv("HOME", "/no/such/home/dir");
        using var env = new ScopedEnv("AQUEOUS_LAYOUT", null);

        var resolved = LayoutTomlReader.ResolvePath("/absolute/layout.toml", "/wm/dir");

        Assert.Equal("/absolute/layout.toml", resolved);
    }

    [Fact]
    public void ResolvePath_ExpandsTildeInEnvOverride()
    {
        using var home = new ScopedEnv("HOME", "/home/tester");
        using var env = new ScopedEnv("AQUEOUS_LAYOUT", "~/custom/layout.toml");

        var resolved = LayoutTomlReader.ResolvePath(null, null);

        Assert.Equal("/home/tester/custom/layout.toml", resolved);
    }

    [Fact]
    public void ResolvePath_NoCandidatesExist_ReturnsNull()
    {
        using var env = new ScopedEnv("AQUEOUS_LAYOUT", null);
        using var xdg = new ScopedEnv("XDG_CONFIG_HOME", "/no/such/xdg/dir");
        using var home = new ScopedEnv("HOME", "/no/such/home/dir");

        var resolved = LayoutTomlReader.ResolvePath(null, null);

        Assert.Null(resolved);
    }

    [Fact]
    public void ResolvePath_HomeFile_PreferredOverXdgWhenBothExist()
    {
        using var envOverride = new ScopedEnv("AQUEOUS_LAYOUT", null);
        var xdgDir = Path.Combine(Path.GetTempPath(), "aq-test-xdg-" + Guid.NewGuid().ToString("N"));
        var homeDir = Path.Combine(Path.GetTempPath(), "aq-test-home-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(xdgDir, "aqueous"));
        Directory.CreateDirectory(Path.Combine(homeDir, ".config", "aqueous"));
        try
        {
            var xdgFile = Path.Combine(xdgDir, "aqueous", "layout.toml");
            var homeFile = Path.Combine(homeDir, ".config", "aqueous", "layout.toml");
            File.WriteAllText(xdgFile, "");
            File.WriteAllText(homeFile, "");

            using var xdg = new ScopedEnv("XDG_CONFIG_HOME", xdgDir);
            using var home = new ScopedEnv("HOME", homeDir);

            var resolved = LayoutTomlReader.ResolvePath(null, null);

            Assert.Equal(homeFile, resolved);
        }
        finally
        {
            try { Directory.Delete(xdgDir, recursive: true); } catch { }
            try { Directory.Delete(homeDir, recursive: true); } catch { }
        }
    }

    [Fact]
    public void ResolvePath_HomeFile_WinsOverEnvOverrideAndInlinePath()
    {
        var homeDir = Path.Combine(Path.GetTempPath(), "aq-test-home-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(homeDir, ".config", "aqueous"));
        try
        {
            var homeFile = Path.Combine(homeDir, ".config", "aqueous", "layout.toml");
            File.WriteAllText(homeFile, "");

            using var home = new ScopedEnv("HOME", homeDir);
            using var envOverride = new ScopedEnv("AQUEOUS_LAYOUT", "/env/path/layout.toml");

            var resolved = LayoutTomlReader.ResolvePath("/configured/layout.toml", "/etc");

            Assert.Equal(homeFile, resolved);
        }
        finally
        {
            try { Directory.Delete(homeDir, recursive: true); } catch { }
        }
    }

    // -----------------------------------------------------------------------------------------
    // Merge() — layout-only overlay semantics
    // -----------------------------------------------------------------------------------------

    [Fact]
    public void Merge_OverlayScalars_WinWholesale()
    {
        var baseCfg = LayoutConfigLoader.Parse("""
            [layout]
            default      = "tile"
            gaps_outer   = 8
            gaps_inner   = 4
            master_ratio = 0.5
            """);

        var overlay = LayoutConfigLoader.Parse("""
            [layout]
            default      = "scrolling"
            gaps_outer   = 20
            gaps_inner   = 10
            master_ratio = 0.7
            """);

        var merged = LayoutTomlReader.Merge(baseCfg, overlay);

        Assert.Equal("scrolling", merged.DefaultLayout);
        Assert.Equal(20, merged.Defaults.GapsOuter);
        Assert.Equal(10, merged.Defaults.GapsInner);
        Assert.Equal(0.7, merged.Defaults.MasterRatio);
    }

    [Fact]
    public void Merge_SlotsAreMergedPerKey_OverlayWins()
    {
        var baseCfg = LayoutConfigLoader.Parse("""
            [layout.slots]
            primary    = "tile"
            secondary  = "float"
            tertiary   = "monocle"
            quaternary = "grid"
            """);

        var overlay = LayoutConfigLoader.Parse("""
            [layout.slots]
            primary   = "scrolling"
            secondary = "grid"
            """);

        var merged = LayoutTomlReader.Merge(baseCfg, overlay);

        Assert.Equal("scrolling", merged.Slots["primary"]);
        Assert.Equal("grid", merged.Slots["secondary"]);
        // Overlay-absent keys: parser defaults still come through.
        // (LayoutConfigLoader always emits the 4 default slot keys, so the overlay's
        //  parsed values for tertiary/quaternary will be its defaults, which match the
        //  base defaults here.)
        Assert.Equal("monocle", merged.Slots["tertiary"]);
        Assert.Equal("grid", merged.Slots["quaternary"]);
    }

    [Fact]
    public void Merge_PerLayoutOpts_OverlayBlockReplacesEntireBlock()
    {
        var baseCfg = LayoutConfigLoader.Parse("""
            [layout.options.tile]
            gaps_outer   = 12
            master_ratio = 0.6

            [layout.options.grid]
            gaps_inner = 8
            """);

        var overlay = LayoutConfigLoader.Parse("""
            [layout.options.tile]
            gaps_outer = 30
            """);

        var merged = LayoutTomlReader.Merge(baseCfg, overlay);

        // tile: overlay block fully replaces base block.
        Assert.Equal(30, merged.PerLayoutOpts["tile"].GapsOuter);
        // grid: only present in base — preserved.
        Assert.True(merged.PerLayoutOpts.ContainsKey("grid"));
        Assert.Equal(8, merged.PerLayoutOpts["grid"].GapsInner);
    }

    [Fact]
    public void Merge_NonLayoutFields_InheritFromBase()
    {
        // wm.toml-only payload: per-output, snap, keybinds, actions, struts.
        var baseCfg = LayoutConfigLoader.Parse("""
            [[output]]
            name   = "DP-1"
            layout = "scrolling"

            [keybinds]
            toggle_start_menu = "Super+Q"

            [actions]
            spawn_terminal = "kitty"

            [struts]
            top = 24
            """);

        // Overlay does not touch any of those.
        var overlay = LayoutConfigLoader.Parse("""
            [layout]
            default = "monocle"
            """);

        var merged = LayoutTomlReader.Merge(baseCfg, overlay);

        Assert.Equal("monocle", merged.DefaultLayout);
        // Non-layout fields are taken verbatim from base.
        Assert.Equal("scrolling", merged.PerOutput["DP-1"]);
        Assert.Equal("kitty", merged.Actions.SpawnTerminal);
        Assert.Equal(24, merged.Struts.Top);
        Assert.True(merged.Keybinds.Builtins.ContainsKey("toggle_start_menu"));
    }

    // -----------------------------------------------------------------------------------------
    // LoadWithSidecar() — end-to-end
    // -----------------------------------------------------------------------------------------

    [Fact]
    public void LoadWithSidecar_NoSidecar_ReturnsBaseUnchanged()
    {
        var dir = Path.Combine(Path.GetTempPath(), "aq-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            // Make sure no XDG/HOME sidecar leaks in.
            using var envOverride = new ScopedEnv("AQUEOUS_LAYOUT", null);
            using var xdg = new ScopedEnv("XDG_CONFIG_HOME", "/no/such/dir/x");
            using var home = new ScopedEnv("HOME", "/no/such/dir/h");

            var wm = Path.Combine(dir, "wm.toml");
            File.WriteAllText(wm, """
                [layout]
                default = "tile"
                """);

            var cfg = LayoutTomlReader.LoadWithSidecar(wm);

            Assert.Equal("tile", cfg.DefaultLayout);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }

    [Fact]
    public void LoadWithSidecar_InlinePath_LoadedAndOverlaid()
    {
        var dir = Path.Combine(Path.GetTempPath(), "aq-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            using var envOverride = new ScopedEnv("AQUEOUS_LAYOUT", null);
            using var xdg = new ScopedEnv("XDG_CONFIG_HOME", "/no/such/dir/x");
            using var home = new ScopedEnv("HOME", "/no/such/dir/h");

            var wm = Path.Combine(dir, "wm.toml");
            File.WriteAllText(wm, """
                [layout]
                default = "tile"
                path = "layout.toml"
                """);
            File.WriteAllText(Path.Combine(dir, "layout.toml"), """
                [layout]
                default = "scrolling"
                """);

            var cfg = LayoutTomlReader.LoadWithSidecar(wm);

            Assert.Equal("scrolling", cfg.DefaultLayout);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }

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
