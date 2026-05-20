using System;
using System.Collections.Generic;
using System.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Bindings;

/// <summary>
/// PR 9.9 (Stage 9): top-level <see cref="IKeyBindingRouter"/> implementation.
///
/// Lifted verbatim from the deleted partial
/// <c>RiverWindowManagerClient.KeyBindingActionRouter.cs</c>: owns the static
/// <see cref="ActionTable"/> dictionary, the <see cref="Handle"/> entry point
/// that resolves tag-action ranges by enum-offset arithmetic before consulting
/// the table, and the small named helpers (<c>SetLayoutByIdOrSlot</c>,
/// <c>ToggleStartMenu</c>, <c>SpawnTerminal</c>, <c>CloseFocusedWindow</c>,
/// <c>ReloadConfig</c>, <c>OnFocused</c>, <c>LockScreen</c>) that each
/// <see cref="ActionTable"/> entry points at. State the helpers used to read
/// directly off the god class is now reached via pass-through accessors
/// (<see cref="RiverWindowManagerClient.LayoutController"/>,
/// <see cref="RiverWindowManagerClient.LayoutConfigForBindings"/>,
/// <see cref="RiverWindowManagerClient.WindowStateController"/>,
/// <see cref="RiverWindowManagerClient.FocusServiceForBindings"/>,
/// <see cref="RiverWindowManagerClient.TagServiceForBindings"/>,
/// <see cref="RiverWindowManagerClient.ManagerRequestSenderForBindings"/>,
/// <see cref="RiverWindowManagerClient.ProcessLauncherForBindings"/>).
/// </summary>
internal sealed class KeyBindingRouter : IKeyBindingRouter
{
    private readonly RiverWindowManagerClient _river;

    public KeyBindingRouter(RiverWindowManagerClient river)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
    }

    // Static dispatch table for built-in (parameterless) key-binding actions.
    // Tag actions (which need to derive a bit index from the enum value) are
    // routed by Handle below before the table is consulted, because expanding
    // 36 individual cases here would defeat the point.
    private static readonly IReadOnlyDictionary<KeyBindingAction, Action<KeyBindingRouter>> ActionTable =
        new Dictionary<KeyBindingAction, Action<KeyBindingRouter>>
        {
            [KeyBindingAction.ToggleStartMenu]      = c => c.ToggleStartMenu(),
            [KeyBindingAction.SpawnTerminal]        = c => c.SpawnTerminal(),
            [KeyBindingAction.CloseFocused]         = c => c.CloseFocusedWindow(),
            [KeyBindingAction.CycleFocus]           = c => c._river.FocusServiceForBindings.CycleFocus(),
            [KeyBindingAction.FocusLeft]            = c => c._river.FocusServiceForBindings.HandleDirectionalFocus(FocusDirection.Left),
            [KeyBindingAction.FocusRight]           = c => c._river.FocusServiceForBindings.HandleDirectionalFocus(FocusDirection.Right),
            [KeyBindingAction.FocusUp]              = c => c._river.FocusServiceForBindings.HandleDirectionalFocus(FocusDirection.Up),
            [KeyBindingAction.FocusDown]            = c => c._river.FocusServiceForBindings.HandleDirectionalFocus(FocusDirection.Down),
            [KeyBindingAction.ScrollViewportLeft]   = c => c._river.HandleScrollViewportForwarding(-1),
            [KeyBindingAction.ScrollViewportRight]  = c => c._river.HandleScrollViewportForwarding(+1),
            [KeyBindingAction.MoveColumnLeft]       = c => c._river.HandleMoveColumnForwarding(FocusDirection.Left),
            [KeyBindingAction.MoveColumnRight]      = c => c._river.HandleMoveColumnForwarding(FocusDirection.Right),
            [KeyBindingAction.ReloadConfig]         = c => c.ReloadConfig(),
            [KeyBindingAction.SetLayoutPrimary]     = c => c.SetLayoutByIdOrSlot("primary"),
            [KeyBindingAction.SetLayoutSecondary]   = c => c.SetLayoutByIdOrSlot("secondary"),
            [KeyBindingAction.SetLayoutTertiary]    = c => c.SetLayoutByIdOrSlot("tertiary"),
            [KeyBindingAction.SetLayoutQuaternary]  = c => c.SetLayoutByIdOrSlot("quaternary"),
            [KeyBindingAction.ViewTagAll]           = c => c._river.TagServiceForBindings.ViewAll(),
            [KeyBindingAction.SendTagAll]           = c => c._river.TagServiceForBindings.SendFocusedToTags(TagState.AllTags),
            [KeyBindingAction.SwapLastTagset]       = c => c._river.TagServiceForBindings.SwapLastTagset(),
            [KeyBindingAction.ToggleFullscreen]     = c => c.OnFocused("toggle_fullscreen", w => c._river.WindowStateController.ToggleFullscreen(w)),
            [KeyBindingAction.ToggleMaximize]       = c => c.OnFocused("toggle_maximize",   w => c._river.WindowStateController.ToggleMaximize(w)),
            [KeyBindingAction.ToggleFloating]       = c => c.OnFocused("toggle_floating",   w => c._river.WindowStateController.ToggleFloating(w)),
            [KeyBindingAction.ToggleMinimize]       = c => c.OnFocused("toggle_minimize",   w => c._river.WindowStateController.ToggleMinimize(w)),
            [KeyBindingAction.UnminimizeLast]       = c => c._river.WindowStateController.UnminimizeLast(),
            [KeyBindingAction.ToggleScratchpad]     = c => c._river.WindowStateController.ToggleScratchpad(ScratchpadRegistry.DefaultPad),
            [KeyBindingAction.SendToScratchpad]     = c => c.OnFocused("send_to_scratchpad", w => c._river.WindowStateController.SendToScratchpad(w, ScratchpadRegistry.DefaultPad)),
            [KeyBindingAction.LockScreen]           = c => c.LockScreen(),
        };

    /// <summary>
    /// Dispatch a built-in <see cref="KeyBindingAction"/>. Tag actions
    /// (ViewTag/SendTag/ToggleViewTag/ToggleWindowTag) are routed first
    /// because they derive a bit index from the enum value and would
    /// otherwise need 36 nearly-identical entries in <see cref="ActionTable"/>.
    /// Everything else is a single dictionary lookup.
    /// </summary>
    public void Handle(KeyBindingAction action)
    {
        // ViewTag1..9 → bit (action - ViewTag1)
        if (action >= KeyBindingAction.ViewTag1 && action <= KeyBindingAction.ViewTag9)
        {
            _river.TagServiceForBindings.ViewTags(TagState.Bit(action - KeyBindingAction.ViewTag1));
            return;
        }
        if (action >= KeyBindingAction.SendTag1 && action <= KeyBindingAction.SendTag9)
        {
            _river.TagServiceForBindings.SendFocusedToTags(TagState.Bit(action - KeyBindingAction.SendTag1));
            return;
        }
        if (action >= KeyBindingAction.ToggleViewTag1 && action <= KeyBindingAction.ToggleViewTag9)
        {
            _river.TagServiceForBindings.ToggleViewTag(TagState.Bit(action - KeyBindingAction.ToggleViewTag1));
            return;
        }
        if (action >= KeyBindingAction.ToggleWindowTag1 && action <= KeyBindingAction.ToggleWindowTag9)
        {
            _river.TagServiceForBindings.ToggleWindowTag(TagState.Bit(action - KeyBindingAction.ToggleWindowTag1));
            return;
        }

        if (ActionTable.TryGetValue(action, out var handler))
        {
            handler(this);
        }
    }

    /// <summary>
    /// Internal entry point used by <see cref="CustomActionRunner"/>'s
    /// <c>builtin:</c> verb (which has already done its own arg parse).
    /// Identical to <see cref="Handle"/>.
    /// </summary>
    internal void InvokeBuiltin(KeyBindingAction action) => Handle(action);

    /// <summary>Resolve <paramref name="idOrSlot"/> through slots first, then engines.</summary>
    internal void SetLayoutByIdOrSlot(string idOrSlot)
    {
        if (string.IsNullOrEmpty(idOrSlot))
        {
            return;
        }

        string id = idOrSlot;
        if (_river.LayoutConfigForBindings.Slots.TryGetValue(idOrSlot, out var resolved))
        {
            id = resolved;
        }

        _river.LayoutController.SetLayout(id);
        _river.ManagerRequestSenderForBindings.ScheduleManage();
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
            _river.LogForwarding("failed to toggle start menu: " + ex.Message);
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
            _river.LogForwarding("failed to spawn terminal: " + ex.Message);
        }
    }

    private void CloseFocusedWindow()
    {
        if (!_river.FocusServiceForBindings.TryGetFocusedAlive(out var focused))
        {
            return;
        }

        // river_window_v1::close opcode=1 (0 is destroy)
        WaylandInterop.wl_proxy_marshal_flags(focused, 1, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    private void ReloadConfig()
    {
        try
        {
            var fresh = LayoutConfig.Load(RiverWindowManagerClient.GetDefaultConfigPathForBindings());
            _river.LayoutConfigForBindings = fresh;
            _river.LayoutController.ReplaceConfig(fresh);
            // Re-apply libinput config to the sidecar so [input.*] edits
            // take effect live (niri-style hot reload). No-op if daemon
            // isn't running.
            InputDaemonClient.Apply(fresh.Input);
            _river.LogForwarding("config reloaded");
            // Note: chord rebinding hot-swap is not done here —
            // existing xkb bindings remain (River v3 has no
            // unbind primitive); changes to [keybinds] take
            // effect on next WM start.
            _river.ManagerRequestSenderForBindings.ScheduleManage();
        }
        catch (Exception ex)
        {
            _river.LogForwarding("config reload failed: " + ex.Message);
        }
    }

    /// <summary>Run <paramref name="action"/> only if a window has focus; log <paramref name="actionName"/> otherwise.</summary>
    private void OnFocused(string actionName, Action<WindowProxy> action)
    {
        if (_river.FocusServiceForBindings.TryGetFocusedAlive(out var focused))
        {
            action(new WindowProxy(focused));
        }
        else
        {
            _river.LogForwarding($"{actionName}: no focused window");
        }
    }

    private void LockScreen()
    {
        try
        {
            _river.LogForwarding("locking screen");

            // Noctalia owns the lock screen (ext-session-lock-v1). It listens
            // for logind's Lock signal, so `loginctl lock-session` is the
            // dependency-free trigger that works whether Noctalia is started
            // by Aqueous or by the user's session.
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
            // Detach via setsid -f so the lock helper leaves the compositor's
            // process group/session; otherwise a fast-failing `qs` chained to
            // `loginctl lock-session` via `||` can tear down the graphical
            // session instead of locking it. Prefer Noctalia's IPC if
            // available, fall back to loginctl.
            psi.ArgumentList.Add(
                "setsid -f sh -c '" +
                "qs -c noctalia-shell ipc call lockScreen lock " +
                ">/dev/null 2>&1 || loginctl lock-session" +
                "' >/dev/null 2>&1");

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
            _river.LogForwarding("failed to lock screen: " + ex.Message);
        }
    }
}
