using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 9.7 — takes <see cref="RiverWindowManagerClient"/> directly,
/// retiring the transient <c>IManagerHandlerCollaborators</c> bridge.
/// Pump-thread only: invoked by <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class ManagerEventHandler : IEventHandler
{
    private readonly RiverWindowManagerClient _river;
    private readonly Action<string>? _log;

    public ManagerEventHandler(RiverWindowManagerClient river, Action<string>? log = null)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
        _log = log;
    }

    public string InterfaceName => "river_window_manager_v1";

    public void Handle(WlEvent ev)
    {
        WlArgument* args = ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr;
        _river.HandleManagerEvent(ev.Opcode, args);
    }
}
