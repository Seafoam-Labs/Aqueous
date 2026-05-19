using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.5 transient collaborator bridge — bridges the lifted
/// <see cref="ManagerEventHandler"/> back into the still-coupled
/// god-class state for the <c>river_window_manager_v1</c> opcodes.
///
/// The manager event body touches a very large surface on
/// <c>RiverWindowManagerClient</c> (every registry, focus state,
/// tag/layout/snap-zone subsystems, manage-sequence flag, pump
/// lifecycle, foreign-toplevel emit, manager-request sender, every
/// bind-site IntPtr) so PR 8.5 ships pass-through-only and the
/// bridge retires in Stage 9 once the relevant state has moved off
/// the god class onto dedicated services.
///
/// Implemented explicitly by <c>RiverWindowManagerClient</c>.
/// </summary>
internal interface IManagerHandlerCollaborators
{
    /// <summary>
    /// Pass-through to the original partial <c>OnManagerEvent</c> body.
    /// Used as the single bridge entry while every manager opcode is
    /// still gated behind the rollout allowlist. As opcodes graduate
    /// to the managed handler, this method's caller list shrinks; when
    /// the allowlist covers every opcode, this method retires.
    /// </summary>
    unsafe void HandleByPartial(uint opcode, WlArgument* args);
}
