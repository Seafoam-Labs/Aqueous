using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.4 transient collaborator bridge — bridges the lifted
/// <see cref="WindowEventHandler"/> back into the still-coupled
/// god-class state for opcodes that mutate per-window WM state
/// (`_windowStates`, `_outputFullscreen`, `_prevFullscreenHandles`,
/// `_activeDrag*`, `_dragStart*`, `_pendingFocusWindow`,
/// `_seatHoveredWindow`, `_seatPointerPos`, `_focusedWindow`) plus
/// the helpers <c>FocusAnyOtherWindow</c>, <c>RequestFocus</c>,
/// <c>ScheduleManage</c>, <c>IsFloatLayoutActive</c>,
/// <c>MarshalUtf8</c>, and <c>Log</c>.
///
/// Implemented explicitly by <c>RiverWindowManagerClient</c>. Retires
/// in Stage 9 when the relevant state moves off the god class onto
/// dedicated services (focus, drag, window-state-host, layout).
///
/// PR 8.4 follows the staged-rollout pattern established by PR 8.3
/// (`SeatEventHandler.Managed.cs`): the managed handler is wired into
/// <c>IEventDispatcher</c> but <see cref="ProxyDispatcher"/> keeps the
/// window branch on the original partial <c>OnWindowEvent</c> until
/// individual opcodes are proven equivalent — see the
/// <c>routeManaged</c> allowlist in <c>ProxyDispatcher.cs</c>.
/// </summary>
internal interface IWindowHandlerCollaborators
{
    /// <summary>
    /// Pass-through to the original partial <c>OnWindowEvent</c> body.
    /// Used as the single bridge entry while every window opcode is
    /// still gated behind the rollout allowlist. As opcodes graduate
    /// to the managed handler, this method's caller list shrinks; when
    /// the allowlist covers every opcode, this method retires.
    /// </summary>
    unsafe void HandleByPartial(IntPtr window, uint opcode, WlArgument* args);
}
