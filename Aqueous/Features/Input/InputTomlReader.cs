using System;
using System.IO;
using Aqueous.Diagnostics;

namespace Aqueous.Features.Input;

/// <summary>
/// Sidecar loader for an optional standalone <c>input.toml</c> that lets users keep the whole
/// <c>[input]</c> block (the libinput knobs plus the XKB keyboard keys) in their own file.
/// Mirrors <see cref="Aqueous.Features.Rules.RulesTomlReader"/>'s discovery contract:
/// <list type="number">
///   <item><c>$AQUEOUS_INPUT</c> environment override (verbatim).</item>
///   <item><c>configuredPath</c> argument (e.g. <c>[input].path</c> from <c>wm.toml</c>).</item>
///   <item><c>$XDG_CONFIG_HOME/aqueous/input.toml</c>.</item>
///   <item><c>~/.config/aqueous/input.toml</c>.</item>
///   <item><c>/etc/xdg/aqueous/input.toml</c>.</item>
/// </list>
/// <para>
/// The file is parsed by the standalone <see cref="InputConfigParser"/>, which understands the
/// <c>[input]</c>, <c>[input.mouse]</c>, <c>[input.touchpad]</c> and <c>[input.trackpoint]</c>
/// sections and ignores everything else. Section names must keep the <c>[input]</c> prefix.
/// </para>
/// <para>
/// Missing file → not an error; <see cref="Load"/> returns <see langword="null"/> so the caller
/// keeps the <c>[input]</c> block from <c>wm.toml</c> unchanged. This keeps existing installs (no
/// <c>input.toml</c>) working as before.
/// </para>
/// </summary>
public static class InputTomlReader
{
    /// <summary>
    /// Loads the input sidecar from the first path found via <see cref="ResolvePath"/>. Never
    /// throws; on a missing file or parse error returns <see langword="null"/>, meaning "no
    /// sidecar; keep the caller's existing <see cref="InputConfig"/>".
    /// </summary>
    /// <param name="configuredPath">
    /// Optional explicit path (e.g. <c>[input].path</c> from <c>wm.toml</c>). <see langword="null"/>
    /// or empty means "no override; use XDG discovery".
    /// </param>
    public static InputConfig? Load(string? configuredPath = null)
    {
        try
        {
            var path = ResolvePath(configuredPath);
            if (path is null || !File.Exists(path))
            {
                return null;
            }

            var cfg = InputConfigParser.Parse(File.ReadAllText(path));
            RiverLog.Write($"input.toml: loaded sidecar from {path}");
            return cfg;
        }
        catch (Exception ex)
        {
            RiverLog.Write($"input.toml: failed to load: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Resolves the input-file path using the documented discovery order. Returns
    /// <see langword="null"/> when none of the candidates exist on disk and no override was
    /// supplied.
    /// </summary>
    public static string? ResolvePath(string? configuredPath)
    {
        // 1. $AQUEOUS_INPUT — explicit user override, returned verbatim (may not exist).
        var env = Environment.GetEnvironmentVariable("AQUEOUS_INPUT");
        if (!string.IsNullOrWhiteSpace(env))
        {
            return ExpandHome(env);
        }

        // 2. configuredPath ([input].path from wm.toml) — returned verbatim (may not exist).
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return ExpandHome(configuredPath);
        }

        // 3. $XDG_CONFIG_HOME/aqueous/input.toml — only if it exists.
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (!string.IsNullOrWhiteSpace(xdg))
        {
            var p = Path.Combine(xdg, "aqueous", "input.toml");
            if (File.Exists(p))
            {
                return p;
            }
        }

        // 4. ~/.config/aqueous/input.toml — only if it exists.
        var home = Environment.GetEnvironmentVariable("HOME");
        if (!string.IsNullOrWhiteSpace(home))
        {
            var p = Path.Combine(home, ".config", "aqueous", "input.toml");
            if (File.Exists(p))
            {
                return p;
            }
        }

        // 5. /etc/xdg/aqueous/input.toml — only if it exists.
        const string sys = "/etc/xdg/aqueous/input.toml";
        if (File.Exists(sys))
        {
            return sys;
        }

        return null;
    }

    /// <summary>
    /// Overlays a discovered <c>input.toml</c> (<paramref name="overlay"/>) on top of the
    /// <c>[input]</c> block parsed from <c>wm.toml</c> (<paramref name="baseCfg"/>). When
    /// <paramref name="overlay"/> is <see langword="null"/> (no sidecar present) the base is
    /// returned unchanged, preserving backwards-compatible behaviour for installs that keep
    /// <c>[input]</c> in <c>wm.toml</c>.
    /// <para>
    /// For each field, the sidecar wins only when it actually set a value (non-default scalar /
    /// non-null nullable); otherwise the base value is kept. This lets a partial <c>input.toml</c>
    /// override a single knob without clobbering the rest of the <c>wm.toml</c> block.
    /// </para>
    /// </summary>
    public static InputConfig Merge(InputConfig baseCfg, InputConfig? overlay)
    {
        if (overlay is null)
        {
            return baseCfg;
        }

        var d = InputConfig.Default;
        return baseCfg with
        {
            FocusFollowsMouse = overlay.FocusFollowsMouse != d.FocusFollowsMouse
                ? overlay.FocusFollowsMouse : baseCfg.FocusFollowsMouse,
            PointerAcceleration = overlay.PointerAcceleration != d.PointerAcceleration
                ? overlay.PointerAcceleration : baseCfg.PointerAcceleration,
            PointerAccelerationFactor = overlay.PointerAccelerationFactor != d.PointerAccelerationFactor
                ? overlay.PointerAccelerationFactor : baseCfg.PointerAccelerationFactor,
            Mouse = MergeDevice(baseCfg.Mouse, overlay.Mouse),
            Touchpad = MergeDevice(baseCfg.Touchpad, overlay.Touchpad),
            Trackpoint = MergeDevice(baseCfg.Trackpoint, overlay.Trackpoint),
            XkbLayout = overlay.XkbLayout ?? baseCfg.XkbLayout,
            XkbVariant = overlay.XkbVariant ?? baseCfg.XkbVariant,
            XkbOptions = overlay.XkbOptions ?? baseCfg.XkbOptions,
        };
    }

    /// <summary>
    /// Per-device merge: each nullable libinput knob from <paramref name="overlay"/> wins only when
    /// the user set it (non-null); otherwise the <paramref name="baseDev"/> value is kept.
    /// </summary>
    private static PerDeviceInput MergeDevice(PerDeviceInput baseDev, PerDeviceInput overlay) =>
        baseDev with
        {
            AccelProfile = overlay.AccelProfile ?? baseDev.AccelProfile,
            AccelSpeed = overlay.AccelSpeed ?? baseDev.AccelSpeed,
            NaturalScroll = overlay.NaturalScroll ?? baseDev.NaturalScroll,
            Tap = overlay.Tap ?? baseDev.Tap,
            Dwt = overlay.Dwt ?? baseDev.Dwt,
            LeftHanded = overlay.LeftHanded ?? baseDev.LeftHanded,
            ClickMethod = overlay.ClickMethod ?? baseDev.ClickMethod,
            ScrollMethod = overlay.ScrollMethod ?? baseDev.ScrollMethod,
            MiddleEmulation = overlay.MiddleEmulation ?? baseDev.MiddleEmulation,
        };

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
