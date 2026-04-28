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

                    // Drag (move or resize) is only meaningful while the float
                    // layout is active; in tile/scrolling/monocle/grid the per-
                    // window Floating override is suppressed by LayoutProposer
                    // bucketing and any FloatX/Y/W/H written here would be
                    // overwritten on the next manage cycle. Fix #4: rather
                    // than just `break`-ing (which would leave _dragEdges /
                    // _dragResizeInformed sticky if the layout was switched
                    // away from float mid-gesture), treat a not-float OpDelta
                    // as an abandoned drag and tear down the same way a
                    // release would, so the next legitimate drag starts
                    // clean.
                    if (!IsFloatLayoutActive(adw.Output))
                    {
                        // Mark for finalisation; ManagerEventHandler will
                        // emit inform_resize_end (if needed) and
                        // op_finish_pointer on the next manage cycle and
                        // clear all drag state.
                        _dragFinished = true;
                        ScheduleManage();
                        break;
                    }

                    adw.Floating = true;

                    if (_dragEdges == 0)
                    {
                        // ----- interactive move -----
                        adw.X = _dragStartX + dx;
                        adw.Y = _dragStartY + dy;
                        adw.HasFloatRect = true;
                        adw.FloatX = adw.X;
                        adw.FloatY = adw.Y;
                        // Fix #6: only overwrite FloatW/FloatH when we have a
                        // positive committed/hinted value. For a freshly-
                        // mapped window where dimensions hasn't fired yet,
                        // W/LastHintW/ProposedW are all 0; clobbering FloatW
                        // (seeded to 800 by LayoutProposer's initial-rect
                        // logic) with 0 would cause the next manage cycle to
                        // skip propose_dimensions (pw<=0) and leave the
                        // window with a permanent FloatW=0, which a later
                        // resize gesture would then read as _dragStartW=0.
                        int newFw = adw.W > 0 ? adw.W
                                  : adw.LastHintW > 0 ? adw.LastHintW
                                  : adw.ProposedW;
                        int newFh = adw.H > 0 ? adw.H
                                  : adw.LastHintH > 0 ? adw.LastHintH
                                  : adw.ProposedH;
                        if (newFw > 0)
                        {
                            adw.FloatW = newFw;
                        }
                        if (newFh > 0)
                        {
                            adw.FloatH = newFh;
                        }
                    }
                    else
                    {
                        // ----- interactive resize -----
                        // Edges bitfield (river_window_v1): top=1, bottom=2, left=4, right=8.
                        // Per protocol guarantees, top+bottom and left+right are never both
                        // set simultaneously, so the per-axis branches are unambiguous.
                        int newX = _dragStartX;
                        int newY = _dragStartY;
                        int newW = _dragStartW;
                        int newH = _dragStartH;

                        if ((_dragEdges & 8u) != 0) // right
                        {
                            newW = _dragStartW + dx;
                        }
                        else if ((_dragEdges & 4u) != 0) // left
                        {
                            newW = _dragStartW - dx;
                            newX = _dragStartX + dx;
                        }

                        if ((_dragEdges & 2u) != 0) // bottom
                        {
                            newH = _dragStartH + dy;
                        }
                        else if ((_dragEdges & 1u) != 0) // top
                        {
                            newH = _dragStartH - dy;
                            newY = _dragStartY + dy;
                        }

                        // Clamp to client-advertised min/max hints. A hint
                        // value of 0 means "no preference" per the protocol.
                        int minW = adw.MinW > 0 ? adw.MinW : 1;
                        int minH = adw.MinH > 0 ? adw.MinH : 1;
                        if (newW < minW)
                        {
                            // If shrinking from the left edge would go below
                            // min width, pin the left edge to keep the right
                            // edge fixed at its starting position.
                            if ((_dragEdges & 4u) != 0)
                            {
                                newX = _dragStartX + (_dragStartW - minW);
                            }

                            newW = minW;
                        }

                        if (newH < minH)
                        {
                            if ((_dragEdges & 1u) != 0)
                            {
                                newY = _dragStartY + (_dragStartH - minH);
                            }

                            newH = minH;
                        }

                        if (adw.MaxW > 0 && newW > adw.MaxW)
                        {
                            if ((_dragEdges & 4u) != 0)
                            {
                                newX = _dragStartX + (_dragStartW - adw.MaxW);
                            }

                            newW = adw.MaxW;
                        }

                        if (adw.MaxH > 0 && newH > adw.MaxH)
                        {
                            if ((_dragEdges & 1u) != 0)
                            {
                                newY = _dragStartY + (_dragStartH - adw.MaxH);
                            }

                            newH = adw.MaxH;
                        }

                        adw.X = newX;
                        adw.Y = newY;
                        adw.HasFloatRect = true;
                        adw.FloatX = newX;
                        adw.FloatY = newY;
                        adw.FloatW = newW;
                        adw.FloatH = newH;

                        // Force the float layer of ProposeForArea to emit
                        // a fresh propose_dimensions next manage cycle so
                        // the client actually grows/shrinks. Without this
                        // the diff-gate on LastHintW/H would still fire,
                        // but ScheduleManage guarantees we get a cycle
                        // even when the WM is otherwise idle.
                        ScheduleManage();
                    }
                }

                break;
            case RiverProtocolOpcodes.Seat.OpRelease:
                Log($"seat 0x{proxy.ToString("x")} pointer operation released");
                _dragFinished = true;
                break;
            case RiverProtocolOpcodes.Seat.PointerPosition:
                // Cache latest pointer position per seat so the
                // Super+RMB drag-resize binding (DragPointerBindingEventHandler)
                // can derive the resize edges from the click position
                // relative to the hovered window's rect. Per protocol
                // (river_seat_v1::pointer_position) the coordinates are in
                // the compositor's logical coordinate space, matching the
                // window X/Y we already track.
                _seatPointerPos[proxy] = (args[0].i, args[1].i);
                break;
            default:
                Log($"seat 0x{proxy.ToString("x")} event opcode={opcode}");
                break;
        }
    }
}
