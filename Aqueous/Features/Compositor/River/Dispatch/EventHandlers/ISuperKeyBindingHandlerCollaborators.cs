using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Transient bridge for <see cref="SuperKeyBindingEventHandler"/> (PR 8.6 of
/// the Stage 8 native-callback rewrite). Currently delegates straight back to
/// the original partial <c>OnSuperKeyBindingEvent</c> body on
/// <c>RiverWindowManagerClient</c> so behaviour is byte-for-byte equivalent
/// regardless of whether the managed handler or the partial fires.
///
/// Retired in Stage 9 once the god class is collapsed and the handler owns
/// the dbus-send P/Invoke directly (or routes it through
/// <see cref="Aqueous.Features.Bindings.IProcessLauncher"/>).
/// </summary>
internal interface ISuperKeyBindingHandlerCollaborators
{
    /// <summary>
    /// Forward a super-key binding event to the original partial implementation.
    /// -> retired in Stage 9.
    /// </summary>
    unsafe void HandleByPartial(uint opcode, WlArgument* args);
}
