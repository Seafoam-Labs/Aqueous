using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.SnapZones;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// Stage 6 Part 1 facade over <c>RiverWindowManagerClient.SnapZones</c>.
/// Thin delegate: every member forwards to
/// <see cref="ISnapZoneServiceCollaborators"/>. The literal lift of
/// drag state happens in Stage 8 when the seat drag pipeline is
/// itself extracted; until then this seam exists so handler call
/// sites can depend on the service interface instead of god-class
/// privates.
/// </summary>
internal sealed class SnapZoneService : ISnapZoneService
{
    private readonly ISnapZoneServiceCollaborators _river;

    public SnapZoneService(ISnapZoneServiceCollaborators river)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
    }

    public void ApplyLiveSnapPreview(IntPtr seat) =>
        _river.ApplyLiveSnapPreviewImpl(seat);

    public void TrySnapDraggedWindowToZone(IntPtr seat) =>
        _river.TrySnapDraggedWindowToZoneImpl(seat);

    public IEnumerable<IReadOnlyList<SnapZoneLayout>> CollectAllSnapLayouts() =>
        _river.CollectAllSnapLayoutsImpl();

    /// <summary>
    /// Pure mapping; no god-class dependency. Identical to the
    /// previous <c>ActivatorToMask</c> private static.
    /// </summary>
    public uint ActivatorToMask(SnapActivator activator) => activator switch
    {
        SnapActivator.Shift => Mods.ModShift,
        SnapActivator.Ctrl  => Mods.ModCtrl,
        SnapActivator.Alt   => Mods.ModAlt,
        SnapActivator.Super => Mods.ModSuper,
        _ => 0u,
    };
}
