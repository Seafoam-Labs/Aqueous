using System;
using System.Threading;

namespace Aqueous.Features.Focus;

/// <summary>
/// PR 9.12 §2.13 Step 1 — singleton holding the pending-focus
/// triple previously living on <c>RiverWindowManagerClient</c>
/// (<c>_pendingFocusWindow</c>, <c>_pendingFocusShellSurface</c>,
/// <c>_pendingFocusSeat</c>). Consumed by <see cref="FocusService"/>,
/// <c>ManagerEventService</c>, and <c>WindowEventService</c>.
///
/// <para>
/// Set by the focus path (window or shell-surface request), drained
/// by the manage cycle when river accepts the focus marshal.
/// Pump-thread only; raw <see cref="IntPtr"/> volatile read/write
/// matches the previous field semantics on the god class.
/// </para>
/// </summary>
internal sealed class PendingFocusStore
{
    private IntPtr _window;
    private IntPtr _shellSurface;
    private IntPtr _seat;

    public IntPtr Window
    {
        get => Volatile.Read(ref _window);
        set => Volatile.Write(ref _window, value);
    }

    public IntPtr ShellSurface
    {
        get => Volatile.Read(ref _shellSurface);
        set => Volatile.Write(ref _shellSurface, value);
    }

    public IntPtr Seat
    {
        get => Volatile.Read(ref _seat);
        set => Volatile.Write(ref _seat, value);
    }

    /// <summary>
    /// Queue a pending window-focus and clear any pending shell-surface
    /// focus. Mirrors the previous <c>SetPendingFocusWindow</c> on the
    /// god class byte-for-byte.
    /// </summary>
    public void SetWindow(IntPtr windowProxy, IntPtr seatProxy)
    {
        Window = windowProxy;
        ShellSurface = IntPtr.Zero;
        Seat = seatProxy;
    }

    /// <summary>
    /// Queue a pending shell-surface focus and clear any pending window
    /// focus. Mirrors the previous <c>SetPendingFocusShellSurface</c> on
    /// the god class byte-for-byte.
    /// </summary>
    public void SetShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
    {
        ShellSurface = shellSurfaceProxy;
        Window = IntPtr.Zero;
        Seat = seatProxy;
    }

    /// <summary>
    /// Clear all three slots. Used by the manage cycle after the
    /// focus marshal is dispatched.
    /// </summary>
    public void Clear()
    {
        Window = IntPtr.Zero;
        ShellSurface = IntPtr.Zero;
        Seat = IntPtr.Zero;
    }
}
