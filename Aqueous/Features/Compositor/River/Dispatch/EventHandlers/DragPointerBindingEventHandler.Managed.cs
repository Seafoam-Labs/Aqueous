using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.7: managed <see cref="IEventHandler"/> for
/// <c>river_pointer_binding_v1</c>. PR 9.5 (Stage 9) retired the
/// <c>IDragPointerBindingHandlerCollaborators</c> bridge; the handler
/// now takes <see cref="RiverWindowManagerClient"/> directly and
/// forwards via the <c>HandleDragPointerBindingEvent</c> accessor
/// (same pattern PR 9.3/9.4 established).
/// </summary>
internal sealed unsafe class DragPointerBindingEventHandler : IEventHandler
{
    private readonly RiverWindowManagerClient _client;
    private readonly Action<string>? _log;

    public DragPointerBindingEventHandler(
        RiverWindowManagerClient client,
        Action<string>? log = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _log = log;
    }

    public string InterfaceName => "river_pointer_binding_v1";

    public void Handle(WlEvent ev)
    {
        var args = (WlArgument*)ev.ArgsPtr;
        _client.HandleDragPointerBindingEvent(ev.Target, ev.Opcode, args);
    }
}
