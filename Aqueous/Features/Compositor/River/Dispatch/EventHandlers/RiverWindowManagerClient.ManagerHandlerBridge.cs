using System;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 8.5 transient bridge — explicit-interface impl forwarding the
/// managed <see cref="ManagerEventHandler"/> back to the original
/// partial <c>OnManagerEvent</c> body so every opcode remains
/// byte-for-byte equivalent during the staged rollout.
///
/// Once individual opcodes graduate through the
/// <c>ProxyDispatcher</c> <c>routeManaged</c> allowlist they will be
/// re-implemented inline on <see cref="ManagerEventHandler"/> with
/// proper service dependencies, shrinking this bridge call site by
/// call site. Stage 9 retires the bridge entirely along with the
/// god-class state it currently reaches into.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient : IManagerHandlerCollaborators
{
    void IManagerHandlerCollaborators.HandleByPartial(uint opcode, WlArgument* args)
    {
        // Pass-through to the byte-for-byte original OnManagerEvent body.
        // The partial owns every god-class private field that the
        // manager opcodes mutate (registries, focus, tags, layout,
        // snap-zones, manage-sequence flag, pump lifecycle, etc.).
        OnManagerEvent(opcode, args);
    }
}
