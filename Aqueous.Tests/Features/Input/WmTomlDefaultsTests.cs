using System;
using System.IO;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Input;

/// <summary>
/// Locks the shipped <c>wm.toml</c> <c>[keybinds]</c> table against the compiled-in
/// <see cref="KeybindConfig.Defaults"/> / <see cref="KeybindConfig.KnownActions"/>. If this
/// test fails, either <c>wm.toml</c> drifted from the defaults or a new action was added
/// without a default — fix one or the other before merging.
/// </summary>
public class WmTomlDefaultsTests
{
    private static string FindWmToml()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "wm.toml");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        throw new FileNotFoundException("Could not locate wm.toml by walking up from " + AppContext.BaseDirectory);
    }

    [Fact]
    public void WmToml_BuiltinKeybinds_MatchCompiledInDefaults()
    {
        var path = FindWmToml();
        var cfg = LayoutConfig.Parse(File.ReadAllText(path));

        // 1. Every action present in wm.toml's [keybinds] is a known action (no stale renames).
        foreach (var action in cfg.Keybinds.Builtins.Keys)
        {
            Assert.Contains(action, KeybindConfig.KnownActions);
        }

        // 2. Every action with a compiled-in default that wm.toml binds must bind it to that
        //    same chord (first entry of the array form, or the single-string form).
        foreach (var (action, defaultChord) in KeybindConfig.Defaults)
        {
            if (!cfg.Keybinds.Builtins.TryGetValue(action, out var chords))
            {
                continue; // not bound in wm.toml — falls back to default at runtime, fine.
            }
            Assert.NotEmpty(chords);
            Assert.Equal(defaultChord, chords[0]);
        }
    }
}
