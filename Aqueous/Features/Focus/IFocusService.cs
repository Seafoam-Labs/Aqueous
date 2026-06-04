using System;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Focus;

/// <summary>
/// Of the <c>RiverWindowManagerClient</c> decomposition: the focus subsystem behind a single seam.
/// Owns the keyboard-focus behaviour.
/// <para>
/// Single-seat by design — the existing god class only models a "primary seat" focus; multi-seat
/// awaits a post-Stage-9
/// </para>
/// <para>
/// All members are pump-thread-only: they either marshal Wayland requests on the focused seat or
/// read/write registry entries that are pump-thread-owned for Wayland-visible state.
/// </para>
/// </summary>
public interface IFocusService
{
    /// <summary>
    /// Currently keyboard-focused window proxy, or <see cref="IntPtr.Zero"/> if none. Tracks the same
    /// field <c>_focusedWindow</c> historically owned by the god class — reads are routed through the
    /// transient collaborator until collapses the god class.
    /// </summary>
    IntPtr FocusedWindow { get; }

    /// <summary>
    /// Self-heal: true and yield the focused window proxy only if it is still tracked in the window
    /// registry. Clears the stale focused-window handle as a side effect when the underlying proxy has
    /// already been destroyed.
    /// </summary>
    bool TryGetFocusedAlive(out IntPtr proxy);

    /// <summary>
    /// Mark <paramref name="windowProxy"/> as the next focus target on <paramref name="seatProxy"/>
    /// and schedule a manage cycle to flush the focus request. Idempotent: no-ops when the same focus
    /// is already applied or pending.
    /// </summary>
    void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy);

    /// <summary>
    /// Request focus on <paramref name="windowProxy"/> via the primary seat (or the first available
    /// seat). No-op for an unknown or zero window proxy.
    /// </summary>
    void RequestFocus(IntPtr windowProxy);

    /// <summary>
    /// Clear focus on the primary seat (river_seat_v1::clear_focus).
    /// </summary>
    void ClearFocus();

    /// <summary>
    /// Pick any window (prefer not <paramref name="avoid"/>) and focus it. <see cref="ClearFocus"/> if
    /// empty.
    /// </summary>
    void FocusAnyOtherWindow(IntPtr avoid);

    /// <summary>
    /// Advance keyboard focus to the next window in registry iteration order.
    /// </summary>
    void CycleFocus();

    /// <summary>
    /// Handle a directional focus key — delegates to the layout engine, falling back to <see
    /// cref="CycleFocus"/>.
    /// </summary>
    void HandleDirectionalFocus(FocusDirection dir);

    /// <summary>
    /// Mark <paramref name="shellSurfaceProxy"/> as the next layer-shell focus target.
    /// </summary>
    void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy);

    /// <summary>
    /// Invalidate a <c>river_shell_surface_v1</c> proxy that the compositor has reported as destroyed
    /// (via the <c>river_shell_surface_v1::destroyed</c> event). Drops its liveness and clears any
    /// pending focus that still targets it so the manage cycle can never marshal
    /// <c>focus_shell_surface</c> on the freed proxy (the "segfault at 2c" crash).
    /// </summary>
    void InvalidateShellSurface(IntPtr shellSurfaceProxy);

    /// <summary>
    /// Self-heal focus when the previously-focused window has just become invisible because of a tag
    /// change. Picks the first visible window on the focused output, else any visible window, else
    /// clears focus.
    /// </summary>
    void RepairFocusAfterTagChange();

    /// <summary>
    /// Forcibly clear the <c>FocusedWindow</c> handle without generating a Wayland clear_focus
    /// request. Used by the window destruction handler when the focused window has just been destroyed
    /// server-side and the protocol would treat a stale focus request as fatal.
    /// </summary>
    void ClearFocusedHandle();
}
