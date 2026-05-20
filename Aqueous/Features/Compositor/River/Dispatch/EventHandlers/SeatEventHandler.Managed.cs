using System;
using System.Collections.Concurrent;
using Aqueous.Features.Compositor.River.Registry;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Third <see cref="IEventHandler"/> extracted out of the <c>RiverWindowManagerClient</c> god
/// class. Handles the nine <c>river_seat_v1</c> events (see <see
/// cref="RiverProtocolOpcodes.Seat"/>): removed, wl_seat, pointer_enter, pointer_leave,
/// window_interaction, shell_surface_interaction, op_delta, op_release, pointer_position. The
/// simple cache-mutation opcodes (Removed / WlSeat / PointerLeave / PointerPosition) live inline;
/// opcodes that touch drag state or the focus pipeline (PointerEnter focus-follow, OpDelta,
/// OpRelease) and the two seat-interaction opcodes are routed through <see
/// cref="ISeatHandlerCollaborators"/> which is implemented explicitly by
/// <c>RiverWindowManagerClient</c> and retires. Pump-thread only: invoked by <see
/// cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class SeatEventHandler : IEventHandler
{
    private readonly ISeatRegistry _seats;
    private readonly IWindowRegistry _windows;
    private readonly ConcurrentDictionary<IntPtr, IntPtr> _seatHoveredWindow;
    // _seatPointerPos retained as a ctor param for signature stability with callers + tests, but
    // PointerPosition writes now route through ISeatHandlerCollaborators.CachePointerPosition (see
    // fix for snap-zone-broken regression). Field kept null-checked; future PR retires it once tests
    // + RiverWindowManagerClient ctor migrate.
    private readonly ConcurrentDictionary<IntPtr, (int X, int Y)> _seatPointerPos;
    // Routes through SeatInteractionService instead of RiverWindowManagerClient. The service consumes
    // fine-grained DI singletons directly.
    private readonly SeatInteractionService _interaction;
    private readonly Action<string>? _log;

    public SeatEventHandler(
        ISeatRegistry seats,
        IWindowRegistry windows,
        ConcurrentDictionary<IntPtr, IntPtr> seatHoveredWindow,
        ConcurrentDictionary<IntPtr, (int X, int Y)> seatPointerPos,
        SeatInteractionService interaction,
        Action<string>? log = null)
    {
        _seats = seats ?? throw new ArgumentNullException(nameof(seats));
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _seatHoveredWindow = seatHoveredWindow ?? throw new ArgumentNullException(nameof(seatHoveredWindow));
        _seatPointerPos = seatPointerPos ?? throw new ArgumentNullException(nameof(seatPointerPos));
        _interaction = interaction ?? throw new ArgumentNullException(nameof(interaction));
        _log = log;
    }

    public string InterfaceName => "river_seat_v1";

    public void Handle(WlEvent ev)
    {
        IntPtr proxy = ev.Target;
        if (!_seats.Entries.ContainsKey(proxy))
        {
            return;
        }

        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.Seat.Removed:
                _log?.Invoke("seat 0x" + proxy.ToString("x") + " removed");
                _seats.Entries.TryRemove(proxy, out _);
                break;

            case RiverProtocolOpcodes.Seat.WlSeat:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    if (_seats.Entries.TryGetValue(proxy, out var s))
                    {
                        s.WlSeatName = args[0].u;
                        _log?.Invoke("seat 0x" + proxy.ToString("x") + " wl_seat_name=" + s.WlSeatName);
                    }
                }
                break;

            case RiverProtocolOpcodes.Seat.PointerEnter:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    IntPtr hovered = args[0].o;
                    // Gate: only follow focus when the hovered window actually changed. River can re-send
                    // pointer_enter during normal motion; treating each as a focus change triggers the manage_dirty
                    // storm (see Fix #1).
                    if (_seatHoveredWindow.TryGetValue(proxy, out var prevHover) && prevHover == hovered)
                    {
                        break;
                    }

                    _seatHoveredWindow[proxy] = hovered;
                    _log?.Invoke("seat 0x" + proxy.ToString("x") + " pointer_enter window 0x" + hovered.ToString("x"));
                    // Sloppy focus: bridge to god class — gating on FocusFollowsMouse, window-known, and
                    // window-differs-from-focused happens there.
                    _interaction.HandlePointerEnterFocusFollow(hovered, proxy);
                }
                break;

            case RiverProtocolOpcodes.Seat.PointerLeave:
                _seatHoveredWindow.TryRemove(proxy, out _);
                _log?.Invoke("seat 0x" + proxy.ToString("x") + " pointer_leave");
                break;

            case RiverProtocolOpcodes.Seat.WindowInteraction:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    IntPtr win = args[0].o;
                    _log?.Invoke("seat 0x" + proxy.ToString("x") + " window_interaction 0x" + win.ToString("x"));
                    _interaction.HandleWindowInteraction(win, proxy);
                }
                break;

            case RiverProtocolOpcodes.Seat.ShellSurfaceInteraction:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    IntPtr ss = args[0].o;
                    _log?.Invoke("seat 0x" + proxy.ToString("x") + " shell_surface_interaction 0x" + ss.ToString("x"));
                    _interaction.HandleShellSurfaceInteraction(ss, proxy);
                }
                break;

            case RiverProtocolOpcodes.Seat.OpDelta:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 2) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    _interaction.HandleOpDelta(proxy, args[0].i, args[1].i);
                }
                break;

            case RiverProtocolOpcodes.Seat.OpRelease:
                _log?.Invoke("seat 0x" + proxy.ToString("x") + " pointer operation released");
                _interaction.HandleOpRelease(proxy);
                break;

            case RiverProtocolOpcodes.Seat.PointerPosition:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 2) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    // Cache latest pointer position per seat so the Super+RMB drag-resize binding can derive the
                    // resize edges from the click position relative to the hovered window's rect, and so SnapZones
                    // can hit-test against the live cursor in OpDelta / OpRelease. Routed through the bridge — see
                    // ISeatHandlerCollaborators.CachePointerPosition.
                    _interaction.CachePointerPosition(proxy, args[0].i, args[1].i);
                }
                break;

            default:
                _log?.Invoke("seat 0x" + proxy.ToString("x") + " event opcode=" + ev.Opcode);
                break;
        }
    }
}
