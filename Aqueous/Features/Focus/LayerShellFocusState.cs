using System;
using System.Collections.Concurrent;

namespace Aqueous.Features.Focus;

/// <summary>
/// Per-seat layer-shell focus mode, driven by the
/// <c>river_layer_shell_seat_v1::focus_exclusive</c>/<c>focus_non_exclusive</c>/<c>focus_none</c>
/// events. See <see cref="ILayerShellFocusState"/>.
/// </summary>
internal enum LayerFocusMode
{
    /// <summary>
    /// No layer surface wants keyboard focus on this seat. The WM owns focus normally.
    /// </summary>
    None = 0,

    /// <summary>
    /// A layer surface gets focus at the end of the current manage sequence, but the WM may still
    /// override it by focusing a window/shell-surface in the same sequence.
    /// </summary>
    NonExclusive = 1,

    /// <summary>
    /// A layer surface holds exclusive keyboard focus; the compositor ignores all WM focus-change
    /// requests for this seat until <see cref="LayerFocusMode.NonExclusive"/> or
    /// <see cref="LayerFocusMode.None"/> is signalled.
    /// </summary>
    Exclusive = 2,
}

/// <summary>
/// Tracks, per <c>river_seat_v1</c>, whether a layer surface currently wants keyboard focus and in
/// which mode. This is the behavioural core of the <c>river-layer-shell-v1</c> migration: the
/// compositor emits <c>focus_exclusive</c>/<c>focus_non_exclusive</c>/<c>focus_none</c> on the
/// per-seat <c>river_layer_shell_seat_v1</c> sub-object, and the WM must suppress its own
/// focus-change requests while a seat is in <see cref="LayerFocusMode.Exclusive"/> (the compositor
/// ignores them anyway; suppressing avoids spurious manage churn).
/// </summary>
internal interface ILayerShellFocusState
{
    /// <summary>
    /// Current layer-focus mode for the given <c>river_seat_v1</c>. Defaults to
    /// <see cref="LayerFocusMode.None"/> for unknown seats.
    /// </summary>
    LayerFocusMode ModeFor(IntPtr riverSeat);

    /// <summary>
    /// True when the seat is in <see cref="LayerFocusMode.Exclusive"/>, i.e. WM focus requests must
    /// be suppressed. Returns false for <see cref="IntPtr.Zero"/> and unknown seats.
    /// </summary>
    bool IsFocusLocked(IntPtr riverSeat);

    /// <summary>
    /// Records <c>focus_exclusive</c> for the seat.
    /// </summary>
    void SetExclusive(IntPtr riverSeat);

    /// <summary>
    /// Records <c>focus_non_exclusive</c> for the seat.
    /// </summary>
    void SetNonExclusive(IntPtr riverSeat);

    /// <summary>
    /// Records <c>focus_none</c> for the seat.
    /// </summary>
    void SetNone(IntPtr riverSeat);

    /// <summary>
    /// Forgets all state for the seat (e.g. on <c>river_seat_v1.removed</c>) so a stale exclusive
    /// lock can never permanently suppress focus.
    /// </summary>
    void Clear(IntPtr riverSeat);
}

/// <inheritdoc cref="ILayerShellFocusState"/>
internal sealed class LayerShellFocusState : ILayerShellFocusState
{
    private readonly ConcurrentDictionary<IntPtr, LayerFocusMode> _modes = new();

    public LayerFocusMode ModeFor(IntPtr riverSeat)
    {
        if (riverSeat == IntPtr.Zero)
        {
            return LayerFocusMode.None;
        }

        return _modes.TryGetValue(riverSeat, out var mode) ? mode : LayerFocusMode.None;
    }

    public bool IsFocusLocked(IntPtr riverSeat) => ModeFor(riverSeat) == LayerFocusMode.Exclusive;

    public void SetExclusive(IntPtr riverSeat) => Set(riverSeat, LayerFocusMode.Exclusive);

    public void SetNonExclusive(IntPtr riverSeat) => Set(riverSeat, LayerFocusMode.NonExclusive);

    public void SetNone(IntPtr riverSeat) => Set(riverSeat, LayerFocusMode.None);

    public void Clear(IntPtr riverSeat)
    {
        if (riverSeat != IntPtr.Zero)
        {
            _modes.TryRemove(riverSeat, out _);
        }
    }

    private void Set(IntPtr riverSeat, LayerFocusMode mode)
    {
        if (riverSeat == IntPtr.Zero)
        {
            return;
        }

        _modes[riverSeat] = mode;
    }
}
