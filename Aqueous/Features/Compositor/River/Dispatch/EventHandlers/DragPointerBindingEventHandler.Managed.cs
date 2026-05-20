using System;
using Aqueous.Features.Input;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Managed <see cref="IEventHandler"/> for <c>river_pointer_binding_v1</c>. final cleanup: the
/// partial-class file holding the event body was lifted into <see
/// cref="DragPointerBindingService"/>; the handler now forwards directly to that service and no
/// longer touches <see cref="RiverWindowManagerClient"/>.
/// </summary>
internal sealed unsafe class DragPointerBindingEventHandler : IEventHandler
{
    private readonly DragPointerBindingService _service;
    private readonly Action<string>? _log;

    public DragPointerBindingEventHandler(
        DragPointerBindingService service,
        Action<string>? log = null)
    {
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _log = log;
    }

    public string InterfaceName => "river_pointer_binding_v1";

    public void Handle(WlEvent ev)
    {
        var args = (WlArgument*)ev.ArgsPtr;
        _service.HandleEvent(ev.Target, ev.Opcode, args);
    }
}
