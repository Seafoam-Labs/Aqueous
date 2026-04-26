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
        // Phase B1c — Tag actions.
        "view_tag_1","view_tag_2","view_tag_3","view_tag_4","view_tag_5",
        "view_tag_6","view_tag_7","view_tag_8","view_tag_9","view_tag_all",
        "send_tag_1","send_tag_2","send_tag_3","send_tag_4","send_tag_5",
        "send_tag_6","send_tag_7","send_tag_8","send_tag_9","send_tag_all",
        "toggle_view_tag_1","toggle_view_tag_2","toggle_view_tag_3","toggle_view_tag_4","toggle_view_tag_5",
        "toggle_view_tag_6","toggle_view_tag_7","toggle_view_tag_8","toggle_view_tag_9",
        "toggle_window_tag_1","toggle_window_tag_2","toggle_window_tag_3","toggle_window_tag_4","toggle_window_tag_5",
        "toggle_window_tag_6","toggle_window_tag_7","toggle_window_tag_8","toggle_window_tag_9",
        "swap_last_tagset",
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

            // Phase B1c — Tag default chords.
            ["view_tag_1"] = "Super+1", ["view_tag_2"] = "Super+2",
            ["view_tag_3"] = "Super+3", ["view_tag_4"] = "Super+4",
            ["view_tag_5"] = "Super+5", ["view_tag_6"] = "Super+6",
            ["view_tag_7"] = "Super+7", ["view_tag_8"] = "Super+8",
            ["view_tag_9"] = "Super+9", ["view_tag_all"] = "Super+0",
            ["send_tag_1"] = "Super+Shift+1", ["send_tag_2"] = "Super+Shift+2",
            ["send_tag_3"] = "Super+Shift+3", ["send_tag_4"] = "Super+Shift+4",
            ["send_tag_5"] = "Super+Shift+5", ["send_tag_6"] = "Super+Shift+6",
            ["send_tag_7"] = "Super+Shift+7", ["send_tag_8"] = "Super+Shift+8",
            ["send_tag_9"] = "Super+Shift+9", ["send_tag_all"] = "Super+Shift+0",
            ["toggle_view_tag_1"] = "Super+Ctrl+1", ["toggle_view_tag_2"] = "Super+Ctrl+2",
            ["toggle_view_tag_3"] = "Super+Ctrl+3", ["toggle_view_tag_4"] = "Super+Ctrl+4",
            ["toggle_view_tag_5"] = "Super+Ctrl+5", ["toggle_view_tag_6"] = "Super+Ctrl+6",
            ["toggle_view_tag_7"] = "Super+Ctrl+7", ["toggle_view_tag_8"] = "Super+Ctrl+8",
            ["toggle_view_tag_9"] = "Super+Ctrl+9",
            ["toggle_window_tag_1"] = "Super+Shift+Ctrl+1", ["toggle_window_tag_2"] = "Super+Shift+Ctrl+2",
            ["toggle_window_tag_3"] = "Super+Shift+Ctrl+3", ["toggle_window_tag_4"] = "Super+Shift+Ctrl+4",
            ["toggle_window_tag_5"] = "Super+Shift+Ctrl+5", ["toggle_window_tag_6"] = "Super+Shift+Ctrl+6",
            ["toggle_window_tag_7"] = "Super+Shift+Ctrl+7", ["toggle_window_tag_8"] = "Super+Shift+Ctrl+8",
            ["toggle_window_tag_9"] = "Super+Shift+Ctrl+9",
            ["swap_last_tagset"] = "Super+grave",
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
