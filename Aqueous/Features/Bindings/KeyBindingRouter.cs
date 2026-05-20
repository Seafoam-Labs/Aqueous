using System;
using System.Collections.Generic;
using System.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Bindings;

/// <summary>
/// PR 9.9 (Stage 9): top-level <see cref="IKeyBindingRouter"/> implementation.
///
/// PR 9.12 §2.6: ctor converted from a single <see cref="RiverWindowManagerClient"/>
/// reference to fine-grained service injection. The router still holds a thin
/// <see cref="RiverWindowManagerClient"/> reference for the cross-cutting
/// helpers that remain on the god class (mutable <c>LayoutConfig</c> swap,
/// <c>HandleScrollViewport</c>/<c>HandleMoveColumn</c>, the default config
/// path helper, and the logging helper). Those retire naturally in §2.9 /
/// §2.13 with the rest of the partial.
/// </summary>
internal sealed class KeyBindingRouter : IKeyBindingRouter
{
    private readonly IFocusService _focusService;
    private readonly LayoutController _layoutController;
    private readonly ITagService _tagService;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly WindowStateController _windowState;
    private readonly RiverWindowManagerClient _river;

    public KeyBindingRouter(
        IFocusService focusService,
        LayoutController layoutController,
        ITagService tagService,
        IManagerRequestSender managerRequestSender,
        WindowStateController windowState,
        RiverWindowManagerClient river)
    {
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _tagService = tagService ?? throw new ArgumentNullException(nameof(tagService));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _windowState = windowState ?? throw new ArgumentNullException(nameof(windowState));
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
            [KeyBindingAction.CycleFocus]           = c => c._focusService.CycleFocus(),
            [KeyBindingAction.FocusLeft]            = c => c._focusService.HandleDirectionalFocus(FocusDirection.Left),
            [KeyBindingAction.FocusRight]           = c => c._focusService.HandleDirectionalFocus(FocusDirection.Right),
            [KeyBindingAction.FocusUp]              = c => c._focusService.HandleDirectionalFocus(FocusDirection.Up),
            [KeyBindingAction.FocusDown]            = c => c._focusService.HandleDirectionalFocus(FocusDirection.Down),
            [KeyBindingAction.ScrollViewportLeft]   = c => c._river.HandleScrollViewportForwarding(-1),
            [KeyBindingAction.ScrollViewportRight]  = c => c._river.HandleScrollViewportForwarding(+1),
            [KeyBindingAction.MoveColumnLeft]       = c => c._river.HandleMoveColumnForwarding(FocusDirection.Left),
            [KeyBindingAction.MoveColumnRight]      = c => c._river.HandleMoveColumnForwarding(FocusDirection.Right),
            [KeyBindingAction.ReloadConfig]         = c => c.ReloadConfig(),
            [KeyBindingAction.SetLayoutPrimary]     = c => c.SetLayoutByIdOrSlot("primary"),
            [KeyBindingAction.SetLayoutSecondary]   = c => c.SetLayoutByIdOrSlot("secondary"),
            [KeyBindingAction.SetLayoutTertiary]    = c => c.SetLayoutByIdOrSlot("tertiary"),
            [KeyBindingAction.SetLayoutQuaternary]  = c => c.SetLayoutByIdOrSlot("quaternary"),
            [KeyBindingAction.ViewTagAll]           = c => c._tagService.ViewAll(),
            [KeyBindingAction.SendTagAll]           = c => c._tagService.SendFocusedToTags(TagState.AllTags),
            [KeyBindingAction.SwapLastTagset]       = c => c._tagService.SwapLastTagset(),
            [KeyBindingAction.ToggleFullscreen]     = c => c.OnFocused("toggle_fullscreen", w => c._windowState.ToggleFullscreen(w)),
            [KeyBindingAction.ToggleMaximize]       = c => c.OnFocused("toggle_maximize",   w => c._windowState.ToggleMaximize(w)),
            [KeyBindingAction.ToggleFloating]       = c => c.OnFocused("toggle_floating",   w => c._windowState.ToggleFloating(w)),
            [KeyBindingAction.ToggleMinimize]       = c => c.OnFocused("toggle_minimize",   w => c._windowState.ToggleMinimize(w)),
            [KeyBindingAction.UnminimizeLast]       = c => c._windowState.UnminimizeLast(),
            [KeyBindingAction.ToggleScratchpad]     = c => c._windowState.ToggleScratchpad(ScratchpadRegistry.DefaultPad),
            [KeyBindingAction.SendToScratchpad]     = c => c.OnFocused("send_to_scratchpad", w => c._windowState.SendToScratchpad(w, ScratchpadRegistry.DefaultPad)),
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
        if (action >= KeyBindingAction.ViewTag1 && action <= KeyBindingAction.ViewTag9)
        {
            _tagService.ViewTags(TagState.Bit(action - KeyBindingAction.ViewTag1));
            return;
        }
        if (action >= KeyBindingAction.SendTag1 && action <= KeyBindingAction.SendTag9)
        {
            _tagService.SendFocusedToTags(TagState.Bit(action - KeyBindingAction.SendTag1));
            return;
        }
        if (action >= KeyBindingAction.ToggleViewTag1 && action <= KeyBindingAction.ToggleViewTag9)
        {
            _tagService.ToggleViewTag(TagState.Bit(action - KeyBindingAction.ToggleViewTag1));
            return;
        }
        if (action >= KeyBindingAction.ToggleWindowTag1 && action <= KeyBindingAction.ToggleWindowTag9)
        {
            _tagService.ToggleWindowTag(TagState.Bit(action - KeyBindingAction.ToggleWindowTag1));
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

        _layoutController.SetLayout(id);
        _managerRequestSender.ScheduleManage();
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
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("failed to toggle start menu: " + ex.Message);
        }
    }

    private void SpawnTerminal()
    {
        try
        {
            var term = Environment.GetEnvironmentVariable("TERMINAL") ?? "alacritty";
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
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("failed to spawn terminal: " + ex.Message);
        }
    }

    private void CloseFocusedWindow()
    {
        if (!_focusService.TryGetFocusedAlive(out var focused))
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
            _layoutController.ReplaceConfig(fresh);
            InputDaemonClient.Apply(fresh.Input);
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("config reloaded");
            _managerRequestSender.ScheduleManage();
        }
        catch (Exception ex)
        {
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("config reload failed: " + ex.Message);
        }
    }

    /// <summary>Run <paramref name="action"/> only if a window has focus; log <paramref name="actionName"/> otherwise.</summary>
    private void OnFocused(string actionName, Action<WindowProxy> action)
    {
        if (_focusService.TryGetFocusedAlive(out var focused))
        {
            action(new WindowProxy(focused));
        }
        else
        {
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log($"{actionName}: no focused window");
        }
    }

    private void LockScreen()
    {
        try
        {
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("locking screen");

            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
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
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("failed to lock screen: " + ex.Message);
        }
    }
}
