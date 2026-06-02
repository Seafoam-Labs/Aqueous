using System;
using System.Collections.Generic;
using System.Diagnostics;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Configuration;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.Rules;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Bindings;

/// <summary>
/// : Top-level <see cref="IKeyBindingRouter"/> implementation. ctor converted from a single <see
/// cref="RiverWindowManagerClient"/> reference to fine-grained service injection. the last class
/// ref is gone. The mutable <c>LayoutConfig</c> handle is reached through <see
/// cref="LayoutController"/> (which already owns the active config and exposes
/// <c>ReplaceConfig</c>), and the default-config-path helper now resolves directly via <see
/// cref="DefaultConfigPath.Resolve"/>.
/// </summary>
internal sealed class KeyBindingRouter : IKeyBindingRouter
{
    private readonly IFocusService _focusService;
    private readonly LayoutController _layoutController;
    private readonly ITagService _tagService;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly WindowStateController _windowState;
    private readonly ViewportInteractionService _viewport;
    private readonly LibinputConfigApplier _libinputApplier;
    private readonly IRulesReloader _rulesReloader;

    public KeyBindingRouter(
        IFocusService focusService,
        LayoutController layoutController,
        ITagService tagService,
        IManagerRequestSender managerRequestSender,
        WindowStateController windowState,
        ViewportInteractionService viewport,
        LibinputConfigApplier libinputApplier,
        IRulesReloader rulesReloader)
    {
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _tagService = tagService ?? throw new ArgumentNullException(nameof(tagService));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _windowState = windowState ?? throw new ArgumentNullException(nameof(windowState));
        _viewport = viewport ?? throw new ArgumentNullException(nameof(viewport));
        _libinputApplier = libinputApplier ?? throw new ArgumentNullException(nameof(libinputApplier));
        _rulesReloader = rulesReloader ?? throw new ArgumentNullException(nameof(rulesReloader));
    }

    // Static dispatch table for built-in (parameterless) key-binding actions. Tag actions (which need
    // to derive a bit index from the enum value) are routed by Handle below before the table is
    // consulted, because expanding 36 individual cases here would defeat the point.
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
            [KeyBindingAction.ScrollViewportLeft]   = c => c._viewport.ScrollViewport(-1),
            [KeyBindingAction.ScrollViewportRight]  = c => c._viewport.ScrollViewport(+1),
            [KeyBindingAction.MoveWindowLeft]       = c => c._viewport.MoveFocusedWindow(FocusDirection.Left),
            [KeyBindingAction.MoveWindowRight]      = c => c._viewport.MoveFocusedWindow(FocusDirection.Right),
            [KeyBindingAction.MoveWindowUp]         = c => c._viewport.MoveFocusedWindow(FocusDirection.Up),
            [KeyBindingAction.MoveWindowDown]       = c => c._viewport.MoveFocusedWindow(FocusDirection.Down),
            [KeyBindingAction.ReloadConfig]         = c => c.ReloadConfig(),
            [KeyBindingAction.ReloadRules]          = c => c._rulesReloader.Reload(),
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
    /// (ViewTag/SendTag/ToggleViewTag/ToggleWindowTag) are routed first because they derive a bit
    /// index from the enum value and would otherwise need 36 nearly-identical entries in <see
    /// cref="ActionTable"/>. Everything else is a single dictionary lookup.
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
    /// Internal entry point used by <see cref="CustomActionRunner"/>'s <c>builtin:</c> verb (which has
    /// already done its own arg parse). Identical to <see cref="Handle"/>.
    /// </summary>
    internal void InvokeBuiltin(KeyBindingAction action) => Handle(action);

    /// <summary>
    /// Resolve <paramref name="idOrSlot"/> through slots first, then engines.
    /// </summary>
    internal void SetLayoutByIdOrSlot(string idOrSlot)
    {
        if (string.IsNullOrEmpty(idOrSlot))
        {
            return;
        }

        string id = idOrSlot;
        if (_layoutController.Config.Slots.TryGetValue(idOrSlot, out var resolved))
        {
            id = resolved;
        }

        _layoutController.SetLayout(id);
        _managerRequestSender.ScheduleManage();
    }

    // -- Built-in action helpers (one tiny method per ActionTable entry) ----

    private void ToggleStartMenu()
    {
        var cmd = _layoutController.Config.Actions?.ToggleStartMenu;
        if (string.IsNullOrWhiteSpace(cmd))
        {
            Aqueous.Diagnostics.RiverLog.Write(
                "toggle_start_menu: no command configured in [actions]");
            return;
        }
        RunShell(cmd, "toggle_start_menu");
    }

    private void SpawnTerminal()
    {
        var cmd = _layoutController.Config.Actions?.SpawnTerminal;
        if (string.IsNullOrWhiteSpace(cmd))
        {
            RiverLog.Write(
                "spawn_terminal: no command configured in [actions]");
            return;
        }
        RunShell(cmd, "spawn_terminal");
    }

    private void CloseFocusedWindow()
    {
        if (!_focusService.TryGetFocusedAlive(out var focused))
        {
            return;
        }

        // River_window_v1::close opcode=1 (0 is destroy)
        WaylandInterop.wl_proxy_marshal_flags(focused, 1, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    private void ReloadConfig()
    {
        try
        {
            var baseFresh = LayoutTomlReader.LoadWithSidecar(DefaultConfigPath.Resolve());
            // Hot-reload input.toml in lockstep with wm.toml; sidecar wins per field it sets.
            var inputOverlay = Aqueous.Features.Input.InputTomlReader.Load();
            var fresh = baseFresh with
            {
                Input = Aqueous.Features.Input.InputTomlReader.Merge(baseFresh.Input, inputOverlay),
            };
            _layoutController.ReplaceConfig(fresh);
            _libinputApplier.Apply(fresh.Input);
            Aqueous.Diagnostics.RiverLog.Write("config reloaded");
            // Super+R reloads rules.toml in lockstep with wm.toml; the reload_rules verb
            // is the rules-only equivalent.
            _rulesReloader.Reload();
            _managerRequestSender.ScheduleManage();
        }
        catch (Exception ex)
        {
            Aqueous.Diagnostics.RiverLog.Write("config reload failed: " + ex.Message);
        }
    }

    /// <summary>
    /// Run <paramref name="action"/> only if a window has focus; log <paramref name="actionName"/>
    /// otherwise.
    /// </summary>
    private void OnFocused(string actionName, Action<WindowProxy> action)
    {
        if (_focusService.TryGetFocusedAlive(out var focused))
        {
            action(new WindowProxy(focused));
        }
        else
        {
            Aqueous.Diagnostics.RiverLog.Write($"{actionName}: no focused window");
        }
    }

    private void LockScreen()
    {
        var cmd = _layoutController.Config.Actions?.LockScreen;
        if (string.IsNullOrWhiteSpace(cmd))
        {
            RiverLog.Write(
                "lock_screen: no command configured in [actions]");
            return;
        }
        RunShell(cmd, "lock_screens");
    }

    private static void RunShell(string cmd, string tag)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add(cmd);

            Process.Start(psi);
        }
        catch (Exception ex)
        {
            RiverLog.Write($"{tag} failed: {ex.Message}");
        }
    }
}
