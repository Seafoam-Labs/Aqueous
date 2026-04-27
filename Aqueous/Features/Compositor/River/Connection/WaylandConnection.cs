using System;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Owns the lifetime of a single <c>wl_display</c> connection plus the
/// thin set of <c>libwayland-client</c> calls that operate on it
/// (connect / disconnect / dispatch / roundtrip / flush / file
/// descriptor). Higher layers should treat this class as the only place
/// where raw <c>wl_display</c> pointers are created or destroyed.
/// </summary>
/// <remarks>
/// This type is intentionally state-only: it does not manage the
/// registry, the dispatcher callback, or the pump thread. Those concerns
/// live in <see cref="Aqueous.Features.Compositor.River.RiverWindowManagerClient"/>
/// (registry / dispatcher) and <see cref="EventPump"/> (pump thread).
/// </remarks>
internal sealed class WaylandConnection : IDisposable
{
    /// <summary>
    /// The native <c>wl_display*</c>, or <see cref="IntPtr.Zero"/> when
    /// no connection is currently held.
    /// </summary>
    public IntPtr Display { get; private set; }

    /// <summary>
    /// True iff <see cref="Display"/> is non-null.
    /// </summary>
    public bool IsConnected => Display != IntPtr.Zero;

    /// <summary>
    /// Opens a connection to the default Wayland display
    /// (<c>WAYLAND_DISPLAY</c> environment variable). Returns
    /// <see langword="true"/> on success; on failure the connection
    /// remains closed and <see cref="Display"/> stays
    /// <see cref="IntPtr.Zero"/>.
    /// </summary>
    public bool Connect()
    {
        if (Display != IntPtr.Zero)
        {
            return true;
        }

        Display = WaylandInterop.wl_display_connect(IntPtr.Zero);
        return Display != IntPtr.Zero;
    }

    /// <summary>
    /// Calls <c>wl_display_roundtrip</c>, blocking until the server has
    /// processed all requests sent so far and any resulting events have
    /// been delivered to our dispatcher. No-op when not connected.
    /// </summary>
    public int Roundtrip()
    {
        return Display == IntPtr.Zero
            ? -1
            : WaylandInterop.wl_display_roundtrip(Display);
    }

    /// <summary>
    /// Calls <c>wl_display_dispatch</c> once. Used by the pump thread.
    /// Returns the libwayland status code (negative on error).
    /// </summary>
    public int Dispatch()
    {
        return Display == IntPtr.Zero
            ? -1
            : WaylandInterop.wl_display_dispatch(Display);
    }

    /// <summary>
    /// Closes the connection if one is open. Safe to call multiple
    /// times; subsequent calls are no-ops.
    /// </summary>
    public void Disconnect()
    {
        if (Display == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_display_disconnect(Display);
        Display = IntPtr.Zero;
    }

    /// <inheritdoc cref="Disconnect"/>
    public void Dispose() => Disconnect();
}
