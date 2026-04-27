using System;
using System.Collections.Generic;
using System.Diagnostics;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Key-binding action router partial of <see cref="RiverWindowManagerClient"/>:
/// owns the static <see cref="ActionTable"/> dictionary, the
/// <c>HandleKeyBindingAction</c> entry point that resolves tag-action
/// ranges by enum-offset arithmetic before consulting the table, and the
/// small named helpers (<c>SetLayoutByIdOrSlot</c>, <c>ToggleStartMenu</c>,
/// <c>SpawnTerminal</c>, <c>CloseFocusedWindow</c>, <c>ReloadConfig</c>,
/// <c>OnFocused</c>) that each <c>ActionTable</c> entry points at. Adding
/// a new built-in chord is one dictionary entry plus one tiny method.
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
    private void OnFocused(string actionName, Action<WindowProxy> action)
    {
        if (_focusedWindow != IntPtr.Zero)
        {
            action(new WindowProxy(_focusedWindow));
        }
        else
        {
            Log($"{actionName}: no focused window");
        }
    }
}
