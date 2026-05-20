using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Bindings;

/// <summary>
/// PR 9.12 §2.13 lift of the
/// <c>RiverWindowManagerClient.KeyBindingRegistrar.cs</c> partial into a
/// top-level service. Owns the per-seat chord declaration loop
/// (<see cref="RegisterAllBindings"/>), the two per-binding declare
/// helpers (built-in + custom), and the per-key event dispatcher
/// (<see cref="HandleKeyBindingEvent"/>). The god-class
/// <c>OnKeyBindingEvent</c> / <c>RegisterAllBindings</c> / dedupe
/// sets are gone; the god class now delegates its two pass-through
/// accessors (<c>RegisterAllBindingsForwarding</c>,
/// <c>IsBindingRegisteredForwarding</c>) and the
/// <c>HandleKeyBindingEvent</c> bridge straight to this class.
///
/// <para>
/// Construction still takes a <see cref="RiverWindowManagerClient"/>
/// reference because the registrar reads/writes god-class state that
/// has not yet been lifted into its own singletons:
/// <c>_xkbBindings</c> + version, the per-binding <c>_keyBindings</c>
/// dict (also used by the diagnostic forwarder
/// <c>IsBindingRegisteredForwarding</c>), the
/// <c>_customBindingActions</c> dict, the GCHandle that backs the
/// native dispatcher's user-data pointer, the active
/// <see cref="LayoutConfig"/>, and the two binding-trio routers. Each
/// of those is reached through a small set of <c>internal</c>
/// accessors on the god class (<c>XkbBindings</c>,
/// <c>XkbBindingsVersion</c>, <c>KeyBindings</c>,
/// <c>CustomBindingActions</c>, <c>SelfHandlePtr</c>,
/// <c>LayoutConfigForRegistrar</c>, <c>KeyBindingRouter</c>,
/// <c>CustomActionRunner</c>, <c>TrackProxyInterface</c>). Those
/// accessors retire together with the god class in the final
/// demolition step.
/// </para>
/// </summary>
internal sealed unsafe class KeyBindingRegistrar : IKeyBindingRegistrar
{
    // Dedupe sets keyed by (seat, keysym, modifiers, action) so the
    // same (seat, chord, action) triple isn't registered twice when
    // SeatInformation fires more than once or a second seat appears.
    private readonly HashSet<(IntPtr seat, uint keysym, uint mods, KeyBindingAction action)> _registeredBuiltins = new();
    private readonly HashSet<(IntPtr seat, uint keysym, uint mods, string verb)> _registeredCustoms = new();

    // action_name -> KeyBindingAction (for built-in chord overrides via [keybinds]).
    // Mirrors the prior RiverWindowManagerClient.BuiltinActionMap alias;
    // kept as a thin re-export of the top-level table so any external
    // references through this class still compile.
    internal static readonly IReadOnlyDictionary<string, KeyBindingAction> BuiltinActionMap =
        KeyBindingActionTable.Map;

    // PR 9.12 §2.13 Step 4 — cut off RiverWindowManagerClient.
    // All god-class accessors previously read through `_river` are now
    // injected as fine-grained DI singletons. RiverLog replaces the
    // god-class static Log forwarder.
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly KeyBindingsRegistry _bindings;
    private readonly LayoutController _layoutController;
    private readonly IKeyBindingRouter _router;
    private readonly ICustomActionRunner _customRunner;

    public KeyBindingRegistrar(
        WaylandBindSiteState bindSiteState,
        KeyBindingsRegistry bindings,
        LayoutController layoutController,
        IKeyBindingRouter router,
        ICustomActionRunner customRunner)
    {
        _bindSiteState    = bindSiteState    ?? throw new ArgumentNullException(nameof(bindSiteState));
        _bindings         = bindings         ?? throw new ArgumentNullException(nameof(bindings));
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _router           = router           ?? throw new ArgumentNullException(nameof(router));
        _customRunner     = customRunner     ?? throw new ArgumentNullException(nameof(customRunner));
    }

    public bool IsRegistered(IntPtr bindingProxy) => _bindings.KeyBindings.ContainsKey(bindingProxy);

    /// <summary>
    /// Register every keybind defined by the active <c>LayoutConfig.Keybinds</c>
    /// (built-in actions with config-overridable chords + custom chords with
    /// free-form action verbs). Falls back to the default chord table for
    /// any built-in not explicitly listed in the config.
    /// </summary>
    public void RegisterAllBindings(IntPtr seatProxy)
    {
        var kb = _layoutController.Config.Keybinds;
        foreach (var (actionName, builtin) in BuiltinActionMap)
        {
            foreach (var chordStr in kb.ChordsFor(actionName))
            {
                var parsed = KeyChord.Parse(chordStr);
                if (parsed is null)
                {
                    RiverLog.Write($"keybind: invalid chord '{chordStr}' for action '{actionName}', ignored");
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
                RiverLog.Write($"keybind: invalid custom chord '{chordStr}', ignored");
                continue;
            }

            RegisterCustomKeyBinding(seatProxy, parsed.Value.Keysym, parsed.Value.Modifiers, verb);
        }
    }

    private void RegisterKeyBinding(IntPtr seatProxy, uint keysym, uint modifiers, KeyBindingAction action)
    {
        var xkbBindings = _bindSiteState.XkbBindings;
        if (xkbBindings == IntPtr.Zero)
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
        var xkbVersion = _bindSiteState.XkbBindingsVersion;
        uint childVersion = xkbVersion == 0 ? 1u : xkbVersion;
        IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
            xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, childVersion, 0,
            seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
        if (binding == IntPtr.Zero)
        {
            _registeredBuiltins.Remove((seatProxy, keysym, modifiers, action));
            return;
        }

        _bindings.KeyBindings[binding] = action;
        _bindSiteState.TrackProxyInterface(binding, "river_xkb_binding_v1");
        WaylandInterop.wl_proxy_add_dispatcher(
            binding,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
            _bindings.SelfHandlePtr,
            IntPtr.Zero);
        // river_xkb_binding_v1::enable opcode=2
        WaylandInterop.wl_proxy_marshal_flags(binding, 2, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        RiverLog.Write($"registered key binding {action} (keysym 0x{keysym:x}, mods 0x{modifiers:x})");
    }

    private void RegisterCustomKeyBinding(IntPtr seatProxy, uint keysym, uint modifiers, string action)
    {
        var xkbBindings = _bindSiteState.XkbBindings;
        if (xkbBindings == IntPtr.Zero)
        {
            return;
        }

        if (!_registeredCustoms.Add((seatProxy, keysym, modifiers, action)))
        {
            return;
        }
        var xkbVersion = _bindSiteState.XkbBindingsVersion;
        uint childVersion = xkbVersion == 0 ? 1u : xkbVersion;
        IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
            xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, childVersion, 0,
            seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
        if (binding == IntPtr.Zero)
        {
            _registeredCustoms.Remove((seatProxy, keysym, modifiers, action));
            return;
        }

        _bindings.KeyBindings[binding] = KeyBindingAction.Custom;
        _bindings.CustomBindingActions[binding] = action;
        _bindSiteState.TrackProxyInterface(binding, "river_xkb_binding_v1");
        WaylandInterop.wl_proxy_add_dispatcher(
            binding,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
            _bindings.SelfHandlePtr,
            IntPtr.Zero);
        WaylandInterop.wl_proxy_marshal_flags(binding, 2, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        RiverLog.Write($"registered custom key binding '{action}' (keysym 0x{keysym:x}, mods 0x{modifiers:x})");
    }

    /// <summary>
    /// Per-key event entry point. Invoked by the god-class
    /// <c>HandleKeyBindingEvent</c> bridge (which is in turn called by
    /// <c>KeyBindingEventHandler</c>). Behaviour byte-for-byte
    /// equivalent to the prior god-class <c>OnKeyBindingEvent</c>.
    /// </summary>
    internal void HandleKeyBindingEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        // 0: pressed, 1: released
        if (opcode != 0)
        {
            return;
        }

        if (!_bindings.KeyBindings.TryGetValue(proxy, out var action))
        {
            // Step 1 diagnostic: silent drops here were the original
            // "keychord stops firing after second window" symptom. Log so the
            // class of regression is visible in the next bug report.
            RiverLog.Write($"key binding miss proxy=0x{proxy.ToString("x")} opcode={opcode}");
            return;
        }

        RiverLog.Write($"key binding pressed: {action}");
        if (action == KeyBindingAction.Custom)
        {
            if (_bindings.CustomBindingActions.TryGetValue(proxy, out var verb))
            {
                _customRunner.Run(verb);
            }

            return;
        }

        _router.Handle(action);
    }
}
