using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Layout-driving partial of <see cref="RiverWindowManagerClient"/>: owns
/// <c>ProposeForArea</c>, <c>BuildSnapshotFor</c>, <c>SendManagerRequest</c>,
/// <c>ScheduleManage</c>, the directional/scroll viewport helpers, and the
/// <c>IsFloatLayoutActive</c> probe used by the drag handler. Promoted out
/// of the inline declaration during the Phase 2 Step 7 readability refactor.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    // --- river_window_manager_v1 events -------------------------------





    private void SendManagerRequest(uint opcode)
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            _manager, opcode, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        WaylandInterop.wl_display_flush(_display);
    }

    /// <summary>
    /// Drive the layout subsystem for one output (or, if
    /// <paramref name="output"/> is <see cref="IntPtr.Zero"/>, the
    /// virtual fallback area). Builds a snapshot of the visible
    /// windows, asks <see cref="LayoutController.Arrange"/> for
    /// placements, and emits <c>propose_dimensions</c> only when the
    /// engine's choice differs from <c>WindowEntry.LastHintW/H</c>.
    /// </summary>
    private void ProposeForArea(IntPtr output, string? outputName, Rect usableArea)
    {
        // Floating windows are a layer, not a layout: they bypass the
        // active engine entirely and use their remembered FloatRect (set
        // by the Super+BTN_LEFT drag handler). When the active engine is
        // "float", we additionally treat every window as floating so the
        // user can drag any of them — the engine itself is only used to
        // compute an initial centred rect for windows that don't have
        // one yet.
        string activeId = _layoutController.ResolveLayoutId(output, outputName);
        bool floatIsActive = activeId == "float";

        // Per-output filter: an engine like ScrollingLayout maintains
        // per-output state (ScrollState.Columns) and *must* only see
        // the windows that belong to this output, otherwise its
        // per-output state accumulates handles from other outputs
        // and KeyNotFoundException / cross-monitor placements ensue.
        // Assignment policy: a window belongs to `output` if its
        // tracked W.Output matches; else, if its (X,Y) falls inside
        // usableArea we adopt it onto this output; otherwise skip.
        // For the IntPtr.Zero fallback (no outputs), accept all.
        bool isFallback = output == IntPtr.Zero;

        // Phase B1c — Tags. Resolve the visible-tag mask for this
        // output (or AllTags for the IntPtr.Zero fallback) so we
        // can filter windows whose Tags do not intersect the
        // mask out of the layout snapshot before invoking the
        // engine. Off-tag windows additionally need a one-shot
        // hide(opcode 4) so the compositor stops drawing them;
        // see the transition pass below.
        uint outputVisibleTags = Aqueous.Features.Tags.TagState.AllTags;
        if (!isFallback && _outputs.TryGetValue(output, out var oeForTags))
        {
            outputVisibleTags = oeForTags.VisibleTags;
        }

        var tiledSnapshot = new List<WindowEntryView>(_windows.Count);
        var floatingHandles = new List<IntPtr>();
        // Phase B1e Pass C: per-window state overrides. Fullscreen
        // and Maximized bypass the layout engine and route directly
        // to short bespoke loops below; their target rects come from
        // the host adapter (OutputRect / UsableArea).
        var fullscreenHandles = new List<IntPtr>();
        var maximizedHandles = new List<IntPtr>();
        // Pass C / C2: hiddenThisCycle is the union of (a) tag-hidden,
        // (b) WindowState.Minimized, and (c) scratchpad windows that
        // are currently dismissed (state.Visible == false). All three
        // share the existing one-shot hide(opcode 4) + cache-invalidation
        // treatment further down.
        var hiddenThisCycle = new List<WindowEntry>();
        foreach (var kvp in _windows)
        {
            var w = kvp.Value;

            if (!isFallback)
            {
                if (w.Output == IntPtr.Zero)
                {
                    // Adopt onto an output: prefer one whose area
                    // contains the current (X,Y); else skip — another
                    // output's ProposeForArea call will adopt it.
                    bool inside =
                        w.X >= usableArea.X && w.X < usableArea.X + usableArea.W &&
                        w.Y >= usableArea.Y && w.Y < usableArea.Y + usableArea.H;
                    if (inside)
                    {
                        w.Output = output;
                        // Phase B1c: inherit the output's currently
                        // visible tags so a freshly-mapped window
                        // appears on whatever tag the user is on
                        // (minus the reserved scratchpad bit). Only
                        // touch a window still sitting on the
                        // default tag — anything else came from a
                        // deliberate SendFocusedToTags.
                        if (w.Tags == Aqueous.Features.Tags.TagState.DefaultTag)
                        {
                            uint inheritMask = outputVisibleTags &
                                               ~Aqueous.Features.Tags.TagState.ScratchpadTag;
                            if (inheritMask != 0u)
                            {
                                w.Tags = inheritMask;
                            }
                        }
                    }
                    else
                    {
                        continue;
                    }
                }
                else if (w.Output != output)
                {
                    continue;
                }
            }

            // Tag visibility gate: a window present on this output
            // but whose Tags do not intersect VisibleTags must not
            // be passed to the layout engine and must be hidden
            // compositor-side.
            bool tagVisible = Aqueous.Features.Tags.TagState.IsVisible(
                w.Tags, outputVisibleTags);
            if (!tagVisible)
            {
                hiddenThisCycle.Add(w);
                continue;
            }

            // Phase B1e Pass C / C2: window-state visibility filter.
            // Minimized windows and scratchpad-parked windows whose
            // visibility flag is currently false (pad dismissed) are
            // hidden the same way tag-hidden windows are: a one-shot
            // hide(opcode 4), placement caches invalidated, and
            // skipped from the layout snapshot entirely.
            _windowStates.TryGetValue(kvp.Key, out var wsState);
            if (wsState != null &&
                (wsState.State == WindowState.Minimized ||
                 (wsState.InScratchpad && !wsState.Visible)))
            {
                hiddenThisCycle.Add(w);
                continue;
            }

            // Phase B1e Pass C / C3: state-driven geometry routing.
            // Fullscreen and Maximized bypass the active layout
            // engine; Floating uses the existing per-window FloatRect
            // path.  When the active engine is "float" we still treat
            // every window as floating so the user's drag handler
            // works as before.  Note that a window can only be
            // Fullscreen on the output it's pinned to: if a window
            // wandered onto a different output, demote it back to
            // its previous state for this cycle.
            if (wsState != null && wsState.State == WindowState.Fullscreen)
            {
                // Single-FS-per-output: only the slot owner gets the
                // FS rect. Defence-in-depth: if a stale FS flag
                // somehow survives an output change, fall through to
                // the Tiled bucket without emitting two FS rects.
                var fsOwner = _outputFullscreen.TryGetValue(output, out var owner) ? owner : IntPtr.Zero;
                if (fsOwner == IntPtr.Zero || fsOwner == kvp.Key)
                {
                    fullscreenHandles.Add(kvp.Key);
                    continue;
                }

                Log($"FS slot conflict on output 0x{output.ToString("x")}: " +
                    $"window 0x{kvp.Key.ToString("x")} flagged FS but slot owner is 0x{fsOwner.ToString("x")}; demoting to tiled");
            }

            if (wsState != null && wsState.State == WindowState.Maximized)
            {
                maximizedHandles.Add(kvp.Key);
                continue;
            }

            if (wsState != null && wsState.State == WindowState.Floating)
            {
                // Seed the WindowEntry's FloatRect from the controller's
                // remembered FloatingGeom on the first cycle a window
                // enters Floating, so the bespoke loop below has a rect
                // to emit even if the user has never dragged it.
                if (!w.HasFloatRect && wsState.FloatingGeom is { } g && g.W > 0 && g.H > 0)
                {
                    w.FloatX = g.X;
                    w.FloatY = g.Y;
                    w.FloatW = g.W;
                    w.FloatH = g.H;
                    w.HasFloatRect = true;
                }

                floatingHandles.Add(kvp.Key);
                continue;
            }

            // Floating is honoured only when the active layout is the
            // dedicated `float` engine. In tile/scrolling/monocle/grid the
            // per-window Floating override is suppressed so every window
            // goes through the active tiling engine.
            // When the float engine is active, every window goes onto
            // the floating layer. Otherwise the per-window Floating
            // override is suppressed so the tiling engine owns geometry.
            if (floatIsActive)
            {
                floatingHandles.Add(kvp.Key);
            }
            else
            {
                tiledSnapshot.Add(new WindowEntryView(
                    Handle: kvp.Key,
                    MinW: w.MinW, MinH: w.MinH,
                    MaxW: w.MaxW, MaxH: w.MaxH,
                    Floating: false,
                    Fullscreen: false,
                    Tags: w.Tags));
            }
        }

        // Visibility transition pass for tag-hidden windows.
        // Emit river_window_v1::hide (opcode 4) once per
        // hide transition, and clear placement caches so a
        // subsequent re-show re-issues propose_dimensions /
        // set_position. Hidden windows must not participate in
        // the per-frame render loop either, hence Visible=false.
        for (int hi = 0; hi < hiddenThisCycle.Count; hi++)
        {
            var w = hiddenThisCycle[hi];
            if (!w.HideSent)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    w.Proxy, 4, IntPtr.Zero, 0, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                w.HideSent = true;
                // Force re-propose / re-position on next show.
                w.LastHintW = 0;
                w.LastHintH = 0;
                w.LastPosX = int.MinValue;
                w.LastPosY = int.MinValue;
                w.LastClipW = 0;
                w.LastClipH = 0;
            }

            w.TagVisible = false;
            w.Visible = false;
        }

        // Adoption fallback: if we are the *only* output and no
        // window has been assigned yet (happens on first cycle
        // because windows start at cascade offsets that may sit
        // outside the reported usableArea), adopt every unassigned
        // window onto us so they are not silently dropped.
        if (!isFallback && tiledSnapshot.Count == 0 && floatingHandles.Count == 0 && _outputs.Count == 1)
        {
            foreach (var kvp in _windows)
            {
                var w = kvp.Value;
                if (w.Output == IntPtr.Zero)
                {
                    w.Output = output;
                }

                bool treatAsFloating = floatIsActive && w.Floating;
                if (floatIsActive || treatAsFloating)
                {
                    floatingHandles.Add(kvp.Key);
                }
                else
                {
                    tiledSnapshot.Add(new WindowEntryView(
                        Handle: kvp.Key, MinW: w.MinW, MinH: w.MinH,
                        MaxW: w.MaxW, MaxH: w.MaxH,
                        Floating: false, Fullscreen: false, Tags: 0u));
                }
            }
        }

        // -------- Tiled windows: drive through the layout engine --------
        if (tiledSnapshot.Count > 0)
        {
            IReadOnlyList<WindowPlacement> placements;
            try
            {
                placements = _layoutController.Arrange(
                    output, outputName, usableArea, tiledSnapshot, _focusedWindow);
            }
            catch (Exception ex)
            {
                Log("layout engine threw, skipping arrange: " + ex.Message);
                placements = Array.Empty<WindowPlacement>();
            }

            for (int i = 0; i < placements.Count; i++)
            {
                var p = placements[i];
                if (!_windows.TryGetValue(p.Handle, out var w))
                {
                    continue;
                }

                int pw = p.Geometry.W;
                int ph = p.Geometry.H;
                if (pw <= 0 || ph <= 0)
                {
                    continue;
                }

                // Honor Visible: invisible (off-screen) placements
                // must NOT trigger set_position with negative coords
                // (render_start checks w.Visible) and must NOT spam
                // propose_dimensions every manage cycle. Update size
                // tracking only on real change so the next time the
                // window scrolls back into view we don't re-propose.
                if (!p.Visible)
                {
                    w.Visible = false;
                    // Cache size for the off-screen column without
                    // any wire traffic; if the column width changes
                    // later we will propose only when it becomes
                    // visible again or when it actually changes.
                    if (pw != w.LastHintW || ph != w.LastHintH)
                    {
                        // Don't update LastHintW/H for invisible windows —
                        // we want the next visible cycle to fire propose
                        // exactly once if needed. Just skip silently.
                    }

                    continue;
                }

                w.Visible = true;
                w.TagVisible = true;
                w.HideSent = false;

                if (pw == w.LastHintW && ph == w.LastHintH)
                {
                    w.X = p.Geometry.X;
                    w.Y = p.Geometry.Y;
                    continue;
                }

                w.LastHintW = pw;
                w.LastHintH = ph;
                w.ProposedW = pw;
                w.ProposedH = ph;
                w.X = p.Geometry.X;
                w.Y = p.Geometry.Y;

                WaylandInterop.wl_proxy_marshal_flags(
                    p.Handle, 3, IntPtr.Zero, 0, 0,
                    (IntPtr)pw, (IntPtr)ph,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            }
        }

        // -------- Floating layer: use the remembered FloatRect ---------
        // Initial-rect math matches FloatingLayout.Arrange so the very
        // first frame of a never-dragged window in float-active mode is
        // identical to what the engine would have produced.
        int initW = Math.Min(800, (int)(usableArea.W * 0.6));
        int initH = Math.Min(600, (int)(usableArea.H * 0.6));
        int initX = usableArea.X + (usableArea.W - initW) / 2;
        int initY = usableArea.Y + (usableArea.H - initH) / 2;

        for (int i = 0; i < floatingHandles.Count; i++)
        {
            var handle = floatingHandles[i];
            if (!_windows.TryGetValue(handle, out var w))
            {
                continue;
            }

            if (!w.HasFloatRect)
            {
                w.FloatX = initX;
                w.FloatY = initY;
                w.FloatW = initW;
                w.FloatH = initH;
                w.HasFloatRect = true;
            }

            int pw = w.FloatW, ph = w.FloatH;
            if (pw <= 0 || ph <= 0)
            {
                continue;
            }

            // Position is what the user dragged to; never overwritten by
            // any engine call. Width/height only proposed when changed.
            w.X = w.FloatX;
            w.Y = w.FloatY;
            w.Visible = true;
            w.TagVisible = true;
            w.HideSent = false;

            if (pw != w.LastHintW || ph != w.LastHintH)
            {
                w.LastHintW = pw;
                w.LastHintH = ph;
                w.ProposedW = pw;
                w.ProposedH = ph;
                WaylandInterop.wl_proxy_marshal_flags(
                    handle, 3, IntPtr.Zero, 0, 0,
                    (IntPtr)pw, (IntPtr)ph,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            }
        }

        // -------- Phase B1e Pass C: Maximized layer --------------------
        // Maximized windows cover the usable area of their pinned
        // output (or this output, when not pinned). Geometry follows
        // exactly the same diff-gating discipline as the floating
        // loop above so we don't re-propose every cycle.
        for (int i = 0; i < maximizedHandles.Count; i++)
        {
            var handle = maximizedHandles[i];
            if (!_windows.TryGetValue(handle, out var w))
            {
                continue;
            }

            int tx = usableArea.X, ty = usableArea.Y;
            int pw = usableArea.W, ph = usableArea.H;
            if (pw <= 0 || ph <= 0)
            {
                continue;
            }

            w.X = tx;
            w.Y = ty;
            w.Visible = true;
            w.TagVisible = true;
            w.HideSent = false;

            if (pw != w.LastHintW || ph != w.LastHintH)
            {
                w.LastHintW = pw;
                w.LastHintH = ph;
                w.ProposedW = pw;
                w.ProposedH = ph;
                WaylandInterop.wl_proxy_marshal_flags(
                    handle, 3, IntPtr.Zero, 0, 0,
                    (IntPtr)pw, (IntPtr)ph,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            }
        }

        // -------- Phase B1e Pass C: Fullscreen layer -------------------
        // Fullscreen windows cover the raw output rect (no struts,
        // no gaps). The single-FS-per-output invariant is enforced
        // up in the snapshot pass; here we trust the bucket.
        // Note: ProposeForArea is invoked once per output with
        // `usableArea` already equal to the OutputEntry rect (see
        // the `manage_start` caller around line 840), so for now we
        // use `usableArea` minus any reservation as the FS rect by
        // *adding back* the OutputEntry's full rect when one is
        // available. UsableArea reservation is a TODO(passC1)
        // pending real exclusive_zone tracking, so today
        // `OutputRect == UsableArea` and the two loops produce
        // identical geometry — which is the documented Pass C
        // behaviour without C1 reservations.
        Rect outputRect = usableArea;
        if (output != IntPtr.Zero && _outputs.TryGetValue(output, out var oeFull))
        {
            outputRect = new Rect(oeFull.X, oeFull.Y,
                oeFull.Width > 0 ? oeFull.Width : usableArea.W,
                oeFull.Height > 0 ? oeFull.Height : usableArea.H);
        }

        for (int i = 0; i < fullscreenHandles.Count; i++)
        {
            var handle = fullscreenHandles[i];
            if (!_windows.TryGetValue(handle, out var w))
            {
                continue;
            }

            int tx = outputRect.X, ty = outputRect.Y;
            int pw = outputRect.W, ph = outputRect.H;
            if (pw <= 0 || ph <= 0)
            {
                continue;
            }

            w.X = tx;
            w.Y = ty;
            w.Visible = true;
            w.TagVisible = true;
            w.HideSent = false;

            if (pw != w.LastHintW || ph != w.LastHintH)
            {
                w.LastHintW = pw;
                w.LastHintH = ph;
                w.ProposedW = pw;
                w.ProposedH = ph;
                WaylandInterop.wl_proxy_marshal_flags(
                    handle, 3, IntPtr.Zero, 0, 0,
                    (IntPtr)pw, (IntPtr)ph,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            }
        }
    }

    // --- utility -------------------------------------------------------

    /// <summary>
    /// True iff the active layout (resolved against the focused window's
    /// output, or the first known output as a fallback) is the dedicated
    /// `float` engine. Drag-to-float promotion and the
    /// builtin:toggle_floating action consult this so per-window floating
    /// is inert in tile/scrolling/monocle/grid layouts.
    /// </summary>
    internal bool IsFloatLayoutActive()
    {
        IntPtr output = IntPtr.Zero;
        string? outputName = null;
        if (_focusedWindow != IntPtr.Zero &&
            _windows.TryGetValue(_focusedWindow, out var fw) &&
            fw.Output != IntPtr.Zero)
        {
            output = fw.Output;
        }
        else
        {
            foreach (var k in _outputs.Keys)
            {
                output = k;
                break;
            }
        }

        return _layoutController.ResolveLayoutId(output, outputName) == "float";
    }


    /// <summary>
    /// Ask the compositor to start a new manage sequence so that any state we
    /// changed outside of one (pending focus from pointer-enter, Super+Tab,
    /// close-and-refocus, drag start) actually gets flushed promptly.
    /// river_window_manager_v1::manage_dirty is opcode 3.
    /// </summary>
    private void ScheduleManage()
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }
        // If we're already inside a manage/render sequence the compositor will flush
        // our pending state when the current handler returns; issuing manage_dirty now
        // would just guarantee an extra cycle (and a potential infinite loop).
        if (_insideManageSequence)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(_manager, 3, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        WaylandInterop.wl_display_flush(_display);
    }

    /// <summary>
    /// Engine-aware directional focus. Asks the active layout engine for
    /// its preferred neighbour (e.g. scrolling's column ordering) and
    /// falls back to insertion-order CycleFocus when the engine has no
    /// opinion. After focus changes to a possibly off-screen window we
    /// schedule a manage cycle so the engine recentres its viewport
    /// (otherwise render_start would skip the new focused window
    /// because Visible=false).
    /// </summary>

    private void HandleScrollViewport(int deltaColumns)
    {
        if (_focusedWindow == IntPtr.Zero || !_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return;
        }

        _layoutController.ScrollViewport(fw.Output, ResolveOutputName(fw.Output), deltaColumns);
        ScheduleManage();
    }

    private void HandleMoveColumn(FocusDirection dir)
    {
        if (_focusedWindow == IntPtr.Zero || !_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return;
        }

        if (_layoutController.MoveFocused(fw.Output, ResolveOutputName(fw.Output), _focusedWindow, dir))
        {
            ScheduleManage();
        }
    }

    /// <summary>Build a per-output WindowEntryView snapshot for navigation queries.</summary>
    private List<WindowEntryView> BuildSnapshotFor(IntPtr output)
    {
        var list = new List<WindowEntryView>(_windows.Count);
        foreach (var kvp in _windows)
        {
            var w = kvp.Value;
            if (output != IntPtr.Zero && w.Output != IntPtr.Zero && w.Output != output)
            {
                continue;
            }

            list.Add(new WindowEntryView(
                Handle: kvp.Key,
                MinW: w.MinW, MinH: w.MinH, MaxW: w.MaxW, MaxH: w.MaxH,
                Floating: w.Floating, Fullscreen: false, Tags: 0u));
        }

        return list;
    }

    private string? ResolveOutputName(IntPtr output)
    {
        // OutputEntry does not currently surface a name field; per-output
        // config matching is handled separately. Returning null keeps the
        // controller's resolution path identical to ProposeForArea's.
        _ = output;
        return null;
    }


    private static string? MarshalUtf8(IntPtr p)
        => p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
}
