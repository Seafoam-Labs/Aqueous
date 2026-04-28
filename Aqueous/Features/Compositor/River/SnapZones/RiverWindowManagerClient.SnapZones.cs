using System;
using Aqueous.Features.Layout;
using Aqueous.Features.SnapZones;

namespace Aqueous.Features.Compositor.River;

// SnapZones drag-end hook (KZones / FancyZones-equivalent).
//
// The full feature (config schema, data model, hit-testing) lives under
// Aqueous.Features.SnapZones; this partial is the *integration* into
// the river-window-management drag pipeline. It is intentionally tiny:
// the drag state machine (SeatEventHandler.OpDelta / OpRelease,
// ManagerEventHandler finalisation) is unchanged — we only nudge the
// FloatX/Y/W/H that the existing OpDelta path has been writing on every
// pointer-motion sample, so the next manage cycle proposes the snapped
// geometry instead of the raw drop position.
//
// Constraints honoured here:
//   * float-layout gate already enforced by SeatEventHandler.OpDelta;
//     we don't need to re-check it.
//   * resize-drags (_dragEdges != 0) are not snapped — only moves.
//   * min/max client-advertised hints are honoured: if the resolved
//     zone rect cannot fit the toplevel, we *refuse* the snap rather
//     than half-applying (matches KZones behaviour).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void TrySnapDraggedWindowToZone(IntPtr seat)
    {
        var adw = _activeDragWindow;
        if (adw == null)
        {
            return;
        }

        // Skip the lookup entirely when no zones are configured. This
        // is the common case until a user opts in via wm.toml.
        var store = _layoutConfig.SnapZones;
        if (store.IsEmpty)
        {
            return;
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
            return;
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
            return;
        }

        var outputName = ResolveOutputName(adw.Output);
        var layout = store.ActiveLayoutFor(adw.Output, outputName);
        if (layout == null)
        {
            return;
        }

        var hit = layout.Hit(px, py, usable);
        if (hit == null)
        {
            return;
        }

        var snapped = SnapZoneLayout.Resolve(hit.Value, usable);
        if (snapped.W <= 0 || snapped.H <= 0)
        {
            return;
        }

        // Honour client-advertised min/max size hints. A zone smaller
        // than min-size or larger than max-size cannot legally hold the
        // window — refuse the snap rather than producing a propose
        // the client will reject.
        if (adw.MinW > 0 && snapped.W < adw.MinW)
        {
            Log($"snap-zone '{hit.Value.Name}' refused: min_w={adw.MinW} > zone w={snapped.W}");
            return;
        }

        if (adw.MinH > 0 && snapped.H < adw.MinH)
        {
            Log($"snap-zone '{hit.Value.Name}' refused: min_h={adw.MinH} > zone h={snapped.H}");
            return;
        }

        if (adw.MaxW > 0 && snapped.W > adw.MaxW)
        {
            // Soft-clamp to max instead of refusing: a window that
            // explicitly caps its width is fine living inside a
            // wider zone, anchored to the zone's top-left corner.
            snapped = new Rect(snapped.X, snapped.Y, adw.MaxW, snapped.H);
        }

        if (adw.MaxH > 0 && snapped.H > adw.MaxH)
        {
            snapped = new Rect(snapped.X, snapped.Y, snapped.W, adw.MaxH);
        }

        adw.X = snapped.X;
        adw.Y = snapped.Y;
        adw.HasFloatRect = true;
        adw.FloatX = snapped.X;
        adw.FloatY = snapped.Y;
        adw.FloatW = snapped.W;
        adw.FloatH = snapped.H;

        Log($"snap-zone '{hit.Value.Name}' applied to window 0x{adw.Proxy.ToString("x")} on output '{outputName ?? "?"}': ({snapped.X},{snapped.Y} {snapped.W}x{snapped.H})");

        // ManagerEventHandler will see _dragFinished on the next manage
        // cycle and emit op_finish_pointer; the float-layout pass will
        // then propose the new dimensions and commit set_position.
        ScheduleManage();
    }
}
