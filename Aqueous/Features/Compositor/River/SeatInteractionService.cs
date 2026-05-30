using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Owns the six seat-bridge methods. Consumed by <c>SeatEventHandler.Managed.cs</c> in place of
/// the prior <c>_river.*</c> calls.
/// <para>
/// the last <c>RiverWindowManagerClient</c> coupling (drag-rect / drag-edges / drag-finished
/// forwarders) is gone — that state now lives on <see cref="DragStateStore"/>, which the service
/// consumes directly. All dependencies are now fine-grained DI singletons (<see
/// cref="DragStateStore"/>, <see cref="IWindowRegistry"/>, <see cref="IFocusService"/>, <see
/// cref="ILayoutProposer"/>, <see cref="IManagerRequestSender"/>,
/// <see cref="LayoutController"/>).
/// </para>
/// <para>
/// Pump-thread only.
/// </para>
/// </summary>
internal sealed class SeatInteractionService
{
    private readonly DragStateStore _dragState;
    private readonly IWindowRegistry _windowRegistry;
    private readonly IFocusService _focusService;
    private readonly ILayoutProposer _layoutProposer;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly LayoutController _layoutController;

    public SeatInteractionService(
        DragStateStore dragState,
        IWindowRegistry windowRegistry,
        IFocusService focusService,
        ILayoutProposer layoutProposer,
        IManagerRequestSender managerRequestSender,
        LayoutController layoutController)
    {
        _dragState             = dragState             ?? throw new ArgumentNullException(nameof(dragState));
        _windowRegistry        = windowRegistry        ?? throw new ArgumentNullException(nameof(windowRegistry));
        _focusService          = focusService          ?? throw new ArgumentNullException(nameof(focusService));
        _layoutProposer        = layoutProposer        ?? throw new ArgumentNullException(nameof(layoutProposer));
        _managerRequestSender  = managerRequestSender  ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _layoutController      = layoutController      ?? throw new ArgumentNullException(nameof(layoutController));
    }

    public void CachePointerPosition(IntPtr seat, int x, int y)
    {
        // River_window_management_v1::pointer_position declares its args as type="int" in the protocol
        // XML — global logical coordinates already in pixel space, NOT wl_fixed. Cache as-is.
        _dragState.SeatPointerPos[seat] = (x, y);
    }

    public void HandleWindowInteraction(IntPtr window, IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandleWindowInteraction window=0x" + window.ToString("x") + " seat=0x" + seat.ToString("x"));
        _focusService.SetFocusedWindow(window, seat);
    }

    public void HandleShellSurfaceInteraction(IntPtr shellSurface, IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandleShellSurfaceInteraction ss=0x" + shellSurface.ToString("x") + " seat=0x" + seat.ToString("x"));
        _focusService.SetFocusedShellSurface(shellSurface, seat);
    }

    public void HandlePointerEnterFocusFollow(IntPtr hoveredWindow, IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandlePointerEnterFocusFollow hovered=0x" + hoveredWindow.ToString("x") + " seat=0x" + seat.ToString("x"));
        if (_layoutController.Config.Input.FocusFollowsMouse
            && hoveredWindow != IntPtr.Zero
            && _windowRegistry.Entries.ContainsKey(hoveredWindow)
            && hoveredWindow != _focusService.FocusedWindow)
        {
            _focusService.SetFocusedWindow(hoveredWindow, seat);
        }
    }

    public void HandleOpDelta(IntPtr seat, int dx, int dy)
    {
        RiverLog.Write("BRIDGE HandleOpDelta seat=0x" + seat.ToString("x") + " dx=" + dx + " dy=" + dy);
        var adw = _dragState.ActiveDragWindow;
        if (adw == null)
        {
            return;
        }

        // Drag (move or resize) is only meaningful while the float layout is active; in
        // tile/scrolling/monocle/grid the per- window Floating override is suppressed by LayoutProposer
        // bucketing and any FloatX/Y/W/H written here would be overwritten on the next manage cycle.
        // Treat a not-float OpDelta as an abandoned drag so the next legitimate drag starts clean.
        if (!_layoutProposer.IsFloatLayoutActive(adw.Output))
        {
            _dragState.DragFinished = true;
            _managerRequestSender.ScheduleManage();
            return;
        }

        adw.Floating = true;

        uint dragEdges = _dragState.DragEdges;
        if (dragEdges == 0)
        {
            // --- Interactive move -----
            adw.X = _dragState.DragStartX + dx;
            adw.Y = _dragState.DragStartY + dy;
            adw.HasFloatRect = true;
            adw.FloatX = adw.X;
            adw.FloatY = adw.Y;
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

            _managerRequestSender.ScheduleManage();
        }
        else
        {
            // --- Interactive resize ----- Edges bitfield (river_window_v1): top=1, bottom=2, left=4,
            // right=8.
            int startX = _dragState.DragStartX;
            int startY = _dragState.DragStartY;
            int startW = _dragState.DragStartW;
            int startH = _dragState.DragStartH;
            int newX = startX;
            int newY = startY;
            int newW = startW;
            int newH = startH;

            if ((dragEdges & 8u) != 0) // right
            {
                newW = startW + dx;
            }
            else if ((dragEdges & 4u) != 0) // left
            {
                newW = startW - dx;
                newX = startX + dx;
            }

            if ((dragEdges & 2u) != 0) // bottom
            {
                newH = startH + dy;
            }
            else if ((dragEdges & 1u) != 0) // top
            {
                newH = startH - dy;
                newY = startY + dy;
            }

            // Clamp to client-advertised min/max hints. A hint value of 0 means "no preference" per the
            // protocol.
            int minW = adw.MinW > 0 ? adw.MinW : 1;
            int minH = adw.MinH > 0 ? adw.MinH : 1;
            if (newW < minW)
            {
                if ((dragEdges & 4u) != 0)
                {
                    newX = startX + (startW - minW);
                }
                newW = minW;
            }
            if (newH < minH)
            {
                if ((dragEdges & 1u) != 0)
                {
                    newY = startY + (startH - minH);
                }
                newH = minH;
            }
            if (adw.MaxW > 0 && newW > adw.MaxW)
            {
                if ((dragEdges & 4u) != 0)
                {
                    newX = startX + (startW - adw.MaxW);
                }
                newW = adw.MaxW;
            }
            if (adw.MaxH > 0 && newH > adw.MaxH)
            {
                if ((dragEdges & 1u) != 0)
                {
                    newY = startY + (startH - adw.MaxH);
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

            _managerRequestSender.ScheduleManage();
        }
    }

    public void HandleOpRelease(IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandleOpRelease seat=0x" + seat.ToString("x"));
        _dragState.DragFinished = true;
    }
}
