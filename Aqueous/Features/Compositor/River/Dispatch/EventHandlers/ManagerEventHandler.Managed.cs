using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.5 — fifth <see cref="IEventHandler"/> extracted out of the
/// <c>RiverWindowManagerClient</c> god class.
///
/// Handles the <c>river_window_manager_v1</c> events (see
/// <see cref="RiverProtocolOpcodes.Manager"/>): unavailable, finished,
/// manage_start, manage_end, output, seat, window, key_bindings_global,
/// drag_pointer_binding, drag_resize_pointer_binding, snap_activator_binding,
/// foreign_toplevel_global.
///
/// Every opcode body still touches a very broad surface on the god class
/// (all three registries, focus state, tag controller, layout proposer,
/// snap-zone service, manage-sequence flag, pump lifecycle,
/// foreign-toplevel emit, manager-request sender, every bind-site
/// IntPtr), so PR 8.5 ships as a pass-through: <see cref="Handle"/>
/// forwards each opcode to
/// <see cref="IManagerHandlerCollaborators.HandleByPartial"/>, which the
/// god class implements by calling the byte-for-byte original
/// <c>OnManagerEvent</c> body. The <c>ProxyDispatcher</c> opcode
/// allowlist starts empty; per the PR 8.3/8.4 rollout pattern, opcodes
/// graduate one at a time after smoke-testing against the real River
/// compositor. The bridge / pass-through fully retires in Stage 9 when
/// the relevant state moves off the god class.
///
/// Pump-thread only: invoked by <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class ManagerEventHandler : IEventHandler
{
    private readonly IManagerHandlerCollaborators _river;
    private readonly Action<string>? _log;

    public ManagerEventHandler(
        IManagerHandlerCollaborators river,
        Action<string>? log = null)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
        _log = log;
    }

    public string InterfaceName => "river_window_manager_v1";

    public void Handle(WlEvent ev)
    {
        // DIAG: prove the manager handler is actually reached after the
        // PR 8.8 native-callback rewrite. If River pings the WM (~1s
        // cadence) and these lines don't appear, the manager target is
        // missing from _proxyInterface; if they do appear but the
        // connection still times out, the partial's OnManagerEvent
        // isn't replying.
        _log?.Invoke("MGR opcode=" + ev.Opcode + " target=0x" + ev.Target.ToString("x") + " argCount=" + ev.ArgCount + " argsPtr=0x" + ev.ArgsPtr.ToString("x"));
        // Unlike windows/outputs/seats there is no registry to validate
        // the target against — the manager is a singleton proxy resolved
        // at bind time. ProxyDispatcher gates this branch on
        // `target == self._manager`, so by the time we get here `ev.Target`
        // is guaranteed to be the manager proxy.
        //
        // PR 8.5 pass-through: every opcode body still touches god-class
        // private state. Delegate to the bridge until each opcode is
        // graduated through the ProxyDispatcher allowlist. ArgsPtr may
        // be zero/short for some opcodes — the partial guards per case,
        // so let it decide.
        WlArgument* args = ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr;
        _river.HandleByPartial(ev.Opcode, args);
    }
}
