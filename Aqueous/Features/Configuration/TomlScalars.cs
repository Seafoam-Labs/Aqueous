using System.Globalization;

namespace Aqueous.Features.Configuration;

/// <summary>
/// Shared, behaviour-preserving scalar helpers for the project's permissive TOML-subset parsers
/// (<see cref="Aqueous.Features.Layout.LayoutConfigLoader"/> and
/// <see cref="Aqueous.Features.Input.InputConfigParser"/>). Lifted verbatim from the original
/// loader so both parsers stay byte-for-byte compatible.
/// </summary>
internal static class TomlScalars
{
    /// <summary>Strips a single layer of matching single/double quotes, if present.</summary>
    public static string StripQuotes(string s)
    {
        if (s.Length >= 2 && (s[0] == '"' && s[^1] == '"' || s[0] == '\'' && s[^1] == '\''))
        {
            return s.Substring(1, s.Length - 2);
        }

        return s;
    }

    /// <summary>Index of the first <paramref name="c"/> that is not inside a double-quoted span.</summary>
    public static int IndexOfUnquoted(string s, char c)
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

    public static int ParseInt(string s, int fallback) =>
        int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    public static double ParseDouble(string s, double fallback) =>
        double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    public static bool ParseBool(string s, bool fallback) => s.Trim().ToLowerInvariant() switch
    {
        "true" or "yes" or "on" or "1" => true,
        "false" or "no" or "off" or "0" => false,
        _ => fallback,
    };

    public static uint ParseColor(string s, uint fallback)
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
