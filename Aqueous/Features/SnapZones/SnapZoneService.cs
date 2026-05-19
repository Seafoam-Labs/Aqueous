using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// Stage 6 Part 1 facade over <c>RiverWindowManagerClient.SnapZones</c>.
/// PR 9.5 (Stage 9) retired the <c>ISnapZoneServiceCollaborators</c>
/// bridge; the service now consumes <see cref="RiverWindowManagerClient"/>
/// directly via the <c>HandleApplyLiveSnapPreview</c> /
/// <c>HandleTrySnapDraggedWindowToZone</c> / <c>HandleCollectAllSnapLayouts</c>
/// pass-through accessors (same pattern PR 9.3/9.4 established).
/// </summary>
internal sealed class SnapZoneService : ISnapZoneService
{
    private readonly RiverWindowManagerClient _client;

    public SnapZoneService(RiverWindowManagerClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    public void ApplyLiveSnapPreview(IntPtr seat) =>
        _client.HandleApplyLiveSnapPreview(seat);

    public void TrySnapDraggedWindowToZone(IntPtr seat) =>
        _client.HandleTrySnapDraggedWindowToZone(seat);

    public IEnumerable<IReadOnlyList<SnapZoneLayout>> CollectAllSnapLayouts() =>
        _client.HandleCollectAllSnapLayouts();

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
