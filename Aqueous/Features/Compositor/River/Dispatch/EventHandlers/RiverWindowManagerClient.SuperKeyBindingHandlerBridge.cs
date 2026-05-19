using System;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

namespace Aqueous.Features.Compositor.River;

// PR 8.6 of the Stage 8 native-callback rewrite — transient bridge between
// the managed SuperKeyBindingEventHandler and the original partial
// OnSuperKeyBindingEvent body on this god class. Retired in Stage 9.
internal sealed unsafe partial class RiverWindowManagerClient : ISuperKeyBindingHandlerCollaborators
{
    void ISuperKeyBindingHandlerCollaborators.HandleByPartial(uint opcode, WlArgument* args)
        => OnSuperKeyBindingEvent(opcode, args);
}
