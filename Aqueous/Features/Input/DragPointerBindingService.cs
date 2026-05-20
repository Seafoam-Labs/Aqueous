using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Input;

/// <summary>
/// PR 9.12 §2.13 — handles the Super+BTN_LEFT / Super+BTN_RIGHT (and
/// per-snap-layout activator) pointer-binding "pressed"/"released"
/// events used to arm interactive move/resize drags.
///
/// Lifted out of the deleted
/// <c>partial class RiverWindowManagerClient</c> file
/// <c>DragPointerBindingEventHandler.cs</c> into a standalone service
/// so the god class loses one more partial. The body still reads/
/// writes drag-lifecycle state that lives on
/// <see cref="RiverWindowManagerClient"/> (active drag window/seat/
/// activator, drag-start coords, edges bitfield, seat→hovered-window
/// map, snap-activator binding registry, <c>_dragResizePointerBinding</c>
/// proxy, <c>ScheduleManage</c>); each is consumed through a
/// dedicated internal accessor on the god class and retires together
/// with it in the final demolition step.
/// </summary>
internal sealed unsafe class DragPointerBindingService
{
    private readonly RiverWindowManagerClient _client;

    public DragPointerBindingService(RiverWindowManagerClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

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

    public void HandleEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        bool isResize = (proxy == _client.DragResizePointerBinding) && _client.DragResizePointerBinding != IntPtr.Zero;

        // SnapZones activator gate: if this event came from one of the
        // Super+<activator>+BTN_LEFT pointer bindings, remember which
        // activator armed the drag so TryResolveSnapForDrag can match
        // the per-layout Activator. Otherwise default to Always (the
        // plain Super+LMB / Super+RMB bindings — only Always-activated
        // snap layouts are eligible).
        Aqueous.Features.SnapZones.SnapActivator pressActivator =
            Aqueous.Features.SnapZones.SnapActivator.Always;
        if (_client.SnapActivatorBindings.TryGetValue(proxy, out var act))
        {
            pressActivator = act;
        }

        if (opcode == RiverProtocolOpcodes.Binding.Pressed)
        {
            // Find a seat that has a currently-hovered window and start a drag for it.
            foreach (var kvp in _client.SeatHoveredWindow)
            {
                IntPtr seat = kvp.Key;
                IntPtr hovered = kvp.Value;
                if (hovered == IntPtr.Zero)
                {
                    continue;
                }

                if (!_client.WindowRegistry.Entries.TryGetValue(hovered, out var w))
                {
                    continue;
                }

                // Strict v1 gate: keybind-driven move/resize honours the
                // same "only when float layout is active" UX as the
                // client-driven pointer_move_requested /
                // pointer_resize_requested paths.
                if (!_client.IsFloatLayoutActive(w.Output))
                {
                    RiverLog.Write($"super+{(isResize ? "RMB" : "LMB")} drag ignored: float layout not active for window 0x{hovered.ToString("x")}");
                    break;
                }

                _client.SetActiveDragWindow(w);
                _client.SetActiveDragSeat(seat);
                _client.SetActiveDragActivator(pressActivator);
                _client.SetDragStartX(w.X);
                _client.SetDragStartY(w.Y);
                // Capture cursor at drag-start so OpDelta can synthesize
                // live pointer coords for snap-zone hit-testing (river
                // does not emit pointer_position during a drag).
                if (_client.SeatPointerPos.TryGetValue(seat, out var dpbP0))
                {
                    _client.SetDragStartPointerX(dpbP0.X);
                    _client.SetDragStartPointerY(dpbP0.Y);
                }
                else
                {
                    _client.SetDragStartPointerX(w.X);
                    _client.SetDragStartPointerY(w.Y);
                }
                // Reset lifecycle flags so ManagerEventHandler issues a
                // fresh op_start_pointer on the next manage cycle even if
                // a prior drag's release path didn't clear them.
                _client.SetDragStarted(false);
                _client.SetDragFinished(false);

                if (isResize)
                {
                    int dragStartW = w.W > 0 ? w.W
                        : w.FloatW > 0 ? w.FloatW
                        : w.LastHintW > 0 ? w.LastHintW
                        : w.ProposedW > 0 ? w.ProposedW
                        : 800;
                    int dragStartH = w.H > 0 ? w.H
                        : w.FloatH > 0 ? w.FloatH
                        : w.LastHintH > 0 ? w.LastHintH
                        : w.ProposedH > 0 ? w.ProposedH
                        : 600;
                    _client.SetDragStartW(dragStartW);
                    _client.SetDragStartH(dragStartH);

                    int px = w.X + dragStartW / 2;
                    int py = w.Y + dragStartH / 2;
                    if (_client.SeatPointerPos.TryGetValue(seat, out var pos))
                    {
                        px = pos.X;
                        py = pos.Y;
                    }

                    uint edges = DeriveEdges(px, py, w.X, w.Y, dragStartW, dragStartH);
                    _client.SetDragEdges(edges);
                    RiverLog.Write($"super+RMB drag-resize start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")} edges={edges} from pointer ({px},{py}) inside ({w.X},{w.Y} {dragStartW}x{dragStartH})");
                }
                else
                {
                    _client.SetDragEdges(0);
                    RiverLog.Write($"super+LMB drag-move start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")}");
                }

                _client.ScheduleManageExternal();
                break;
            }
        }
        else if (opcode == RiverProtocolOpcodes.Binding.Released)
        {
            RiverLog.Write($"super+{(isResize ? "RMB" : "LMB")} pointer binding released");
            // The matching op_release from the seat will set _dragFinished; nothing else to do here.
        }
    }
}
