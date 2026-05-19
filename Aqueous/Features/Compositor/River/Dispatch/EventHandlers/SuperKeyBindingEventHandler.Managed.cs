using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.6 of the Stage 8 native-callback rewrite: managed
/// <see cref="IEventHandler"/> for the <c>river_super_key_binding_v1</c>
/// proxy that today fires only two opcodes (<c>pressed</c>/<c>released</c>)
/// and triggers a dbus-send fire-and-forget to toggle the Aqueous start menu.
///
/// Following the Shape-A "shrink-don't-delete" pattern Stages 3/4/5/6.1 +
/// PR 8.2/8.3/8.4/8.5 established: the body still lives in the original
/// partial <c>OnSuperKeyBindingEvent</c> on <c>RiverWindowManagerClient</c>
/// and this handler delegates through <see cref="ISuperKeyBindingHandlerCollaborators"/>.
/// </summary>
internal sealed unsafe class SuperKeyBindingEventHandler : IEventHandler
{
    private readonly ISuperKeyBindingHandlerCollaborators _river;
    private readonly Action<string>? _log;

    public SuperKeyBindingEventHandler(
        ISuperKeyBindingHandlerCollaborators river,
        Action<string>? log = null)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
        _log = log;
    }

    public string InterfaceName => "river_super_key_binding_v1";

    public void Handle(WlEvent ev)
    {
        var args = ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr;
        _river.HandleByPartial(ev.Opcode, args);
    }
}
