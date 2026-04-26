using System;
using System.Collections.Generic;

namespace Aqueous.WM.Features.Input;

/// <summary>
/// Keybind configuration parsed from <c>[keybinds]</c> and
/// <c>[keybinds.custom]</c> sections of <c>wm.toml</c>.
///
/// <para><b>Built-ins</b> map a canonical action name (e.g. <c>"focus_left"</c>,
/// <c>"cycle_focus"</c>, <c>"reload_config"</c>) to one or more chord strings.
/// An empty list explicitly unbinds the default chord.</para>
///
/// <para><b>Custom</b> maps a chord string directly to an action verb:
/// <c>spawn:&lt;cmd&gt;</c>, <c>set_layout:&lt;id-or-slot&gt;</c>, or
/// <c>builtin:&lt;name&gt;</c>.</para>
/// </summary>
public sealed class KeybindConfig
{
    /// <summary>action_name → list of chord strings (empty = unbind).</summary>
    public Dictionary<string, List<string>> Builtins { get; init; } =
        new(StringComparer.Ordinal);

    /// <summary>chord-string → action verb.</summary>
    public Dictionary<string, string> Custom { get; init; } =
        new(StringComparer.Ordinal);

    /// <summary>Built-in action names recognised by the WM. Single source of truth.</summary>
    public static readonly string[] KnownActions =
    {
        "toggle_start_menu",
        "spawn_terminal",
        "close_focused",
        "cycle_focus",
        "focus_left", "focus_right", "focus_up", "focus_down",
        "scroll_viewport_left", "scroll_viewport_right",
        "move_column_left", "move_column_right",
        "reload_config",
        "set_layout_primary", "set_layout_secondary",
        "set_layout_tertiary", "set_layout_quaternary",
    };

    /// <summary>Compiled-in fallback chords for each built-in action.</summary>
    public static IReadOnlyDictionary<string, string> Defaults { get; } =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["toggle_start_menu"]     = "Super+Space",
            ["spawn_terminal"]        = "Super+Return",
            ["close_focused"]         = "Super+Q",
            ["cycle_focus"]           = "Super+Tab",
            ["focus_left"]            = "Super+H",
            ["focus_right"]           = "Super+L",
            ["focus_up"]              = "Super+K",
            ["focus_down"]            = "Super+J",
            ["scroll_viewport_left"]  = "Super+Comma",
            ["scroll_viewport_right"] = "Super+Period",
            ["move_column_left"]      = "Super+Shift+H",
            ["move_column_right"]     = "Super+Shift+L",
            // reload_config / set_layout_* are unbound by default — opt-in.
        };

    /// <summary>
    /// Returns the effective chord list for <paramref name="action"/>:
    /// the user override if present (empty list = unbind), else the
    /// compiled-in default (or empty list if no default exists).
    /// </summary>
    public IReadOnlyList<string> ChordsFor(string action)
    {
        if (Builtins.TryGetValue(action, out var list)) return list;
        if (Defaults.TryGetValue(action, out var d))    return new[] { d };
        return Array.Empty<string>();
    }
}
