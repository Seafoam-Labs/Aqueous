using System;
using System.Collections.Generic;
using Aqueous.Features.SnapZones;

namespace Aqueous.Features.Compositor.River.SnapZones;

/// <summary>
/// Stage 6 Part 1 transient bridge: <c>SnapZoneService</c> calls back
/// into <c>RiverWindowManagerClient</c> for the four operations that
/// still live on the god class (drag-state read/write + the
/// pre-existing private helpers that wrap them). Implemented
/// explicitly by <c>RiverWindowManagerClient</c>; deleted in Stage 8
/// when the seat drag pipeline + ResolveOutputName + ScheduleManage
/// each have their own home.
/// </summary>
/// <remarks>
/// Pump-thread only. Members documented with the stage that retires
/// them, mirroring the Stage 2/3/4/5 bridge convention.
/// </remarks>
internal interface ISnapZoneServiceCollaborators
{
    /// <summary>
    /// Drives the existing private <c>ApplyLiveSnapPreview</c> on the
    /// god class. -> retired in Stage 8 (seat drag pipeline lifts out).
    /// </summary>
    void ApplyLiveSnapPreviewImpl(IntPtr seat);

    /// <summary>
    /// Drives the existing private <c>TrySnapDraggedWindowToZone</c>
    /// on the god class. -> retired in Stage 8.
    /// </summary>
    void TrySnapDraggedWindowToZoneImpl(IntPtr seat);

    /// <summary>
    /// Drives the existing private <c>CollectAllSnapLayouts</c> on
    /// the god class. -> retired in Stage 8 (snap zone store + output
    /// registry move into the service once <c>ResolveOutputName</c>
    /// is gone).
    /// </summary>
    IEnumerable<IReadOnlyList<SnapZoneLayout>> CollectAllSnapLayoutsImpl();
}
