using System;
using System.Collections.Concurrent;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Compositor.River.Registry;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.3 — unit tests for <see cref="SeatEventHandler"/>.
///
/// Covers the nine opcode branches (Removed / WlSeat / PointerEnter /
/// PointerLeave / WindowInteraction / ShellSurfaceInteraction / OpDelta /
/// OpRelease / PointerPosition), inline cache mutations
/// (`_seatHoveredWindow`, `_seatPointerPos`), and the
/// <see cref="ISeatHandlerCollaborators"/> bridge call surface (window
/// interaction, shell-surface interaction, pointer-enter focus-follow,
/// OpDelta, OpRelease).
/// </summary>
public sealed unsafe class SeatEventHandlerTests
{
    private const string Iface = "river_seat_v1";

    private sealed class FakeBridge : ISeatHandlerCollaborators
    {
        public int WindowInteractionCalls;
        public IntPtr LastWindowInteractionWindow;
        public IntPtr LastWindowInteractionSeat;

        public int ShellSurfaceInteractionCalls;
        public IntPtr LastShellSurfaceInteractionSurface;
        public IntPtr LastShellSurfaceInteractionSeat;

        public int FocusFollowCalls;
        public IntPtr LastFocusFollowHovered;
        public IntPtr LastFocusFollowSeat;

        public int OpDeltaCalls;
        public IntPtr LastOpDeltaSeat;
        public int LastOpDeltaDx;
        public int LastOpDeltaDy;

        public int OpReleaseCalls;
        public IntPtr LastOpReleaseSeat;

        public int CachePointerPositionCalls;
        public IntPtr LastCachePointerSeat;
        public int LastCachePointerX;
        public int LastCachePointerY;

        public void CachePointerPosition(IntPtr seat, int x, int y)
        {
            CachePointerPositionCalls++;
            LastCachePointerSeat = seat;
            LastCachePointerX = x;
            LastCachePointerY = y;
        }

        public void HandleWindowInteraction(IntPtr window, IntPtr seat)
        {
            WindowInteractionCalls++;
            LastWindowInteractionWindow = window;
            LastWindowInteractionSeat = seat;
        }

        public void HandleShellSurfaceInteraction(IntPtr shellSurface, IntPtr seat)
        {
            ShellSurfaceInteractionCalls++;
            LastShellSurfaceInteractionSurface = shellSurface;
            LastShellSurfaceInteractionSeat = seat;
        }

        public void HandlePointerEnterFocusFollow(IntPtr hoveredWindow, IntPtr seat)
        {
            FocusFollowCalls++;
            LastFocusFollowHovered = hoveredWindow;
            LastFocusFollowSeat = seat;
        }

        public void HandleOpDelta(IntPtr seat, int dx, int dy)
        {
            OpDeltaCalls++;
            LastOpDeltaSeat = seat;
            LastOpDeltaDx = dx;
            LastOpDeltaDy = dy;
        }

        public void HandleOpRelease(IntPtr seat)
        {
            OpReleaseCalls++;
            LastOpReleaseSeat = seat;
        }
    }

    private static (
        SeatEventHandler h,
        SeatRegistry s,
        WindowRegistry w,
        ConcurrentDictionary<IntPtr, IntPtr> hovered,
        ConcurrentDictionary<IntPtr, (int X, int Y)> pp,
        FakeBridge b,
        IntPtr seat,
        Aqueous.Features.Compositor.River.SeatEntry entry) Build()
    {
        var s = new SeatRegistry();
        var w = new WindowRegistry();
        var hovered = new ConcurrentDictionary<IntPtr, IntPtr>();
        var pp = new ConcurrentDictionary<IntPtr, (int X, int Y)>();
        var b = new FakeBridge();
        var h = new SeatEventHandler(s, w, hovered, pp, b);
        IntPtr seat = (IntPtr)0x4001;
        s.Entries[seat] = new Aqueous.Features.Compositor.River.SeatEntry { Proxy = seat };
        var entry = s.Entries[seat];
        return (h, s, w, hovered, pp, b, seat, entry);
    }

    [Fact]
    public void InterfaceName_is_river_seat_v1()
    {
        var (h, _, _, _, _, _, _, _) = Build();
        Assert.Equal(Iface, h.InterfaceName);
    }

    [Fact]
    public void Ctor_null_args_throw()
    {
        var s = new SeatRegistry();
        var w = new WindowRegistry();
        var hovered = new ConcurrentDictionary<IntPtr, IntPtr>();
        var pp = new ConcurrentDictionary<IntPtr, (int X, int Y)>();
        var b = new FakeBridge();
        Assert.Throws<ArgumentNullException>(() => new SeatEventHandler(null!, w, hovered, pp, b));
        Assert.Throws<ArgumentNullException>(() => new SeatEventHandler(s, null!, hovered, pp, b));
        Assert.Throws<ArgumentNullException>(() => new SeatEventHandler(s, w, null!, pp, b));
        Assert.Throws<ArgumentNullException>(() => new SeatEventHandler(s, w, hovered, null!, b));
        Assert.Throws<ArgumentNullException>(() => new SeatEventHandler(s, w, hovered, pp, null!));
    }

    [Fact]
    public void Unknown_proxy_is_a_noop()
    {
        var (h, _, _, _, _, b, _, _) = Build();
        h.Handle(new WlEvent(Iface, (IntPtr)0xDEAD, RiverProtocolOpcodes.Seat.PointerLeave, IntPtr.Zero, 0));
        Assert.Equal(0, b.WindowInteractionCalls);
        Assert.Equal(0, b.OpDeltaCalls);
    }

    [Fact]
    public void Removed_opcode_drops_seat_from_registry()
    {
        var (h, s, _, _, _, _, seat, _) = Build();
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.Removed, IntPtr.Zero, 0));
        Assert.False(s.Entries.ContainsKey(seat));
    }

    [Fact]
    public void WlSeat_opcode_sets_wl_seat_name()
    {
        var (h, _, _, _, _, _, seat, entry) = Build();
        WlArgument arg;
        arg.u = 11;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.WlSeat, (IntPtr)(&arg), 1));
        Assert.Equal(11u, entry.WlSeatName);
    }

    [Fact]
    public void PointerEnter_caches_hovered_and_calls_focus_follow_when_changed()
    {
        var (h, _, _, hovered, _, b, seat, _) = Build();
        IntPtr win = (IntPtr)0x9001;
        WlArgument arg;
        arg.o = win;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.PointerEnter, (IntPtr)(&arg), 1));
        Assert.Equal(win, hovered[seat]);
        Assert.Equal(1, b.FocusFollowCalls);
        Assert.Equal(win, b.LastFocusFollowHovered);
        Assert.Equal(seat, b.LastFocusFollowSeat);
    }

    [Fact]
    public void PointerEnter_repeat_with_same_hovered_does_not_re_focus()
    {
        var (h, _, _, hovered, _, b, seat, _) = Build();
        IntPtr win = (IntPtr)0x9001;
        hovered[seat] = win; // pretend we already saw it
        WlArgument arg;
        arg.o = win;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.PointerEnter, (IntPtr)(&arg), 1));
        Assert.Equal(0, b.FocusFollowCalls);
    }

    [Fact]
    public void PointerLeave_drops_hovered_cache()
    {
        var (h, _, _, hovered, _, _, seat, _) = Build();
        hovered[seat] = (IntPtr)0xABCD;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.PointerLeave, IntPtr.Zero, 0));
        Assert.False(hovered.ContainsKey(seat));
    }

    [Fact]
    public void WindowInteraction_calls_bridge()
    {
        var (h, _, _, _, _, b, seat, _) = Build();
        IntPtr win = (IntPtr)0xC0DE;
        WlArgument arg;
        arg.o = win;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.WindowInteraction, (IntPtr)(&arg), 1));
        Assert.Equal(1, b.WindowInteractionCalls);
        Assert.Equal(win, b.LastWindowInteractionWindow);
        Assert.Equal(seat, b.LastWindowInteractionSeat);
    }

    [Fact]
    public void ShellSurfaceInteraction_calls_bridge()
    {
        var (h, _, _, _, _, b, seat, _) = Build();
        IntPtr ss = (IntPtr)0xF00D;
        WlArgument arg;
        arg.o = ss;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.ShellSurfaceInteraction, (IntPtr)(&arg), 1));
        Assert.Equal(1, b.ShellSurfaceInteractionCalls);
        Assert.Equal(ss, b.LastShellSurfaceInteractionSurface);
        Assert.Equal(seat, b.LastShellSurfaceInteractionSeat);
    }

    [Fact]
    public void OpDelta_forwards_dx_dy_to_bridge()
    {
        var (h, _, _, _, _, b, seat, _) = Build();
        var args = stackalloc WlArgument[2];
        args[0].i = 5;
        args[1].i = -7;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.OpDelta, (IntPtr)args, 2));
        Assert.Equal(1, b.OpDeltaCalls);
        Assert.Equal(seat, b.LastOpDeltaSeat);
        Assert.Equal(5, b.LastOpDeltaDx);
        Assert.Equal(-7, b.LastOpDeltaDy);
    }

    [Fact]
    public void OpRelease_forwards_to_bridge()
    {
        var (h, _, _, _, _, b, seat, _) = Build();
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.OpRelease, IntPtr.Zero, 0));
        Assert.Equal(1, b.OpReleaseCalls);
        Assert.Equal(seat, b.LastOpReleaseSeat);
    }

    [Fact]
    public void PointerPosition_routes_through_bridge()
    {
        // PR 8.3 fix: the managed handler routes the PointerPosition
        // write through ISeatHandlerCollaborators.CachePointerPosition
        // so the partial's _seatPointerPos dict (consulted by the
        // SnapZones path) receives the cache via the same lexical
        // reference it always did, eliminating any ctor-captured-vs-
        // partial-field divergence.
        var (h, _, _, _, _, b, seat, _) = Build();
        var args = stackalloc WlArgument[2];
        args[0].i = 320;
        args[1].i = 240;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.PointerPosition, (IntPtr)args, 2));
        Assert.Equal(1, b.CachePointerPositionCalls);
        Assert.Equal(seat, b.LastCachePointerSeat);
        Assert.Equal(320, b.LastCachePointerX);
        Assert.Equal(240, b.LastCachePointerY);
    }

    [Fact]
    public void OpDelta_with_short_payload_is_a_noop()
    {
        var (h, _, _, _, _, b, seat, _) = Build();
        WlArgument arg;
        arg.i = 5;
        h.Handle(new WlEvent(Iface, seat, RiverProtocolOpcodes.Seat.OpDelta, (IntPtr)(&arg), 1));
        Assert.Equal(0, b.OpDeltaCalls);
    }

    [Fact]
    public void Unknown_opcode_is_silent_noop()
    {
        var (h, _, _, _, _, b, seat, _) = Build();
        h.Handle(new WlEvent(Iface, seat, opcode: 99, IntPtr.Zero, 0));
        Assert.Equal(0, b.WindowInteractionCalls);
        Assert.Equal(0, b.OpDeltaCalls);
        Assert.Equal(0, b.OpReleaseCalls);
    }

    [Fact]
    public void Implements_IEventHandler()
    {
        var (h, _, _, _, _, _, _, _) = Build();
        Assert.IsAssignableFrom<IEventHandler>(h);
    }
}
