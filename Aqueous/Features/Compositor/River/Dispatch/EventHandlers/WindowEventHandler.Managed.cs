using System;
using Aqueous.Features.Compositor.River.Registry;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.4 — fourth <see cref="IEventHandler"/> extracted out of the
/// <c>RiverWindowManagerClient</c> god class.
///
/// Handles the <c>river_window_v1</c> events (see
/// <see cref="RiverProtocolOpcodes.Window"/>): closed, dimensions_hint,
/// dimensions, app_id, title, parent, decoration_hint,
/// pointer_move_requested, pointer_resize_requested,
/// show_window_menu_requested, maximize_requested, unmaximize_requested,
/// fullscreen_requested, exit_fullscreen_requested, minimize_requested,
/// unreliable_pid, presentation_hint, identifier, activate_requested,
/// unminimize_requested.
///
/// Every opcode body still mutates ~15 god-class private fields (drag
/// state, fullscreen map, pending-focus, window-state controller, focus
/// helpers, ScheduleManage), so PR 8.4 ships as a pass-through:
/// <see cref="Handle"/> forwards each opcode to
/// <see cref="IWindowHandlerCollaborators.HandleByPartial"/>, which the
/// god class implements by calling the byte-for-byte original
/// <c>OnWindowEvent</c> body. The
/// <c>ProxyDispatcher</c> opcode allowlist starts empty; per the PR 8.3
/// rollout pattern, opcodes graduate one at a time after smoke-testing
/// against the real River compositor. The bridge / pass-through fully
/// retires in Stage 9 when the relevant state moves off the god class.
///
/// Pump-thread only: invoked by <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class WindowEventHandler : IEventHandler
{
    private readonly IWindowRegistry _windows;
    private readonly IWindowHandlerCollaborators _river;
    private readonly Action<string>? _log;

    public WindowEventHandler(
        IWindowRegistry windows,
        IWindowHandlerCollaborators river,
        Action<string>? log = null)
    {
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _river = river ?? throw new ArgumentNullException(nameof(river));
        _log = log;
    }

    public string InterfaceName => "river_window_v1";

    public void Handle(WlEvent ev)
    {
        IntPtr proxy = ev.Target;
        if (!_windows.Entries.ContainsKey(proxy))
        {
            // Window may have been removed between event emission
            // and dispatch (e.g. close arrived first and untracked
            // the proxy). Match the partial's early-return guard.
            return;
        }

        // PR 8.4 pass-through: every opcode body still touches god-class
        // private state (drag, fullscreen, pending-focus, window-state
        // controller). Delegate to the bridge until each opcode is
        // graduated through the ProxyDispatcher allowlist. ArgsPtr may
        // be zero/short for some opcodes — the partial guards per case,
        // so let it decide.
        WlArgument* args = ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr;
        _river.HandleByPartial(proxy, ev.Opcode, args);
    }
}
