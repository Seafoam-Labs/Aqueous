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

// drag-pointer binding event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
//
// Two pointer bindings flow through this handler, distinguished by the
// proxy that fired the event:
//
//   * _dragPointerBinding        — Super + BTN_LEFT  → interactive move.
//   * _dragResizePointerBinding  — Super + BTN_RIGHT → interactive resize,
//                                   with edges derived from the pointer's
//                                   quadrant inside the hovered window.
//
// Both reuse the same _activeDragWindow / _dragEdges / _dragStart* state
// that the client-driven pointer_move_requested / pointer_resize_requested
// arms today; ManagerEventHandler emits op_start_pointer (and, for
// resize, inform_resize_start) on the next manage cycle, OpDelta updates
// FloatX/Y/W/H, and OpRelease finalises everything. No changes to the
// downstream pipeline are required for the new arming source.
internal sealed unsafe partial class RiverWindowManagerClient
{
    // Edge bitfield matching river_window_v1: top=1, bottom=2, left=4, right=8.
    // Center-third clicks fall back to the bottom-right corner so that a
    // press anywhere inside a window still resolves to a usable resize
    // gesture (this matches the i3/sway convention).
    private static uint DeriveEdges(int px, int py, int wx, int wy, int ww, int wh)
    {
        if (ww <= 0 || wh <= 0)
        {
            return 2u | 8u; // bottom | right (SE corner) — safe fallback.
        }

        double relX = (double)(px - wx) / ww;
        double relY = (double)(py - wy) / wh;
        uint edges = 0;
        if (relX < 1.0 / 3.0)
        {
            edges |= 4u; // left
        }
        else if (relX > 2.0 / 3.0)
        {
            edges |= 8u; // right
        }

        if (relY < 1.0 / 3.0)
        {
            edges |= 1u; // top
        }
        else if (relY > 2.0 / 3.0)
        {
            edges |= 2u; // bottom
        }

        if (edges == 0)
        {
            edges = 2u | 8u; // dead-zone fallback: SE corner.
        }

        return edges;
    }

    private void OnDragPointerBindingEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        bool isResize = (proxy == _dragResizePointerBinding) && _dragResizePointerBinding != IntPtr.Zero;

        // SnapZones activator gate: if this event came from one of the
        // Super+<activator>+BTN_LEFT pointer bindings, remember which
        // activator armed the drag so TryResolveSnapForDrag can match
        // the per-layout Activator. Otherwise default to Always (the
        // plain Super+LMB / Super+RMB bindings — only Always-activated
        // snap layouts are eligible).
        Aqueous.Features.SnapZones.SnapActivator pressActivator =
            Aqueous.Features.SnapZones.SnapActivator.Always;
        if (_snapActivatorBindings.TryGetValue(proxy, out var act))
        {
            pressActivator = act;
        }

        if (opcode == RiverProtocolOpcodes.Binding.Pressed)
        {
            // Find a seat that has a currently-hovered window and start a drag for it.
            foreach (var kvp in _seatHoveredWindow)
            {
                IntPtr seat = kvp.Key;
                IntPtr hovered = kvp.Value;
                if (hovered == IntPtr.Zero)
                {
                    continue;
                }

                if (!_windows.TryGetValue(hovered, out var w))
                {
                    continue;
                }

                // Strict v1 gate (Phase 3.2 of Option 3 plan): keybind-driven
                // move/resize honours the same "only when float layout is
                // active" UX as the client-driven pointer_move_requested /
                // pointer_resize_requested paths. Outside float, the per-
                // window Floating override is suppressed by LayoutProposer
                // bucketing and any FloatX/Y/W/H written during op_delta
                // would be overwritten on the next manage cycle, so arming
                // would just produce a half-armed drag with no visible
                // effect. Cleanly ignore instead.
                if (!IsFloatLayoutActive(w.Output))
                {
                    Log($"super+{(isResize ? "RMB" : "LMB")} drag ignored: float layout not active for window 0x{hovered.ToString("x")}");
                    break;
                }

                _activeDragWindow = w;
                _activeDragSeat = seat;
                _activeDragActivator = pressActivator;
                _dragStartX = w.X;
                _dragStartY = w.Y;
                // Reset lifecycle flags so ManagerEventHandler issues a
                // fresh op_start_pointer on the next manage cycle even if
                // a prior drag's release path didn't clear them.
                _dragStarted = false;
                _dragFinished = false;

                if (isResize)
                {
                    // Same fallback chain as PointerResizeRequested (fix #2).
                    _dragStartW = w.W > 0 ? w.W
                        : w.FloatW > 0 ? w.FloatW
                        : w.LastHintW > 0 ? w.LastHintW
                        : w.ProposedW > 0 ? w.ProposedW
                        : 800;
                    _dragStartH = w.H > 0 ? w.H
                        : w.FloatH > 0 ? w.FloatH
                        : w.LastHintH > 0 ? w.LastHintH
                        : w.ProposedH > 0 ? w.ProposedH
                        : 600;

                    // Resolve pointer position; if pointer_position hasn't
                    // arrived yet (rare — river is required to send it
                    // every manage sequence) fall back to the window's
                    // centre, which yields the SE corner via the dead-zone
                    // fallback in DeriveEdges.
                    int px = _dragStartX + _dragStartW / 2;
                    int py = _dragStartY + _dragStartH / 2;
                    if (_seatPointerPos.TryGetValue(seat, out var pos))
                    {
                        px = pos.X;
                        py = pos.Y;
                    }

                    _dragEdges = DeriveEdges(px, py, _dragStartX, _dragStartY, _dragStartW, _dragStartH);
                    Log($"super+RMB drag-resize start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")} edges={_dragEdges} from pointer ({px},{py}) inside ({_dragStartX},{_dragStartY} {_dragStartW}x{_dragStartH})");
                }
                else
                {
                    _dragEdges = 0;
                    Log($"super+LMB drag-move start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")}");
                }

                ScheduleManage();
                break;
            }
        }
        else if (opcode == RiverProtocolOpcodes.Binding.Released)
        {
            Log($"super+{(isResize ? "RMB" : "LMB")} pointer binding released");
            // The matching op_release from the seat will set _dragFinished; nothing else to do here.
        }
    }
}
