using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Compositor.River;

// river_seat_v1 event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void OnSeatEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        if (!_seats.TryGetValue(proxy, out var s))
        {
            return;
        }
        // See RiverProtocolOpcodes.Seat for the full event table.
        switch (opcode)
        {
            case RiverProtocolOpcodes.Seat.Removed:
                Log($"seat 0x{proxy.ToString("x")} removed");
                _seats.TryRemove(proxy, out _);
                break;
            case RiverProtocolOpcodes.Seat.WlSeat:
                s.WlSeatName = args[0].u;
                Log($"seat 0x{proxy.ToString("x")} wl_seat_name={s.WlSeatName}");
                break;
            case RiverProtocolOpcodes.Seat.PointerEnter:
                {
                    IntPtr hovered = args[0].o;
                    // Gate: only log / follow focus when the hovered window actually changed.
                    // River can re-send pointer_enter during normal motion; treating each
                    // as a focus change triggers the manage_dirty storm (see Fix #1).
                    if (_seatHoveredWindow.TryGetValue(proxy, out var prevHover) && prevHover == hovered)
                    {
                        break;
                    }

                    _seatHoveredWindow[proxy] = hovered;
                    Log($"seat 0x{proxy.ToString("x")} pointer_enter window 0x{hovered.ToString("x")}");
                    // Sloppy focus: follow the pointer so keystrokes go where the user is looking.
                    if (_layoutConfig.Input.FocusFollowsMouse
                        &&hovered != IntPtr.Zero
                        && _windows.ContainsKey(hovered)
                        && hovered != _focusedWindow)
                    {
                        SetFocusedWindow(hovered, proxy);
                    }

                    break;
                }
            case RiverProtocolOpcodes.Seat.PointerLeave:
                _seatHoveredWindow.TryRemove(proxy, out _);
                Log($"seat 0x{proxy.ToString("x")} pointer_leave");
                break;
            case RiverProtocolOpcodes.Seat.WindowInteraction:
                Log($"seat 0x{proxy.ToString("x")} window_interaction 0x{args[0].o.ToString("x")}");
                _seatInteractionService.HandleWindowInteraction(args[0].o, proxy);
                break;
            case RiverProtocolOpcodes.Seat.ShellSurfaceInteraction:
                Log($"seat 0x{proxy.ToString("x")} shell_surface_interaction 0x{args[0].o.ToString("x")}");
                _seatInteractionService.HandleShellSurfaceInteraction(args[0].o, proxy);
                break;
            case RiverProtocolOpcodes.Seat.OpDelta:
                int dx = args[0].i;
                int dy = args[1].i;
                if (_activeDragWindow != null)
                {
                    var adw = _activeDragWindow;
                    adw.X = _dragStartX + dx;
                    adw.Y = _dragStartY + dy;
                    // Promote the dragged window to the floating layer and
                    // remember its rect so subsequent manage cycles do not
                    // overwrite the drag-derived position with the active
                    // layout engine's choice. Width/height come from the
                    // last known committed dimensions; if the client has
                    // not committed a size yet, fall back to the last
                    // proposed hint.
                    // Drag-to-float promotion is only meaningful when the
                    // active layout is the float engine; otherwise the tiling
                    // engine owns geometry and a per-window Floating override
                    // would be ignored anyway (see ProposeForArea).
                    if (IsFloatLayoutActive())
                    {
                        adw.Floating = true;
                    }

                    adw.HasFloatRect = true;
                    adw.FloatX = adw.X;
                    adw.FloatY = adw.Y;
                    adw.FloatW = adw.W > 0 ? adw.W : (adw.LastHintW > 0 ? adw.LastHintW : adw.ProposedW);
                    adw.FloatH = adw.H > 0 ? adw.H : (adw.LastHintH > 0 ? adw.LastHintH : adw.ProposedH);
                }

                break;
            case RiverProtocolOpcodes.Seat.OpRelease:
                Log($"seat 0x{proxy.ToString("x")} pointer operation released");
                _dragFinished = true;
                break;
            default:
                Log($"seat 0x{proxy.ToString("x")} event opcode={opcode}");
                break;
        }
    }
}
