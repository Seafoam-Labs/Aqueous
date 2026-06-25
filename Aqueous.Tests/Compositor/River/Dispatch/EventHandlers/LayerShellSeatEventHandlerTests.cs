using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
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

    private static (LayerShellSeatEventHandler handler, LayerShellFocusState focus, FakeFocusService focusService) Build()
    {
        var focus = new LayerShellFocusState();
        var bind = new WaylandBindSiteState();
        bind.SeatByLayerShellSeat[LsSeat] = Seat;
        bind.LayerShellSeatBySeat[Seat] = LsSeat;
        var focusService = new FakeFocusService();
        var handler = new LayerShellSeatEventHandler(focus, bind, focusService);
        return (handler, focus, focusService);
    }

    [Fact]
    public void Implements_IEventHandler_for_layer_shell_seat()
    {
        var (handler, _, _) = Build();
        Assert.Contains(typeof(IEventHandler), typeof(LayerShellSeatEventHandler).GetInterfaces());
        Assert.Equal("river_layer_shell_seat_v1", handler.InterfaceName);
    }

    [Fact]
    public void FocusExclusive_locks_the_resolved_seat()
    {
        var (handler, focus, _) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusExclusive, IntPtr.Zero, 0));

        Assert.Equal(LayerFocusMode.Exclusive, focus.ModeFor(Seat));
        Assert.True(focus.IsFocusLocked(Seat));
    }

    [Fact]
    public void FocusNonExclusive_does_not_lock()
    {
        var (handler, focus, _) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusNonExclusive, IntPtr.Zero, 0));

        Assert.Equal(LayerFocusMode.NonExclusive, focus.ModeFor(Seat));
        Assert.False(focus.IsFocusLocked(Seat));
    }

    [Fact]
    public void FocusNone_clears_the_lock()
    {
        var (handler, focus, focusService) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusExclusive, IntPtr.Zero, 0));
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusNone, IntPtr.Zero, 0));

        Assert.Equal(LayerFocusMode.None, focus.ModeFor(Seat));
        Assert.False(focus.IsFocusLocked(Seat));
    }

    [Fact]
    public void FocusNone_after_grab_reasserts_window_focus()
    {
        var (handler, _, focusService) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusExclusive, IntPtr.Zero, 0));
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusNone, IntPtr.Zero, 0));

        // Releasing an exclusive keyboard grab must re-assert window focus, otherwise the keyboard is
        // left focused on nobody after the launcher closes.
        Assert.Equal(1, focusService.ReassertCount);
    }

    [Fact]
    public void FocusNone_without_prior_grab_does_not_reassert()
    {
        var (handler, _, focusService) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", LsSeat,
            RiverProtocolOpcodes.LayerShellSeat.FocusNone, IntPtr.Zero, 0));

        Assert.Equal(0, focusService.ReassertCount);
    }

    [Fact]
    public void Unknown_subobject_proxy_is_a_no_op()
    {
        var (handler, focus, _) = Build();
        handler.Handle(new WlEvent("river_layer_shell_seat_v1", new IntPtr(0xDEAD),
            RiverProtocolOpcodes.LayerShellSeat.FocusExclusive, IntPtr.Zero, 0));

        Assert.False(focus.IsFocusLocked(Seat));
    }

    private sealed class FakeFocusService : IFocusService
    {
        public int ReassertCount { get; private set; }

        public IntPtr FocusedWindow => IntPtr.Zero;
        public bool TryGetFocusedAlive(out IntPtr proxy) { proxy = IntPtr.Zero; return false; }
        public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy) { }
        public void RequestFocus(IntPtr windowProxy) { }
        public void ClearFocus() { }
        public void FocusAnyOtherWindow(IntPtr avoid) { }
        public void FocusAnyOtherWindow(IntPtr avoid, IntPtr workspace) { }
        public void CycleFocus() { }
        public void HandleDirectionalFocus(FocusDirection dir) { }
        public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy) { }
        public void InvalidateShellSurface(IntPtr shellSurfaceProxy) { }
        public void RepairFocusAfterTagChange() { }
        public void ClearFocusedHandle() { }
        public void ReassertFocusAfterLayerRelease() => ReassertCount++;
    }

    [Fact]
    public void Focus_opcodes_match_protocol_order()
    {
        Assert.Equal(0u, RiverProtocolOpcodes.LayerShellSeat.FocusExclusive);
        Assert.Equal(1u, RiverProtocolOpcodes.LayerShellSeat.FocusNonExclusive);
        Assert.Equal(2u, RiverProtocolOpcodes.LayerShellSeat.FocusNone);
    }
}
