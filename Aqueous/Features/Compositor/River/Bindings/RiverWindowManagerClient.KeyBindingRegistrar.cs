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
    // Dedupe sets keyed by (seat, keysym, modifiers, action-name) so the same
    // (seat, chord, action) triple isn't registered twice when SeatInformation
    // fires more than once or a second seat appears. Stored on the instance
    // because the dedupe must persist across multiple RegisterAllBindings
    // calls for different seats.
    private readonly HashSet<(IntPtr seat, uint keysym, uint mods, KeyBindingAction action)> _registeredBuiltins = new();
    private readonly HashSet<(IntPtr seat, uint keysym, uint mods, string verb)> _registeredCustoms = new();
    // Dedupe for pointer bindings per seat — second seat must not double-register.
    private readonly HashSet<IntPtr> _seatsWithPointerBindings = new();

    // action_name -> KeyBindingAction (for built-in chord overrides via [keybinds]).
    // PR 9.12 §2.7: the table moved to top-level Aqueous.Features.Bindings.KeyBindingActionTable;
    // this field is preserved as an alias so partial/test code that referenced
    // RiverWindowManagerClient.BuiltinActionMap keeps compiling unchanged.
    internal static readonly IReadOnlyDictionary<string, KeyBindingAction> BuiltinActionMap =
        Aqueous.Features.Bindings.KeyBindingActionTable.Map;

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
        if (!_registeredBuiltins.Add((seatProxy, keysym, modifiers, action)))
        {
            return; // already registered for this seat
        }
        // river_xkb_bindings_v1::get_xkb_binding opcode=1
        // args: seat(o), id(new_id), keysym(u), modifiers(u)
        // Bind the child proxy at the parent's advertised version (not a hardcoded literal),
        // otherwise a future river bump asserts inside libwayland on first event dispatch.
        uint childVersion = _xkbBindingsVersion == 0 ? 1u : _xkbBindingsVersion;
        IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
            _xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, childVersion, 0,
            seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
        if (binding == IntPtr.Zero)
        {
            _registeredBuiltins.Remove((seatProxy, keysym, modifiers, action));
            return;
        }

        _keyBindings[binding] = action;
        TrackProxyInterface(binding, "river_xkb_binding_v1");
        WaylandInterop.wl_proxy_add_dispatcher(
            binding,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
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

        if (!_registeredCustoms.Add((seatProxy, keysym, modifiers, action)))
        {
            return;
        }
        uint childVersion = _xkbBindingsVersion == 0 ? 1u : _xkbBindingsVersion;
        IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
            _xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, childVersion, 0,
            seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
        if (binding == IntPtr.Zero)
        {
            _registeredCustoms.Remove((seatProxy, keysym, modifiers, action));
            return;
        }

        _keyBindings[binding] = KeyBindingAction.Custom;
        _customBindingActions[binding] = action;
        TrackProxyInterface(binding, "river_xkb_binding_v1");
        WaylandInterop.wl_proxy_add_dispatcher(
            binding,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
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
            // Step 1 diagnostic: silent drops here were the original
            // "keychord stops firing after second window" symptom. Log so the
            // class of regression is visible in the next bug report.
            Log($"key binding miss proxy=0x{proxy.ToString("x")} opcode={opcode}");
            return;
        }

        Log($"key binding pressed: {action}");
        if (action == KeyBindingAction.Custom)
        {
            if (_customBindingActions.TryGetValue(proxy, out var verb))
            {
                // PR 9.9: dispatch through the lifted top-level service
                // (was the deleted private RunCustomAction partial method).
                _customActionRunner.Run(verb);
            }

            return;
        }

        // PR 9.9: dispatch through the lifted top-level service (was the
        // deleted private HandleKeyBindingAction partial method).
        _keyBindingRouter.Handle(action);
    }
}
