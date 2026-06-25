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
            ["move_window_left"] = KeyBindingAction.MoveWindowLeft,
            ["move_window_right"] = KeyBindingAction.MoveWindowRight,
            ["move_window_up"] = KeyBindingAction.MoveWindowUp,
            ["move_window_down"] = KeyBindingAction.MoveWindowDown,
            ["reload_config"] = KeyBindingAction.ReloadConfig,
            ["reload_rules"] = KeyBindingAction.ReloadRules,
            ["set_layout_primary"] = KeyBindingAction.SetLayoutPrimary,
            ["set_layout_secondary"] = KeyBindingAction.SetLayoutSecondary,
            ["set_layout_tertiary"] = KeyBindingAction.SetLayoutTertiary,
            ["set_layout_quaternary"] = KeyBindingAction.SetLayoutQuaternary,
            ["focus_workspace_1"] = KeyBindingAction.FocusWorkspace1,
            ["focus_workspace_2"] = KeyBindingAction.FocusWorkspace2,
            ["focus_workspace_3"] = KeyBindingAction.FocusWorkspace3,
            ["focus_workspace_4"] = KeyBindingAction.FocusWorkspace4,
            ["focus_workspace_5"] = KeyBindingAction.FocusWorkspace5,
            ["focus_workspace_6"] = KeyBindingAction.FocusWorkspace6,
            ["focus_workspace_7"] = KeyBindingAction.FocusWorkspace7,
            ["focus_workspace_8"] = KeyBindingAction.FocusWorkspace8,
            ["focus_workspace_9"] = KeyBindingAction.FocusWorkspace9,
            ["move_to_workspace_1"] = KeyBindingAction.MoveToWorkspace1,
            ["move_to_workspace_2"] = KeyBindingAction.MoveToWorkspace2,
            ["move_to_workspace_3"] = KeyBindingAction.MoveToWorkspace3,
            ["move_to_workspace_4"] = KeyBindingAction.MoveToWorkspace4,
            ["move_to_workspace_5"] = KeyBindingAction.MoveToWorkspace5,
            ["move_to_workspace_6"] = KeyBindingAction.MoveToWorkspace6,
            ["move_to_workspace_7"] = KeyBindingAction.MoveToWorkspace7,
            ["move_to_workspace_8"] = KeyBindingAction.MoveToWorkspace8,
            ["move_to_workspace_9"] = KeyBindingAction.MoveToWorkspace9,
            ["focus_workspace_up"] = KeyBindingAction.FocusWorkspaceUp,
            ["focus_workspace_down"] = KeyBindingAction.FocusWorkspaceDown,
            ["focus_previous_workspace"] = KeyBindingAction.FocusPreviousWorkspace,
            ["move_to_workspace_up"] = KeyBindingAction.MoveToWorkspaceUp,
            ["move_to_workspace_down"] = KeyBindingAction.MoveToWorkspaceDown,
            ["move_workspace_up"] = KeyBindingAction.MoveWorkspaceUp,
            ["move_workspace_down"] = KeyBindingAction.MoveWorkspaceDown,
            ["focus_output_left"] = KeyBindingAction.FocusOutputLeft,
            ["focus_output_right"] = KeyBindingAction.FocusOutputRight,
            ["move_to_output_left"] = KeyBindingAction.MoveToOutputLeft,
            ["move_to_output_right"] = KeyBindingAction.MoveToOutputRight,
            ["toggle_fullscreen"] = KeyBindingAction.ToggleFullscreen,
            ["toggle_maximize"] = KeyBindingAction.ToggleMaximize,
            ["toggle_floating"] = KeyBindingAction.ToggleFloating,
            ["toggle_minimize"] = KeyBindingAction.ToggleMinimize,
            ["unminimize_last"] = KeyBindingAction.UnminimizeLast,
            ["toggle_scratchpad"] = KeyBindingAction.ToggleScratchpad,
            ["send_to_scratchpad"] = KeyBindingAction.SendToScratchpad,
            ["lock_screen"] = KeyBindingAction.LockScreen,
            ["untrap_pointer"] = KeyBindingAction.UntrapPointer
        };
}
