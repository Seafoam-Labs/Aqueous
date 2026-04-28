using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Features.Input;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Key-binding registrar partial of <see cref="RiverWindowManagerClient"/>:
/// owns the <see cref="BuiltinActionMap"/> (action-name → enum), the
/// per-seat registration entry points (<c>RegisterAllBindings</c>,
/// <c>RegisterKeyBinding</c>, <c>RegisterCustomKeyBinding</c>), and the
/// <c>OnKeyBindingEvent</c> dispatcher entry point. Routing of the resolved
/// <see cref="KeyBindingAction"/> lives in the sibling
/// <c>RiverWindowManagerClient.KeyBindingActionRouter.cs</c>; free-form
/// custom verbs (<c>spawn:</c>/<c>set_layout:</c>/<c>builtin:</c>) live in
/// <c>RiverWindowManagerClient.CustomActionRunner.cs</c>.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    // action_name -> KeyBindingAction (for built-in chord overrides via [keybinds]).
    private static readonly Dictionary<string, KeyBindingAction> BuiltinActionMap =
        new(StringComparer.Ordinal)
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
            ["set_layout_primary"] = KeyBindingAction.SetLayoutPrimary,
            ["set_layout_secondary"] = KeyBindingAction.SetLayoutSecondary,
            ["set_layout_tertiary"] = KeyBindingAction.SetLayoutTertiary,
            ["set_layout_quaternary"] = KeyBindingAction.SetLayoutQuaternary,
            // Phase B1c — Tag actions exposed to [keybinds] config.
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
            // Phase B1e — Window state ops (Pass B integration).
            ["toggle_fullscreen"] = KeyBindingAction.ToggleFullscreen,
            ["toggle_maximize"] = KeyBindingAction.ToggleMaximize,
            ["toggle_floating"] = KeyBindingAction.ToggleFloating,
            ["toggle_minimize"] = KeyBindingAction.ToggleMinimize,
            ["unminimize_last"] = KeyBindingAction.UnminimizeLast,
            ["toggle_scratchpad"] = KeyBindingAction.ToggleScratchpad,
            ["send_to_scratchpad"] = KeyBindingAction.SendToScratchpad,
            // toggle_scratchpad_named / send_to_scratchpad_named are not
            // mapped here: they require a :arg suffix and are reachable
            // only via [keybinds.custom] -> RunCustomAction's builtin:
            // branch, which parses one trailing :name segment.
        };

    /// <summary>
    /// Register every keybind defined by the active <see cref="LayoutConfig.Keybinds"/>
    /// (built-in actions with config-overridable chords + custom chords with
    /// free-form action verbs). Falls back to <see cref="KeybindConfig.Defaults"/>
    /// for any built-in not explicitly listed in the config.
    /// </summary>
    private void RegisterAllBindings(IntPtr seatProxy)
    {
        var kb = _layoutConfig.Keybinds;
        foreach (var (actionName, builtin) in BuiltinActionMap)
        {
            foreach (var chordStr in kb.ChordsFor(actionName))
            {
                var parsed = KeyChord.Parse(chordStr);
                if (parsed is null)
                {
                    Log($"keybind: invalid chord '{chordStr}' for action '{actionName}', ignored");
                    continue;
                }

                RegisterKeyBinding(seatProxy, parsed.Value.Keysym, parsed.Value.Modifiers, builtin);
            }
        }

        // Custom chord -> action verb (spawn:/set_layout:/builtin:).
        foreach (var (chordStr, verb) in kb.Custom)
        {
            var parsed = KeyChord.Parse(chordStr);
            if (parsed is null)
            {
                Log($"keybind: invalid custom chord '{chordStr}', ignored");
                continue;
            }

            RegisterCustomKeyBinding(seatProxy, parsed.Value.Keysym, parsed.Value.Modifiers, verb);
        }
    }

    private void RegisterKeyBinding(IntPtr seatProxy, uint keysym, uint modifiers, KeyBindingAction action)
    {
        if (_xkbBindings == IntPtr.Zero)
        {
            return;
        }
        // river_xkb_bindings_v1::get_xkb_binding opcode=1
        // args: seat(o), id(new_id), keysym(u), modifiers(u)
        IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
            _xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, 3, 0,
            seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
        if (binding == IntPtr.Zero)
        {
            return;
        }

        _keyBindings[binding] = action;
        WaylandInterop.wl_proxy_add_dispatcher(
            binding,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
            GCHandle.ToIntPtr(_selfHandle),
            IntPtr.Zero);
        // river_xkb_binding_v1::enable opcode=2
        WaylandInterop.wl_proxy_marshal_flags(binding, 2, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        Log($"registered key binding {action} (keysym 0x{keysym:x}, mods 0x{modifiers:x})");
    }

    private void RegisterCustomKeyBinding(IntPtr seatProxy, uint keysym, uint modifiers, string action)
    {
        if (_xkbBindings == IntPtr.Zero)
        {
            return;
        }

        IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
            _xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, 3, 0,
            seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
        if (binding == IntPtr.Zero)
        {
            return;
        }

        _keyBindings[binding] = KeyBindingAction.Custom;
        _customBindingActions[binding] = action;
        WaylandInterop.wl_proxy_add_dispatcher(
            binding,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
            GCHandle.ToIntPtr(_selfHandle),
            IntPtr.Zero);
        WaylandInterop.wl_proxy_marshal_flags(binding, 2, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        Log($"registered custom key binding '{action}' (keysym 0x{keysym:x}, mods 0x{modifiers:x})");
    }

    private void OnKeyBindingEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        // 0: pressed, 1: released
        if (opcode != 0)
        {
            return;
        }

        if (!_keyBindings.TryGetValue(proxy, out var action))
        {
            return;
        }

        Log($"key binding pressed: {action}");
        if (action == KeyBindingAction.Custom)
        {
            if (_customBindingActions.TryGetValue(proxy, out var verb))
            {
                RunCustomAction(verb);
            }

            return;
        }

        HandleKeyBindingAction(action);
    }
}
