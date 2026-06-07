using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Focus;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Behavioural coverage for <see cref="LayerShellSeatEventHandler"/> + <see cref="LayerShellFocusState"/>:
/// the three no-argument <c>river_layer_shell_seat_v1</c> focus events must drive the per-seat
/// layer-focus mode, resolving the controlled <c>river_seat_v1</c> from the firing sub-object proxy.
/// </summary>
public sealed class LayerShellSeatEventHandlerTests
{
    private static readonly IntPtr LsSeat = new(0x1000);
    private static readonly IntPtr Seat = new(0x2000);

    private static (LayerShellSeatEventHandler handler, LayerShellFocusState focus) Build()
    {
        var focus = new LayerShellFocusState();
        var bind = new WaylandBindSiteState();
        bind.SeatByLayerShellSeat[LsSeat] = Seat;
        bind.LayerShellSeatBySeat[Seat] = LsSeat;
        var handler = new LayerShellSeatEventHandler(focus, bind);
        return (handler, focus);
    }

    [Fact]
    public void Implements_IEventHandler_for_layer_shell_seat()
    {
        var (handler, _) = Build();
        Assert.Contains(typeof(IEventHandler), typeof(LayerShellSeatEventHandler).GetInterfaces());
        Assert.Equal("river_layer_shell_seat_v1", handler.InterfaceName);
    }

    [Fact]
    public void FocusExclusive_locks_the_resolved_seat()
    {
        var (handler, focus) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusExclusive, IntPtr.Zero, 0));

        Assert.Equal(LayerFocusMode.Exclusive, focus.ModeFor(Seat));
        Assert.True(focus.IsFocusLocked(Seat));
    }

    [Fact]
    public void FocusNonExclusive_does_not_lock()
    {
        var (handler, focus) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusNonExclusive, IntPtr.Zero, 0));

        Assert.Equal(LayerFocusMode.NonExclusive, focus.ModeFor(Seat));
        Assert.False(focus.IsFocusLocked(Seat));
    }

    [Fact]
    public void FocusNone_clears_the_lock()
    {
        var (handler, focus) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusExclusive, IntPtr.Zero, 0));
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusNone, IntPtr.Zero, 0));

        Assert.Equal(LayerFocusMode.None, focus.ModeFor(Seat));
        Assert.False(focus.IsFocusLocked(Seat));
    }

    [Fact]
    public void Unknown_subobject_proxy_is_a_no_op()
    {
        var (handler, focus) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", new IntPtr(0xDEAD),
            RiverProtocolOpcodes.LayerShellSeat.FocusExclusive, IntPtr.Zero, 0));

        Assert.False(focus.IsFocusLocked(Seat));
    }

    [Fact]
    public void Focus_opcodes_match_protocol_order()
    {
        Assert.Equal(0u, RiverProtocolOpcodes.LayerShellSeat.FocusExclusive);
        Assert.Equal(1u, RiverProtocolOpcodes.LayerShellSeat.FocusNonExclusive);
        Assert.Equal(2u, RiverProtocolOpcodes.LayerShellSeat.FocusNone);
    }
}
