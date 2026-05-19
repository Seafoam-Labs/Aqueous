using System;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

namespace Aqueous.Features.Compositor.River;

internal sealed unsafe partial class RiverWindowManagerClient : IDragPointerBindingHandlerCollaborators
{
    void IDragPointerBindingHandlerCollaborators.HandleByPartial(IntPtr target, uint opcode, WlArgument* args)
        => OnDragPointerBindingEvent(target, opcode, args);
}
