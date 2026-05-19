using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.8 Stage 8 transient collaborator bridge for <c>RegistryEventHandler</c>.
/// Routes <c>wl_registry</c> events back to the existing
/// <see cref="Aqueous.Features.Compositor.River.Connection.RegistryBinder.HandleEvent"/>
/// owned by the god class via its <c>_registry</c> field.
///
/// Retires in Stage 9 when the god class collapses and the registry binder
/// is owned by a dedicated <c>IRegistryService</c>.
/// </summary>
internal interface IRegistryHandlerCollaborators
{
    /// <summary>
    /// Forwards a tracked <c>wl_registry</c> event to the existing
    /// <see cref="Aqueous.Features.Compositor.River.Connection.RegistryBinder.HandleEvent"/>.
    /// </summary>
    unsafe void HandleRegistryEvent(uint opcode, WlArgument* args);
}
