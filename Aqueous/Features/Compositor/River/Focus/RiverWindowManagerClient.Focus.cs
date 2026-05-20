using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 4 of the <see cref="RiverWindowManagerClient"/> decomposition:
/// the focus-related behaviour has moved into
/// <see cref="Aqueous.Features.Focus.FocusService"/>, accessed via
/// <see cref="Aqueous.Features.Focus.IFocusService"/>.
///
/// <para>
/// Stage 9 PR 9.6: <c>IFocusServiceCollaborators</c> bridge retired.
/// The accessors below replace the prior explicit-interface bridge
/// methods 1-for-1, exposing god-class state directly so
/// <c>FocusService</c> can consume <c>RiverWindowManagerClient</c>
/// without an intermediary. They retire in Stage 9 final when the
/// god class collapses and the underlying fields move onto
/// <c>FocusService</c>.
/// </para>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    // -- Thin wrappers (call-site compatibility) -----------------------

    private bool TryGetFocusedAlive(out IntPtr proxy) => _focusService.TryGetFocusedAlive(out proxy);

    public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy) =>
        _focusService.SetFocusedWindow(windowProxy, seatProxy);

    private void RequestFocus(IntPtr windowProxy) =>
        _focusService.RequestFocus(windowProxy);

    private void ClearFocus() => _focusService.ClearFocus();

    private void FocusAnyOtherWindow(IntPtr avoid) =>
        _focusService.FocusAnyOtherWindow(avoid);

    private void CycleFocus() => _focusService.CycleFocus();

    private void HandleDirectionalFocus(FocusDirection dir) =>
        _focusService.HandleDirectionalFocus(dir);

    public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy) =>
        _focusService.SetFocusedShellSurface(shellSurfaceProxy, seatProxy);

    // -- Pass-through accessors (Stage 9 PR 9.6) -----------------------
    // Same surface the retired IFocusServiceCollaborators exposed, now
    // reachable directly from FocusService via the typed god-class ref.
    // -> retired in Stage 9 final (god-class collapse).

    internal IntPtr FocusedWindow
    {
        get => _focusedWindow;
        set => _focusedWindow = value;
    }

    internal IntPtr PrimarySeat => _primarySeat;

    internal IEnumerable<IntPtr> SeatProxies => _seatRegistry.Entries.Keys;

    internal IntPtr PendingFocusWindow => _pendingFocusWindow;

    internal IntPtr PendingFocusShellSurface => _pendingFocusShellSurface;

    internal void SetPendingFocusWindow(IntPtr windowProxy, IntPtr seatProxy)
    {
        _pendingFocusWindow = windowProxy;
        _pendingFocusShellSurface = IntPtr.Zero;
        _pendingFocusSeat = seatProxy;
    }

    internal void SetPendingFocusShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
    {
        _pendingFocusShellSurface = shellSurfaceProxy;
        _pendingFocusWindow = IntPtr.Zero;
        _pendingFocusSeat = seatProxy;
    }

    internal void SendClearFocus(IntPtr seatProxy)
    {
        WaylandInterop.wl_proxy_marshal_flags(seatProxy, 3, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }
}
