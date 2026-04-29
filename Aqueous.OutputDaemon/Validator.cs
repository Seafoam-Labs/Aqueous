using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Aqueous.OutputDaemon;

/// <summary>
/// Input validation for <c>set</c> requests. Rejects malformed mode
/// strings, out-of-range scales, unknown transforms, and unresolvable
/// output identifiers BEFORE invoking <c>wlr-randr</c>.
/// </summary>
internal static class Validator
{
    private static readonly Regex ModeRe = new(@"^\d+x\d+(@\d+(\.\d+)?)?$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly HashSet<string> Transforms = new(StringComparer.OrdinalIgnoreCase)
    {
        "normal", "90", "180", "270",
        "flipped", "flipped-90", "flipped-180", "flipped-270",
    };

    public const double MinScale = 0.5;
    public const double MaxScale = 3.0;

    /// <summary>
    /// Resolve and validate one change spec from the wire (a JSON dict)
    /// against the live snapshot. Returns null + populated <paramref name="error"/>
    /// if invalid.
    /// </summary>
    public static OutputChange? Resolve(
        Dictionary<string, object?> spec,
        IReadOnlyList<WlrRandr.Output> snapshot,
        out string? error)
    {
        error = null;

        // Match by EDID first (preferred), then by name.
        WlrRandr.Output? match = null;
        var edid = spec.GetString("edid");
        if (!string.IsNullOrEmpty(edid))
        {
            foreach (var o in snapshot)
                if (string.Equals(o.EdidSha256, edid, StringComparison.OrdinalIgnoreCase))
                { match = o; break; }
            if (match is null)
            {
                error = $"unknown edid '{edid}'";
                return null;
            }
        }
        else
        {
            var name = spec.GetString("name");
            if (string.IsNullOrEmpty(name))
            {
                error = "missing 'name' or 'edid'";
                return null;
            }
            foreach (var o in snapshot)
                if (string.Equals(o.Name, name, StringComparison.Ordinal))
                { match = o; break; }
            if (match is null)
            {
                error = $"unknown output '{name}'";
                return null;
            }
        }

        var change = new OutputChange { Name = match.Name };

        if (spec.TryGetValue("enabled", out var en) && en is bool eb) change.Enabled = eb;

        var mode = spec.GetString("mode");
        if (!string.IsNullOrEmpty(mode))
        {
            if (!ModeRe.IsMatch(mode!))
            {
                error = $"bad mode '{mode}' (expected WIDTHxHEIGHT[@RATE])";
                return null;
            }
            if (!ModeAdvertised(match, mode!))
            {
                error = $"mode '{mode}' not in availableModes for '{match.Name}'";
                return null;
            }
            change.Mode = mode;
        }

        if (spec.GetDouble("scale") is double sc)
        {
            if (double.IsNaN(sc) || sc < MinScale || sc > MaxScale)
            {
                error = $"scale {sc} out of [{MinScale}, {MaxScale}]";
                return null;
            }
            change.Scale = sc;
        }

        var tr = spec.GetString("transform");
        if (!string.IsNullOrEmpty(tr))
        {
            if (!Transforms.Contains(tr!))
            {
                error = $"unknown transform '{tr}'";
                return null;
            }
            change.Transform = tr;
        }

        if (spec.TryGetValue("position", out var posObj) && posObj is List<object?> pl && pl.Count == 2)
        {
            int? px = ToInt(pl[0]);
            int? py = ToInt(pl[1]);
            if (px is null || py is null)
            {
                error = "position must be [int, int]";
                return null;
            }
            change.Position = (px.Value, py.Value);
        }

        if (spec.TryGetValue("adaptive_sync", out var av) && av is bool ab)
            change.AdaptiveSync = ab;

        return change;
    }

    private static bool ModeAdvertised(WlrRandr.Output o, string mode)
    {
        if (o.Modes.Count == 0) return true; // no enumeration → trust user
        // Parse "WxH[@R]"
        int x = mode.IndexOf('x');
        int at = mode.IndexOf('@');
        if (x <= 0) return false;
        int wEnd = x;
        int hStart = x + 1;
        int hEnd = at >= 0 ? at : mode.Length;
        if (!int.TryParse(mode.AsSpan(0, wEnd), out int w)) return false;
        if (!int.TryParse(mode.AsSpan(hStart, hEnd - hStart), out int h)) return false;
        double? r = null;
        if (at >= 0 && double.TryParse(mode.AsSpan(at + 1), NumberStyles.Float, CultureInfo.InvariantCulture, out var rr))
            r = rr;
        foreach (var m in o.Modes)
        {
            if (m.Width != w || m.Height != h) continue;
            if (r is null) return true;
            if (Math.Abs(m.Refresh - r.Value) < 0.5) return true;
        }
        return false;
    }

    private static int? ToInt(object? v) => v switch
    {
        double d => (int)d,
        int i => i,
        long l => (int)l,
        _ => null,
    };
}
