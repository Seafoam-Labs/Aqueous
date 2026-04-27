using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Phase 2 / Step 6 — key-binding registration, custom-action dispatch and the
/// built-in action table. Replaces the 256-line <c>HandleKeyBindingAction</c>
/// switch with a static <see cref="ActionTable"/> dictionary; a
/// <see cref="KeyBindingAction"/> chord becomes one table entry instead of a
/// new <c>case</c>.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    // Static dispatch table for built-in (parameterless) key-binding actions.
    // Tag actions (which need to derive a bit index from the enum value) are
    // routed by HandleKeyBindingAction below before the table is consulted,
    // because expanding 36 individual cases here would defeat the point.
    private static readonly IReadOnlyDictionary<KeyBindingAction, Action<RiverWindowManagerClient>> ActionTable =
        new Dictionary<KeyBindingAction, Action<RiverWindowManagerClient>>
        {
            [KeyBindingAction.ToggleStartMenu]      = c => c.ToggleStartMenu(),
            [KeyBindingAction.SpawnTerminal]        = c => c.SpawnTerminal(),
            [KeyBindingAction.CloseFocused]         = c => c.CloseFocusedWindow(),
            [KeyBindingAction.CycleFocus]           = c => c.CycleFocus(),
            [KeyBindingAction.FocusLeft]            = c => c.HandleDirectionalFocus(FocusDirection.Left),
            [KeyBindingAction.FocusRight]           = c => c.HandleDirectionalFocus(FocusDirection.Right),
            [KeyBindingAction.FocusUp]              = c => c.HandleDirectionalFocus(FocusDirection.Up),
            [KeyBindingAction.FocusDown]            = c => c.HandleDirectionalFocus(FocusDirection.Down),
            [KeyBindingAction.ScrollViewportLeft]   = c => c.HandleScrollViewport(-1),
            [KeyBindingAction.ScrollViewportRight]  = c => c.HandleScrollViewport(+1),
            [KeyBindingAction.MoveColumnLeft]       = c => c.HandleMoveColumn(FocusDirection.Left),
            [KeyBindingAction.MoveColumnRight]      = c => c.HandleMoveColumn(FocusDirection.Right),
            [KeyBindingAction.ReloadConfig]         = c => c.ReloadConfig(),
            [KeyBindingAction.SetLayoutPrimary]     = c => c.SetLayoutByIdOrSlot("primary"),
            [KeyBindingAction.SetLayoutSecondary]   = c => c.SetLayoutByIdOrSlot("secondary"),
            [KeyBindingAction.SetLayoutTertiary]    = c => c.SetLayoutByIdOrSlot("tertiary"),
            [KeyBindingAction.SetLayoutQuaternary]  = c => c.SetLayoutByIdOrSlot("quaternary"),
            [KeyBindingAction.ViewTagAll]           = c => c._tagController.ViewAll(),
            [KeyBindingAction.SendTagAll]           = c => c._tagController.SendFocusedToTags(TagState.AllTags),
            [KeyBindingAction.SwapLastTagset]       = c => c._tagController.SwapLastTagset(),
            [KeyBindingAction.ToggleFullscreen]     = c => c.OnFocused("toggle_fullscreen", w => c._windowState.ToggleFullscreen(w)),
            [KeyBindingAction.ToggleMaximize]       = c => c.OnFocused("toggle_maximize",   w => c._windowState.ToggleMaximize(w)),
            [KeyBindingAction.ToggleFloating]       = c => c.OnFocused("toggle_floating",   w => c._windowState.ToggleFloating(w)),
            [KeyBindingAction.ToggleMinimize]       = c => c.OnFocused("toggle_minimize",   w => c._windowState.ToggleMinimize(w)),
            [KeyBindingAction.UnminimizeLast]       = c => c._windowState.UnminimizeLast(),
            [KeyBindingAction.ToggleScratchpad]     = c => c._windowState.ToggleScratchpad(ScratchpadRegistry.DefaultPad),
            [KeyBindingAction.SendToScratchpad]     = c => c.OnFocused("send_to_scratchpad", w => c._windowState.SendToScratchpad(w, ScratchpadRegistry.DefaultPad)),
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

    /// <summary>
    /// Dispatch a built-in <see cref="KeyBindingAction"/>. Tag actions
    /// (ViewTag/SendTag/ToggleViewTag/ToggleWindowTag) are routed first
    /// because they derive a bit index from the enum value and would
    /// otherwise need 36 nearly-identical entries in <see cref="ActionTable"/>.
    /// Everything else is a single dictionary lookup.
    /// </summary>
    private void HandleKeyBindingAction(KeyBindingAction action)
    {
        // ViewTag1..9 → bit (action - ViewTag1)
        if (action >= KeyBindingAction.ViewTag1 && action <= KeyBindingAction.ViewTag9)
        {
            _tagController.ViewTags(TagState.Bit(action - KeyBindingAction.ViewTag1));
            return;
        }
        if (action >= KeyBindingAction.SendTag1 && action <= KeyBindingAction.SendTag9)
        {
            _tagController.SendFocusedToTags(TagState.Bit(action - KeyBindingAction.SendTag1));
            return;
        }
        if (action >= KeyBindingAction.ToggleViewTag1 && action <= KeyBindingAction.ToggleViewTag9)
        {
            _tagController.ToggleViewTag(TagState.Bit(action - KeyBindingAction.ToggleViewTag1));
            return;
        }
        if (action >= KeyBindingAction.ToggleWindowTag1 && action <= KeyBindingAction.ToggleWindowTag9)
        {
            _tagController.ToggleWindowTag(TagState.Bit(action - KeyBindingAction.ToggleWindowTag1));
            return;
        }

        if (ActionTable.TryGetValue(action, out var handler))
        {
            handler(this);
        }
    }

    private void InvokeBuiltin(KeyBindingAction action) => HandleKeyBindingAction(action);

    /// <summary>Resolve <paramref name="idOrSlot"/> through slots first, then engines.</summary>
    private void SetLayoutByIdOrSlot(string idOrSlot)
    {
        if (string.IsNullOrEmpty(idOrSlot))
        {
            return;
        }

        string id = idOrSlot;
        if (_layoutConfig.Slots.TryGetValue(idOrSlot, out var resolved))
        {
            id = resolved;
        }

        _layoutController.SetLayout(id);
        ScheduleManage();
    }

    // ---- Built-in action helpers (one tiny method per ActionTable entry) ----

    private void ToggleStartMenu()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "dbus-send",
                Arguments =
                    "--session --type=method_call --dest=org.Aqueous /org/Aqueous org.Aqueous.ToggleStartMenu",
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Exception ex)
        {
            Log("failed to toggle start menu: " + ex.Message);
        }
    }

    private void SpawnTerminal()
    {
        try
        {
            var term = Environment.GetEnvironmentVariable("TERMINAL") ?? "alacritty";
            // Hardened spawn: detach via setsid (so the child survives WM
            // restarts / manage storms), explicitly export the WM's
            // WAYLAND_DISPLAY / XDG_RUNTIME_DIR, and clear DISPLAY to
            // prevent silent Xwayland fallback (an X11 client would never
            // register as a river_window_v1 and therefore never receive
            // focus / input through this code path).
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add($"setsid -f {term} >/dev/null 2>&1");

            var wayland = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
            var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (!string.IsNullOrEmpty(wayland))
            {
                psi.EnvironmentVariables["WAYLAND_DISPLAY"] = wayland;
            }

            if (!string.IsNullOrEmpty(runtime))
            {
                psi.EnvironmentVariables["XDG_RUNTIME_DIR"] = runtime;
            }

            psi.EnvironmentVariables["XDG_SESSION_TYPE"] = "wayland";
            psi.EnvironmentVariables["XDG_CURRENT_DESKTOP"] = "Aqueous";
            psi.EnvironmentVariables.Remove("DISPLAY");

            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Log("failed to spawn terminal: " + ex.Message);
        }
    }

    private void CloseFocusedWindow()
    {
        if (_focusedWindow == IntPtr.Zero)
        {
            return;
        }

        // river_window_v1::close opcode=1 (0 is destroy)
        WaylandInterop.wl_proxy_marshal_flags(_focusedWindow, 1, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    private void ReloadConfig()
    {
        try
        {
            var fresh = LayoutConfig.Load(GetDefaultConfigPath());
            _layoutConfig = fresh;
            _layoutController.ReplaceConfig(fresh);
            Log("config reloaded");
            // Note: chord rebinding hot-swap is not done here —
            // existing xkb bindings remain (River v3 has no
            // unbind primitive); changes to [keybinds] take
            // effect on next WM start.
            ScheduleManage();
        }
        catch (Exception ex)
        {
            Log("config reload failed: " + ex.Message);
        }
    }

    /// <summary>Run <paramref name="action"/> only if a window has focus; log <paramref name="actionName"/> otherwise.</summary>
    private void OnFocused(string actionName, Action<IntPtr> action)
    {
        if (_focusedWindow != IntPtr.Zero)
        {
            action(_focusedWindow);
        }
        else
        {
            Log($"{actionName}: no focused window");
        }
    }

    /// <summary>
    /// Dispatch a custom action verb. Recognised forms:
    /// <list type="bullet">
    ///   <item><c>spawn:&lt;cmd&gt;</c> — fork/exec via <c>/bin/sh -c</c>.</item>
    ///   <item><c>set_layout:&lt;id-or-slot&gt;</c> — switch active layout.</item>
    ///   <item><c>builtin:&lt;action_name&gt;</c> — invoke a built-in.</item>
    /// </list>
    /// </summary>
    private void RunCustomAction(string action)
    {
        int colon = action.IndexOf(':');
        string verb = colon < 0 ? action : action.Substring(0, colon);
        string arg = colon < 0 ? "" : action.Substring(colon + 1).Trim();
        switch (verb)
        {
            case "spawn":
                RunSpawnVerb(arg);
                break;
            case "set_layout":
                SetLayoutByIdOrSlot(arg);
                break;
            case "builtin":
                RunBuiltinVerb(arg);
                break;
            default:
                Log($"unknown custom action verb '{verb}'");
                break;
        }
    }

    private void RunSpawnVerb(string arg)
    {
        if (arg.Length == 0)
        {
            return;
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add($"setsid -f sh -c {EscapeForShell(arg)} >/dev/null 2>&1");
            var wayland = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
            var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (!string.IsNullOrEmpty(wayland))
            {
                psi.EnvironmentVariables["WAYLAND_DISPLAY"] = wayland;
            }

            if (!string.IsNullOrEmpty(runtime))
            {
                psi.EnvironmentVariables["XDG_RUNTIME_DIR"] = runtime;
            }

            psi.EnvironmentVariables.Remove("DISPLAY");
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Log($"spawn '{arg}' failed: {ex.Message}");
        }
    }

    private void RunBuiltinVerb(string arg)
    {
        // Phase B1e Pass B: split one optional trailing ":argument"
        // segment so chords like
        //   builtin:toggle_scratchpad_named:term
        // can dispatch to the parameterised actions while preserving
        // the existing parameterless form (e.g. builtin:cycle_focus).
        string bname = arg;
        string barg = string.Empty;
        int sub = arg.IndexOf(':');
        if (sub >= 0)
        {
            bname = arg.Substring(0, sub);
            barg = arg.Substring(sub + 1).Trim();
        }

        switch (bname)
        {
            case "toggle_scratchpad_named":
                if (barg.Length == 0)
                {
                    Log("builtin:toggle_scratchpad_named requires :name");
                    return;
                }

                _windowState.ToggleScratchpad(barg);
                return;
            case "send_to_scratchpad_named":
                if (barg.Length == 0)
                {
                    Log("builtin:send_to_scratchpad_named requires :name");
                    return;
                }

                if (_focusedWindow != IntPtr.Zero)
                {
                    _windowState.SendToScratchpad(_focusedWindow, barg);
                }
                else
                {
                    Log("builtin:send_to_scratchpad_named: no focused window");
                }

                return;
            default:
                if (BuiltinActionMap.TryGetValue(bname, out var b))
                {
                    InvokeBuiltin(b);
                }
                else
                {
                    Log($"unknown builtin '{bname}'");
                }

                return;
        }
    }

    private static string EscapeForShell(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
