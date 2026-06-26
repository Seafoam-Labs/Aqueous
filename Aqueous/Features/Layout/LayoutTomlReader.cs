using System;
using System.Collections.Generic;
using System.IO;
using Aqueous.Diagnostics;

namespace Aqueous.Features.Layout;

/// <summary>
/// Sidecar loader for an optional standalone <c>layout.toml</c> that lets users keep the
/// layout-only sections of <c>wm.toml</c> in their own file. Mirrors
/// <see cref="Aqueous.Features.Rules.RulesTomlReader"/>'s discovery contract:
/// <list type="number">
///   <item><c>~/.config/aqueous/layout.toml</c>.</item>
///   <item><c>$AQUEOUS_LAYOUT</c> environment override (verbatim).</item>
///   <item><c>[layout].path</c> from <c>wm.toml</c> (resolved relative to <c>wm.toml</c>'s directory).</item>
///   <item><c>$XDG_CONFIG_HOME/aqueous/layout.toml</c>.</item>
///   <item><c>/etc/xdg/aqueous/layout.toml</c>.</item>
/// </list>
/// <para>
/// Only the <c>[layout]</c>, <c>[layout.slots]</c> and <c>[layout.options.*]</c> sections of the
/// sidecar take effect. Everything else (keybinds, output, input, exec, …) stays in
/// <c>wm.toml</c> and is untouched by this reader. When both files supply a layout-only field,
/// the sidecar wins.
/// </para>
/// <para>
/// Missing sidecar → not an error; the base <see cref="LayoutConfig"/> is returned unchanged. A
/// malformed sidecar is logged once and otherwise ignored (same permissive posture as the rest
/// of the configuration loader).
/// </para>
/// </summary>
public static class LayoutTomlReader
{
    /// <summary>
    /// Resolves the sidecar path using the documented discovery order. Returns
    /// <see langword="null"/> when no candidate exists.
    /// </summary>
    /// <param name="configuredPath">
    /// Optional value of <c>[layout].path</c> from <c>wm.toml</c>. May be <see langword="null"/>.
    /// </param>
    /// <param name="wmTomlDir">
    /// Directory containing <c>wm.toml</c>, used to resolve a relative <paramref name="configuredPath"/>.
    /// </param>
    public static string? ResolvePath(string? configuredPath, string? wmTomlDir)
    {
        // 1. ~/.config/aqueous/layout.toml (highest priority when it exists).
        var home = Environment.GetEnvironmentVariable("HOME");
        if (!string.IsNullOrWhiteSpace(home))
        {
            var p = Path.Combine(home, ".config", "aqueous", "layout.toml");
            if (File.Exists(p))
            {
                return p;
            }
        }

        // 2. $AQUEOUS_LAYOUT override (returned verbatim, may not exist).
        var env = Environment.GetEnvironmentVariable("AQUEOUS_LAYOUT");
        if (!string.IsNullOrWhiteSpace(env))
        {
            return ExpandHome(env);
        }

        // 3. [layout].path — resolve relative to wm.toml's directory when not absolute.
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            var expanded = ExpandHome(configuredPath);
            if (!Path.IsPathRooted(expanded) && !string.IsNullOrEmpty(wmTomlDir))
            {
                expanded = Path.Combine(wmTomlDir, expanded);
            }
            return expanded;
        }

        // 4. $XDG_CONFIG_HOME/aqueous/layout.toml.
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (!string.IsNullOrWhiteSpace(xdg))
        {
            var p = Path.Combine(xdg, "aqueous", "layout.toml");
            if (File.Exists(p))
            {
                return p;
            }
        }

        // 5. /etc/xdg/aqueous/layout.toml.
        const string sys = "/etc/xdg/aqueous/layout.toml";
        if (File.Exists(sys))
        {
            return sys;
        }

        return null;
    }

    /// <summary>
    /// Reads the <c>[layout].path</c> scalar from a <c>wm.toml</c> text without re-parsing the
    /// whole document. Returns <see langword="null"/> when the key is missing.
    /// </summary>
    public static string? ExtractInlinePath(string wmTomlText)
    {
        if (string.IsNullOrEmpty(wmTomlText))
        {
            return null;
        }

        string? section = null;
        foreach (var rawLine in wmTomlText.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("#"))
            {
                continue;
            }

            if (line.StartsWith("[["))
            {
                int end = line.IndexOf("]]", StringComparison.Ordinal);
                section = end > 2 ? "[[" + line.Substring(2, end - 2).Trim() + "]]" : line;
                continue;
            }

            if (line.StartsWith("["))
            {
                int end = line.IndexOf(']');
                section = end > 1 ? line.Substring(1, end - 1).Trim() : line;
                continue;
            }

            if (section != "layout")
            {
                continue;
            }

            int eq = line.IndexOf('=');
            if (eq <= 0)
            {
                continue;
            }

            var key = line.Substring(0, eq).Trim();
            if (key != "path")
            {
                continue;
            }

            var val = line.Substring(eq + 1).Trim();
            // Strip trailing inline comment (#) outside quotes.
            bool inStr = false;
            for (int i = 0; i < val.Length; i++)
            {
                if (val[i] == '"') { inStr = !inStr; }
                else if (!inStr && val[i] == '#') { val = val.Substring(0, i).Trim(); break; }
            }

            if (val.Length >= 2 && val[0] == '"' && val[^1] == '"')
            {
                val = val.Substring(1, val.Length - 2);
            }
            return string.IsNullOrWhiteSpace(val) ? null : val;
        }

        return null;
    }

    /// <summary>
    /// Loads <paramref name="wmPath"/> as the base <see cref="LayoutConfig"/> and, when a sidecar
    /// <c>layout.toml</c> is discoverable, overlays its layout-only fields on top. Never throws;
    /// any failure falls back to the base config (or to <see cref="LayoutConfig.Default"/>).
    /// </summary>
    public static LayoutConfig LoadWithSidecar(string wmPath)
    {
        var baseCfg = LayoutConfigLoader.Load(wmPath);

        string? inlinePath = null;
        try
        {
            if (File.Exists(wmPath))
            {
                inlinePath = ExtractInlinePath(File.ReadAllText(wmPath));
            }
        }
        catch
        {
            // Treat as "no inline path".
        }

        var wmDir = string.IsNullOrEmpty(wmPath) ? null : Path.GetDirectoryName(wmPath);
        var sidecar = ResolvePath(inlinePath, wmDir);
        if (sidecar is null || !File.Exists(sidecar))
        {
            return baseCfg;
        }

        try
        {
            var sidecarCfg = LayoutConfigLoader.Parse(File.ReadAllText(sidecar));
            RiverLog.Write($"layout.toml: loaded sidecar from {sidecar}");
            return Merge(baseCfg, sidecarCfg);
        }
        catch (Exception ex)
        {
            RiverLog.Write($"layout.toml: failed to parse {sidecar}: {ex.Message}");
            return baseCfg;
        }
    }

    /// <summary>
    /// Overlay merge: returns <paramref name="baseCfg"/> with the layout-only fields replaced by
    /// those from <paramref name="overlay"/>. Non-layout fields (keybinds, exec,
    /// output, input, struts, actions, state) are taken verbatim from <paramref name="baseCfg"/>.
    /// <para>
    /// Slot map and per-layout options map are merged per key (overlay wins per key; base keys
    /// missing from overlay are preserved). Scalar layout fields and the border block are taken
    /// wholesale from the overlay.
    /// </para>
    /// </summary>
    public static LayoutConfig Merge(LayoutConfig baseCfg, LayoutConfig overlay)
    {
        // Slots: per-key overlay.
        var slots = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var kv in baseCfg.Slots) { slots[kv.Key] = kv.Value; }
        foreach (var kv in overlay.Slots) { slots[kv.Key] = kv.Value; }

        // PerLayoutOpts: per-layout-id overlay (entire LayoutOptions block wins).
        var perLayout = new Dictionary<string, LayoutOptions>(StringComparer.Ordinal);
        foreach (var kv in baseCfg.PerLayoutOpts) { perLayout[kv.Key] = kv.Value; }
        foreach (var kv in overlay.PerLayoutOpts) { perLayout[kv.Key] = kv.Value; }

        // Per-workspace layout overrides: per-key overlay ([[workspace]] is a layout-only concept).
        var perWorkspace = new Dictionary<int, string>();
        foreach (var kv in baseCfg.PerWorkspace) { perWorkspace[kv.Key] = kv.Value; }
        foreach (var kv in overlay.PerWorkspace) { perWorkspace[kv.Key] = kv.Value; }

        var perOutputWorkspace = new Dictionary<(string, int), string>();
        foreach (var kv in baseCfg.PerOutputWorkspace) { perOutputWorkspace[kv.Key] = kv.Value; }
        foreach (var kv in overlay.PerOutputWorkspace) { perOutputWorkspace[kv.Key] = kv.Value; }

        return new LayoutConfig
        {
            // Layout-only fields: overlay wins wholesale.
            DefaultLayout = overlay.DefaultLayout,
            Defaults = overlay.Defaults,
            Slots = slots,
            PerLayoutOpts = perLayout,
            PerWorkspace = perWorkspace,
            PerOutputWorkspace = perOutputWorkspace,
            Border = overlay.Border,
            ForceSsd = overlay.ForceSsd,

            // Non-layout fields: inherit verbatim from base (wm.toml).
            Blur = baseCfg.Blur,
            Opacity = baseCfg.Opacity,
            WorkspaceTransition = baseCfg.WorkspaceTransition,
            PerOutput = baseCfg.PerOutput,
            PerOutputSelectors = baseCfg.PerOutputSelectors,
            Keybinds = baseCfg.Keybinds,
            State = baseCfg.State,
            Exec = baseCfg.Exec,
            Actions = baseCfg.Actions,
            Input = baseCfg.Input,
            Struts = baseCfg.Struts,
        };
    }

    private static string ExpandHome(string path)
    {
        if (path.Length > 0 && path[0] == '~')
        {
            var home = Environment.GetEnvironmentVariable("HOME");
            if (!string.IsNullOrEmpty(home))
            {
                return home + path.Substring(1);
            }
        }
        return path;
    }
}
