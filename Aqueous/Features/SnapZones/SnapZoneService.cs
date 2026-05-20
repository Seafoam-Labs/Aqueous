using System;
using System.Collections.Generic;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Layout;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// SnapZones drag hook (KZones / FancyZones-equivalent). PR 9.12 §2.13
/// drained the former <c>RiverWindowManagerClient.SnapZones</c> partial
/// here; the service reads the few remaining god-class fields
/// (active-drag window, per-seat pointer cache, output registry,
/// layout config, drag activator) through internal accessors and
/// schedules manage cycles via <see cref="IManagerRequestSender"/>.
/// Those accessors retire together with the god class in the final
/// demolition step.
/// </summary>
internal sealed class SnapZoneService : ISnapZoneService
{
    private readonly RiverWindowManagerClient _client;

    // Latch for the most recently previewed zone name during the
    // current drag. Lives on the service so a re-entry into the same
    // zone only logs once.
    private string? _dragLastSnapZone;

    public SnapZoneService(RiverWindowManagerClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

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

        var adw = _client.ActiveDragWindow;
        if (adw == null)
        {
            return false;
        }

        // Skip the lookup entirely when no zones are configured. This
        // is the common case until a user opts in via wm.toml.
        var store = _client.LayoutConfig.SnapZones;
        if (store.IsEmpty)
        {
            return false;
        }

        // Pointer position is per-seat (cached by SeatEventHandler.PointerPosition).
        // If we don't have a sample yet (rare — the protocol emits one every
        // manage sequence), fall back to the window's current top-left. That
        // still produces a sensible snap for a drag that lands near the edge.
        int px, py;
        bool pointerCacheHit = _client.SeatPointerPos.TryGetValue(seat, out var pos);
        if (pointerCacheHit)
        {
            px = pos.X;
            py = pos.Y;
        }
        else
        {
            px = adw.X;
            py = adw.Y;
        }

        // Diagnostic: identify whether snap-zone failures are caused by
        // a stale/empty pointer cache, mis-resolved output, or activator
        // mismatch. Remove once the post-PR-8.3 snap regression is
        // diagnosed and the real root cause is fixed.
        RiverLog.Write($"snap-resolve seat=0x{seat.ToString("x")} src={(pointerCacheHit ? "cache" : "fallback")} px={px} py={py} activeDragActivator={_client.ActiveDragActivator}");

        // Resolve the dragged window's output rect. The drag is gated on
        // float-layout-active, which guarantees adw.Output is set.
        if (!_client.OutputRegistry.Entries.TryGetValue(adw.Output, out var output))
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

        var outputName = _client.ResolveOutputName(adw.Output);
        var layout = store.ActiveLayoutFor(adw.Output, outputName);
        if (layout == null)
        {
            return false;
        }

        // Activator gate (KZones-style opt-in modifier). When the
        // layout requires a non-Always activator, snap only when the
        // drag was armed by the matching Super+<activator>+BTN_LEFT
        // pointer binding. Always-activated layouts continue to snap
        // for any move-drag (the v1 behaviour). The activator is
        // baked into the drag at press time — releasing the modifier
        // mid-drag does NOT cancel the snap, because river pointer
        // bindings only carry their static modifier mask. This is a
        // conscious trade-off; see the registration code in
        // ManagerEventHandler.SeatInformation for the rationale.
        if (layout.Activator != SnapActivator.Always &&
            layout.Activator != _client.ActiveDragActivator)
        {
            RiverLog.Write($"snap-resolve activator-gate-skip layout.Activator={layout.Activator} activeDrag={_client.ActiveDragActivator}");
            return false;
        }

        var hit = layout.Hit(px, py, usable);
        RiverLog.Write($"snap-hit usable={usable.X},{usable.Y},{usable.W}x{usable.H} layoutActivator={layout.Activator} hit={(hit?.Name ?? "<none>")}");
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
    public void ApplyLiveSnapPreview(IntPtr seat)
    {
        var adw = _client.ActiveDragWindow;
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
                RiverLog.Write($"snap-zone '{zoneName}' previewed for window 0x{adw.Proxy.ToString("x")}: ({rect.X},{rect.Y} {rect.W}x{rect.H})");
                _dragLastSnapZone = zoneName;
                _client.ManagerRequestSender.ScheduleManage();
            }
        }
        else if (_dragLastSnapZone != null)
        {
            // Pointer left the previously-hovered zone — restore the
            // free-drag rect (already written by OpDelta before this
            // call, so nothing to undo here) and reset the latch so a
            // re-entry logs again.
            RiverLog.Write($"snap-zone preview cleared for window 0x{adw.Proxy.ToString("x")}");
            _dragLastSnapZone = null;
            _client.ManagerRequestSender.ScheduleManage();
        }
    }

    public void TrySnapDraggedWindowToZone(IntPtr seat)
    {
        var adw = _client.ActiveDragWindow;
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

        RiverLog.Write($"snap-zone '{zoneName}' applied to window 0x{adw.Proxy.ToString("x")}: ({snapped.X},{snapped.Y} {snapped.W}x{snapped.H})");

        _dragLastSnapZone = null;

        // ManagerEventHandler will see _dragFinished on the next manage
        // cycle and emit op_finish_pointer; the float-layout pass will
        // then propose the new dimensions and commit set_position.
        _client.ManagerRequestSender.ScheduleManage();
    }

    /// <summary>
    /// Enumerates every <see cref="SnapZoneLayout"/> currently in the
    /// store, grouped by output. Used at seat-info time to discover the
    /// distinct activator modifiers that need their own pointer
    /// bindings registered.
    /// </summary>
    public IEnumerable<IReadOnlyList<SnapZoneLayout>> CollectAllSnapLayouts()
    {
        var store = _client.LayoutConfig.SnapZones;
        if (store.IsEmpty)
        {
            yield break;
        }

        // The store doesn't expose its dictionary; iterate the known
        // outputs (incl. the wildcard) and dedup.
        var seen = new HashSet<SnapZoneLayout>();
        var names = new List<string?> { null, SnapZoneStore.Wildcard };
        foreach (var kv in _client.OutputRegistry.Entries)
        {
            names.Add(_client.ResolveOutputName(kv.Key));
        }

        foreach (var n in names)
        {
            var list = store.LayoutsFor(n);
            if (list.Count == 0)
            {
                continue;
            }

            var fresh = new List<SnapZoneLayout>();
            foreach (var l in list)
            {
                if (seen.Add(l))
                {
                    fresh.Add(l);
                }
            }

            if (fresh.Count > 0)
            {
                yield return fresh;
            }
        }
    }

    /// <summary>
    /// Maps a <see cref="SnapActivator"/> to the river_seat_v1 modifier
    /// bitmask used when registering pointer bindings. Returns 0 for
    /// <see cref="SnapActivator.Always"/> (which is handled by the
    /// plain Super+LMB binding and does not need a separate proxy).
    /// </summary>
    public uint ActivatorToMask(SnapActivator activator) => activator switch
    {
        SnapActivator.Shift => Mods.ModShift,
        SnapActivator.Ctrl  => Mods.ModCtrl,
        SnapActivator.Alt   => Mods.ModAlt,
        SnapActivator.Super => Mods.ModSuper,
        _ => 0u,
    };
}
