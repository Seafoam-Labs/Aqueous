using System;
using System.Collections.Generic;
using System.IO;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Configuration;
using Aqueous.Features.Input;
using Aqueous.Features.State;

namespace Aqueous.Features.Layout;

/// <summary>
/// Hand-rolled TOML subset loader for <see cref="LayoutConfig"/>. Lives in its own file so the
/// model stays small and reads as a record. The parser recognises:
/// <list type="bullet">
/// <item>
/// <c>[section]</c> and <c>[section.subsection]</c>
/// </item>
/// <item>
/// <c>[[output]]</c> arrays-of-tables
/// </item>
/// <item>
/// <c>key = value</c> with string ("."), int, float, bool
/// </item>
/// <item>
/// line comments starting with <c>#</c>
/// </item>
/// </list>
/// Unknown keys and unknown <c>[layout.options.&lt;id&gt;]</c> sections are preserved as-is — this
/// is required for plugin-supplied layouts whose id is not known to the core registry at parse
/// time.
/// </summary>
public static class LayoutConfigLoader
{
    /// <summary>
    /// Loads a config from <paramref name="path"/>. On any error returns <see
    /// cref="LayoutConfig.Default"/> — the WM must never fail to start because of a malformed config.
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
    /// Parses a TOML-subset configuration text. Never throws; malformed values fall back to their
    /// per-key defaults via the <c>ParseXxx</c> helpers below.
    /// </summary>
    public static LayoutConfig Parse(string text)
    {
        string? defaultLayout = null;
        string? primary = null, secondary = null, tertiary = null, quaternary = null;
        var perLayout = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        var perOutput = new Dictionary<string, string>(StringComparer.Ordinal);
        int gapsOuter = 8, gapsInner = 4, masterCount = 1, borderWidth = 2;
        int strutTop = 0, strutBottom = 0, strutLeft = 0, strutRight = 0;
        double masterRatio = 0.55;
        uint borderFocused = 0xFF88C0D0u, borderNormal = 0xFF3B4252u, borderUrgent = 0xFFBF616Au;
        // [blur] section — global backdrop blur driven to riverdelta via set_blur. Defaults mirror BlurSpec.Default.
        bool blurEnabled = BlurSpec.Default.Enabled;
        int blurRadius = BlurSpec.Default.Radius;
        int blurPasses = BlurSpec.Default.Passes;

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

        // [input] family of sections ([input], [input.mouse|touchpad|trackpoint]) is parsed
        // separately by InputConfigParser (delegated at the end of Parse), so the input concern
        // owns its own parsing.

        string? curSection = null;
        // Used by [[output]] tables.
        string? pendingOutputName = null;
        string? pendingOutputEdid = null;
        string? pendingOutputMake = null;
        string? pendingOutputModel = null;
        string? pendingOutputSerial = null;
        string? pendingOutputLayout = null;

        // EDID/make/model/serial-selector overrides, populated when an [[output]] block names a
        // physical monitor by stable identity instead of (or in addition to) a connector. The name
        // dictionary still wins at resolution time — see LayoutConfig.ResolveLayoutForOutput.
        var perOutputSelectors = new List<(OutputSelector, string)>();

        void FlushOutput()
        {
            if (pendingOutputLayout != null)
            {
                // Prefer the name-keyed dict whenever a `name = "..."` was supplied; otherwise fall
                // back to the selector list when at least one of edid/make/model/serial is set.
                if (!string.IsNullOrEmpty(pendingOutputName))
                {
                    perOutput[pendingOutputName] = pendingOutputLayout;
                }
                else if (!string.IsNullOrEmpty(pendingOutputEdid)
                         || !string.IsNullOrEmpty(pendingOutputMake)
                         || !string.IsNullOrEmpty(pendingOutputModel)
                         || !string.IsNullOrEmpty(pendingOutputSerial))
                {
                    perOutputSelectors.Add((
                        new OutputSelector(
                            Name: null,
                            Edid: string.IsNullOrEmpty(pendingOutputEdid) ? null : pendingOutputEdid,
                            Make: string.IsNullOrEmpty(pendingOutputMake) ? null : pendingOutputMake,
                            Model: string.IsNullOrEmpty(pendingOutputModel) ? null : pendingOutputModel,
                            Serial: string.IsNullOrEmpty(pendingOutputSerial) ? null : pendingOutputSerial),
                        pendingOutputLayout));
                }
            }

            pendingOutputName = null;
            pendingOutputEdid = null;
            pendingOutputMake = null;
            pendingOutputModel = null;
            pendingOutputSerial = null;
            pendingOutputLayout = null;
        }

        // ------------------------------------------------------------- [[exec]] autostart entries.
        // Each [[exec]] table becomes one ExecEntry. Required keys (`name`, `command`) must both be
        // present; otherwise the entry is silently dropped (a warning is logged once we have a logger
        // seam here). Duplicate `name`s: first wins.
        // ---------------------------------------------------------------
        var execEntries = new List<ExecEntry>();
        var execNames = new HashSet<string>(StringComparer.Ordinal);
        string? execPendingName = null;
        string? execPendingCommand = null;
        ExecWhen execPendingWhen = ExecWhen.Startup;
        bool execPendingOnce = true;
        bool execPendingRestart = false;
        string? execPendingLogPath = null;
        Dictionary<string, string> execPendingEnv = new(StringComparer.Ordinal);
        bool execHasPending = false;

        void FlushExec()
        {
            if (!execHasPending)
            {
                return;
            }

            execHasPending = false;
            if (string.IsNullOrWhiteSpace(execPendingName)
                || string.IsNullOrWhiteSpace(execPendingCommand))
            {
                // Silently drop incomplete entries — same permissive posture as the rest of the loader.
                execPendingName = null;
                execPendingCommand = null;
                execPendingWhen = ExecWhen.Startup;
                execPendingOnce = true;
                execPendingRestart = false;
                execPendingLogPath = null;
                execPendingEnv = new Dictionary<string, string>(StringComparer.Ordinal);
                return;
            }

            if (!execNames.Add(execPendingName!))
            {
                // Duplicate name: first wins.
                execPendingName = null;
                execPendingCommand = null;
                execPendingWhen = ExecWhen.Startup;
                execPendingOnce = true;
                execPendingRestart = false;
                execPendingLogPath = null;
                execPendingEnv = new Dictionary<string, string>(StringComparer.Ordinal);
                return;
            }

            execEntries.Add(new ExecEntry
            {
                Name = execPendingName!,
                Command = execPendingCommand!,
                When = execPendingWhen,
                Once = execPendingOnce,
                Restart = execPendingRestart,
                LogPath = execPendingLogPath,
                Env = execPendingEnv,
            });
            execPendingName = null;
            execPendingCommand = null;
            execPendingWhen = ExecWhen.Startup;
            execPendingOnce = true;
            execPendingRestart = false;
            execPendingLogPath = null;
            execPendingEnv = new Dictionary<string, string>(StringComparer.Ordinal);
        }

        Dictionary<string, string> actionsMap = [];

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("#"))
            {
                continue;
            }

            if (line.StartsWith("[["))
            {
                // Array-of-tables — [[output]], [[exec]].
                FlushOutput();
                FlushExec();
                int end = line.IndexOf("]]", StringComparison.Ordinal);
                curSection = end > 2 ? "[[" + line.Substring(2, end - 2).Trim() + "]]" : line;

                if (curSection == "[[exec]]")
                {
                    // Open a fresh exec entry buffer.
                    execHasPending = true;
                    execPendingEnv = new Dictionary<string, string>(StringComparer.Ordinal);
                }

                continue;
            }

            if (line.StartsWith("["))
            {
                FlushOutput();
                FlushExec();
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
            // Strip trailing inline comment (#)
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
                    switch (key)
                    {
                        case "name":
                            pendingOutputName = val;
                            break;
                        case "edid":
                            pendingOutputEdid = val;
                            break;
                        case "make":
                            pendingOutputMake = val;
                            break;
                        case "model":
                            pendingOutputModel = val;
                            break;
                        case "serial":
                            pendingOutputSerial = val;
                            break;
                        case "layout":
                            pendingOutputLayout = val;
                            break;
                    }

                    break;
                case "[[exec]]":
                    switch (key)
                    {
                        case "name":
                            execPendingName = val;
                            break;
                        case "command":
                            execPendingCommand = val;
                            break;
                        case "when":
                            execPendingWhen = val.ToLowerInvariant() switch
                            {
                                "reload" => ExecWhen.Reload,
                                "always" => ExecWhen.Always,
                                _ => ExecWhen.Startup,
                            };
                            break;
                        case "once":
                            execPendingOnce = ParseBool(val, execPendingOnce);
                            break;
                        case "restart":
                            execPendingRestart = ParseBool(val, execPendingRestart);
                            break;
                        case "log":
                            execPendingLogPath = string.IsNullOrEmpty(val) ? null : val;
                            break;
                        case "env":
                            ParseInlineEnvTable(valRaw, execPendingEnv);
                            break;
                    }

                    break;
                case "[[snapzones]]":
                case "[[snapzones.zone]]":
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
                    // Key is the chord (it may have been wrapped in quotes).
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
                // [input], [input.mouse|touchpad|trackpoint] are handled by InputConfigParser.
                case "blur":
                    switch (key)
                    {
                        case "enabled": blurEnabled = ParseBool(val, blurEnabled); break;
                        case "radius": blurRadius = Math.Max(0, ParseInt(val, blurRadius)); break;
                        case "passes": blurPasses = Math.Max(0, ParseInt(val, blurPasses)); break;
                    }

                    break;
                case "struts":
                    switch (key)
                    {
                        case "top": strutTop = ParseInt(val, strutTop); break;
                        case "bottom": strutBottom = ParseInt(val, strutBottom); break;
                        case "left": strutLeft = ParseInt(val, strutLeft); break;
                        case "right": strutRight = ParseInt(val, strutRight); break;
                    }

                    break;
                case "actions":
                    actionsMap[StripQuotes(key)] = val;
                    break;
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
        FlushExec();

        var defaults = new LayoutOptions(
            gapsOuter, gapsInner, masterRatio, masterCount,
            new Dictionary<string, string>());
        var struts = new StrutsConfig()
        {
            Top = Math.Max(0, strutTop),
            Bottom = Math.Max(0, strutBottom),
            Left = Math.Max(0, strutLeft),
            Right = Math.Max(0, strutRight),
        };

        // Deprecation: [layout.options.game-mode] is ignored — game-mode options live in
        // rules.toml under [game_mode] so they can be hot-reloaded independently of wm.toml.
        // Warned once per load; will become an error in a future release.
        if (perLayout.ContainsKey("game-mode"))
        {
            Aqueous.Diagnostics.RiverLog.Write(
                "[layout.options.game-mode] in wm.toml is deprecated — game-mode options live " +
                "in rules.toml under [game_mode]. Values here are ignored. See docs/rules.md.");
        }

        // Build per-layout options. Scalars inherit from defaults unless overridden via dedicated keys
        // (gaps_outer, gaps_inner, master_*).
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
        var actions = new ActionsConfig()
        {
            LockScreen = actionsMap.TryGetValue("lock_screen", out var ls) ? ls : null,
            SpawnTerminal = actionsMap.TryGetValue("spawn_terminal", out var st) ? st : "alacritty",
            ToggleStartMenu = actionsMap.TryGetValue("toggle_start_menu", out var tm) ? tm : null,
        };

        return new LayoutConfig
        {
            DefaultLayout = defaultLayout ?? "tile",
            Defaults = defaults,
            Slots = slots,
            PerLayoutOpts = perLayoutOpts,
            PerOutput = perOutput,
            PerOutputSelectors = perOutputSelectors,
            Border = new BorderSpec(borderWidth, borderFocused, borderNormal, borderUrgent),
            Blur = new BlurSpec(blurEnabled, blurRadius, blurPasses),
            Keybinds = keybinds,
            State = stateConfig,
            Exec = new ExecConfig { Entries = execEntries },
            Input = InputConfigParser.Parse(text),
            Struts = struts,
            Actions = actions
        };
    }


    /// <summary>
    /// Parses the right-hand side of a chord assignment. Accepts either a quoted/unquoted single
    /// string (<c>"Super+H"</c>) or an inline array of strings (<c>["Super+H", "Alt+F1"]</c>). An
    /// empty array is the explicit "unbind" form and yields an empty list.
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

            // Split on commas not inside quotes
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

    /// <summary>
    /// Parses a single-line TOML inline table of the form <c>{ KEY = "value", OTHER = "v" }</c> and
    /// merges its key/value pairs into <paramref name="into"/>. Best-effort: malformed input is
    /// ignored. Used by <c>[[exec]] env = { … }</c>.
    /// </summary>
    private static void ParseInlineEnvTable(string raw, IDictionary<string, string> into)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return;
        }

        var s = raw.Trim();
        // Strip outer braces.
        int lb = s.IndexOf('{');
        int rb = s.LastIndexOf('}');
        if (lb < 0 || rb <= lb)
        {
            return;
        }

        var body = s.Substring(lb + 1, rb - lb - 1).Trim();
        if (body.Length == 0)
        {
            return;
        }

        // Split on top-level commas (i.e. commas that are NOT inside double-quoted spans).
        var parts = new List<string>();
        var cur = new System.Text.StringBuilder();
        bool inQuotes = false;
        for (int i = 0; i < body.Length; i++)
        {
            char c = body[i];
            if (c == '"' && (i == 0 || body[i - 1] != '\\'))
            {
                inQuotes = !inQuotes;
                cur.Append(c);
                continue;
            }

            if (c == ',' && !inQuotes)
            {
                parts.Add(cur.ToString());
                cur.Clear();
                continue;
            }

            cur.Append(c);
        }

        if (cur.Length > 0)
        {
            parts.Add(cur.ToString());
        }

        foreach (var p in parts)
        {
            var pair = p.Trim();
            if (pair.Length == 0)
            {
                continue;
            }

            int eq = pair.IndexOf('=');
            if (eq <= 0)
            {
                continue;
            }

            var k = pair.Substring(0, eq).Trim();
            var v = StripQuotes(pair.Substring(eq + 1).Trim());
            if (k.Length == 0)
            {
                continue;
            }

            into[k] = v;
        }
    }

    // Scalar parsing helpers forward to the shared TomlScalars so LayoutConfigLoader and
    // InputConfigParser stay byte-for-byte compatible.
    private static string StripQuotes(string s) => TomlScalars.StripQuotes(s);

    private static int IndexOfUnquoted(string s, char c) => TomlScalars.IndexOfUnquoted(s, c);

    private static int ParseInt(string s, int fallback) => TomlScalars.ParseInt(s, fallback);

    private static double ParseDouble(string s, double fallback) => TomlScalars.ParseDouble(s, fallback);

    private static bool ParseBool(string s, bool fallback) => TomlScalars.ParseBool(s, fallback);

    private static uint ParseColor(string s, uint fallback) => TomlScalars.ParseColor(s, fallback);
}
