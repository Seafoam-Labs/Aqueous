using System;
using Aqueous.Features.Layout;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// A single snap target, defined in normalized [0.0, 1.0] output-local
/// coordinates so the same configuration survives resolution changes,
/// HiDPI scaling, and per-output usable-area variation. The rectangle
/// is resolved to integer pixels lazily by <see cref="SnapZoneLayout.Resolve"/>
/// at the moment a snap is committed.
///
/// SnapZones are KWin-KZones / FancyZones-style targets: a floating
/// window that is dropped over a zone snaps to that zone's resolved
/// rectangle. See <see cref="SnapZoneController"/> for the live
/// drag-end hook into the river-window-management pipeline.
/// </summary>
public readonly record struct SnapZone(
    string Name,
    double NX, double NY, double NW, double NH);
