using System;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 8.8 Stage 8 — explicit-interface implementation of
/// <see cref="IRegistryHandlerCollaborators"/> forwarding the
/// <c>wl_registry</c> event back to the existing
/// <c>_registry.HandleEvent</c> on the god class.
///
/// Retires in Stage 9.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
    : IRegistryHandlerCollaborators
{
    void IRegistryHandlerCollaborators.HandleRegistryEvent(uint opcode, WlArgument* args)
    {
        _registry.HandleEvent(opcode, args);
    }
}
