using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 9.9 (Stage 9) — accessor partial supplying the small set of god-class
/// helpers that the lifted <see cref="Aqueous.Features.Bindings.KeyBindingRouter"/>
/// and <see cref="Aqueous.Features.Bindings.CustomActionRunner"/> still need.
///
/// PR 9.12 §2.6: the per-service forwarders (LayoutController, FocusService,
/// TagService, ManagerRequestSender, WindowStateController, ProcessLauncher,
/// KeyBindingRouterForCustom) retired — those services are now ctor-injected
/// directly into the routers. Only the four cross-cutting helpers that still
/// live on the god class remain here:
/// <list type="bullet">
///   <item><see cref="LayoutConfigForBindings"/> — mutable so <c>ReloadConfig</c>
///   can swap the active config.</item>
///   <item><see cref="HandleScrollViewportForwarding"/> /
///   <see cref="HandleMoveColumnForwarding"/> — bodies still live on
///   <c>LayoutProposer</c> partial; lifted in §2.9.</item>
///   <item><see cref="LogForwarding"/> — wraps the god-class <c>Log</c> helper;
///   lifted in §2.12.</item>
///   <item><see cref="GetDefaultConfigPathForBindings"/> — pure helper still
///   on the god class; lifted in §2.12.</item>
/// </list>
/// Retires with the rest of the god class in §2.13.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    internal LayoutConfig LayoutConfigForBindings
    {
        get => _layoutConfig;
        set => _layoutConfig = value;
    }

    internal void LogForwarding(string message) => Log(message);

    internal void HandleScrollViewportForwarding(int deltaColumns) =>
        HandleScrollViewport(deltaColumns);

    internal void HandleMoveColumnForwarding(FocusDirection dir) =>
        HandleMoveColumn(dir);

    internal static string GetDefaultConfigPathForBindings() => GetDefaultConfigPath();
}
