using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Input;

/// <summary>
/// Handles the Super+BTN_LEFT / Super+BTN_RIGHT (and per-snap-layout activator) pointer-binding
/// pressed/released events.
/// <para>
/// cutover: the service no longer references <see cref="RiverWindowManagerClient"/>. All
/// drag-lifecycle state (active drag window/seat/activator, drag-start coords, edges bitfield,
/// seat→hovered-window map, drag-resize pointer-binding proxy, snap-activator binding registry) is
/// consumed from <see cref="DragStateStore"/> and <see cref="PointerBindingStore"/>; window lookup
/// goes through <see cref="IWindowRegistry"/>; the float-layout gate goes through <see
/// cref="ILayoutProposer"/>; and the manage-cycle ack goes through <see
/// cref="IManagerRequestSender"/>.
/// </para>
/// </summary>
internal sealed unsafe class DragPointerBindingService
{
    private readonly DragStateStore _dragState;
    private readonly PointerBindingStore _pointerBindings;
    private readonly IWindowRegistry _windowRegistry;
    private readonly ILayoutProposer _layoutProposer;
    private readonly IManagerRequestSender _managerRequestSender;

    public DragPointerBindingService(
        DragStateStore dragState,
        PointerBindingStore pointerBindings,
        IWindowRegistry windowRegistry,
        ILayoutProposer layoutProposer,
        IManagerRequestSender managerRequestSender)
    {
        _dragState            = dragState            ?? throw new ArgumentNullException(nameof(dragState));
        _pointerBindings      = pointerBindings      ?? throw new ArgumentNullException(nameof(pointerBindings));
        _windowRegistry       = windowRegistry       ?? throw new ArgumentNullException(nameof(windowRegistry));
        _layoutProposer       = layoutProposer       ?? throw new ArgumentNullException(nameof(layoutProposer));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
    }

    // Edge bitfield matching river_window_v1: top=1, bottom=2, left=4, right=8. Center-third clicks
    // fall back to the bottom-right corner so that a press anywhere inside a window still resolves to
    // a usable resize gesture (this matches the i3/sway convention).
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
        bool isResize = (proxy == _pointerBindings.DragResizePointerBinding)
            && _pointerBindings.DragResizePointerBinding != IntPtr.Zero;

        if (opcode == RiverProtocolOpcodes.Binding.Pressed)
        {
            // Find a seat that has a currently-hovered window and start a drag for it.
            foreach (var kvp in _dragState.SeatHoveredWindow)
            {
                IntPtr seat = kvp.Key;
                IntPtr hovered = kvp.Value;
                if (hovered == IntPtr.Zero)
                {
                    continue;
                }

                if (!_windowRegistry.Entries.TryGetValue(hovered, out var w))
                {
                    continue;
                }

                // Strict v1 gate: keybind-driven move/resize honours the same "only when float layout is active"
                // UX as the client-driven pointer_move_requested / pointer_resize_requested paths.
                // Allow keybind-driven move/resize when the output is on the float engine OR this
                // specific window is an individually-floating popup/dialog over a tiling layout.
                if (!(_layoutProposer.IsFloatLayoutActive(w.Output) || w.Floating))
                {
                    RiverLog.Write($"super+{(isResize ? "RMB" : "LMB")} drag ignored: float layout not active for window 0x{hovered.ToString("x")}");
                    break;
                }

                _dragState.ActiveDragWindow = w;
                _dragState.ActiveDragSeat = seat;
                _dragState.DragStartX = w.X;
                _dragState.DragStartY = w.Y;
                // Capture cursor at drag-start so OpDelta can synthesize live pointer coords for snap-zone
                // hit-testing (river does not emit pointer_position during a drag).
                if (_dragState.SeatPointerPos.TryGetValue(seat, out var dpbP0))
                {
                    _dragState.DragStartPointerX = dpbP0.X;
                    _dragState.DragStartPointerY = dpbP0.Y;
                }
                else
                {
                    _dragState.DragStartPointerX = w.X;
                    _dragState.DragStartPointerY = w.Y;
                }
                // Reset lifecycle flags so ManagerEventHandler issues a fresh op_start_pointer on the next manage
                // cycle even if a prior drag's release path didn't clear them.
                _dragState.DragStarted = false;
                _dragState.DragFinished = false;

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
                    _dragState.DragStartW = dragStartW;
                    _dragState.DragStartH = dragStartH;

                    int px = w.X + dragStartW / 2;
                    int py = w.Y + dragStartH / 2;
                    if (_dragState.SeatPointerPos.TryGetValue(seat, out var pos))
                    {
                        px = pos.X;
                        py = pos.Y;
                    }

                    uint edges = DeriveEdges(px, py, w.X, w.Y, dragStartW, dragStartH);
                    _dragState.DragEdges = edges;
                    RiverLog.Write($"super+RMB drag-resize start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")} edges={edges} from pointer ({px},{py}) inside ({w.X},{w.Y} {dragStartW}x{dragStartH})");
                }
                else
                {
                    _dragState.DragEdges = 0;
                    RiverLog.Write($"super+LMB drag-move start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")}");
                }

                _managerRequestSender.ScheduleManage();
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
