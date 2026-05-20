using System;
using System.Collections.Generic;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// Part 1 seam over the river-window-management snap-zone integration. Lifts the four entry points
/// the rest of the river dispatcher uses to talk to the snap-zone pipeline, so handlers
/// (Seat/Manager/DragPointerBinding) can stop referencing private methods on
/// <c>RiverWindowManagerClient</c>.
/// </summary>
/// <remarks>
/// Pump-thread only. The implementation is a thin facade over the existing
/// <c>RiverWindowManagerClient.SnapZones</c> partial via <c>ISnapZoneServiceCollaborators</c>; the
/// literal lift of drag state (`_activeDragWindow`, `_seatPointerPos`, `_dragLastSnapZone`,
/// `_activeDragActivator`) is deferred until when the seat drag pipeline is itself extracted.
/// </remarks>
public interface ISnapZoneService
{
    /// <summary>
    /// Live drag-preview hook called per-OpDelta sample while a move-drag is in flight. When the
    /// pointer is over a snap zone, overwrites the dragged window's Float* rect so the next manage
    /// cycle commits the snapped geometry; emits a single log line per zone transition.
    /// </summary>
    void ApplyLiveSnapPreview(IntPtr seat);

    /// <summary>
    /// Apply-on-release hook called from SeatEventHandler when the drag's pointer button releases.
    /// Resolves the snap zone (if any), commits the resulting rect onto the drag window, and schedules
    /// a manage cycle.
    /// </summary>
    void TrySnapDraggedWindowToZone(IntPtr seat);

    /// <summary>
    /// Enumerates every distinct <see cref="SnapZoneLayout"/> the store knows about, grouped by
    /// output. ManagerEventHandler uses this at seat-info time to discover the activator modifiers
    /// that need their own pointer bindings registered.
    /// </summary>
    IEnumerable<IReadOnlyList<SnapZoneLayout>> CollectAllSnapLayouts();

    /// <summary>
    /// Maps a <see cref="SnapActivator"/> to the river_seat_v1 modifier bitmask used when registering
    /// pointer bindings. Returns 0 for <see cref="SnapActivator.Always"/>.
    /// </summary>
    uint ActivatorToMask(SnapActivator activator);
}
