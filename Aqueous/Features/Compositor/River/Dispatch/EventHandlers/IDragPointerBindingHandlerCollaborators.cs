using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.7 transient bridge between the managed
/// <c>DragPointerBindingEventHandler</c> and the unlifted
/// <c>RiverWindowManagerClient.OnDragPointerBindingEvent</c> partial.
///
/// <para>Implemented by <c>RiverWindowManagerClient</c>. Retired in Stage 9
/// when the partial body finally migrates into the managed handler.</para>
/// </summary>
internal interface IDragPointerBindingHandlerCollaborators
{
    /// <summary>Forward to the existing partial OnDragPointerBindingEvent.
    /// -> retired Stage 9.</summary>
    unsafe void HandleByPartial(IntPtr target, uint opcode, WlArgument* args);
}
