using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.State;

namespace Aqueous.Features.Layout;

/// <summary>
/// Lift of the <c>RiverWindowManagerClient.LayoutProposer.cs</c> partial (741 LOC) into a
/// top-level service. Owns <see cref="ProposeForArea"/> (the geometry-driving core), <see
/// cref="BuildSnapshotFor"/>, the <see cref="IsFloatLayoutActive()"/> probes, and <see
/// cref="ResolveOutputName"/>. The class methods of the same names are now thin forwarders to this
/// class (kept because five partial event-handler files still call them via <c>this</c>).
/// <para>
/// Construction still takes a <see cref="RiverWindowManagerClient"/> reference because the
/// proposer reads/writes class state that has not yet been lifted into its own singletons:
/// <c>_layoutController</c>, the <c>IWindowRegistry</c> / <c>IOutputRegistry</c>, the
/// <c>WindowStateStore</c>, the <c>OutputFullscreenMap</c>, the focused-window handle, and the
/// <c>_prevFullscreenHandles</c> hash set. Each is reached through a small set of <c>internal</c>
/// accessors on the god class. Those accessors retire together with the god class in the final
/// demolition step.
/// </para>
/// <para>
/// Pump-thread only. Mirrors the prior partial's threading contract exactly; no new locks or
/// queues are introduced here.
/// </para>
/// </summary>
internal sealed unsafe class LayoutProposer : ILayoutProposer
{
    // Cut off RiverWindowManagerClient. All class accessors. LayoutFocusNeighbor is delegated
    // directly to LayoutController.FocusNeighbor (the prior class forwarder is gone).
    private readonly LayoutController _layoutController;
    private readonly IWindowRegistry _windowRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly WindowStateStore _windowStates;
    private readonly OutputFullscreenMap _outputFullscreen;
    private readonly FocusedWindowTracker _focusedWindowTracker;
    private readonly PrevFullscreenStore _prevFullscreenStore;

    public LayoutProposer(
        LayoutController layoutController,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        WindowStateStore windowStates,
        OutputFullscreenMap outputFullscreen,
        FocusedWindowTracker focusedWindowTracker,
        PrevFullscreenStore prevFullscreenStore)
    {
        _layoutController     = layoutController     ?? throw new ArgumentNullException(nameof(layoutController));
        _windowRegistry       = windowRegistry       ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry       = outputRegistry       ?? throw new ArgumentNullException(nameof(outputRegistry));
        _windowStates         = windowStates         ?? throw new ArgumentNullException(nameof(windowStates));
        _outputFullscreen     = outputFullscreen     ?? throw new ArgumentNullException(nameof(outputFullscreen));
        _focusedWindowTracker = focusedWindowTracker ?? throw new ArgumentNullException(nameof(focusedWindowTracker));
        _prevFullscreenStore  = prevFullscreenStore  ?? throw new ArgumentNullException(nameof(prevFullscreenStore));
    }

    /// <summary>
    /// Drive the layout subsystem for one output (or, if <paramref name="output"/> is <see
    /// cref="IntPtr.Zero"/>, the virtual fallback area). Builds a snapshot of the visible windows,
    /// asks <see cref="LayoutController.Arrange"/> for placements, and emits <c>propose_dimensions</c>
    /// only when the engine's choice differs from <c>WindowEntry.LastHintW/H</c>.
    /// </summary>
    public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea) =>
        ProposeForArea(output, outputName, usableArea, usableArea);

    /// <summary>
    /// Drive the layout subsystem for one output. <paramref name="outputRect"/> is the raw
    /// output rectangle (no struts applied) used by the fullscreen branch and by any rule-matched
    /// window with <c>ignore_struts = true</c>; <paramref name="usableArea"/> is the strut-shrunk
    /// rect consumed by every other branch (tiled, floating, maximized without opt-in).
    /// </summary>
    public void ProposeForArea(IntPtr output, string? outputName, Rect outputRect, Rect usableArea)
    {
        var layoutController = _layoutController;
        var windowRegistry = _windowRegistry;
        var outputRegistry = _outputRegistry;
        var windowStates = _windowStates;
        var outputFullscreen = _outputFullscreen;
        var focusedWindow = _focusedWindowTracker.Current;
        var prevFullscreenHandles = _prevFullscreenStore.Handles;

        // Stamp the currently-focused window's LastFocusTick from the tracker once per pass
        // so GameModeLayout can break anchor ties deterministically ("most-recently focused
        // wins"). Cost: one dictionary hit per proposer pass.
        if (focusedWindow != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(focusedWindow, out var focusedEntry))
        {
            focusedEntry.LastFocusTick = _focusedWindowTracker.CurrentTick;
        }

        // Floating windows are a layer, not a layout: they bypass the active engine entirely and use
        // their remembered FloatRect (set by the Super+BTN_LEFT drag handler). When the active engine is
        // "float", we additionally treat every window as floating so the user can drag any of them — the
        // engine itself is only.
        string activeId = layoutController.ResolveLayoutId(output, outputName);
        bool floatIsActive = activeId == "float";

        // Per-output filter: an engine like ScrollingLayout maintains per-output state
        // (ScrollState.Columns) and *must* only see the windows that belong to this output, otherwise its
        // per-output state accumulates handles from other outputs and KeyNotFoundException /
        // cross-monitor placements ensue. Assignment policy: a window belongs to `output` if its tracked
        // W.Output matches; else, if its (X,Y) falls inside usableArea we adopt it onto this output;
        // otherwise skip. For the IntPtr.Zero fallback (no outputs), accept all.
        bool isFallback = output == IntPtr.Zero;

        // Phase B1c — Tags. Resolve the visible-tag mask for this output (or AllTags for the IntPtr.Zero
        // fallback) so we can filter windows whose Tags do not intersect the mask out of the layout
        // snapshot before invoking the engine. Off-tag windows additionally need a one-shot hide(opcode
        // 4) so the compositor stops drawing them; see the transition pass below.
        uint outputVisibleTags = Aqueous.Features.Tags.TagState.AllTags;
        if (!isFallback && outputRegistry.Entries.TryGetValue(output, out var oeForTags))
        {
            outputVisibleTags = oeForTags.VisibleTags;
        }

        var tiledSnapshot = new List<WindowEntryView>(windowRegistry.Entries.Count);
        var floatingHandles = new List<IntPtr>();
        var fullscreenHandles = new List<IntPtr>();
        var maximizedHandles = new List<IntPtr>();
        var hiddenThisCycle = new List<WindowEntry>();
        foreach (var kvp in windowRegistry.Entries)
        {
            var w = kvp.Value;

            if (!isFallback)
            {
                if (w.Output == IntPtr.Zero)
                {
                    bool inside =
                        w.X >= usableArea.X && w.X < usableArea.X + usableArea.W &&
                        w.Y >= usableArea.Y && w.Y < usableArea.Y + usableArea.H;
                    bool adopt = inside || outputRegistry.Entries.Count == 1;
                    if (adopt)
                    {
                        w.Output = output;
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

            bool tagVisible = Aqueous.Features.Tags.TagState.IsVisible(
                w.Tags, outputVisibleTags);
            if (!tagVisible)
            {
                hiddenThisCycle.Add(w);
                continue;
            }

            windowStates.TryGetValue(kvp.Key, out var wsState);
            if (wsState != null &&
                (wsState.State == WindowState.Minimized ||
                 (wsState.InScratchpad && !wsState.Visible)))
            {
                hiddenThisCycle.Add(w);
                continue;
            }

            if (wsState != null && wsState.State == WindowState.Fullscreen)
            {
                var fsOwner = outputFullscreen.TryGetValue(output, out var owner) ? owner : IntPtr.Zero;
                if (fsOwner == IntPtr.Zero || fsOwner == kvp.Key)
                {
                    fullscreenHandles.Add(kvp.Key);
                    continue;
                }

                Aqueous.Diagnostics.RiverLog.Write($"FS slot conflict on output 0x{output.ToString("x")}: " +
                    $"window 0x{kvp.Key.ToString("x")} flagged FS but slot owner is 0x{fsOwner.ToString("x")}; demoting to tiled");
            }

            if (wsState != null && wsState.State == WindowState.Maximized)
            {
                maximizedHandles.Add(kvp.Key);
                continue;
            }

            if (wsState != null && wsState.State == WindowState.Floating)
            {
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
                    Tags: w.Tags,
                    // Propagate game-mode anchor metadata (Placement + requested buffer + focus
                    // tick) into the engine view. RequestedBuffer* mirrors WidthHint/HeightHint,
                    // i.e. the client's last dimensions_hint.
                    Placement: w.Placement,
                    RequestedBufferW: w.WidthHint,
                    RequestedBufferH: w.HeightHint,
                    LastFocusTick: w.LastFocusTick));
            }
        }

        // Visibility transition pass for tag-hidden windows.
        for (int hi = 0; hi < hiddenThisCycle.Count; hi++)
        {
            var w = hiddenThisCycle[hi];
            if (!w.HideSent)
            {
                if (windowRegistry.Entries.ContainsKey(w.Proxy))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        w.Proxy, 4, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
                w.HideSent = true;
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

        // Adoption fallback: if we are the *only* output, ensure every unassigned window is adopted onto
        // us.
        if (!isFallback && outputRegistry.Entries.Count == 1)
        {
            foreach (var kvp in windowRegistry.Entries)
            {
                var w = kvp.Value;
                if (w.Output == IntPtr.Zero)
                {
                    w.Output = output;

                    bool treatAsFloating = (floatIsActive || w.Floating);
                    if (floatIsActive || treatAsFloating)
                    {
                        if (!floatingHandles.Contains(kvp.Key))
                            floatingHandles.Add(kvp.Key);
                    }
                    else
                    {
                        bool alreadyTiled = false;
                        for(int ti=0; ti<tiledSnapshot.Count; ti++) if(tiledSnapshot[ti].Handle == kvp.Key) { alreadyTiled = true; break; }

                        if (!alreadyTiled)
                        {
                            tiledSnapshot.Add(new WindowEntryView(
                                Handle: kvp.Key, MinW: w.MinW, MinH: w.MinH,
                                MaxW: w.MaxW, MaxH: w.MaxH,
                                Floating: false, Fullscreen: false, Tags: w.Tags,
                                Placement: w.Placement,
                                RequestedBufferW: w.WidthHint,
                                RequestedBufferH: w.HeightHint,
                                LastFocusTick: w.LastFocusTick));
                        }
                    }
                }
            }
        }

        // Fix #3: when a window leaves the FS bucket this cycle, force a re-propose by zeroing its
        // placement caches.
        if (prevFullscreenHandles.Count > 0)
        {
            List<IntPtr>? toDrop = null;
            foreach (var prev in prevFullscreenHandles)
            {
                bool stillFs = false;
                for (int i = 0; i < fullscreenHandles.Count; i++)
                {
                    if (fullscreenHandles[i] == prev) { stillFs = true; break; }
                }
                if (stillFs)
                {
                    continue;
                }
                if (windowRegistry.Entries.TryGetValue(prev, out var pw))
                {
                    pw.LastHintW = 0;
                    pw.LastHintH = 0;
                    pw.LastPosX = int.MinValue;
                    pw.LastPosY = int.MinValue;
                    pw.LastClipW = 0;
                    pw.LastClipH = 0;
                }
                (toDrop ??= new List<IntPtr>()).Add(prev);
            }
            if (toDrop != null)
            {
                for (int i = 0; i < toDrop.Count; i++)
                {
                    prevFullscreenHandles.Remove(toDrop[i]);
                }
            }
        }

        // ------ Tiled windows: drive through the layout engine --------
        if (tiledSnapshot.Count > 0)
        {
            IReadOnlyList<WindowPlacement> placements;
            try
            {
                placements = layoutController.Arrange(
                    output, outputName, usableArea, tiledSnapshot, focusedWindow, outputRect);
            }
            catch (Exception ex)
            {
                Aqueous.Diagnostics.RiverLog.Write("layout engine threw, skipping arrange: " + ex.Message);
                placements = Array.Empty<WindowPlacement>();
            }

            for (int i = 0; i < placements.Count; i++)
            {
                var p = placements[i];
                if (!windowRegistry.Entries.TryGetValue(p.Handle, out var w))
                {
                    continue;
                }

                if (!p.Visible)
                {
                    w.Visible    = false;
                    w.TagVisible = false;
                    continue;
                }

                int pw = p.Geometry.W;
                int ph = p.Geometry.H;
                if (pw <= 0 || ph <= 0)
                {
                    continue;
                }

                if (!p.Visible)
                {
                    w.Visible = false;
                    if (pw != w.LastHintW || ph != w.LastHintH)
                    {
                        // Don't update LastHintW/H for invisible windows.
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

                if (windowRegistry.Entries.ContainsKey(p.Handle))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        p.Handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }
        }

        // ------ Floating layer: use the remembered FloatRect ---------
        int initW = Math.Min(800, (int)(usableArea.W * 0.6));
        int initH = Math.Min(600, (int)(usableArea.H * 0.6));
        int initX = usableArea.X + (usableArea.W - initW) / 2;
        int initY = usableArea.Y + (usableArea.H - initH) / 2;

        for (int i = 0; i < floatingHandles.Count; i++)
        {
            var handle = floatingHandles[i];
            if (!windowRegistry.Entries.TryGetValue(handle, out var w))
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
                if (windowRegistry.Entries.ContainsKey(handle))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }

            if (w.NodeProxy != IntPtr.Zero
                && (w.LastPosX != w.X || w.LastPosY != w.Y))
            {
                if (windowRegistry.Entries.ContainsKey(handle))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        w.NodeProxy, 1, IntPtr.Zero, 0, 0,
                        (IntPtr)w.X, (IntPtr)w.Y,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
                w.LastPosX = w.X;
                w.LastPosY = w.Y;
            }
        }

        // ------ Maximized windows --------
        for (int i = 0; i < maximizedHandles.Count; i++)
        {
            var handle = maximizedHandles[i];
            if (!windowRegistry.Entries.TryGetValue(handle, out var w))
            {
                continue;
            }

            // Rule-matched windows with `ignore_struts = true` resolve maximized geometry
            // against the raw output rect; everyone else stays inside the strut-shrunk area.
            Rect maxArea = w.Placement is { Rule.IgnoreStruts: true } ? outputRect : usableArea;
            int tx = maxArea.X, ty = maxArea.Y;
            int pw = maxArea.W, ph = maxArea.H;
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
                if (windowRegistry.Entries.ContainsKey(handle))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }

            if (w.NodeProxy != IntPtr.Zero
                && (w.LastPosX != w.X || w.LastPosY != w.Y))
            {
                if (windowRegistry.Entries.ContainsKey(handle))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        w.NodeProxy, 1, IntPtr.Zero, 0, 0,
                        (IntPtr)w.X, (IntPtr)w.Y,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
                w.LastPosX = w.X;
                w.LastPosY = w.Y;
            }
        }

        // ------ Fullscreen windows --------
        // Fullscreen must always cover the *raw* output — exclusion zones / struts do NOT apply.
        // `outputRect` was passed in by the manager call site; only fall back if the caller passed
        // the legacy single-rect overload (in which case usableArea == outputRect).
        Rect fsRect = outputRect;
        if (output != IntPtr.Zero && outputRegistry.Entries.TryGetValue(output, out var oeFull)
            && oeFull.Width > 0 && oeFull.Height > 0)
        {
            fsRect = new Rect(oeFull.X, oeFull.Y, oeFull.Width, oeFull.Height);
        }

        for (int i = 0; i < fullscreenHandles.Count; i++)
        {
            var handle = fullscreenHandles[i];
            if (!windowRegistry.Entries.TryGetValue(handle, out var w))
            {
                continue;
            }
            if (output != IntPtr.Zero &&
                outputFullscreen.TryGetValue(output, out var slotOwner) &&
                slotOwner != IntPtr.Zero &&
                slotOwner != handle)
            {
                continue;
            }

            int tx = fsRect.X, ty = fsRect.Y;
            int pw = fsRect.W, ph = fsRect.H;
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
                if (windowRegistry.Entries.ContainsKey(handle))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }

            prevFullscreenHandles.Add(handle);
        }
    }

    /// <summary>
    /// True iff the active layout (resolved against the focused window's output, or the first known
    /// output as a fallback) is the dedicated `float` engine.
    /// </summary>
    public bool IsFloatLayoutActive()
    {
        IntPtr output = IntPtr.Zero;
        var focusedWindow = _focusedWindowTracker.Current;
        var windowRegistry = _windowRegistry;
        var outputRegistry = _outputRegistry;
        if (focusedWindow != IntPtr.Zero &&
            windowRegistry.Entries.TryGetValue(focusedWindow, out var fw) &&
            fw.Output != IntPtr.Zero)
        {
            output = fw.Output;
        }
        else
        {
            foreach (var k in outputRegistry.Entries.Keys)
            {
                output = k;
                break;
            }
        }

        return IsFloatLayoutActive(output);
    }

    /// <summary>
    /// Output-parametrised overload of <see cref="IsFloatLayoutActive()"/>.
    /// </summary>
    public bool IsFloatLayoutActive(IntPtr output)
    {
        if (output == IntPtr.Zero)
        {
            foreach (var k in _outputRegistry.Entries.Keys)
            {
                output = k;
                break;
            }
        }

        return _layoutController.ResolveLayoutId(output, null) == "float";
    }

    /// <summary>
    /// Build a per-output WindowEntryView snapshot for navigation queries.
    /// </summary>
    public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output)
    {
        var windowRegistry = _windowRegistry;
        var list = new List<WindowEntryView>(windowRegistry.Entries.Count);
        foreach (var kvp in windowRegistry.Entries)
        {
            var w = kvp.Value;
            if (output != IntPtr.Zero && w.Output != IntPtr.Zero && w.Output != output)
            {
                continue;
            }

            list.Add(new WindowEntryView(
                Handle: kvp.Key,
                MinW: w.MinW, MinH: w.MinH, MaxW: w.MaxW, MaxH: w.MaxH,
                Floating: w.Floating, Fullscreen: false, Tags: 0u,
                Placement: w.Placement,
                RequestedBufferW: w.WidthHint,
                RequestedBufferH: w.HeightHint,
                LastFocusTick: w.LastFocusTick));
        }

        return list;
    }

    public string? ResolveOutputName(IntPtr output)
    {
        // OutputEntry does not currently surface a name field.
        _ = output;
        return null;
    }

    /// <summary>
    /// Engine-aware directional focus — delegates directly to <see
    /// cref="LayoutController.FocusNeighbor"/>.
    /// </summary>
    public IntPtr? LayoutFocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> snapshot) =>
        _layoutController.FocusNeighbor(output, outputName, current, dir, snapshot);
}
