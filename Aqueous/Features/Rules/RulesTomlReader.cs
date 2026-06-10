using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Aqueous.Diagnostics;

namespace Aqueous.Features.Rules;

/// <summary>
/// Hand-rolled TOML-subset loader for <c>rules.toml</c>. Sibling of
/// <c>LayoutConfigLoader</c>; shares the same permissive posture (never throws, falls back
/// to defaults on malformed input, unknown keys are ignored).
///
/// <para>
/// File discovery order (first hit wins) — see <see cref="ResolvePath"/>:
/// </para>
/// <list type="number">
/// <item><c>$AQUEOUS_RULES</c> environment variable (absolute path).</item>
/// <item><c>configuredPath</c> argument (from <c>[rules].path</c> in <c>wm.toml</c>).</item>
/// <item><c>$XDG_CONFIG_HOME/aqueous/rules.toml</c>.</item>
/// <item><c>~/.config/aqueous/rules.toml</c>.</item>
/// </list>
/// <para>
/// A missing file is not an error — <see cref="Load"/> returns <see cref="RulesConfig.Empty"/>.
/// This keeps existing installs (no <c>rules.toml</c>) working unchanged.
/// </para>
/// </summary>
public static class RulesTomlReader
{
    /// <summary>
    /// Loads the rules file from the first path found via <see cref="ResolvePath"/>.
    /// Never throws; on I/O or parse error returns <see cref="RulesConfig.Empty"/>.
    /// </summary>
    /// <param name="configuredPath">
    /// Optional <c>[rules].path</c> value supplied by <c>wm.toml</c>. <see langword="null"/>
    /// or empty means "no override; use XDG discovery".
    /// </param>
    public static RulesConfig Load(string? configuredPath = null)
    {
        try
        {
            var path = ResolvePath(configuredPath);
            if (path is null || !File.Exists(path))
            {
                return RulesConfig.Empty;
            }

            return Parse(File.ReadAllText(path));
        }
        catch
        {
            return RulesConfig.Empty;
        }
    }

    /// <summary>
    /// Resolves the rules-file path using the documented discovery order. Returns
    /// <see langword="null"/> if none of the candidates exist on disk *and* no candidate
    /// was supplied — callers should treat that as "no rules file, use empty config".
    /// </summary>
    /// <remarks>
    /// The <c>$AQUEOUS_RULES</c> override and the <c>[rules].path</c> argument are returned
    /// even if the file doesn't exist (so callers can log a helpful "not found" warning);
    /// the XDG / home candidates are only returned when they actually exist.
    /// </remarks>
    public static string? ResolvePath(string? configuredPath)
    {
        // 1. $AQUEOUS_RULES — explicit user override, returned verbatim (may not exist).
        var env = Environment.GetEnvironmentVariable("AQUEOUS_RULES");
        if (!string.IsNullOrWhiteSpace(env))
        {
            return ExpandHome(env);
        }

        // 2. [rules].path from wm.toml — returned verbatim (may not exist).
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return ExpandHome(configuredPath);
        }

        // 3. $XDG_CONFIG_HOME/aqueous/rules.toml — only if it exists.
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (!string.IsNullOrWhiteSpace(xdg))
        {
            var p = Path.Combine(xdg, "aqueous", "rules.toml");
            if (File.Exists(p))
            {
                return p;
            }
        }

        // 4. ~/.config/aqueous/rules.toml — only if it exists.
        var home = Environment.GetEnvironmentVariable("HOME");
        if (!string.IsNullOrWhiteSpace(home))
        {
            var p = Path.Combine(home, ".config", "aqueous", "rules.toml");
            if (File.Exists(p))
            {
                return p;
            }
        }

        return null;
    }

    /// <summary>
    /// Parses a TOML-subset rules document. Pure function — no I/O. Malformed values fall
    /// back to documented defaults; rules without any matcher are dropped silently (same
    /// permissive posture as <c>LayoutConfigLoader</c>).
    /// </summary>
    public static RulesConfig Parse(string text)
    {
        // [game_mode] options.
        var gmRemainder = GameModeOptions.Default.RemainderLayout;
        var gmGapsInner = GameModeOptions.Default.GapsInner;
        var gmFallback = GameModeOptions.Default.FallbackLayout;

        // Pending [[window]] table — flushed on next [[window]] or EOF.
        var rules = new List<WindowRule>();
        bool wPending = false;
        string? wAppId = null;
        string? wClass = null;
        string? wTitle = null;
        string wLayout = "game-mode";
        AnchorKind wAnchor = AnchorKind.Center;
        SizeSpec wSize = SizeSpec.Native.Instance;
        double wScale = 1.0;
        int? wTag = null;
        bool wFullscreen = false;
        bool wIgnoreStruts = false;
        bool? wBlur = null;

        void ResetWindow()
        {
            wAppId = null;
            wClass = null;
            wTitle = null;
            wLayout = "game-mode";
            wAnchor = AnchorKind.Center;
            wSize = SizeSpec.Native.Instance;
            wScale = 1.0;
            wTag = null;
            wFullscreen = false;
            wIgnoreStruts = false;
            wBlur = null;
        }

        void FlushWindow()
        {
            if (!wPending)
            {
                return;
            }

            wPending = false;

            // River v1 does not currently forward a dedicated WM_CLASS event, so
            // WindowEntry.XClass is always null on the shipping build and any
            // class=… matcher can never produce a hit. Rather than silently dropping
            // such a rule (the previous behaviour, which made the documented matcher
            // a footgun), log an actionable warning and strip the field so the rest
            // of the rule still applies if another matcher is present.
            if (wClass is not null)
            {
                RiverLog.Write(
                    "rules.toml: 'class' matcher is not supported on this compositor build " +
                    $"(class=\"{wClass}\" ignored). Use 'app_id' instead.");
                wClass = null;
            }

            // At least one matcher is required — rules with none would match every window,
            // which is almost never what the user meant. Drop silently.
            if (wAppId is null && wClass is null && wTitle is null)
            {
                ResetWindow();
                return;
            }

            // Only "game-mode" is recognised today; future layouts will pass through.
            if (string.IsNullOrEmpty(wLayout))
            {
                wLayout = "game-mode";
            }

            rules.Add(new WindowRule(
                AppId: wAppId,
                Class: wClass,
                Title: wTitle,
                Layout: wLayout,
                Anchor: wAnchor,
                Size: wSize,
                Scale: wScale,
                Tag: wTag,
                Fullscreen: wFullscreen,
                IgnoreStruts: wIgnoreStruts,
                Blur: wBlur));

            ResetWindow();
        }

        string? section = null;

        foreach (var rawLine in text.Split('\n'))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0)
            {
                continue;
            }

            // Section header.
            if (line[0] == '[')
            {
                FlushWindow();

                if (line.StartsWith("[[window]]", StringComparison.Ordinal))
                {
                    section = "window";
                    wPending = true;
                    continue;
                }

                if (line.StartsWith("[game_mode]", StringComparison.Ordinal))
                {
                    section = "game_mode";
                    continue;
                }

                // Unknown section — keep parsing but stop assigning into pending state.
                section = null;
                continue;
            }

            // key = value.
            int eq = line.IndexOf('=');
            if (eq <= 0)
            {
                continue;
            }

            var key = line.Substring(0, eq).Trim();
            var val = line.Substring(eq + 1).Trim();

            switch (section)
            {
                case "game_mode":
                    switch (key)
                    {
                        case "remainder_layout":
                            gmRemainder = StripQuotes(val);
                            break;
                        case "gaps_inner":
                            gmGapsInner = ParseInt(val, gmGapsInner);
                            break;
                        case "fallback_layout":
                            gmFallback = StripQuotes(val);
                            break;
                    }
                    break;

                case "window":
                    switch (key)
                    {
                        case "app_id":
                            wAppId = StripQuotes(val);
                            break;
                        case "class":
                            wClass = StripQuotes(val);
                            break;
                        case "title":
                            wTitle = StripQuotes(val);
                            break;
                        case "layout":
                            wLayout = StripQuotes(val);
                            break;
                        case "anchor":
                            wAnchor = ParseAnchor(StripQuotes(val), wAnchor);
                            break;
                        case "size":
                            wSize = ParseSize(StripQuotes(val));
                            break;
                        case "scale":
                            {
                                var s = ParseDouble(val, wScale);
                                // Clamp to a sane positive range; out-of-range falls back to 1.0.
                                wScale = s > 0.0 && s <= 8.0 ? s : 1.0;
                                break;
                            }
                        case "tag":
                            {
                                var t = ParseInt(val, -1);
                                wTag = t is >= 1 and <= 9 ? t : null;
                                break;
                            }
                        case "fullscreen":
                            wFullscreen = ParseBool(val, wFullscreen);
                            break;
                        case "ignore_struts":
                            wIgnoreStruts = ParseBool(val, wIgnoreStruts);
                            break;
                        case "blur":
                            // null = inherit global [blur].enabled; false = force-exclude
                            // (e.g. games); true = force-include.
                            wBlur = ParseBool(val, false);
                            break;
                    }
                    break;
            }
        }

        FlushWindow();

        return new RulesConfig(
            GameMode: new GameModeOptions(gmRemainder, gmGapsInner, gmFallback),
            Windows: rules);
    }

    private static SizeSpec ParseSize(string raw)
    {
        var s = raw.Trim();
        if (s.Length == 0 || s.Equals("native", StringComparison.OrdinalIgnoreCase))
        {
            return SizeSpec.Native.Instance;
        }

        // WxH where the parts parse as ints → Pixels; where they parse as doubles in
        // (0, 1] → Fraction. Anything else falls back to Native.
        int x = s.IndexOf('x');
        if (x <= 0 || x >= s.Length - 1)
        {
            return SizeSpec.Native.Instance;
        }

        var lhs = s.Substring(0, x).Trim();
        var rhs = s.Substring(x + 1).Trim();

        // Pixels take priority: "1920x1080" is unambiguous because ints with no '.' won't be
        // mistaken for fractions in (0, 1].
        if (!lhs.Contains('.') && !rhs.Contains('.')
            && int.TryParse(lhs, NumberStyles.Integer, CultureInfo.InvariantCulture, out var wPx)
            && int.TryParse(rhs, NumberStyles.Integer, CultureInfo.InvariantCulture, out var hPx))
        {
            if (wPx > 0 && hPx > 0)
            {
                return new SizeSpec.Pixels(wPx, hPx);
            }

            return SizeSpec.Native.Instance;
        }

        if (double.TryParse(lhs, NumberStyles.Float, CultureInfo.InvariantCulture, out var wF)
            && double.TryParse(rhs, NumberStyles.Float, CultureInfo.InvariantCulture, out var hF))
        {
            if (wF > 0.0 && wF <= 1.0 && hF > 0.0 && hF <= 1.0)
            {
                return new SizeSpec.Fraction(wF, hF);
            }
        }

        return SizeSpec.Native.Instance;
    }

    private static AnchorKind ParseAnchor(string raw, AnchorKind fallback) =>
        raw.Trim().ToLowerInvariant() switch
        {
            "center" => AnchorKind.Center,
            "top" => AnchorKind.Top,
            "bottom" => AnchorKind.Bottom,
            "left" => AnchorKind.Left,
            "right" => AnchorKind.Right,
            _ => fallback,
        };

    private static string StripComment(string s)
    {
        // Strip everything from the first unquoted '#' onwards.
        bool inStr = false;
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '"')
            {
                inStr = !inStr;
            }
            else if (!inStr && s[i] == '#')
            {
                return s.Substring(0, i);
            }
        }

        return s;
    }

    private static string StripQuotes(string s)
    {
        s = s.Trim();
        if (s.Length >= 2 && (s[0] == '"' && s[^1] == '"' || s[0] == '\'' && s[^1] == '\''))
        {
            return s.Substring(1, s.Length - 2);
        }

        return s;
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

    private static int ParseInt(string s, int fallback) =>
        int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    private static double ParseDouble(string s, double fallback) =>
        double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    private static bool ParseBool(string s, bool fallback) => s.Trim().ToLowerInvariant() switch
    {
        "true" or "yes" or "on" or "1" => true,
        "false" or "no" or "off" or "0" => false,
        _ => fallback,
    };
}
