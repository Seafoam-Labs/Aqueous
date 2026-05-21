using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Aqueous.OutputDaemon;

/// <summary>
/// Input validation for <c>set</c> requests. Rejects malformed mode strings, out-of-range scales,
/// unknown transforms, and unresolvable output identifiers BEFORE invoking <c>wlr-randr</c>.
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
    /// Resolve and validate one change spec against the live snapshot.
    /// Back-compat shim: returns the first resolved change (or null) and the first error.
    /// </summary>
    public static OutputChange? Resolve(
        Dictionary<string, object?> spec,
        IReadOnlyList<WlrRandr.Output> snapshot,
        out string? error)
    {
        var list = ResolveAll(spec, snapshot, out error, out var warnings);
        if (list.Count == 0)
        {
            if (error is null && warnings.Count > 0) error = warnings[0];
            return null;
        }
        return list[0];
    }

    /// <summary>
    /// Resolve a spec to zero or more <see cref="OutputChange"/>s. Supports glob (<c>*</c>, <c>?</c>) in
    /// the <c>name</c> matcher; <c>edid</c> is always exact.
    /// </summary>
    /// <remarks>
    /// <para><paramref name="error"/> is set only when the spec is structurally invalid OR matched zero
    /// outputs. <paramref name="warnings"/> collects per-output skip reasons under a wildcard expansion
    /// (e.g., mode not advertised on one of N monitors) so the caller can log them without aborting.</para>
    /// </remarks>
    public static List<OutputChange> ResolveAll(
        Dictionary<string, object?> spec,
        IReadOnlyList<WlrRandr.Output> snapshot,
        out string? error,
        out List<string> warnings)
    {
        error = null;
        warnings = new List<string>();
        var result = new List<OutputChange>();

        // Determine matched outputs.
        var matches = new List<WlrRandr.Output>();
        bool isWildcard = false;
        var edid = spec.GetString("edid");
        if (!string.IsNullOrEmpty(edid))
        {
            // EDID is always exact — hashes don't glob meaningfully.
            foreach (var o in snapshot)
                if (string.Equals(o.EdidSha256, edid, StringComparison.OrdinalIgnoreCase))
                { matches.Add(o); break; }
            if (matches.Count == 0)
            {
                error = $"unknown edid '{edid}'";
                return result;
            }
        }
        else
        {
            var name = spec.GetString("name");
            if (string.IsNullOrEmpty(name))
            {
                error = "missing 'name' or 'edid'";
                return result;
            }
            if (IsGlob(name!))
            {
                isWildcard = true;
                var re = GlobToRegex(name!);
                foreach (var o in snapshot)
                    if (re.IsMatch(o.Name)) matches.Add(o);
                if (matches.Count == 0)
                {
                    error = $"no outputs match '{name}'";
                    return result;
                }
            }
            else
            {
                foreach (var o in snapshot)
                    if (string.Equals(o.Name, name, StringComparison.Ordinal))
                    { matches.Add(o); break; }
                if (matches.Count == 0)
                {
                    error = $"unknown output '{name}'";
                    return result;
                }
            }
        }

        // Reject position with wildcard expansion (v1: no auto-tile).
        bool hasPosition = spec.TryGetValue("position", out var _posCheck) && _posCheck is List<object?>;
        if (isWildcard && hasPosition)
        {
            error = "position not allowed with wildcard name";
            return result;
        }

        // Per-output validation.
        foreach (var match in matches)
        {
            var ch = BuildChange(spec, match, out var perErr);
            if (ch is null)
            {
                if (isWildcard) warnings.Add($"{match.Name}: {perErr}");
                else error = perErr;
            }
            else
            {
                result.Add(ch);
            }
        }

        // If we matched but produced nothing, surface an aggregated error.
        if (result.Count == 0 && error is null)
            error = warnings.Count > 0
                ? $"all matched outputs failed validation: {string.Join("; ", warnings)}"
                : "no outputs produced";

        return result;
    }

    private static OutputChange? BuildChange(
        Dictionary<string, object?> spec, WlrRandr.Output match, out string? error)
    {
        error = null;
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

    private static bool IsGlob(string s)
        => s.Contains('*', StringComparison.Ordinal) || s.Contains('?', StringComparison.Ordinal);

    private static Regex GlobToRegex(string glob)
    {
        var sb = new StringBuilder("^");
        foreach (var c in glob)
        {
            sb.Append(c switch
            {
                '*' => ".*",
                '?' => ".",
                _ => Regex.Escape(c.ToString()),
            });
        }
        sb.Append('$');
        return new Regex(sb.ToString(),
            RegexOptions.CultureInvariant | RegexOptions.Compiled);
    }

    /// <summary>
    /// Merge a list of resolved changes by output name. Later entries override per-field values from
    /// earlier ones (only non-null fields are copied). Use this to combine wildcard specs with specific
    /// overrides: list wildcards first, specifics after.
    /// </summary>
    public static List<OutputChange> Merge(IEnumerable<OutputChange> changes)
    {
        var byName = new Dictionary<string, OutputChange>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var c in changes)
        {
            if (string.IsNullOrEmpty(c.Name)) continue;
            if (!byName.TryGetValue(c.Name, out var acc))
            {
                acc = new OutputChange { Name = c.Name };
                byName[c.Name] = acc;
                order.Add(c.Name);
            }
            if (c.Enabled is not null) acc.Enabled = c.Enabled;
            if (c.Mode is not null) acc.Mode = c.Mode;
            if (c.Scale is not null) acc.Scale = c.Scale;
            if (c.Transform is not null) acc.Transform = c.Transform;
            if (c.Position is not null) acc.Position = c.Position;
            if (c.AdaptiveSync is not null) acc.AdaptiveSync = c.AdaptiveSync;
        }
        var merged = new List<OutputChange>(order.Count);
        foreach (var n in order) merged.Add(byName[n]);
        return merged;
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
