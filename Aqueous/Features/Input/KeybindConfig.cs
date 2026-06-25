using System;
using System.Collections.Generic;

namespace Aqueous.Features.Input;

/// <summary>
/// Keybind configuration parsed from <c>[keybinds]</c> and <c>[keybinds.custom]</c> sections of
/// <c>wm.toml</c>.
/// <para>
/// <b>Built-ins</b> map a canonical action name (e.g. <c>"focus_left"</c>, <c>"cycle_focus"</c>,
/// <c>"reload_config"</c>) to one or more chord strings. An empty list explicitly unbinds the
/// default chord.
/// </para>
/// <para>
/// <b>Custom</b> maps a chord string directly to an action verb: <c>spawn:&lt;cmd&gt;</c>,
/// <c>set_layout:&lt;id-or-slot&gt;</c>, or <c>builtin:&lt;name&gt;</c>.
/// </para>
/// </summary>
public sealed class KeybindConfig
{
    /// <summary>
    /// Action_name → list of chord strings (empty = unbind).
    /// </summary>
    public Dictionary<string, List<string>> Builtins { get; init; } =
        new(StringComparer.Ordinal);

    /// <summary>
    /// Chord-string → action verb.
    /// </summary>
    public Dictionary<string, string> Custom { get; init; } =
        new(StringComparer.Ordinal);

    /// <summary>
    /// Built-in action names recognised by the WM. Single source of truth.
    /// </summary>
    public static readonly string[] KnownActions =
    {
        "toggle_start_menu",
        "spawn_terminal",
        "close_focused",
        "cycle_focus",
        "focus_left", "focus_right", "focus_up", "focus_down",
        "scroll_viewport_left", "scroll_viewport_right",
        "move_window_left", "move_window_right", "move_window_up", "move_window_down",
        "reload_config",
        "set_layout_primary", "set_layout_secondary",
        "set_layout_tertiary", "set_layout_quaternary",
        "focus_workspace_1","focus_workspace_2","focus_workspace_3","focus_workspace_4","focus_workspace_5",
        "focus_workspace_6","focus_workspace_7","focus_workspace_8","focus_workspace_9",
        "move_to_workspace_1","move_to_workspace_2","move_to_workspace_3","move_to_workspace_4","move_to_workspace_5",
        "move_to_workspace_6","move_to_workspace_7","move_to_workspace_8","move_to_workspace_9",
        "focus_workspace_up","focus_workspace_down","focus_previous_workspace",
        "move_to_workspace_up","move_to_workspace_down",
        "move_workspace_up","move_workspace_down",
        "toggle_fullscreen",
        "toggle_maximize",
        "toggle_floating",
        "toggle_minimize",
        "unminimize_last",
        "toggle_scratchpad",         // default pad
        "toggle_scratchpad_named",   // requires :name argument via custom binding
        "send_to_scratchpad",        // default pad
        "send_to_scratchpad_named",  // requires :name argument via custom binding
        "lock_screen"
    };

    /// <summary>
    /// Compiled-in fallback chords for each built-in action.
    /// </summary>
    public static IReadOnlyDictionary<string, string> Defaults { get; } =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["toggle_start_menu"] = "Super+Space",
            ["spawn_terminal"] = "Super+Return",
            ["close_focused"] = "Super+Q",
            ["cycle_focus"] = "Super+Tab",
            ["focus_left"] = "Super+H",
            ["focus_right"] = "Super+L",
            ["focus_up"] = "Super+K",
            ["focus_down"] = "Super+J",
            ["scroll_viewport_left"] = "Super+Comma",
            ["scroll_viewport_right"] = "Super+Period",
            ["move_window_left"] = "Super+Shift+Left",
            ["move_window_right"] = "Super+Shift+Right",
            ["move_window_up"] = "Super+Shift+Up",
            ["move_window_down"] = "Super+Shift+Down",
            ["reload_config"] = "Super+R",

            // Workspace default chords (niri-style, ext-workspace-v1).
            ["focus_workspace_1"] = "Super+1",
            ["focus_workspace_2"] = "Super+2",
            ["focus_workspace_3"] = "Super+3",
            ["focus_workspace_4"] = "Super+4",
            ["focus_workspace_5"] = "Super+5",
            ["focus_workspace_6"] = "Super+6",
            ["focus_workspace_7"] = "Super+7",
            ["focus_workspace_8"] = "Super+8",
            ["focus_workspace_9"] = "Super+9",
            ["move_to_workspace_1"] = "Super+Shift+1",
            ["move_to_workspace_2"] = "Super+Shift+2",
            ["move_to_workspace_3"] = "Super+Shift+3",
            ["move_to_workspace_4"] = "Super+Shift+4",
            ["move_to_workspace_5"] = "Super+Shift+5",
            ["move_to_workspace_6"] = "Super+Shift+6",
            ["move_to_workspace_7"] = "Super+Shift+7",
            ["move_to_workspace_8"] = "Super+Shift+8",
            ["move_to_workspace_9"] = "Super+Shift+9",
            ["focus_workspace_up"] = "Super+Bracketleft",
            ["focus_workspace_down"] = "Super+Bracketright",
            ["focus_previous_workspace"] = "Super+grave",
            ["move_to_workspace_up"] = "Super+Shift+Bracketleft",
            ["move_to_workspace_down"] = "Super+Shift+Bracketright",
            ["toggle_fullscreen"] = "Super+Shift+F",
            ["toggle_maximize"] = "Super+Shift+M",
            ["toggle_floating"] = "Super+Shift+Space",
            ["toggle_minimize"] = "Super+N",
            ["unminimize_last"] = "Super+Shift+N",
            ["toggle_scratchpad"] = "Super+Backslash",
            ["send_to_scratchpad"] = "Super+Shift+Backslash",
            ["lock_screen"] = "Super+Ctrl+L"
            // Toggle_scratchpad_named / send_to_scratchpad_named: opt-in via [keybinds.custom] only.
        };

    /// <summary>
    /// Returns the effective chord list for <paramref name="action"/>: the user override if present
    /// (empty list = unbind), else the compiled-in default (or empty list if no default exists).
    /// </summary>
    public IReadOnlyList<string> ChordsFor(string action)
    {
        if (Builtins.TryGetValue(action, out var list))
        {
            return list;
        }

        if (Defaults.TryGetValue(action, out var d))
        {
            return new[] { d };
        }

        return Array.Empty<string>();
    }
}
