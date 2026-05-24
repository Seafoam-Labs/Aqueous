using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Bindings;

/// <summary>
/// Top-level home for the built-in action-name → enum table used by both <see
/// cref="KeyBindingRegistrar"/> (to translate <c>[keybinds]</c> chord overrides) and the lifted
/// <see cref="CustomActionRunner"/> (to resolve <c>builtin:&lt;name&gt;</c> verbs from
/// <c>[keybinds.custom]</c>). The previous home was the
/// <c>RiverWindowManagerClient.KeyBindingRegistrar</c> partial as an <c>internal static
/// readonly</c> field; it is here to keep the contract for both consumers byte-for-byte identical.
/// </summary>
internal static class KeyBindingActionTable
{
    public static readonly IReadOnlyDictionary<string, KeyBindingAction> Map =
        new Dictionary<string, KeyBindingAction>(StringComparer.Ordinal)
        {
            ["toggle_start_menu"] = KeyBindingAction.ToggleStartMenu,
            ["spawn_terminal"] = KeyBindingAction.SpawnTerminal,
            ["close_focused"] = KeyBindingAction.CloseFocused,
            ["cycle_focus"] = KeyBindingAction.CycleFocus,
            ["focus_left"] = KeyBindingAction.FocusLeft,
            ["focus_right"] = KeyBindingAction.FocusRight,
            ["focus_up"] = KeyBindingAction.FocusUp,
            ["focus_down"] = KeyBindingAction.FocusDown,
            ["scroll_viewport_left"] = KeyBindingAction.ScrollViewportLeft,
            ["scroll_viewport_right"] = KeyBindingAction.ScrollViewportRight,
            ["move_column_left"] = KeyBindingAction.MoveColumnLeft,
            ["move_column_right"] = KeyBindingAction.MoveColumnRight,
            ["reload_config"] = KeyBindingAction.ReloadConfig,
            ["reload_rules"] = KeyBindingAction.ReloadRules,
            ["set_layout_primary"] = KeyBindingAction.SetLayoutPrimary,
            ["set_layout_secondary"] = KeyBindingAction.SetLayoutSecondary,
            ["set_layout_tertiary"] = KeyBindingAction.SetLayoutTertiary,
            ["set_layout_quaternary"] = KeyBindingAction.SetLayoutQuaternary,
            ["view_tag_1"] = KeyBindingAction.ViewTag1,
            ["view_tag_2"] = KeyBindingAction.ViewTag2,
            ["view_tag_3"] = KeyBindingAction.ViewTag3,
            ["view_tag_4"] = KeyBindingAction.ViewTag4,
            ["view_tag_5"] = KeyBindingAction.ViewTag5,
            ["view_tag_6"] = KeyBindingAction.ViewTag6,
            ["view_tag_7"] = KeyBindingAction.ViewTag7,
            ["view_tag_8"] = KeyBindingAction.ViewTag8,
            ["view_tag_9"] = KeyBindingAction.ViewTag9,
            ["view_tag_all"] = KeyBindingAction.ViewTagAll,
            ["send_tag_1"] = KeyBindingAction.SendTag1,
            ["send_tag_2"] = KeyBindingAction.SendTag2,
            ["send_tag_3"] = KeyBindingAction.SendTag3,
            ["send_tag_4"] = KeyBindingAction.SendTag4,
            ["send_tag_5"] = KeyBindingAction.SendTag5,
            ["send_tag_6"] = KeyBindingAction.SendTag6,
            ["send_tag_7"] = KeyBindingAction.SendTag7,
            ["send_tag_8"] = KeyBindingAction.SendTag8,
            ["send_tag_9"] = KeyBindingAction.SendTag9,
            ["send_tag_all"] = KeyBindingAction.SendTagAll,
            ["toggle_view_tag_1"] = KeyBindingAction.ToggleViewTag1,
            ["toggle_view_tag_2"] = KeyBindingAction.ToggleViewTag2,
            ["toggle_view_tag_3"] = KeyBindingAction.ToggleViewTag3,
            ["toggle_view_tag_4"] = KeyBindingAction.ToggleViewTag4,
            ["toggle_view_tag_5"] = KeyBindingAction.ToggleViewTag5,
            ["toggle_view_tag_6"] = KeyBindingAction.ToggleViewTag6,
            ["toggle_view_tag_7"] = KeyBindingAction.ToggleViewTag7,
            ["toggle_view_tag_8"] = KeyBindingAction.ToggleViewTag8,
            ["toggle_view_tag_9"] = KeyBindingAction.ToggleViewTag9,
            ["toggle_window_tag_1"] = KeyBindingAction.ToggleWindowTag1,
            ["toggle_window_tag_2"] = KeyBindingAction.ToggleWindowTag2,
            ["toggle_window_tag_3"] = KeyBindingAction.ToggleWindowTag3,
            ["toggle_window_tag_4"] = KeyBindingAction.ToggleWindowTag4,
            ["toggle_window_tag_5"] = KeyBindingAction.ToggleWindowTag5,
            ["toggle_window_tag_6"] = KeyBindingAction.ToggleWindowTag6,
            ["toggle_window_tag_7"] = KeyBindingAction.ToggleWindowTag7,
            ["toggle_window_tag_8"] = KeyBindingAction.ToggleWindowTag8,
            ["toggle_window_tag_9"] = KeyBindingAction.ToggleWindowTag9,
            ["swap_last_tagset"] = KeyBindingAction.SwapLastTagset,
            ["toggle_fullscreen"] = KeyBindingAction.ToggleFullscreen,
            ["toggle_maximize"] = KeyBindingAction.ToggleMaximize,
            ["toggle_floating"] = KeyBindingAction.ToggleFloating,
            ["toggle_minimize"] = KeyBindingAction.ToggleMinimize,
            ["unminimize_last"] = KeyBindingAction.UnminimizeLast,
            ["toggle_scratchpad"] = KeyBindingAction.ToggleScratchpad,
            ["send_to_scratchpad"] = KeyBindingAction.SendToScratchpad,
            ["lock_screen"] = KeyBindingAction.LockScreen,
        };
}
