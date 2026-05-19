using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Features.Compositor.River.Focus;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 4 of the <see cref="RiverWindowManagerClient"/> decomposition:
/// the focus-related behaviour has moved into
/// <see cref="Aqueous.Features.Focus.FocusService"/>, accessed via
/// <see cref="IFocusService"/>. This partial now holds two things:
///
/// <list type="number">
/// <item>The explicit implementation of
/// <see cref="IFocusServiceCollaborators"/> — the transient bridge
/// that lets <c>FocusService</c> read/write the god class's
/// <c>_focusedWindow</c> / <c>_pendingFocus*</c> fields and call back
/// into the still-entangled manage-cycle and layout helpers. Each
/// member is XML-doc'd in the interface with the stage that retires
/// it.</item>
/// <item>Thin instance-method wrappers (<c>RequestFocus</c>,
/// <c>ClearFocus</c>, <c>CycleFocus</c>, etc.) that forward to
/// <c>_focusService</c>. The wrappers exist solely so the
/// not-yet-extracted partials (Seat/Window/Manager event handlers,
/// LayoutProposer, WindowStateHost, CustomActionRunner) keep
/// compiling unchanged. Each wrapper disappears when its caller is
/// extracted in Stage 8.</item>
/// </list>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient : IFocusServiceCollaborators
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

    // -- IFocusServiceCollaborators (explicit) -------------------------

    IntPtr IFocusServiceCollaborators.FocusedWindow
    {
        get => _focusedWindow;
        set => _focusedWindow = value;
    }

    IntPtr IFocusServiceCollaborators.PrimarySeat => _primarySeat;

    IEnumerable<IntPtr> IFocusServiceCollaborators.SeatProxies => _seatRegistry.Entries.Keys;

    IntPtr IFocusServiceCollaborators.PendingFocusWindow => _pendingFocusWindow;

    IntPtr IFocusServiceCollaborators.PendingFocusShellSurface => _pendingFocusShellSurface;

    void IFocusServiceCollaborators.SetPendingFocusWindow(IntPtr windowProxy, IntPtr seatProxy)
    {
        _pendingFocusWindow = windowProxy;
        _pendingFocusShellSurface = IntPtr.Zero;
        _pendingFocusSeat = seatProxy;
    }

    void IFocusServiceCollaborators.SetPendingFocusShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
    {
        _pendingFocusShellSurface = shellSurfaceProxy;
        _pendingFocusWindow = IntPtr.Zero;
        _pendingFocusSeat = seatProxy;
    }

    void IFocusServiceCollaborators.ScheduleManage() => ScheduleManage();

    void IFocusServiceCollaborators.SendClearFocus(IntPtr seatProxy)
    {
        WaylandInterop.wl_proxy_marshal_flags(seatProxy, 3, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    string? IFocusServiceCollaborators.ResolveOutputName(IntPtr outputProxy) =>
        ResolveOutputName(outputProxy);

    IReadOnlyList<WindowEntryView> IFocusServiceCollaborators.BuildSnapshotFor(IntPtr outputProxy) =>
        BuildSnapshotFor(outputProxy);

    IntPtr? IFocusServiceCollaborators.LayoutFocusNeighbor(
        IntPtr output, string? outputName, IntPtr current, FocusDirection dir, IReadOnlyList<WindowEntryView> snapshot) =>
        _layoutController.FocusNeighbor(output, outputName, current, dir, snapshot);

    void IFocusServiceCollaborators.Log(string message) => Log(message);
}
