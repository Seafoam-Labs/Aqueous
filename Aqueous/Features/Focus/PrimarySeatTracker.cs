using System;
using System.Threading;

namespace Aqueous.Features.Focus;

/// <summary>
/// Singleton holding the raw <see cref="IntPtr"/> of the primary seat's <c>wl_seat</c> proxy
/// (formerly <c>RiverWindowManagerClient._primarySeat</c>). Pinned at the first
/// <c>SeatInformation</c> event after registry binding; used by the focus path to resolve which
/// seat to address when no explicit seat is supplied.
/// </summary>
internal sealed class PrimarySeatTracker
{
    private IntPtr _current;

    public IntPtr Current
    {
        get => Volatile.Read(ref _current);
        set => Volatile.Write(ref _current, value);
    }
}
