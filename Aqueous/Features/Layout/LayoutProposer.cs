using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
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
/// accessors on the god class. Those accessors retire together with the god class.
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
    // Workspace-visibility oracle: ProposeForArea drops any window whose assigned workspace is
    // tracked-but-inactive so off-workspace windows never enter the tiled snapshot (the fix for the
    // half-size symptom where a window hidden on another workspace still claimed a master/stack slot).
    private readonly Aqueous.Features.Workspaces.WorkspaceStore _workspaceStore;
    // Used by the NodeProxy set_position liveness gate: a node proxy that is no longer in the
    // bind-site interface map has been torn down (e.g. by a stale WindowEntry overwrite in an
    // older codepath) and marshalling through it would write through a freed wl_proxy at +0x2c.
    private readonly WaylandBindSiteState _bindSiteState;
    // Tracks the layout id that was active on each output during the previous ProposeForArea pass.
    // When the id changes (LayoutController engine-swap) we invalidate per-window LastHint*/LastPos*
    // so the next pass cannot short-circuit on stale "same geometry" caches and skip the marshal,
    // mirroring the prevFullscreenHandles cleanup pattern when exiting fullscreen.
    private readonly Dictionary<IntPtr, string> _lastActiveIdByOutput = new();

    // Global backdrop-blur change-gate. The manager-level set_blur (opcode 7) is render state, so
    // it is marshalled from ProposeForArea (already inside the render sequence, like set_borders)
    // but only when the resolved [blur] config differs from what was last sent. _blurSent latches
    // the first emit so an unchanged config is never re-sent every frame.
    private bool _blurSent;
    private BlurSpec _lastBlurSent;

    // Global window-opacity change-gate. The manager-level set_opacity (opcode 8) is render
    // state, so it is marshalled from ProposeForArea (already inside the render sequence, like
    // set_blur) but only when the resolved [opacity] config differs from what was last sent.
    // _opacitySent latches the first emit so an unchanged config is never re-sent every frame.
    private bool _opacitySent;
    private OpacitySpec _lastOpacitySent;

    /// <summary>
    /// Convert a 0..1 opacity fraction to the 32-bit unsigned wire encoding expected by
    /// <c>set_opacity</c> / <c>set_window_opacity</c> (0 = transparent, 0xffffffff = opaque).
    /// </summary>
    private static uint EncodeOpacity(double opacity) =>
        (uint)Math.Round(Math.Clamp(opacity, 0.0, 1.0) * uint.MaxValue);

    public LayoutProposer(
        LayoutController layoutController,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        WindowStateStore windowStates,
        OutputFullscreenMap outputFullscreen,
        FocusedWindowTracker focusedWindowTracker,
        PrevFullscreenStore prevFullscreenStore,
        WaylandBindSiteState bindSiteState,
        Aqueous.Features.Workspaces.WorkspaceStore workspaceStore)
    {
        _layoutController     = layoutController     ?? throw new ArgumentNullException(nameof(layoutController));
        _windowRegistry       = windowRegistry       ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry       = outputRegistry       ?? throw new ArgumentNullException(nameof(outputRegistry));
        _windowStates         = windowStates         ?? throw new ArgumentNullException(nameof(windowStates));
        _outputFullscreen     = outputFullscreen     ?? throw new ArgumentNullException(nameof(outputFullscreen));
        _focusedWindowTracker = focusedWindowTracker ?? throw new ArgumentNullException(nameof(focusedWindowTracker));
        _prevFullscreenStore  = prevFullscreenStore  ?? throw new ArgumentNullException(nameof(prevFullscreenStore));
        _bindSiteState        = bindSiteState        ?? throw new ArgumentNullException(nameof(bindSiteState));
        _workspaceStore       = workspaceStore       ?? throw new ArgumentNullException(nameof(workspaceStore));
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

        // ------ Global backdrop blur: marshal the manager-level set_blur (opcode 7) once and on
        // every [blur] config change (Super+R reload). This is render state, so it is sent here
        // inside the render sequence, mirroring set_borders. Gated against the last-sent BlurSpec
        // so it is not re-marshalled every frame.
        var blurCfg = _layoutController.Config.Blur;
        if (!_blurSent || !_lastBlurSent.Equals(blurCfg))
        {
            var manager = _bindSiteState.Manager;
            if (manager != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    manager, 7, IntPtr.Zero, 0, 0,
                    (IntPtr)(blurCfg.Enabled ? 1u : 0u),
                    (IntPtr)blurCfg.Radius,
                    (IntPtr)blurCfg.Passes,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _blurSent = true;
                _lastBlurSent = blurCfg;
            }
        }

        // ------ Global window opacity: marshal the manager-level set_opacity (opcode 8) once and
        // on every [opacity] config change (Super+R reload). This is render state, so it is sent
        // here inside the render sequence, mirroring set_blur. Gated against the last-sent
        // OpacitySpec so it is not re-marshalled every frame.
        var opacityCfg = _layoutController.Config.Opacity;
        if (!_opacitySent || !_lastOpacitySent.Equals(opacityCfg))
        {
            var manager = _bindSiteState.Manager;
            if (manager != IntPtr.Zero)
            {
                double globalOpacity = opacityCfg.Enabled ? opacityCfg.Value : 1.0;
                WaylandInterop.wl_proxy_marshal_flags(
                    manager, 8, IntPtr.Zero, 0, 0,
                    (IntPtr)EncodeOpacity(globalOpacity),
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _opacitySent = true;
                _lastOpacitySent = opacityCfg;
            }
        }

        // Stamp the currently-focused window's LastFocusTick from the tracker once per pass
        // so GameModeLayout can break anchor ties deterministically ("most-recently focused
        // wins"). Cost: one dictionary hit per proposer pass.
        if (focusedWindow != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(focusedWindow, out var focusedEntry))
        {
            focusedEntry.LastFocusTick = _focusedWindowTracker.CurrentTick;
        }

        int activeWorkspaceNumber = _workspaceStore.ActiveWorkspaceNumber(output, outputRegistry);

        // Floating windows are a layer, not a layout: they bypass the active engine entirely and use
        // their remembered FloatRect (set by the Super+BTN_LEFT drag handler). When the active engine is
        // "float", we additionally treat every window as floating so the user can drag any of them — the
        // engine itself is only.
        string activeId = activeWorkspaceNumber > 0
            ? layoutController.ResolveLayoutId(output, outputName, activeWorkspaceNumber)
            : layoutController.ResolveLayoutId(output, outputName, 1);
        bool floatIsActive = activeId == "float";

        // Engine-swap invalidation: if the active layout id on this output changed since the previous
        // pass, walk every WindowEntry assigned to this output and reset the per-window geometry
        // caches. Without this, a hot-swap that happens to land a window at the exact same (X,Y,W,H)
        // as the previous engine would short-circuit the propose_dimensions / set_position emits
        // below and the surface would never move (e.g. engine A without struts → engine B with
        // struts can yield identical numbers for an unlucky window).
        if (_lastActiveIdByOutput.TryGetValue(output, out var prevActiveId))
        {
            if (prevActiveId != activeId)
            {
                foreach (var kvp in windowRegistry.Entries)
                {
                    var pw = kvp.Value;
                    if (pw.Output != output) continue;
                    pw.LastHintW = 0;
                    pw.LastHintH = 0;
                    pw.LastPosX = int.MinValue;
                    pw.LastPosY = int.MinValue;
                    pw.LastClipW = 0;
                    pw.LastClipH = 0;
                }
            }
        }
        _lastActiveIdByOutput[output] = activeId;

        // Per-output filter: an engine like ScrollingLayout maintains per-output state
        // (ScrollState.Columns) and *must* only see the windows that belong to this output, otherwise its
        // per-output state accumulates handles from other outputs and KeyNotFoundException /
        // cross-monitor placements ensue. Assignment policy: a window belongs to `output` if its tracked
        // W.Output matches; else, if its (X,Y) falls inside usableArea we adopt it onto this output;
        // otherwise skip. For the IntPtr.Zero fallback (no outputs), accept all.
        bool isFallback = output == IntPtr.Zero;

        // Tags. Resolve the visible-tag mask for this output (or AllTags for the IntPtr.Zero
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

            // Workspace filter (sits alongside the legacy tag filter; option 5-A). A window whose
            // assigned workspace is tracked but not active belongs to another workspace and must be
            // hidden the same one-shot way tag-hidden windows are, so it never reaches the engine and
            // n reflects only the visible workspace. Unassigned (Zero) and reaped/untracked handles
            // fall through as visible — see WorkspaceStore.IsHiddenByWorkspace.
            if (_workspaceStore.IsHiddenByWorkspace(w.Workspace))
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
                // Liveness gate: only marshal hide(opcode 4) when the proxy is non-null AND we have
                // proof the compositor has already bound it (ShowSent == we previously emitted a
                // show on this proxy, which implies it survived its manage_start round-trip). A
                // window that has never been shown — e.g. one that opens on a non-visible tag —
                // doesn't need a hide; the compositor isn't drawing it yet, and sending into a
                // not-yet-bound or already-torn-down river_window_v1 proxy NULL-derefs libwayland
                // at offset 0x2c. See WindowRegistry.Untrack which nulls Proxy on removal.
                if (w.Proxy != IntPtr.Zero &&
                    w.ShowSent &&
                    windowRegistry.Entries.ContainsKey(w.Proxy))
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
                    output, outputName, usableArea, tiledSnapshot, focusedWindow,
                    activeWorkspaceNumber > 0 ? activeWorkspaceNumber : 1, outputRect);
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
                w.X = p.Geometry.X;
                w.Y = p.Geometry.Y;

                if (pw != w.LastHintW || ph != w.LastHintH)
                {
                    w.LastHintW = pw;
                    w.LastHintH = ph;
                    w.ProposedW = pw;
                    w.ProposedH = ph;

                    if (windowRegistry.Entries.ContainsKey(p.Handle))
                    {
                        WaylandInterop.wl_proxy_marshal_flags(
                            p.Handle, 3, IntPtr.Zero, 0, 0,
                            (IntPtr)pw, (IntPtr)ph,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        // Mark the proxy as bound on the compositor side: this is the first request we
                        // ever marshal into a freshly-tracked river_window_v1, so subsequent passes can
                        // safely send hide(opcode 4) without risking the libwayland NULL-deref at 0x2c
                        // that hits never-bound or already-torn-down proxies.
                        w.ShowSent = true;
                    }
                }

                // Propagate node-position updates so same-tag reorders (engine MoveFocused swaps)
                // actually move surfaces on screen. Mirrors the floating/maximized branches; gated
                // on LastPosX/Y change so we only marshal when geometry actually shifts.
                // Liveness gate: only marshal set_position when the cached NodeProxy is still
                // registered in the bind-site interface map AND the registry entry we just looked
                // up is the same WindowEntry instance whose NodeProxy we are about to use. Without
                // this, a stale node proxy (overwritten by an older HandleWindowInformation path)
                // would crash at +0x2c inside wl_proxy_marshal_array_flags.
                if (w.NodeProxy != IntPtr.Zero
                    && (w.LastPosX != w.X || w.LastPosY != w.Y)
                    && _bindSiteState.TryGetProxyInterface(w.NodeProxy) == "river_node_v1"
                    && windowRegistry.Entries.TryGetValue(p.Handle, out var liveT)
                    && ReferenceEquals(liveT, w)
                    && liveT.NodeProxy == w.NodeProxy)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        w.NodeProxy, 1, IntPtr.Zero, 0, 0,
                        (IntPtr)w.X, (IntPtr)w.Y,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    w.LastPosX = w.X;
                    w.LastPosY = w.Y;
                }

                // ------ Borders: pick focused/normal colour, marshal set_borders (opcode 8).
                // Gated on a change in colour/width so we only re-send on focus switches instead
                // of every render frame (mirrors the LastHintW/H and LastPosX/Y gating above).
                {
                    int    bWidth  = p.Border.Width;
                    uint   bColor  = bWidth > 0
                        ? (p.Handle == focusedWindow ? p.Border.Focused : p.Border.Normal)
                        : 0u;
                    if (!w.BordersSent || w.LastBorderColor != bColor || w.LastBorderWidth != bWidth)
                    {
                        // edges bitfield: top|bottom|left|right = 1|2|4|8 = 0xF (none == 0 disables).
                        uint edges = bWidth > 0 ? 0xFu : 0u;
                        // BorderSpec packs 8 bits/channel (0xAARRGGBB); set_borders expects 32 bits
                        // per channel, so expand each channel by * 0x01010101.
                        uint r = ((bColor >> 16) & 0xFF) * 0x01010101u;
                        uint g = ((bColor >>  8) & 0xFF) * 0x01010101u;
                        uint b = ( bColor        & 0xFF) * 0x01010101u;
                        uint a = ((bColor >> 24) & 0xFF) * 0x01010101u;
                        WaylandInterop.wl_proxy_marshal_flags(
                            p.Handle, 8, IntPtr.Zero, 0, 0,
                            (IntPtr)edges, (IntPtr)bWidth,
                            (IntPtr)r, (IntPtr)g, (IntPtr)b, (IntPtr)a);
                        w.BordersSent     = true;
                        w.LastBorderColor = bColor;
                        w.LastBorderWidth = bWidth;
                    }
                }

                // ------ Per-window blur: marshal set_window_blur (opcode 25). The effective
                // decision is the matching rule's blur override (null = inherit) falling back to
                // the global [blur].enabled default. Change-gated against the cached value so we
                // only re-send when it flips (rule match change / global toggle on reload).
                {
                    bool blurEnabled = w.Placement?.BlurOverride ?? blurCfg.Enabled;
                    if (!w.WindowBlurSent || w.LastWindowBlurEnabled != blurEnabled)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(
                            p.Handle, 25, IntPtr.Zero, 0, 0,
                            (IntPtr)(blurEnabled ? 1u : 0u),
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        w.WindowBlurSent = true;
                        w.LastWindowBlurEnabled = blurEnabled;
                    }
                }

                // ------ Per-window opacity: marshal set_window_opacity (opcode 26). The effective
                // value is the matching rule's opacity override (null = inherit) falling back to
                // the global [opacity] default. Change-gated against the cached value so we only
                // re-send when it changes (rule match change / global edit on reload).
                {
                    double opacity = w.Placement?.OpacityOverride
                                     ?? (opacityCfg.Enabled ? opacityCfg.Value : 1.0);
                    if (!w.WindowOpacitySent || w.LastWindowOpacity != opacity)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(
                            p.Handle, 26, IntPtr.Zero, 0, 0,
                            (IntPtr)EncodeOpacity(opacity),
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        w.WindowOpacitySent = true;
                        w.LastWindowOpacity = opacity;
                    }
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
                    // See tiled branch above: first marshal into the proxy proves liveness for the
                    // hide-pass liveness gate.
                    w.ShowSent = true;
                }
            }

            // Liveness gate — see tiled branch for rationale.
            if (w.NodeProxy != IntPtr.Zero
                && (w.LastPosX != w.X || w.LastPosY != w.Y)
                && _bindSiteState.TryGetProxyInterface(w.NodeProxy) == "river_node_v1"
                && windowRegistry.Entries.TryGetValue(handle, out var liveF)
                && ReferenceEquals(liveF, w)
                && liveF.NodeProxy == w.NodeProxy)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    w.NodeProxy, 1, IntPtr.Zero, 0, 0,
                    (IntPtr)w.X, (IntPtr)w.Y,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
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
                    // See tiled branch above: first marshal into the proxy proves liveness for the
                    // hide-pass liveness gate.
                    w.ShowSent = true;
                }
            }

            // Liveness gate — see tiled branch for rationale.
            if (w.NodeProxy != IntPtr.Zero
                && (w.LastPosX != w.X || w.LastPosY != w.Y)
                && _bindSiteState.TryGetProxyInterface(w.NodeProxy) == "river_node_v1"
                && windowRegistry.Entries.TryGetValue(handle, out var liveM)
                && ReferenceEquals(liveM, w)
                && liveM.NodeProxy == w.NodeProxy)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    w.NodeProxy, 1, IntPtr.Zero, 0, 0,
                    (IntPtr)w.X, (IntPtr)w.Y,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
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
                    // See tiled branch above: first marshal into the proxy proves liveness for the
                    // hide-pass liveness gate.
                    w.ShowSent = true;
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
        IReadOnlyList<WindowEntryView> snapshot,
        uint visibleTags) =>
        _layoutController.FocusNeighbor(output, outputName, current, dir, snapshot, visibleTags);
}
