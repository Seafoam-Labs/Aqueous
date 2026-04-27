using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Input;

/// <summary>
/// Parsed representation of a textual key chord (e.g. <c>"Super+Shift+H"</c>)
/// into the river_xkb_bindings_v1 modifier bitmask + XKB keysym pair used
/// by <c>get_xkb_binding</c>.
///
/// Modifier tokens (case-insensitive): <c>Super</c>/<c>Mod4</c>/<c>Logo</c>,
/// <c>Ctrl</c>/<c>Control</c>, <c>Alt</c>/<c>Mod1</c>, <c>Shift</c>.
/// Key tokens: single ASCII character, named keys (<c>Return</c>, <c>Space</c>,
/// <c>Tab</c>, <c>Comma</c>, <c>Period</c>, <c>Escape</c>, <c>BackSpace</c>,
/// <c>Left</c>/<c>Right</c>/<c>Up</c>/<c>Down</c>), or <c>F1</c>–<c>F24</c>.
/// </summary>
public readonly record struct KeyChord(uint Modifiers, uint Keysym)
{
    /// <summary>
    /// Parses a chord string like <c>"Super+H"</c>, <c>"Ctrl+Alt+F1"</c>,
    /// <c>"Super+Shift+L"</c>. Returns <c>null</c> on malformed input.
    /// </summary>
    public static KeyChord? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var parts = text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return null;

        uint mods = 0;
        uint? keysym = null;
        foreach (var raw in parts)
        {
            var tok = raw.ToLowerInvariant();
            switch (tok)
            {
                case "super": case "mod4": case "logo": case "win":
                    // Honour AQUEOUS_MOD: "Super" in chords means the configured primary modifier.
                    mods |= Mods.PrimaryMask; continue;
                case "alt": case "mod1":
                    // If the primary mod is Alt, "Alt" collapses onto the same bit; otherwise it's literal Alt.
                    mods |= Mods.Primary == Mods.Kind.Alt ? Mods.PrimaryMask : Mods.ModAlt; continue;
                case "shift":
                    mods |= Mods.ModShift; continue;
                case "ctrl": case "control":
                    mods |= 4u; continue;
            }
            // Key token (only one allowed).
            if (keysym.HasValue) return null;
            var k = ResolveKeysym(raw);
            if (k is null) return null;
            keysym = k;
        }
        if (keysym is null) return null;
        return new KeyChord(mods, keysym.Value);
    }

    private static readonly Dictionary<string, uint> NamedKeys =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["return"]    = 0xff0d,
            ["enter"]     = 0xff0d,
            ["space"]     = 0x0020,
            ["tab"]       = 0xff09,
            ["escape"]    = 0xff1b,
            ["esc"]       = 0xff1b,
            ["backspace"] = 0xff08,
            ["delete"]    = 0xffff,
            ["left"]      = 0xff51,
            ["up"]        = 0xff52,
            ["right"]     = 0xff53,
            ["down"]      = 0xff54,
            ["home"]      = 0xff50,
            ["end"]       = 0xff57,
            ["pageup"]    = 0xff55,
            ["pagedown"]  = 0xff56,
            ["comma"]     = 0x002c,
            ["period"]    = 0x002e,
            ["semicolon"] = 0x003b,
            ["slash"]     = 0x002f,
            ["minus"]     = 0x002d,
            ["equal"]     = 0x003d,
            ["plus"]      = 0x002b,
            ["bracketleft"]  = 0x005b,
            ["bracketright"] = 0x005d,
            ["grave"]     = 0x0060,
            ["apostrophe"] = 0x0027,
            ["backslash"] = 0x005c,
        };

    private static uint? ResolveKeysym(string token)
    {
        if (NamedKeys.TryGetValue(token, out var v)) return v;

        // Function keys F1..F24 → 0xffbe..0xffd5
        if ((token.Length == 2 || token.Length == 3) &&
            (token[0] == 'F' || token[0] == 'f'))
        {
            if (int.TryParse(token.AsSpan(1), out var n) && n >= 1 && n <= 24)
                return (uint)(0xffbe + (n - 1));
        }

        // Single character — fall back to lowercase ASCII codepoint.
        // (xkbcommon's keysym values match Latin-1 codepoints for printable ASCII.)
        if (token.Length == 1)
        {
            char c = token[0];
            if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
            if (c >= 0x20 && c <= 0x7e) return c;
        }
        return null;
    }
}
