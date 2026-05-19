using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River.Focus;

/// <summary>
/// Transient collaborator bridge for <see cref="Aqueous.Features.Focus.FocusService"/>.
///
/// <para>
/// Each member is a temporary hook back into <see cref="RiverWindowManagerClient"/>
/// to be retired by a later decomposition stage. The XML-doc on each
/// member names the stage that deletes it. When the last member is
/// gone, this interface itself goes away.
/// </para>
///
/// <para>
/// Single-implementation by design: only <see cref="RiverWindowManagerClient"/>
/// implements it explicitly. Tests fake this interface directly.
/// </para>
/// </summary>
internal interface IFocusServiceCollaborators
{
    /// <summary>
    /// Backing storage for <c>_focusedWindow</c> on the god class. Get/set
    /// by <see cref="Aqueous.Features.Focus.FocusService"/>.
    /// -> retired in Stage 9 (FocusService owns the field outright once
    /// the god class disappears).
    /// </summary>
    IntPtr FocusedWindow { get; set; }

    /// <summary>The primary <c>wl_seat</c> proxy, or <see cref="IntPtr.Zero"/>. -> retired in Stage 9.</summary>
    IntPtr PrimarySeat { get; }

    /// <summary>Enumerates known seats (used as a fallback when there is no primary). -> retired in Stage 9.</summary>
    IEnumerable<IntPtr> SeatProxies { get; }

    /// <summary>Updates the pending-focus fields used by the manage_start flush. -> retired in Stage 5 (IManagerRequestSender owns flushing).</summary>
    void SetPendingFocusWindow(IntPtr windowProxy, IntPtr seatProxy);

    /// <summary>Updates the pending-focus fields for a layer-shell surface. -> retired in Stage 5.</summary>
    void SetPendingFocusShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy);

    /// <summary>Reads the pending-focus-window field (used by the same-focus short-circuit). -> retired in Stage 5.</summary>
    IntPtr PendingFocusWindow { get; }

    /// <summary>Reads the pending-focus-shell-surface field. -> retired in Stage 5.</summary>
    IntPtr PendingFocusShellSurface { get; }

    /// <summary>Schedule a manage cycle so the layout engine re-runs. -> retired in Stage 5 (LayoutProposer subscribes to FocusedWindowChanged).</summary>
    void ScheduleManage();

    /// <summary>Send river_seat_v1::clear_focus (opcode 3) on the given seat. -> retired in Stage 5 (IManagerRequestSender).</summary>
    void SendClearFocus(IntPtr seatProxy);

    /// <summary>
    /// Resolves an output proxy to its name (used by the layout engine when
    /// computing directional focus). -> retired in Stage 5 (IOutputGeometry).
    /// </summary>
    string? ResolveOutputName(IntPtr outputProxy);

    /// <summary>
    /// Builds the per-output window snapshot consumed by the layout
    /// engine's <c>FocusNeighbor</c>. -> retired in Stage 5 (LayoutProposer
    /// owns snapshot construction).
    /// </summary>
    IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr outputProxy);

    /// <summary>
    /// Delegates to <c>LayoutController.FocusNeighbor</c>; returns the next
    /// window to focus or <c>null</c> if the engine has no preference.
    /// -> retired in Stage 5 (FocusService injects ILayoutProposer).
    /// </summary>
    IntPtr? LayoutFocusNeighbor(IntPtr output, string? outputName, IntPtr current, FocusDirection dir, IReadOnlyList<WindowEntryView> snapshot);

    /// <summary>Diagnostic log hook. -> retired in Stage 9 (FocusService takes ILogger).</summary>
    void Log(string message);
}
