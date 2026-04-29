using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace Aqueous.OutputDaemon;

/// <summary>
/// Minimal TOML-subset reader covering the keys this daemon consumes
/// from <c>wm.toml</c> / <c>outputs.toml</c>:
/// <list type="bullet">
///   <item>top-level <c>[display]</c> table</item>
///   <item>repeated <c>[[output]]</c> tables</item>
///   <item>repeated <c>[[display.profile]]</c> tables (each with nested
///         <c>[[display.profile.output]]</c> entries)</item>
/// </list>
/// Mirrors Aqueous's own TOML subset: <c>[section]</c>, <c>[[array]]</c>,
/// <c>key = value</c>, <c># comments</c>, scalar strings/ints/floats/bools,
/// inline arrays for positions. Unknown keys are ignored.
/// </summary>
internal sealed class TomlConfig
{
    public sealed class DisplaySettings
    {
        public bool ApplyOnStart = true;
        public bool ApplyOnReload = true;
        public string? FallbackProfile;
        public string IdentifyBy = "edid";
        public int RollbackSeconds = 0;
    }

    public sealed class OutputSpec
    {
        // Matchers
        public string? Name;
        public string? Edid;
        // Settings (all optional)
        public bool? Enabled;
        public string? Mode;
        public double? Scale;
        public string? Transform;
        public (int X, int Y)? Position;
        public bool? AdaptiveSync;
        public bool Primary;

        public Dictionary<string, object?> ToDict()
        {
            var d = new Dictionary<string, object?>(StringComparer.Ordinal);
            if (!string.IsNullOrEmpty(Edid)) d["edid"] = Edid;
            if (!string.IsNullOrEmpty(Name)) d["name"] = Name;
            if (Enabled is bool en) d["enabled"] = en;
            if (!string.IsNullOrEmpty(Mode)) d["mode"] = Mode;
            if (Scale is double sc) d["scale"] = sc;
            if (!string.IsNullOrEmpty(Transform)) d["transform"] = Transform;
            if (Position is (int x, int y))
                d["position"] = new List<object?> { (double)x, (double)y };
            if (AdaptiveSync is bool vrr) d["adaptive_sync"] = vrr;
            return d;
        }
    }

    public sealed class Profile
    {
        public string Name = "";
        public List<OutputSpec> Outputs = new();
    }

    public DisplaySettings Display = new();
    public List<OutputSpec> Outputs = new();
    public List<Profile> Profiles = new();

    public static TomlConfig? Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return Parse(File.ReadAllText(path));
        }
        catch
        {
            return null;
        }
    }

    public static TomlConfig Parse(string text)
    {
        var cfg = new TomlConfig();
        // Header context: a "header" identifies what table the next
        // key=value pairs feed into.
        string section = "";       // current dotted section name
        OutputSpec? curOutput = null;
        Profile? curProfile = null;
        OutputSpec? curProfileOutput = null;

        foreach (var rawLine in text.Split('\n'))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0) continue;

            if (line[0] == '[')
            {
                // section header
                bool array = line.StartsWith("[[", StringComparison.Ordinal);
                int end = line.IndexOf(array ? "]]" : "]", StringComparison.Ordinal);
                if (end < 0) continue;
                var header = line.Substring(array ? 2 : 1, end - (array ? 2 : 1)).Trim();
                section = header;

                if (array && header == "output")
                {
                    curOutput = new OutputSpec();
                    cfg.Outputs.Add(curOutput);
                    curProfile = null; curProfileOutput = null;
                }
                else if (array && header == "display.profile")
                {
                    curProfile = new Profile();
                    cfg.Profiles.Add(curProfile);
                    curOutput = null; curProfileOutput = null;
                }
                else if (array && header == "display.profile.output")
                {
                    curProfileOutput = new OutputSpec();
                    if (curProfile is not null) curProfile.Outputs.Add(curProfileOutput);
                    curOutput = null;
                }
                else
                {
                    curOutput = null; curProfileOutput = null;
                    if (header != "display.profile") curProfile = null;
                }
                continue;
            }

            // key = value
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            var key = line.Substring(0, eq).Trim();
            var raw = line.Substring(eq + 1).Trim();
            var val = ParseValue(raw);

            switch (section)
            {
                case "display":
                    ApplyDisplay(cfg.Display, key, val);
                    break;
                case "output" when curOutput is not null:
                    ApplyOutputSpec(curOutput, key, val);
                    break;
                case "display.profile" when curProfile is not null:
                    if (key == "name" && val is string ps) curProfile.Name = ps;
                    break;
                case "display.profile.output" when curProfileOutput is not null:
                    ApplyOutputSpec(curProfileOutput, key, val);
                    break;
            }
        }
        return cfg;
    }

    private static void ApplyDisplay(DisplaySettings d, string key, object? v)
    {
        switch (key)
        {
            case "apply_on_start":   if (v is bool a) d.ApplyOnStart = a; break;
            case "apply_on_reload":  if (v is bool b) d.ApplyOnReload = b; break;
            case "fallback_profile": if (v is string fp) d.FallbackProfile = fp; break;
            case "identify_by":      if (v is string ib) d.IdentifyBy = ib; break;
            case "rollback_seconds": if (v is double rs) d.RollbackSeconds = (int)rs; break;
        }
    }

    private static void ApplyOutputSpec(OutputSpec o, string key, object? v)
    {
        switch (key)
        {
            case "name":          if (v is string n)  o.Name = n; break;
            case "edid":          if (v is string e)  o.Edid = e; break;
            case "enabled":       if (v is bool en)   o.Enabled = en; break;
            case "mode":          if (v is string m)  o.Mode = m; break;
            case "scale":         if (v is double s)  o.Scale = s; break;
            case "transform":     if (v is string t)  o.Transform = t; break;
            case "adaptive_sync": if (v is bool vrr)  o.AdaptiveSync = vrr; break;
            case "primary":       if (v is bool pr)   o.Primary = pr; break;
            case "position":
                if (v is List<object?> arr && arr.Count == 2 &&
                    arr[0] is double px && arr[1] is double py)
                    o.Position = ((int)px, (int)py);
                break;
        }
    }

    // ----- value parser ---------------------------------------------------

    private static object? ParseValue(string raw)
    {
        if (raw.Length == 0) return null;
        if (raw[0] == '"')
        {
            int end = raw.LastIndexOf('"');
            if (end <= 0) return null;
            return Unescape(raw.Substring(1, end - 1));
        }
        if (raw == "true") return true;
        if (raw == "false") return false;
        if (raw[0] == '[')
        {
            int end = raw.LastIndexOf(']');
            if (end <= 0) return null;
            var inner = raw.Substring(1, end - 1);
            var list = new List<object?>();
            foreach (var part in inner.Split(','))
            {
                var t = part.Trim();
                if (t.Length == 0) continue;
                list.Add(ParseValue(t));
            }
            return list;
        }
        if (double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
            return d;
        return raw;
    }

    private static string Unescape(string s)
    {
        if (s.IndexOf('\\') < 0) return s;
        var sb = new System.Text.StringBuilder(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '\\' && i + 1 < s.Length)
            {
                char e = s[++i];
                sb.Append(e switch
                {
                    'n' => '\n', 'r' => '\r', 't' => '\t',
                    '"' => '"', '\\' => '\\', _ => e,
                });
            }
            else sb.Append(c);
        }
        return sb.ToString();
    }

    private static string StripComment(string line)
    {
        // Naive: ignore # outside double quotes.
        bool inStr = false;
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (c == '"') inStr = !inStr;
            else if (c == '#' && !inStr) return line.Substring(0, i);
        }
        return line;
    }
}
