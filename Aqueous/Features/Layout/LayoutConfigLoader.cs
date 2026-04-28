using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Aqueous.Features.Input;
using Aqueous.Features.State;

namespace Aqueous.Features.Layout;

/// <summary>
/// Hand-rolled TOML subset loader for <see cref="LayoutConfig"/>. Lives in
/// its own file so the model stays small and reads as a record. The parser
/// recognises:
/// <list type="bullet">
///   <item><c>[section]</c> and <c>[section.subsection]</c></item>
///   <item><c>[[output]]</c> arrays-of-tables</item>
///   <item><c>key = value</c> with string ("..."), int, float, bool</item>
///   <item>line comments starting with <c>#</c></item>
/// </list>
/// Unknown keys and unknown <c>[layout.options.&lt;id&gt;]</c> sections are
/// preserved as-is — this is required for plugin-supplied layouts whose
/// id is not known to the core registry at parse time.
/// </summary>
public static class LayoutConfigLoader
{
    /// <summary>
    /// Loads a config from <paramref name="path"/>. On any error returns
    /// <see cref="LayoutConfig.Default"/> — the WM must never fail to start
    /// because of a malformed config.
    /// </summary>
    public static LayoutConfig Load(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return LayoutConfig.Default;
            }

            return Parse(File.ReadAllText(path));
        }
        catch
        {
            return LayoutConfig.Default;
        }
    }

    /// <summary>
    /// Parses a TOML-subset configuration text. Never throws; malformed
    /// values fall back to their per-key defaults via the <c>ParseXxx</c>
    /// helpers below.
    /// </summary>
    public static LayoutConfig Parse(string text)
    {
        string? defaultLayout = null;
        string? primary = null, secondary = null, tertiary = null, quaternary = null;
        var perLayout = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        var perOutput = new Dictionary<string, string>(StringComparer.Ordinal);
        int gapsOuter = 8, gapsInner = 4, masterCount = 1, borderWidth = 2;
        double masterRatio = 0.55;
        uint borderFocused = 0xFF88C0D0u, borderNormal = 0xFF3B4252u, borderUrgent = 0xFFBF616Au;

        // Keybind tables.
        var kbBuiltins = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var kbCustom = new Dictionary<string, string>(StringComparer.Ordinal);
        var knownActions = new HashSet<string>(KeybindConfig.KnownActions, StringComparer.Ordinal);

        // Scratchpad
        var stFsHidesBar = StateConfig.Default.FullscreenHidesBar;
        var stMaxFullOutput = StateConfig.Default.MaximizeFullOutput;
        var spOnEmpty = ScratchpadConfig.Default.OnEmpty;
        var spWidthFrac = ScratchpadConfig.Default.WidthFrac;
        var spHeightFrac = ScratchpadConfig.Default.HeightFrac;
        var spAnchor = ScratchpadConfig.Default.Anchor;
        var spSpawn = new Dictionary<string, string>(StringComparer.Ordinal);

        //Input Config
        var inFocusFollowsMouse = InputConfig.Default.FocusFollowsMouse;
        var pointerAcceleration = InputConfig.Default.PointerAcceleration;
        var pointerAccelerationFactor = InputConfig.Default.PointerAccelerationFactor;
        // Per-device libinput knobs ([input.mouse|touchpad|trackpoint]).
        // Mutable PerDeviceInput-shaped buffers populated by the section
        // switch below; flushed into immutable PerDeviceInput records at
        // the end of Parse.
        var devMouse = new PerDeviceBuf();
        var devTouch = new PerDeviceBuf();
        var devTrack = new PerDeviceBuf();

        string? curSection = null;
        // Used by [[output]] tables.
        string? pendingOutputName = null;
        string? pendingOutputLayout = null;

        void FlushOutput()
        {
            if (pendingOutputName != null && pendingOutputLayout != null)
            {
                perOutput[pendingOutputName] = pendingOutputLayout;
            }

            pendingOutputName = null;
            pendingOutputLayout = null;
        }

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("#"))
            {
                continue;
            }

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
            if (eq <= 0)
            {
                continue;
            }

            var key = line.Substring(0, eq).Trim();
            var valRaw = line.Substring(eq + 1).Trim();
            // strip trailing inline comment (#)
            int hash = IndexOfUnquoted(valRaw, '#');
            if (hash >= 0)
            {
                valRaw = valRaw.Substring(0, hash).Trim();
            }

            var val = StripQuotes(valRaw);

            switch (curSection)
            {
                case "layout":
                    switch (key)
                    {
                        case "default": defaultLayout = val; break;
                        case "gaps_outer": gapsOuter = ParseInt(val, gapsOuter); break;
                        case "gaps_inner": gapsInner = ParseInt(val, gapsInner); break;
                        case "master_ratio": masterRatio = ParseDouble(val, masterRatio); break;
                        case "master_count": masterCount = ParseInt(val, masterCount); break;
                        case "border_width": borderWidth = ParseInt(val, borderWidth); break;
                        case "border_focused": borderFocused = ParseColor(val, borderFocused); break;
                        case "border_normal": borderNormal = ParseColor(val, borderNormal); break;
                        case "border_urgent": borderUrgent = ParseColor(val, borderUrgent); break;
                    }

                    break;
                case "layout.slots":
                    switch (key)
                    {
                        case "primary": primary = val; break;
                        case "secondary": secondary = val; break;
                        case "tertiary": tertiary = val; break;
                        case "quaternary": quaternary = val; break;
                    }

                    break;
                case "[[output]]":
                    if (key == "name")
                    {
                        pendingOutputName = val;
                    }
                    else if (key == "layout")
                    {
                        pendingOutputLayout = val;
                    }

                    break;
                case "keybinds":
                    if (knownActions.Contains(key))
                    {
                        kbBuiltins[key] = ParseChordList(valRaw);
                    }

                    // Unknown action names are ignored (forward-compat).
                    break;
                case "keybinds.custom":
                {
                    // key is the chord (it may have been wrapped in quotes).
                    var chord = StripQuotes(key);
                    kbCustom[chord] = val;
                    break;
                }
                case "state":
                    switch (key)
                    {
                        case "fullscreen_hides_bar": stFsHidesBar = ParseBool(val, stFsHidesBar); break;
                        case "maximize_full_output": stMaxFullOutput = ParseBool(val, stMaxFullOutput); break;
                    }

                    break;
                case "scratchpad":
                    switch (key)
                    {
                        case "on_empty": spOnEmpty = val; break;
                        case "width_frac": spWidthFrac = ParseDouble(val, spWidthFrac); break;
                        case "height_frac": spHeightFrac = ParseDouble(val, spHeightFrac); break;
                        case "anchor": spAnchor = val; break;
                    }

                    break;
                case "scratchpad.spawn":
                    spSpawn[StripQuotes(key)] = val;
                    break;
                case "input":
                    switch (key)
                    {
                        case "focus_follows_mouse":
                            inFocusFollowsMouse = ParseBool(val, inFocusFollowsMouse);
                            break;
                        case "pointer_acceleration":
                            pointerAcceleration = ParseBool(val, pointerAcceleration);
                            break;
                        case "pointer_acceleration_factor":
                            pointerAccelerationFactor = ParseDouble(val, pointerAccelerationFactor);
                            break;
                    }

                    break;
                case "input.mouse":      ParseDeviceKey(devMouse, key, val); break;
                case "input.touchpad":   ParseDeviceKey(devTouch, key, val); break;
                case "input.trackpoint": ParseDeviceKey(devTrack, key, val); break;
                default:
                    if (curSection != null && curSection.StartsWith("layout.options.", StringComparison.Ordinal))
                    {
                        var layoutId = curSection.Substring("layout.options.".Length);
                        if (!perLayout.TryGetValue(layoutId, out var bag))
                        {
                            perLayout[layoutId] = bag = new Dictionary<string, string>(StringComparer.Ordinal);
                        }

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
            int pGo = defaults.GapsOuter, pGi = defaults.GapsInner, pMc = defaults.MasterCount;
            double pMr = defaults.MasterRatio;
            var extra = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var kv2 in kv.Value)
            {
                switch (kv2.Key)
                {
                    case "gaps_outer": pGo = ParseInt(kv2.Value, pGo); break;
                    case "gaps_inner": pGi = ParseInt(kv2.Value, pGi); break;
                    case "master_count": pMc = ParseInt(kv2.Value, pMc); break;
                    case "master_ratio": pMr = ParseDouble(kv2.Value, pMr); break;
                    default: extra[kv2.Key] = kv2.Value; break;
                }
            }

            perLayoutOpts[kv.Key] = new LayoutOptions(pGo, pGi, pMr, pMc, extra);
        }

        var slots = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["primary"] = primary ?? "tile",
            ["secondary"] = secondary ?? "float",
            ["tertiary"] = tertiary ?? "monocle",
            ["quaternary"] = quaternary ?? "grid",
        };

        var keybinds = new KeybindConfig { Builtins = kbBuiltins, Custom = kbCustom };

        var stateConfig = new StateConfig
        {
            FullscreenHidesBar = stFsHidesBar,
            MaximizeFullOutput = stMaxFullOutput,
            Scratchpad = new ScratchpadConfig
            {
                OnEmpty = spOnEmpty,
                WidthFrac = spWidthFrac,
                HeightFrac = spHeightFrac,
                Anchor = spAnchor,
                SpawnCommands = spSpawn,
            },
        };

        return new LayoutConfig
        {
            DefaultLayout = defaultLayout ?? "tile",
            Defaults = defaults,
            Slots = slots,
            PerLayoutOpts = perLayoutOpts,
            PerOutput = perOutput,
            Border = new BorderSpec(borderWidth, borderFocused, borderNormal, borderUrgent),
            Keybinds = keybinds,
            State = stateConfig,
            Input = new InputConfig()
            {
                FocusFollowsMouse = inFocusFollowsMouse,
                PointerAcceleration = pointerAcceleration,
                PointerAccelerationFactor = pointerAccelerationFactor,
                Mouse      = devMouse.ToRecord(),
                Touchpad   = devTouch.ToRecord(),
                Trackpoint = devTrack.ToRecord(),
            }
        };
    }

    /// <summary>
    /// Mutable scratch buffer that mirrors <see cref="PerDeviceInput"/>'s
    /// nullable fields. Used while parsing <c>[input.mouse|touchpad|trackpoint]</c>
    /// sub-tables, then frozen via <see cref="ToRecord"/>.
    /// </summary>
    private sealed class PerDeviceBuf
    {
        public string? AccelProfile;
        public double? AccelSpeed;
        public bool? NaturalScroll;
        public bool? Tap;
        public bool? Dwt;
        public bool? LeftHanded;
        public string? ClickMethod;
        public string? ScrollMethod;
        public bool? MiddleEmulation;

        public PerDeviceInput ToRecord() => new()
        {
            AccelProfile    = AccelProfile,
            AccelSpeed      = AccelSpeed,
            NaturalScroll   = NaturalScroll,
            Tap             = Tap,
            Dwt             = Dwt,
            LeftHanded      = LeftHanded,
            ClickMethod     = ClickMethod,
            ScrollMethod    = ScrollMethod,
            MiddleEmulation = MiddleEmulation,
        };
    }

    /// <summary>
    /// Maps one <c>key = value</c> from an <c>[input.&lt;device&gt;]</c>
    /// sub-table onto <paramref name="d"/>. Key names mirror niri's KDL
    /// schema (with <c>-</c> normalised to <c>_</c>) so configs port
    /// trivially.
    /// </summary>
    private static void ParseDeviceKey(PerDeviceBuf d, string key, string val)
    {
        // Accept both "accel-speed" and "accel_speed" — niri uses dashes,
        // most TOML tooling prefers underscores.
        var k = key.Replace('-', '_');
        var v = StripQuotes(val);
        switch (k)
        {
            case "accel_profile":
                d.AccelProfile = v;
                break;
            case "accel_speed":
                d.AccelSpeed = ParseDouble(val, 0.0);
                break;
            case "natural_scroll":
                d.NaturalScroll = ParseBool(val, false);
                break;
            case "tap":
                d.Tap = ParseBool(val, false);
                break;
            case "dwt":
                d.Dwt = ParseBool(val, false);
                break;
            case "left_handed":
                d.LeftHanded = ParseBool(val, false);
                break;
            case "click_method":
                d.ClickMethod = v;
                break;
            case "scroll_method":
                d.ScrollMethod = v;
                break;
            case "middle_emulation":
                d.MiddleEmulation = ParseBool(val, false);
                break;
        }
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
            if (end < 0)
            {
                return list;
            }

            var inner = s.Substring(1, end - 1).Trim();
            if (inner.Length == 0)
            {
                return list; // = []
            }

            // split on commas not inside quotes
            int start = 0;
            bool inStr = false;
            for (int i = 0; i <= inner.Length; i++)
            {
                if (i < inner.Length && inner[i] == '"')
                {
                    inStr = !inStr;
                }

                if (i == inner.Length || (inner[i] == ',' && !inStr))
                {
                    var item = StripQuotes(inner.Substring(start, i - start).Trim());
                    if (item.Length > 0)
                    {
                        list.Add(item);
                    }

                    start = i + 1;
                }
            }

            return list;
        }

        var single = StripQuotes(s);
        if (single.Length > 0)
        {
            list.Add(single);
        }

        return list;
    }

    private static string StripQuotes(string s)
    {
        if (s.Length >= 2 && (s[0] == '"' && s[^1] == '"' || s[0] == '\'' && s[^1] == '\''))
        {
            return s.Substring(1, s.Length - 2);
        }

        return s;
    }

    private static int IndexOfUnquoted(string s, char c)
    {
        bool inStr = false;
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '"')
            {
                inStr = !inStr;
            }
            else if (!inStr && s[i] == c)
            {
                return i;
            }
        }

        return -1;
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

    private static uint ParseColor(string s, uint fallback)
    {
        // Accept "#RRGGBB" or "#AARRGGBB" or raw uint.
        if (s.StartsWith("#"))
        {
            var hex = s.Substring(1);
            if (uint.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v))
            {
                return hex.Length == 6 ? 0xFF000000u | v : v;
            }
        }

        return uint.TryParse(s, out var p) ? p : fallback;
    }
}
