using System;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 8.4 transient bridge — explicit-interface impl forwarding the
/// managed <see cref="WindowEventHandler"/> back to the original
/// partial <c>OnWindowEvent</c> body so every opcode remains
/// byte-for-byte equivalent during the staged rollout.
///
/// Once individual opcodes graduate through the
/// <c>ProxyDispatcher</c> <c>routeManaged</c> allowlist they will be
/// re-implemented inline on <see cref="WindowEventHandler"/> with
/// proper service dependencies, shrinking this bridge call site by
/// call site. Stage 9 retires the bridge entirely along with the
/// god-class state it currently reaches into.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient : IWindowHandlerCollaborators
{
    void IWindowHandlerCollaborators.HandleByPartial(IntPtr window, uint opcode, WlArgument* args)
    {
        // Pass-through to the byte-for-byte original OnWindowEvent body.
        // The partial owns every god-class private field that the
        // window opcodes mutate (drag, fullscreen, pending-focus,
        // _windowStates, _outputFullscreen, _prevFullscreenHandles,
        // _seatHoveredWindow, _focusedWindow, _activeDrag*).
        OnWindowEvent(window, opcode, args);
    }
}
