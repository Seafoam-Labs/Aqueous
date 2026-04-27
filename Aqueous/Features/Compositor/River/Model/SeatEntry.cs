using System;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Per-seat state mirrored from <c>river_seat_v1</c> events. Promoted
/// out of the nested-class declaration inside
/// <see cref="RiverWindowManagerClient"/> during the Phase 2
/// readability refactor — semantics are unchanged.
/// </summary>
internal sealed class SeatEntry
{
    public IntPtr Proxy;
    public uint WlSeatName;
}
