using System;
using Aqueous.Features.Compositor.River.Dispatch.Services;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Managed <see cref="IEventHandler"/> for <c>river_window_manager_v1</c>. final cleanup: the
/// partial-class file holding the event body was lifted into <see cref="ManagerEventService"/>;
/// the handler now forwards directly to that service and no longer touches <see
/// cref="RiverWindowManagerClient"/>.
/// </summary>
internal sealed unsafe class ManagerEventHandler : IEventHandler
{
    private readonly ManagerEventService _service;
    private readonly Action<string>? _log;

    public ManagerEventHandler(ManagerEventService service, Action<string>? log = null)
    {
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _log = log;
    }

    public string InterfaceName => "river_window_manager_v1";

    public void Handle(WlEvent ev)
    {
        WlArgument* args = ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr;
        _service.HandleEvent(ev.Opcode, args);
    }
}
