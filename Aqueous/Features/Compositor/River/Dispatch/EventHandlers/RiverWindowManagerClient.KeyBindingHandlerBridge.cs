using System;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 8.8 Stage 8 — explicit-interface implementation of
/// <see cref="IKeyBindingHandlerCollaborators"/> forwarding the
/// <c>river_xkb_binding_v1</c> event back to the existing
/// <c>OnKeyBindingEvent</c> partial on the god class.
///
/// Retires in Stage 9.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
    : IKeyBindingHandlerCollaborators
{
    void IKeyBindingHandlerCollaborators.HandleKeyBindingEvent(
        IntPtr target, uint opcode, WlArgument* args)
    {
        OnKeyBindingEvent(target, opcode, args);
    }
}
