using System;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 8.3 transient bridge — explicit-interface impl forwarding the
/// god-class's seat-interaction service, focus follow, and drag state
/// into the lifted <see cref="SeatEventHandler"/>. Retired in Stage 9
/// when the relevant state (`_activeDragWindow`, `_dragStart*`,
/// `_focusedWindow`, `_layoutConfig`, seat-interaction service) moves
/// onto dedicated services.
///
/// The OpDelta / OpRelease bodies preserved byte-for-byte from the
/// original <c>OnSeatEvent</c> switch in <see cref="SeatEventHandler"/>
/// (which is now a standalone <see cref="IEventHandler"/> implementation).
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    internal void CachePointerPosition(IntPtr seat, int x, int y)
    {
        // river_window_management_v1::pointer_position declares its args
        // as type="int" in the protocol XML — global logical coordinates
        // already in pixel space, NOT wl_fixed. A prior fix mistakenly
        // applied a >> 8 shift here, which divided cursor positions by 256
        // and snapped every drag to a tiny rect near the origin (the
        // "window jumps to 0,0" regression). Cache as-is.
        _seatPointerPos[seat] = (x, y);
    }

    internal void HandleWindowInteraction(IntPtr window, IntPtr seat)
    {
        Log("BRIDGE HandleWindowInteraction window=0x" + window.ToString("x") + " seat=0x" + seat.ToString("x"));
        _seatInteractionService.HandleWindowInteraction(window, seat);
    }

    internal void HandleShellSurfaceInteraction(IntPtr shellSurface, IntPtr seat)
    {
        Log("BRIDGE HandleShellSurfaceInteraction ss=0x" + shellSurface.ToString("x") + " seat=0x" + seat.ToString("x"));
        _seatInteractionService.HandleShellSurfaceInteraction(shellSurface, seat);
    }

    internal void HandlePointerEnterFocusFollow(IntPtr hoveredWindow, IntPtr seat)
    {
        Log("BRIDGE HandlePointerEnterFocusFollow hovered=0x" + hoveredWindow.ToString("x") + " seat=0x" + seat.ToString("x"));
        if (_layoutConfig.Input.FocusFollowsMouse
            && hoveredWindow != IntPtr.Zero
            && _windowRegistry.Entries.ContainsKey(hoveredWindow)
            && hoveredWindow != _focusedWindow)
        {
            SetFocusedWindow(hoveredWindow, seat);
        }
    }

    internal void HandleOpDelta(IntPtr seat, int dx, int dy)
    {
        Log("BRIDGE HandleOpDelta seat=0x" + seat.ToString("x") + " dx=" + dx + " dy=" + dy);
        if (_activeDragWindow == null)
        {
            return;
        }

        var adw = _activeDragWindow;

        // Drag (move or resize) is only meaningful while the float
        // layout is active; in tile/scrolling/monocle/grid the per-
        // window Floating override is suppressed by LayoutProposer
        // bucketing and any FloatX/Y/W/H written here would be
        // overwritten on the next manage cycle. Fix #4: rather than
        // just `break`-ing (which would leave _dragEdges /
        // _dragResizeInformed sticky if the layout was switched away
        // from float mid-gesture), treat a not-float OpDelta as an
        // abandoned drag and tear down the same way a release would,
        // so the next legitimate drag starts clean.
        if (!IsFloatLayoutActive(adw.Output))
        {
            _dragFinished = true;
            ScheduleManage();
            return;
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
            // positive committed/hinted value.
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

            // SnapZones live preview: if the pointer is currently over
            // a configured zone, override the free-drag rect we just
            // wrote with the resolved zone rect.
            _snapZoneService.ApplyLiveSnapPreview(seat);
        }
        else
        {
            // ----- interactive resize -----
            // Edges bitfield (river_window_v1): top=1, bottom=2, left=4, right=8.
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

            // Clamp to client-advertised min/max hints. A hint value
            // of 0 means "no preference" per the protocol.
            int minW = adw.MinW > 0 ? adw.MinW : 1;
            int minH = adw.MinH > 0 ? adw.MinH : 1;
            if (newW < minW)
            {
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

            // Force the float layer of ProposeForArea to emit a fresh
            // propose_dimensions next manage cycle so the client
            // actually grows/shrinks.
            ScheduleManage();
        }
    }

    internal void HandleOpRelease(IntPtr seat)
    {
        Log("BRIDGE HandleOpRelease seat=0x" + seat.ToString("x"));
        // SnapZones: only for interactive moves (resize ignored). If
        // the pointer landed inside a configured zone for the window's
        // output, override the just-computed FloatX/Y/W/H with the
        // resolved zone rect so ManagerEventHandler emits
        // propose_dimensions with the snapped geometry on the next
        // manage cycle. The protocol op_finish_pointer is still issued
        // by the existing finalisation path — SnapZones piggy-backs on
        // that, no new wire traffic.
        if (_activeDragWindow != null && _dragEdges == 0)
        {
            _snapZoneService.TrySnapDraggedWindowToZone(seat);
        }

        _dragFinished = true;
    }
}
