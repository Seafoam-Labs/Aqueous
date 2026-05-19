using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.7: managed <see cref="IEventHandler"/> for
/// <c>river_pointer_binding_v1</c>. Currently a pass-through to the
/// existing partial via <see cref="IDragPointerBindingHandlerCollaborators"/>;
/// staged-rollout allowlist in <c>ProxyDispatcher</c> graduates opcodes
/// from the partial into managed inline impls one at a time (mirrors
/// PR 8.3/8.4/8.5/8.6 pattern).
/// </summary>
internal sealed unsafe class DragPointerBindingEventHandler : IEventHandler
{
    private readonly IDragPointerBindingHandlerCollaborators _river;
    private readonly Action<string>? _log;

    public DragPointerBindingEventHandler(
        IDragPointerBindingHandlerCollaborators river,
        Action<string>? log = null)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
        _log = log;
    }

    public string InterfaceName => "river_pointer_binding_v1";

    public void Handle(WlEvent ev)
    {
        var args = (WlArgument*)ev.ArgsPtr;
        _river.HandleByPartial(ev.Target, ev.Opcode, args);
    }
}
