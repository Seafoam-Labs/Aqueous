using System;
using Aqueous.Features.Bindings;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 9.9 (Stage 9) — accessor partial supplying the small set of god-class
/// private fields and helper methods that the new top-level
/// <see cref="Aqueous.Features.Bindings.KeyBindingRouter"/> and
/// <see cref="Aqueous.Features.Bindings.CustomActionRunner"/> read/write.
///
/// Mirrors the Shape-A pattern PRs 9.3–9.8 / 9.10 used: thin internal
/// accessors that forward to existing private fields/helpers so the lifted
/// service bodies remain byte-for-byte equivalent to the partial bodies
/// they replaced. Retires alongside the god class in PR 9.12.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    // --- Read-only service accessors ---------------------------------
    internal LayoutController LayoutController => _layoutController;

    internal WindowStateController WindowStateController => _windowState;

    internal IFocusService FocusServiceForBindings => _focusService;

    internal ITagService TagServiceForBindings => _tagController;

    internal IManagerRequestSender ManagerRequestSenderForBindings => _managerRequestSender;

    internal IProcessLauncher ProcessLauncherForBindings => _processLauncher;

    /// <summary>
    /// Access to the top-level <see cref="IKeyBindingRouter"/> singleton
    /// for the lifted <see cref="CustomActionRunner"/> — its
    /// <c>builtin:</c> / <c>set_layout:</c> verbs delegate back through
    /// the router rather than duplicating its dispatch tables.
    /// </summary>
    internal IKeyBindingRouter KeyBindingRouterForCustom => _keyBindingRouter;

    // --- Mutable config (ReloadConfig swaps the reference) -----------
    internal LayoutConfig LayoutConfigForBindings
    {
        get => _layoutConfig;
        set => _layoutConfig = value;
    }

    // --- Helpers still living on the god class -----------------------
    internal void LogForwarding(string message) => Log(message);

    internal void HandleScrollViewportForwarding(int deltaColumns) =>
        HandleScrollViewport(deltaColumns);

    internal void HandleMoveColumnForwarding(FocusDirection dir) =>
        HandleMoveColumn(dir);

    internal static string GetDefaultConfigPathForBindings() => GetDefaultConfigPath();
}
