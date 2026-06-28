namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Cancels any in-flight focus-follows-mouse delayed pointer-focus. A tiny seam implemented by
/// <see cref="SeatInteractionService"/> so the window-close path (which must not depend on the whole
/// seat service) can sever the focus-follows-mouse delayed-apply ↔ window-closed collision directly.
/// <para>
/// Pump-thread only.
/// </para>
/// </summary>
internal interface IPointerFocusCanceller
{
    /// <summary>
    /// Cancel any pending (delayed) focus-follows-mouse focus change. No-op when none is in flight.
    /// </summary>
    void CancelPendingPointerFocus();
}
