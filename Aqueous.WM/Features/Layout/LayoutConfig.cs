using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using Aqueous.WM.Features.Input;

[assembly: InternalsVisibleTo("Aqueous.WM.Tests")]

namespace Aqueous.WM.Features.Layout;

/// <summary>
/// In-memory representation of <c>~/.config/aqueous/wm.toml</c>. Only the
/// keys actually consumed by the layout subsystem are modelled. The
/// loader is hand-rolled (a tiny TOML subset — sections, key/value pairs,
/// arrays-of-tables) so we don't pull a dependency for the AOT build.
/// </summary>
public sealed class LayoutConfig
{
    /// <summary>Global default layout id (used when nothing else applies).</summary>
    public string DefaultLayout { get; init; } = "tile";

    /// <summary>Default options applied to every layout that doesn't override them.</summary>
    public LayoutOptions Defaults { get; init; } = LayoutOptions.Default;

    /// <summary>Slot-name → layout id, e.g. <c>"primary" → "tile"</c>.</summary>
    public IReadOnlyDictionary<string, string> Slots { get; init; } =
        new Dictionary<string, string>
        {
            ["primary"]    = "tile",
            ["secondary"]  = "float",
            ["tertiary"]   = "monocle",
            ["quaternary"] = "grid",
        };

    /// <summary>Per-layout option overrides, keyed by layout id.</summary>
    public IReadOnlyDictionary<string, LayoutOptions> PerLayoutOpts { get; init; } =
        new Dictionary<string, LayoutOptions>();

    /// <summary>Output-name → layout id (matches <c>river_output_v1.name</c>).</summary>
    public IReadOnlyDictionary<string, string> PerOutput { get; init; } =
        new Dictionary<string, string>();

    /// <summary>Border styling shared by every layout that draws borders.</summary>
    public BorderSpec Border { get; init; } = new(2, 0xFF88C0D0u, 0xFF3B4252u, 0xFFBF616Au);

    /// <summary>Configurable keybind table parsed from <c>[keybinds]</c>.</summary>
    public KeybindConfig Keybinds { get; init; } = new();

    /// <summary>Compiled-in fallback config (used when no file is present).</summary>
    public static LayoutConfig Default { get; } = new();

    /// <summary>
    /// Returns the merged options for a given layout id: per-layout
    /// overrides win, otherwise the global defaults are returned.
    /// </summary>
    public LayoutOptions OptionsFor(string layoutId)
    {
        if (PerLayoutOpts.TryGetValue(layoutId, out var perLayout))
        {
            // Merge: per-layout `Extra` wins, common scalars from per-layout if non-zero
            // else from defaults.
            return new LayoutOptions(
                GapsOuter:    perLayout.GapsOuter    > 0 ? perLayout.GapsOuter    : Defaults.GapsOuter,
                GapsInner:    perLayout.GapsInner    > 0 ? perLayout.GapsInner    : Defaults.GapsInner,
                MasterRatio:  perLayout.MasterRatio  > 0 ? perLayout.MasterRatio  : Defaults.MasterRatio,
                MasterCount:  perLayout.MasterCount  > 0 ? perLayout.MasterCount  : Defaults.MasterCount,
                Extra:        perLayout.Extra);
        }
        return Defaults;
    }

    /// <summary>
    /// Loads a config from <paramref name="path"/>. On any error returns
    /// <see cref="Default"/> — the WM must never fail to start because of
    /// a malformed config.
    /// </summary>
    public static LayoutConfig Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return Default;
            return Parse(File.ReadAllText(path));
        }
        catch
        {
            return Default;
        }
    }

    // -------------------------------------------------------------------
    // Tiny TOML subset parser. Recognises:
    //   - "[section]" and "[section.subsection]"
    //   - "[[output]]" arrays-of-tables
    //   - "key = value" with string ("..."), int, float, bool
    //   - line comments starting with '#'
    // Unknown keys are ignored.
    // -------------------------------------------------------------------
    internal static LayoutConfig Parse(string text)
    {
        string?  defaultLayout = null;
        string?  primary = null, secondary = null, tertiary = null, quaternary = null;
        var perLayout = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        var perOutput = new Dictionary<string, string>(StringComparer.Ordinal);
        int gapsOuter = 8, gapsInner = 4, masterCount = 1, borderWidth = 2;
        double masterRatio = 0.55;
        uint borderFocused = 0xFF88C0D0u, borderNormal = 0xFF3B4252u, borderUrgent = 0xFFBF616Au;

        // Keybind tables.
        var kbBuiltins = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var kbCustom   = new Dictionary<string, string>(StringComparer.Ordinal);
        var knownActions = new HashSet<string>(KeybindConfig.KnownActions, StringComparer.Ordinal);

        string? curSection = null;
        // Used by [[output]] tables.
        string? pendingOutputName = null;
        string? pendingOutputLayout = null;

        void FlushOutput()
        {
            if (pendingOutputName != null && pendingOutputLayout != null)
                perOutput[pendingOutputName] = pendingOutputLayout;
            pendingOutputName = null;
            pendingOutputLayout = null;
        }

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;

            if (line.StartsWith("[["))
            {
                // array-of-tables — we only care about [[output]]
                FlushOutput();
                int end = line.IndexOf("]]", StringComparison.Ordinal);
                curSection = end > 2 ? "[[" + line.Substring(2, end - 2).Trim() + "]]" : line;
                continue;
            }
            if (line.StartsWith("["))
            {
                FlushOutput();
                int end = line.IndexOf(']');
                curSection = end > 1 ? line.Substring(1, end - 1).Trim() : line;
                continue;
            }

            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            var key = line.Substring(0, eq).Trim();
            var valRaw = line.Substring(eq + 1).Trim();
            // strip trailing inline comment (#)
            int hash = IndexOfUnquoted(valRaw, '#');
            if (hash >= 0) valRaw = valRaw.Substring(0, hash).Trim();
            var val = StripQuotes(valRaw);

            switch (curSection)
            {
                case "layout":
                    switch (key)
                    {
                        case "default":         defaultLayout = val; break;
                        case "gaps_outer":      gapsOuter   = ParseInt(val, gapsOuter); break;
                        case "gaps_inner":      gapsInner   = ParseInt(val, gapsInner); break;
                        case "master_ratio":    masterRatio = ParseDouble(val, masterRatio); break;
                        case "master_count":    masterCount = ParseInt(val, masterCount); break;
                        case "border_width":    borderWidth = ParseInt(val, borderWidth); break;
                        case "border_focused":  borderFocused = ParseColor(val, borderFocused); break;
                        case "border_normal":   borderNormal  = ParseColor(val, borderNormal); break;
                        case "border_urgent":   borderUrgent  = ParseColor(val, borderUrgent); break;
                    }
                    break;
                case "layout.slots":
                    switch (key)
                    {
                        case "primary":    primary = val; break;
                        case "secondary":  secondary = val; break;
                        case "tertiary":   tertiary = val; break;
                        case "quaternary": quaternary = val; break;
                    }
                    break;
                case "[[output]]":
                    if (key == "name")        pendingOutputName   = val;
                    else if (key == "layout") pendingOutputLayout = val;
                    break;
                case "keybinds":
                    if (knownActions.Contains(key))
                        kbBuiltins[key] = ParseChordList(valRaw);
                    // Unknown action names are ignored (forward-compat).
                    break;
                case "keybinds.custom":
                {
                    // key is the chord (it may have been wrapped in quotes).
                    var chord = StripQuotes(key);
                    kbCustom[chord] = val;
                    break;
                }
                default:
                    if (curSection != null && curSection.StartsWith("layout.options.", StringComparison.Ordinal))
                    {
                        var layoutId = curSection.Substring("layout.options.".Length);
                        if (!perLayout.TryGetValue(layoutId, out var bag))
                            perLayout[layoutId] = bag = new Dictionary<string, string>(StringComparer.Ordinal);
                        bag[key] = val;
                    }
                    break;
            }
        }
        FlushOutput();

        var defaults = new LayoutOptions(
            gapsOuter, gapsInner, masterRatio, masterCount,
            new Dictionary<string, string>());

        // Build per-layout options. Scalars inherit from defaults unless
        // overridden via dedicated keys (gaps_outer, gaps_inner, master_*).
        var perLayoutOpts = new Dictionary<string, LayoutOptions>(StringComparer.Ordinal);
        foreach (var kv in perLayout)
        {
            int  pGo = defaults.GapsOuter, pGi = defaults.GapsInner, pMc = defaults.MasterCount;
            double pMr = defaults.MasterRatio;
            var extra = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var kv2 in kv.Value)
            {
                switch (kv2.Key)
                {
                    case "gaps_outer":   pGo = ParseInt(kv2.Value, pGo); break;
                    case "gaps_inner":   pGi = ParseInt(kv2.Value, pGi); break;
                    case "master_count": pMc = ParseInt(kv2.Value, pMc); break;
                    case "master_ratio": pMr = ParseDouble(kv2.Value, pMr); break;
                    default:             extra[kv2.Key] = kv2.Value; break;
                }
            }
            perLayoutOpts[kv.Key] = new LayoutOptions(pGo, pGi, pMr, pMc, extra);
        }

        var slots = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["primary"]    = primary    ?? "tile",
            ["secondary"]  = secondary  ?? "float",
            ["tertiary"]   = tertiary   ?? "monocle",
            ["quaternary"] = quaternary ?? "grid",
        };

        var keybinds = new KeybindConfig { Builtins = kbBuiltins, Custom = kbCustom };

        return new LayoutConfig
        {
            DefaultLayout = defaultLayout ?? "tile",
            Defaults      = defaults,
            Slots         = slots,
            PerLayoutOpts = perLayoutOpts,
            PerOutput     = perOutput,
            Border        = new BorderSpec(borderWidth, borderFocused, borderNormal, borderUrgent),
            Keybinds      = keybinds,
        };
    }

    /// <summary>
    /// Parses the right-hand side of a chord assignment. Accepts either a
    /// quoted/unquoted single string (<c>"Super+H"</c>) or an inline array
    /// of strings (<c>["Super+H", "Alt+F1"]</c>). An empty array is the
    /// explicit "unbind" form and yields an empty list.
    /// </summary>
    private static List<string> ParseChordList(string raw)
    {
        var list = new List<string>();
        var s = raw.Trim();
        if (s.StartsWith("["))
        {
            int end = s.LastIndexOf(']');
            if (end < 0) return list;
            var inner = s.Substring(1, end - 1).Trim();
            if (inner.Length == 0) return list; // = []
            // split on commas not inside quotes
            int start = 0;
            bool inStr = false;
            for (int i = 0; i <= inner.Length; i++)
            {
                if (i < inner.Length && inner[i] == '"') inStr = !inStr;
                if (i == inner.Length || (inner[i] == ',' && !inStr))
                {
                    var item = StripQuotes(inner.Substring(start, i - start).Trim());
                    if (item.Length > 0) list.Add(item);
                    start = i + 1;
                }
            }
            return list;
        }
        var single = StripQuotes(s);
        if (single.Length > 0) list.Add(single);
        return list;
    }

    private static string StripQuotes(string s)
    {
        if (s.Length >= 2 && (s[0] == '"' && s[^1] == '"' || s[0] == '\'' && s[^1] == '\''))
            return s.Substring(1, s.Length - 2);
        return s;
    }

    private static int IndexOfUnquoted(string s, char c)
    {
        bool inStr = false;
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '"') inStr = !inStr;
            else if (!inStr && s[i] == c) return i;
        }
        return -1;
    }

    private static int ParseInt(string s, int fallback) =>
        int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    private static double ParseDouble(string s, double fallback) =>
        double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    private static uint ParseColor(string s, uint fallback)
    {
        // Accept "#RRGGBB" or "#AARRGGBB" or raw uint.
        if (s.StartsWith("#"))
        {
            var hex = s.Substring(1);
            if (uint.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v))
                return hex.Length == 6 ? 0xFF000000u | v : v;
        }
        return uint.TryParse(s, out var p) ? p : fallback;
    }
}
