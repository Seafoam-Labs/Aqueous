using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.8 Stage 8 transient collaborator bridge for <c>KeyBindingEventHandler</c>.
/// Routes <c>river_xkb_binding_v1</c> events back to the existing
/// <c>OnKeyBindingEvent</c> partial owned by the god class
/// (<c>RiverWindowManagerClient.KeyBindingRegistrar.cs</c>).
///
/// Retires in Stage 9 when the god class collapses and key-binding routing
/// is owned by <see cref="Aqueous.Features.Bindings.IKeyBindingRouter"/>.
/// </summary>
internal interface IKeyBindingHandlerCollaborators
{
    /// <summary>
    /// Forwards a tracked <c>river_xkb_binding_v1</c> event to
    /// the existing <c>OnKeyBindingEvent(IntPtr, uint, WlArgument*)</c>
    /// partial body.
    /// </summary>
    unsafe void HandleKeyBindingEvent(IntPtr target, uint opcode, WlArgument* args);
}
