using System;
using Aqueous.Features.Layout;
using Aqueous.Features.SnapZones;

namespace Aqueous.Features.Compositor.River;

// SnapZones drag hook (KZones / FancyZones-equivalent).
//
// The full feature (config schema, data model, hit-testing) lives under
// Aqueous.Features.SnapZones; this partial is the *integration* into
// the river-window-management drag pipeline.
//
// Two entry points:
//
//   * TryResolveSnapForDrag — pure helper. Hit-tests the cached pointer
//     position for a seat against the active SnapZone layout for the
//     dragged window's output and returns the resolved (clamped to
//     min/max client hints) zone rect. Used both by the live preview
//     during OpDelta and by the on-release apply.
//
//   * TrySnapDraggedWindowToZone — apply-on-release. Calls the helper
//     and overwrites the drag window's FloatX/Y/W/H so the next
//     manage cycle commits the snapped geometry.
//
// Live preview note (option C, see "currently does not actually render
// snapzones when dragging starts"):
//
//   Aqueous is a *client* of river-window-management and does not bind
//   wl_compositor / wl_shm — there is no path to allocate a buffer and
//   commit an overlay surface (the previous plan that proposed a
//   wlr-style layer-shell overlay assumed infrastructure that does not
//   exist in this codebase). Instead the live feedback during a drag is
//   produced by the dragged window itself: SeatEventHandler.OpDelta
//   asks TryResolveSnapForDrag whether the pointer is over a zone and,
//   if so, overrides the just-computed FloatX/Y/W/H with the resolved
//   zone rect. The user then sees the dragged window snap to and fill
//   the zone live, exactly like KWin's KZones preview but using the
//   real window as its own ghost.
//
// Constraints honoured here:
//   * float-layout gate is enforced by SeatEventHandler.OpDelta; we
//     don't need to re-check it.
//   * resize-drags (_dragEdges != 0) are not snapped — only moves.
//   * min/max client-advertised hints are honoured: a zone too small
//     for the toplevel's min size is refused; a zone larger than the
//     toplevel's max size is soft-clamped to the max anchored at the
//     zone's top-left.
internal sealed unsafe partial class RiverWindowManagerClient
{
    /// <summary>
    /// Resolves the SnapZone the pointer is currently hovering for the
    /// active drag-window, returning the screen-space rectangle the
    /// window should occupy if the drag were released right now.
    /// Returns false (and does not modify <paramref name="snapped"/>)
    /// when there is no active drag, no configured zones, no output
    /// match, no zone hit, or the resolved rect cannot legally hold
    /// the window per its min-size hints.
    /// </summary>
    /// <remarks>
    /// Pure: does not mutate any window/drag state and does not call
    /// ScheduleManage. Safe to invoke per-OpDelta sample.
    /// </remarks>
    private bool TryResolveSnapForDrag(IntPtr seat, out Rect snapped, out string? zoneName)
    {
        snapped = default;
        zoneName = null;

        var adw = _activeDragWindow;
        if (adw == null)
        {
            return false;
        }

        // Skip the lookup entirely when no zones are configured. This
        // is the common case until a user opts in via wm.toml.
        var store = _layoutConfig.SnapZones;
        if (store.IsEmpty)
        {
            return false;
        }

        // Pointer position is per-seat (cached by SeatEventHandler.PointerPosition).
        // If we don't have a sample yet (rare — the protocol emits one every
        // manage sequence), fall back to the window's current top-left. That
        // still produces a sensible snap for a drag that lands near the edge.
        int px, py;
        if (_seatPointerPos.TryGetValue(seat, out var pos))
        {
            px = pos.X;
            py = pos.Y;
        }
        else
        {
            px = adw.X;
            py = adw.Y;
        }

        // Resolve the dragged window's output rect. The drag is gated on
        // float-layout-active, which guarantees adw.Output is set.
        if (!_outputs.TryGetValue(adw.Output, out var output))
        {
            return false;
        }

        // Use the raw output rect as the usable area. The full plan
        // calls for subtracting layer-shell exclusive zones (panels)
        // here — Aqueous's layer-shell handler tracks those separately
        // and integrating them is a follow-up. As-is, snapping a
        // window flush against the screen edge is the standard
        // KZones default, so this is a sensible v1.
        var usable = new Rect(output.X, output.Y, output.Width, output.Height);
        if (usable.W <= 0 || usable.H <= 0)
        {
            return false;
        }

        var outputName = ResolveOutputName(adw.Output);
        var layout = store.ActiveLayoutFor(adw.Output, outputName);
        if (layout == null)
        {
            return false;
        }

        var hit = layout.Hit(px, py, usable);
        if (hit == null)
        {
            return false;
        }

        var rect = SnapZoneLayout.Resolve(hit.Value, usable);
        if (rect.W <= 0 || rect.H <= 0)
        {
            return false;
        }

        // Honour client-advertised min/max size hints. A zone smaller
        // than min-size cannot legally hold the window — refuse the
        // snap rather than producing a propose the client will reject.
        if (adw.MinW > 0 && rect.W < adw.MinW)
        {
            return false;
        }

        if (adw.MinH > 0 && rect.H < adw.MinH)
        {
            return false;
        }

        // Soft-clamp to max instead of refusing: a window that
        // explicitly caps its width/height is fine living inside a
        // larger zone, anchored to the zone's top-left corner.
        if (adw.MaxW > 0 && rect.W > adw.MaxW)
        {
            rect = new Rect(rect.X, rect.Y, adw.MaxW, rect.H);
        }

        if (adw.MaxH > 0 && rect.H > adw.MaxH)
        {
            rect = new Rect(rect.X, rect.Y, rect.W, adw.MaxH);
        }

        snapped = rect;
        zoneName = hit.Value.Name;
        return true;
    }

    /// <summary>
    /// Live drag-preview hook called from SeatEventHandler.OpDelta for
    /// move-drags (resize is intentionally excluded). When the pointer
    /// is over a SnapZone, overwrites the just-computed FloatX/Y/W/H
    /// on the dragged window with the resolved zone rect so the next
    /// manage cycle commits the snapped geometry — the dragged window
    /// itself becomes the visual preview, snapping into the zone as
    /// the pointer enters it and reverting to free-drag positioning
    /// when the pointer leaves.
    /// </summary>
    /// <remarks>
    /// We deliberately do *not* call ScheduleManage here: OpDelta is
    /// already triggering manage cycles via the existing drag
    /// machinery, and adding a per-sample schedule would multiply
    /// commit traffic during a move (which previously did not
    /// schedule because move-drags are committed by River itself).
    /// Tracks the last hovered zone in <c>_dragLastSnapZone</c> so we
    /// only emit one log line per zone transition rather than one per
    /// motion sample.
    /// </remarks>
    private void ApplyLiveSnapPreview(IntPtr seat)
    {
        var adw = _activeDragWindow;
        if (adw == null)
        {
            return;
        }

        if (TryResolveSnapForDrag(seat, out var rect, out var zoneName))
        {
            adw.X = rect.X;
            adw.Y = rect.Y;
            adw.HasFloatRect = true;
            adw.FloatX = rect.X;
            adw.FloatY = rect.Y;
            adw.FloatW = rect.W;
            adw.FloatH = rect.H;

            if (!string.Equals(_dragLastSnapZone, zoneName, StringComparison.Ordinal))
            {
                Log($"snap-zone '{zoneName}' previewed for window 0x{adw.Proxy.ToString("x")}: ({rect.X},{rect.Y} {rect.W}x{rect.H})");
                _dragLastSnapZone = zoneName;
                ScheduleManage();
            }
        }
        else if (_dragLastSnapZone != null)
        {
            // Pointer left the previously-hovered zone — restore the
            // free-drag rect (already written by OpDelta before this
            // call, so nothing to undo here) and reset the latch so a
            // re-entry logs again.
            Log($"snap-zone preview cleared for window 0x{adw.Proxy.ToString("x")}");
            _dragLastSnapZone = null;
            ScheduleManage();
        }
    }

    private void TrySnapDraggedWindowToZone(IntPtr seat)
    {
        var adw = _activeDragWindow;
        if (adw == null)
        {
            return;
        }

        if (!TryResolveSnapForDrag(seat, out var snapped, out var zoneName))
        {
            // Reset the live-preview latch on release regardless of
            // whether a zone was hit — the next drag should start
            // clean.
            _dragLastSnapZone = null;
            return;
        }

        adw.X = snapped.X;
        adw.Y = snapped.Y;
        adw.HasFloatRect = true;
        adw.FloatX = snapped.X;
        adw.FloatY = snapped.Y;
        adw.FloatW = snapped.W;
        adw.FloatH = snapped.H;

        Log($"snap-zone '{zoneName}' applied to window 0x{adw.Proxy.ToString("x")}: ({snapped.X},{snapped.Y} {snapped.W}x{snapped.H})");

        _dragLastSnapZone = null;

        // ManagerEventHandler will see _dragFinished on the next manage
        // cycle and emit op_finish_pointer; the float-layout pass will
        // then propose the new dimensions and commit set_position.
        ScheduleManage();
    }

    // Latch for the most recently previewed zone name during the
    // current drag. Lives in this partial so the field declaration sits
    // alongside the only code that reads/writes it.
    private string? _dragLastSnapZone;
}
