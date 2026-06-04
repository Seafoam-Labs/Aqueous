using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Aqueous.Features.Focus;

/// <summary>
/// Singleton holding the pending-focus triple. Consumed by <see cref="FocusService"/>,
/// <c>ManagerEventService</c>, and <c>WindowEventService</c>.
/// <para>
/// Set by the focus path (window or shell-surface request), drained by the manage cycle when river
/// accepts the focus marshal. Pump-thread only; raw <see cref="IntPtr"/> volatile read/write
/// matches the previous field semantics on the god class.
/// </para>
/// </summary>
internal sealed class PendingFocusStore
{
    private IntPtr _window;
    private IntPtr _shellSurface;
    private IntPtr _seat;

    // Liveness tracking for shell-surface focus proxies. A <c>river_shell_surface_v1</c> proxy is
    // only known to be alive between the moment its <c>shell_surface_interaction</c> event arrives
    // (<see cref="MarkShellSurfaceLive"/>) and the moment it is superseded (window focus / clear) or
    // consumed by the manage cycle (<see cref="ForgetShellSurface"/>). The manage-cycle drain gates
    // the <c>focus_shell_surface</c> marshal on <see cref="IsShellSurfaceLive"/> so it never
    // marshals on a stale/freed proxy — mirroring the <c>_windowRegistry.ContainsKey</c> guard the
    // window-focus branch already uses. Keyed by raw proxy; value byte is unused.
    private readonly ConcurrentDictionary<IntPtr, byte> _liveShellSurfaces = new();

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
    /// Queue a pending window-focus and clear any pending shell-surface focus. Mirrors the previous
    /// <c>SetPendingFocusWindow</c> on the god class byte-for-byte.
    /// </summary>
    public void SetWindow(IntPtr windowProxy, IntPtr seatProxy)
    {
        IntPtr superseded = ShellSurface;
        Window = windowProxy;
        ShellSurface = IntPtr.Zero;
        Seat = seatProxy;
        // The shell surface is no longer the focus target; drop its liveness so a later drain can
        // never resurrect it.
        if (superseded != IntPtr.Zero)
        {
            ForgetShellSurface(superseded);
        }
    }

    /// <summary>
    /// Queue a pending shell-surface focus and clear any pending window focus. Mirrors the previous
    /// <c>SetPendingFocusShellSurface</c> on the god class byte-for-byte.
    /// </summary>
    public void SetShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
    {
        ShellSurface = shellSurfaceProxy;
        Window = IntPtr.Zero;
        Seat = seatProxy;
        if (shellSurfaceProxy != IntPtr.Zero)
        {
            MarkShellSurfaceLive(shellSurfaceProxy);
        }
    }

    /// <summary>
    /// Clear all three slots. Used by the manage cycle after the focus marshal is dispatched.
    /// </summary>
    public void Clear()
    {
        IntPtr superseded = ShellSurface;
        Window = IntPtr.Zero;
        ShellSurface = IntPtr.Zero;
        Seat = IntPtr.Zero;
        if (superseded != IntPtr.Zero)
        {
            ForgetShellSurface(superseded);
        }
    }

    /// <summary>
    /// Record that a <c>river_shell_surface_v1</c> proxy is currently alive. Called from the
    /// <c>shell_surface_interaction</c> path where the proxy is guaranteed valid.
    /// </summary>
    public void MarkShellSurfaceLive(IntPtr shellSurfaceProxy)
    {
        if (shellSurfaceProxy != IntPtr.Zero)
        {
            _liveShellSurfaces[shellSurfaceProxy] = 0;
        }
    }

    /// <summary>
    /// Drop a shell-surface proxy from the liveness set. Called when the focus is superseded /
    /// cleared or after the manage cycle has consumed (marshaled) it.
    /// </summary>
    public void ForgetShellSurface(IntPtr shellSurfaceProxy)
    {
        _liveShellSurfaces.TryRemove(shellSurfaceProxy, out _);
    }

    /// <summary>
    /// <c>true</c> when the given shell-surface proxy is still known to be alive and therefore safe
    /// to marshal <c>focus_shell_surface</c> on.
    /// </summary>
    public bool IsShellSurfaceLive(IntPtr shellSurfaceProxy)
    {
        return shellSurfaceProxy != IntPtr.Zero && _liveShellSurfaces.ContainsKey(shellSurfaceProxy);
    }
}
