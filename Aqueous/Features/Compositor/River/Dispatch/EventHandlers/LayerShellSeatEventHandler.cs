using System;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Focus;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// <see cref="IEventHandler"/> for <c>river_layer_shell_seat_v1</c> (the per-seat sub-object created
/// via <c>river_layer_shell_v1.get_seat</c>). It receives the three no-argument focus events and
/// drives <see cref="ILayerShellFocusState"/> so the WM can suppress its own focus-change requests
/// while a layer surface holds exclusive keyboard focus:
/// <list type="bullet">
///   <item><c>focus_exclusive</c> (opcode 0) → <see cref="LayerFocusMode.Exclusive"/>.</item>
///   <item><c>focus_non_exclusive</c> (opcode 1) → <see cref="LayerFocusMode.NonExclusive"/>.</item>
///   <item><c>focus_none</c> (opcode 2) → <see cref="LayerFocusMode.None"/>.</item>
/// </list>
/// The events carry no arguments; the controlled <c>river_seat_v1</c> is resolved from the firing
/// sub-object proxy (<see cref="WlEvent.Target"/>) via the association map populated when the
/// sub-object was created (<see cref="WaylandBindSiteState.SeatByLayerShellSeat"/>).
/// <para>
/// Pump-thread only: invoked by the native callback via <see cref="IEventDispatcher.Dispatch"/>.
/// </para>
/// </summary>
internal sealed class LayerShellSeatEventHandler : IEventHandler
{
    private readonly ILayerShellFocusState _focusState;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly Action<string>? _log;

    public LayerShellSeatEventHandler(
        ILayerShellFocusState focusState,
        WaylandBindSiteState bindSiteState,
        Action<string>? log = null)
    {
        _focusState = focusState ?? throw new ArgumentNullException(nameof(focusState));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _log = log;
    }

    public string InterfaceName => "river_layer_shell_seat_v1";

    public void Handle(WlEvent ev)
    {
        // Resolve the controlled river_seat_v1 from the firing sub-object proxy. If the association
        // is unknown (sub-object already torn down), there is nothing to drive.
        if (!_bindSiteState.SeatByLayerShellSeat.TryGetValue(ev.Target, out var seat) || seat == IntPtr.Zero)
        {
            return;
        }

        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.LayerShellSeat.FocusExclusive:
                _focusState.SetExclusive(seat);
                _log?.Invoke($"layer_shell_seat focus_exclusive on seat 0x{seat:x}");
                break;
            case RiverProtocolOpcodes.LayerShellSeat.FocusNonExclusive:
                _focusState.SetNonExclusive(seat);
                _log?.Invoke($"layer_shell_seat focus_non_exclusive on seat 0x{seat:x}");
                break;
            case RiverProtocolOpcodes.LayerShellSeat.FocusNone:
                _focusState.SetNone(seat);
                _log?.Invoke($"layer_shell_seat focus_none on seat 0x{seat:x}");
                break;
        }
    }
}
