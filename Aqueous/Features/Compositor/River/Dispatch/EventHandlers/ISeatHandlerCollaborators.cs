using System;
namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.3 transient bridge — exposes the slice of god-class state that
/// the lifted <see cref="SeatEventHandler"/> needs to drive the
/// <c>river_seat_v1</c> event sequence (pointer enter/leave/op-delta/
/// op-release/window-interaction/shell-surface-interaction).
///
/// The OpDelta + OpRelease bodies and the sloppy-focus path inside
/// PointerEnter are bridged as whole-body delegates (`HandleOpDelta`,
/// `HandleOpRelease`, `HandlePointerEnterFocusFollow`) because they
/// touch ~10 god-class privates — `_activeDragWindow`, `_dragEdges`,
/// `_dragStartX/Y/W/H`, `_dragFinished`, `_layoutConfig`, `IsFloatLayoutActive`,
/// `ScheduleManage`, plus the snap-zone preview pipeline. Lifting them
/// inline would require draining all of those across the bridge for
/// zero behavioural benefit at this stage.
///
/// Each member is XML-doc'd with the stage that retires it. Implemented
/// only by <c>RiverWindowManagerClient</c>; will be deleted in Stage 9
/// when the god class collapses.
/// </summary>
internal interface ISeatHandlerCollaborators
{
    /// <summary>Forward the seat-interaction (window-focus request) path. -> retired in Stage 9.</summary>
    void HandleWindowInteraction(IntPtr window, IntPtr seat);

    /// <summary>Forward the seat-interaction (shell-surface-focus request) path. -> retired in Stage 9.</summary>
    void HandleShellSurfaceInteraction(IntPtr shellSurface, IntPtr seat);

    /// <summary>Sloppy-focus follow-the-mouse on pointer_enter; gates on FocusFollowsMouse + window-known + window-differs. -> retired in Stage 9.</summary>
    void HandlePointerEnterFocusFollow(IntPtr hoveredWindow, IntPtr seat);

    /// <summary>Whole OpDelta body — interactive move/resize, snap-preview, drag teardown. -> retired in Stage 9.</summary>
    void HandleOpDelta(IntPtr seat, int dx, int dy);

    /// <summary>Whole OpRelease body — snap-to-zone finalisation + drag teardown. -> retired in Stage 9.</summary>
    void HandleOpRelease(IntPtr seat);

    /// <summary>
    /// Cache the latest pointer position per seat. Routed through the
    /// bridge (not written directly by the managed handler) to guarantee
    /// byte-for-byte equivalence with the pre-PR-8.3 path that drives the
    /// snap-zone read in <c>RiverWindowManagerClient.SnapZones.cs</c>.
    /// -> retired in Stage 9 when <c>_seatPointerPos</c> moves onto a
    /// dedicated pointer-state service.
    /// </summary>
    void CachePointerPosition(IntPtr seat, int x, int y);
}
