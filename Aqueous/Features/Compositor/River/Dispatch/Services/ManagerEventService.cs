using System;
using System.Collections.Generic;
using Aqueous.Diagnostics;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River.Dispatch.Services;

/// <summary>
/// Handles river_window_manager_v1 events (manage_start / render_start / *_information /
/// session_*).
/// <para>
/// cutover: the service no longer references <see cref="RiverWindowManagerClient"/>. All state is
/// consumed via fine-grained DI singletons (registries, drag/pointer-binding/ manage-cycle stores,
/// focus/key-binding services, layout proposer, manager request sender, bind-site state).
/// </para>
/// </summary>
internal sealed unsafe class ManagerEventService
{
    private readonly IEventPump _pump;
    private readonly IWindowRegistry _windowRegistry;
    private readonly IShellSurfaceRegistry _shellSurfaceRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly ISeatRegistry _seatRegistry;
    private readonly FocusedWindowTracker _focusedWindowTracker;
    private readonly PendingFocusStore _pendingFocus;
    private readonly PrimarySeatTracker _primarySeat;
    private readonly IFocusService _focusService;
    private readonly DragStateStore _dragState;
    private readonly PointerBindingStore _pointerBindings;
    private readonly ManageCycleState _manageCycle;
    private readonly WindowStateStore _windowStates;
    private readonly LayoutController _layoutController;
    private readonly ILayoutProposer _layoutProposer;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly IKeyBindingRegistrar _keyBindingRegistrar;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly KeyBindingsRegistry _keyBindingsRegistry;
    private readonly IWindowStateHost _windowStateHost;
    private readonly ILayerShellUsableAreaStore _layerShellUsableAreas;
    private readonly Workspaces.WorkspaceStore _workspaceStore;

    // Tracks the LayoutController epoch the force_ssd decision was last applied for. When the epoch
    // advances (config reload via Super+R) the SSD latches are re-armed so a toggled force_ssd
    // value re-applies, and windows previously switched to SSD are reverted to CSD when the flag is
    // turned off. -1 forces the first manage cycle to seed the epoch.
    private long _ssdConfigEpoch = -1;

    // Signature of the window stacking order emitted on the previous render pass. place_top
    // (river_node_v1 opcode 2) is only re-marshalled when this changes, so a steady-state slide
    // (focus/positions moving but z-order unchanged) does not churn the compositor's
    // rendering_requested.list and flip its order_hash — the churn that disturbed the animation
    // clone's z-order and produced the sliding afterimage. 0 forces the first pass to emit.
    private ulong _lastEmissionOrderHash;

    // Last manager-level visual effect values marshalled during a render sequence. Re-sending these
    // unchanged can force compositor-side blur/backdrop recomputation on every frame.
    private bool _hasSentManagerBlur;
    private bool _lastManagerBlurEnabled;
    private int _lastManagerBlurRadius;
    private int _lastManagerBlurPasses;
    private bool _hasSentManagerOpacity;
    private uint _lastManagerOpacityEncoded;
    private bool _hasSentWorkspaceTransition;
    private bool _lastWorkspaceTransitionEnabled;
    private int _lastWorkspaceTransitionRateFixed;

    private static uint EncodeOpacity(double opacity) =>
        (uint)Math.Round(Math.Clamp(opacity, 0.0, 1.0) * uint.MaxValue);

    internal static double ResolveWindowOpacity(WindowEntry we, IntPtr key, IntPtr focused, OpacitySpec opacityCfg)
    {
        if (!opacityCfg.Enabled)
        {
            return 1.0;
        }

        if (we.Placement?.OpacityOverride is double overrideOpacity)
        {
            return Math.Clamp(overrideOpacity, 0.0, 1.0);
        }

        if (opacityCfg.FocusSensitive)
        {
            return Math.Clamp(key == focused ? opacityCfg.Focused : opacityCfg.Unfocused, 0.0, 1.0);
        }

        return Math.Clamp(opacityCfg.Value, 0.0, 1.0);
    }

    private static void SplitArgb8888ToUint32Channels(uint color, out uint r, out uint g, out uint b, out uint a)
    {
        r = ((color >> 16) & 0xFF) * 0x01010101u;
        g = ((color >> 8) & 0xFF) * 0x01010101u;
        b = (color & 0xFF) * 0x01010101u;
        a = ((color >> 24) & 0xFF) * 0x01010101u;
    }

    public ManagerEventService(
        IEventPump pump,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        ISeatRegistry seatRegistry,
        FocusedWindowTracker focusedWindowTracker,
        PendingFocusStore pendingFocus,
        PrimarySeatTracker primarySeat,
        IFocusService focusService,
        DragStateStore dragState,
        PointerBindingStore pointerBindings,
        ManageCycleState manageCycle,
        WindowStateStore windowStates,
        LayoutController layoutController,
        ILayoutProposer layoutProposer,
        IManagerRequestSender managerRequestSender,
        IKeyBindingRegistrar keyBindingRegistrar,
        WaylandBindSiteState bindSiteState,
        KeyBindingsRegistry keyBindingsRegistry,
        IWindowStateHost windowStateHost,
        IShellSurfaceRegistry shellSurfaceRegistry,
        ILayerShellUsableAreaStore layerShellUsableAreas,
        Workspaces.WorkspaceStore workspaceStore)
    {
        _pump = pump ?? throw new ArgumentNullException(nameof(pump));
        _windowRegistry = windowRegistry ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry = outputRegistry ?? throw new ArgumentNullException(nameof(outputRegistry));
        _seatRegistry = seatRegistry ?? throw new ArgumentNullException(nameof(seatRegistry));
        _focusedWindowTracker = focusedWindowTracker ?? throw new ArgumentNullException(nameof(focusedWindowTracker));
        _pendingFocus = pendingFocus ?? throw new ArgumentNullException(nameof(pendingFocus));
        _primarySeat = primarySeat ?? throw new ArgumentNullException(nameof(primarySeat));
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _dragState = dragState ?? throw new ArgumentNullException(nameof(dragState));
        _pointerBindings = pointerBindings ?? throw new ArgumentNullException(nameof(pointerBindings));
        _manageCycle = manageCycle ?? throw new ArgumentNullException(nameof(manageCycle));
        _windowStates = windowStates ?? throw new ArgumentNullException(nameof(windowStates));
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _layoutProposer = layoutProposer ?? throw new ArgumentNullException(nameof(layoutProposer));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _keyBindingRegistrar = keyBindingRegistrar ?? throw new ArgumentNullException(nameof(keyBindingRegistrar));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _keyBindingsRegistry = keyBindingsRegistry ?? throw new ArgumentNullException(nameof(keyBindingsRegistry));
        _windowStateHost = windowStateHost ?? throw new ArgumentNullException(nameof(windowStateHost));
        _shellSurfaceRegistry = shellSurfaceRegistry ?? throw new ArgumentNullException(nameof(shellSurfaceRegistry));
        _layerShellUsableAreas = layerShellUsableAreas ?? throw new ArgumentNullException(nameof(layerShellUsableAreas));
        _workspaceStore = workspaceStore ?? throw new ArgumentNullException(nameof(workspaceStore));
    }

    /// <summary>
    /// Folds the per-output layer-shell <c>non_exclusive_area</c> hint (panels/bars exclusive zones,
    /// in global coordinates) into the strut-derived usable rect by intersecting the two. The hint is
    /// advisory: when no area has been reported for the output, or the intersection is degenerate,
    /// the strut-derived <paramref name="strutUsable"/> is returned unchanged.
    /// </summary>
    private Rect ApplyLayerShellUsable(IntPtr output, Rect strutUsable)
    {
        if (output == IntPtr.Zero ||
            !_layerShellUsableAreas.TryGet(output, out var a))
        {
            return strutUsable;
        }

        var layer = new Rect(a.X, a.Y, a.Width, a.Height);
        var intersection = LayoutMath.Intersect(strutUsable, layer);

        // Empty intersection means either nothing was reported, the hint was degenerate, or it does
        // not overlap the strut rect (misreported). In all cases keep the strut rect rather than
        // collapsing the layout to nothing.
        return intersection is { W: > 0, H: > 0 } ? intersection : strutUsable;
    }

    public void HandleEvent(uint opcode, WlArgument* args)
    {
        try
        {
            switch (opcode)
            {
                case RiverProtocolOpcodes.Manager.Unavailable:
                    RiverLog.Write("river_window_manager_v1.unavailable — another WM is active; giving up");
                    _pump.Stop(TimeSpan.Zero);
                    break;
                case RiverProtocolOpcodes.Manager.Finished:
                    RiverLog.Write("river_window_manager_v1.finished");
                    _pump.Stop(TimeSpan.Zero);
                    break;
                case RiverProtocolOpcodes.Manager.ManageStart:
                    HandleManageStart();
                    break;
                case RiverProtocolOpcodes.Manager.RenderStart:
                    HandleRenderStart();
                    break;
                case RiverProtocolOpcodes.Manager.SessionLocked:
                    RiverLog.Write("session_locked");
                    break;
                case RiverProtocolOpcodes.Manager.SessionUnlocked:
                    RiverLog.Write("session_unlocked");
                    break;
                case RiverProtocolOpcodes.Manager.WindowInformation:
                    HandleWindowInformation(args);
                    break;
                case RiverProtocolOpcodes.Manager.OutputInformation:
                    HandleOutputInformation(args);
                    break;
                case RiverProtocolOpcodes.Manager.SeatInformation:
                    HandleSeatInformation(args);
                    break;
            }
        }
        catch (Exception ex)
        {
            RiverLog.Write($"ManagerEventService.HandleEvent opcode={opcode} threw: {ex}");
        }
    }

    /// <summary>
    /// Applies the <c>[layout].force_ssd</c> decision during a manage sequence. When enabled, asks
    /// every SSD-capable window (one whose <c>decoration_hint</c> is not <c>only_supports_csd</c>)
    /// to drop its client-side decorations via <c>river_window_v1.use_ssd</c>, suppressing the
    /// client-drawn titlebar / minimize / maximize / close buttons. The send is latched per window
    /// (<see cref="WindowEntry.SsdApplied"/>) so it fires once. On config reload (epoch bump) the
    /// latches are re-armed; windows previously switched to SSD are reverted with <c>use_csd</c>
    /// when the flag is turned off. only_csd clients (most GTK apps) are skipped — the request is a
    /// protocol no-op for them.
    /// </summary>
    private void ApplyForceSsd()
    {
        bool forceSsd = _layoutController.Config.ForceSsd;

        // Config-reload re-arm: re-evaluate on every window when the epoch advances.
        if (_ssdConfigEpoch != _layoutController.Epoch)
        {
            _ssdConfigEpoch = _layoutController.Epoch;
            foreach (var entry in _windowRegistry.Entries.Values)
            {
                if (entry.SsdApplied && !forceSsd)
                {
                    // force_ssd was turned off: ask the window to return to client-side decoration.
                    WaylandInterop.wl_proxy_marshal_flags(
                        entry.Proxy, RiverProtocolOpcodes.Window.UseCsd, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    RiverLog.Write($"use_csd on window 0x{entry.Proxy.ToString("x")} (force_ssd disabled)");
                }

                entry.SsdApplied = false;
            }
        }

        if (!forceSsd)
        {
            return;
        }

        foreach (var entry in _windowRegistry.Entries.Values)
        {
            if (entry.SsdApplied)
            {
                continue; // latch: send use_ssd once per window.
            }

            if (!entry.DecorationHintReceived)
            {
                continue; // wait for the client's decoration_hint before deciding.
            }

            if (entry.DecorationHint == RiverProtocolOpcodes.Window.DecorationOnlyCsd)
            {
                continue; // protocol no-op for only_csd clients — skip.
            }

            WaylandInterop.wl_proxy_marshal_flags(
                entry.Proxy, RiverProtocolOpcodes.Window.UseSsd, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            entry.SsdApplied = true;
            RiverLog.Write($"use_ssd on window 0x{entry.Proxy.ToString("x")}");
        }
    }

    private void HandleManageStart()
    {
        _manageCycle.InsideManageSequence = true;
        _managerRequestSender.InsideManageSequence = true;
        bool finished = false;
        // Set if an output had to be skipped because its real dimensions were not yet known. A
        // ScheduleManage() issued here is a no-op (InsideManageSequence is true and short-circuits
        // it), so we flush a real retry in the finally block AFTER the sequence flag is cleared.
        bool deferredManage = false;
        try
        {
            RiverLog.Write(
                $"manage_start (windows={_windowRegistry.Entries.Count} outputs={_outputRegistry.Entries.Count} seats={_seatRegistry.Entries.Count} shells={_shellSurfaceRegistry.Count})");

            // Self-heal focus.
            if (_focusedWindowTracker.Current == IntPtr.Zero
                && _pendingFocus.Window == IntPtr.Zero
                && !_shellSurfaceRegistry.IsLive(_pendingFocus.ShellSurface)
                && _windowRegistry.Entries.Count > 0)
            {
                _focusService.FocusAnyOtherWindow(IntPtr.Zero);
            }

            // Enable the pointer binding (must be issued inside a manage sequence).
            if (_pointerBindings.DragPointerBindingNeedsEnable && _pointerBindings.DragPointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    _pointerBindings.DragPointerBinding, 1, IntPtr.Zero, 0, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _pointerBindings.DragPointerBindingNeedsEnable = false;
                RiverLog.Write("enabled Super+BTN_LEFT pointer binding");
            }

            if (_pointerBindings.DragResizePointerBindingNeedsEnable && _pointerBindings.DragResizePointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    _pointerBindings.DragResizePointerBinding, 1, IntPtr.Zero, 0, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _pointerBindings.DragResizePointerBindingNeedsEnable = false;
                RiverLog.Write("enabled Super+BTN_RIGHT pointer binding");
            }

            // Server-side decoration: honour [layout].force_ssd. use_ssd/use_csd may only be sent
            // inside a manage sequence, which is exactly here.
            ApplyForceSsd();

            // Drag finish path.
            if (_dragState.DragFinished)
            {
                if (_dragState.DragResizeInformed && _dragState.ActiveDragWindow != null)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        _dragState.ActiveDragWindow.Proxy, 13, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    RiverLog.Write($"inform_resize_end on window 0x{_dragState.ActiveDragWindow.Proxy.ToString("x")}");
                }

                WaylandInterop.wl_proxy_marshal_flags(
                    _dragState.ActiveDragSeat, 5, IntPtr.Zero, 1, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                _dragState.ActiveDragWindow = null;
                _dragState.ActiveDragSeat = IntPtr.Zero;
                _dragState.DragFinished = false;
                _dragState.DragStarted = false;
                _dragState.DragEdges = 0;
                _dragState.DragResizeInformed = false;
            }

            if (_dragState.ActiveDragSeat != IntPtr.Zero && _dragState.ActiveDragWindow != null && !_dragState.DragStarted)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    _dragState.ActiveDragSeat, 4, IntPtr.Zero, 1, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _dragState.DragStarted = true;

                if (_dragState.DragEdges != 0 && !_dragState.DragResizeInformed)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        _dragState.ActiveDragWindow.Proxy, 12, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    _dragState.DragResizeInformed = true;
                    uint edges = _dragState.DragEdges;
                    RiverLog.Write($"inform_resize_start on window 0x{_dragState.ActiveDragWindow.Proxy.ToString("x")} edges={edges}");
                }
            }

            // Drain pending focus BEFORE the propose pass. IsWindowLayoutReady no longer gates on
            // entry.Output (which is only populated by ProposeForArea below), so the pre-propose
            // bucket state (Visible && !HideSent) is the authoritative readiness signal. Running
            // the drain after propose would let a hide-pass that just flipped HideSent on the
            // pending-focus target push the marshal into the defer branch on every cycle, recreating
            // the black-screen deadlock from the other side.
            if (_pendingFocus.Seat != IntPtr.Zero
                && !_seatRegistry.Entries.ContainsKey(_pendingFocus.Seat))
            {
                // The marshal target itself is dead: the river_seat_v1 proxy was removed
                // (river_seat_v1::removed) between queueing the focus and this drain. Marshaling
                // focus_window / focus_shell_surface on it would be a use-after-free inside
                // libwayland (segfault in wl_proxy_marshal_flags). Drop the stale pending focus.
                RiverLog.Write(
                    $"pending_focus: dropping focus on dead seat 0x{_pendingFocus.Seat.ToString("x")}");
                _pendingFocus.Clear();
            }
            else if (_pendingFocus.Seat != IntPtr.Zero)
            {
                bool consumed = true;
                // If a pending window is queued and still live, it takes precedence. If it is queued
                // but stale (already destroyed by river between WindowInformation and the drain), drop
                // it and fall through to any queued shell-surface focus so layer-shell handoffs are
                // not silently swallowed.
                if (_pendingFocus.Window != IntPtr.Zero
                    && _windowRegistry.Entries.ContainsKey(_pendingFocus.Window))
                {
                    var win = new WindowProxy(_pendingFocus.Window);

                    if (!_windowStateHost.IsWindowLayoutReady(win))
                    {
                        RiverLog.Write(
                            $"pending_focus: deferring focus on window 0x{_pendingFocus.Window.ToString("x")} (layout not ready)");
                        _managerRequestSender.ScheduleManage();
                        consumed = false;
                    }
                    else
                    {
                        WaylandInterop.wl_proxy_marshal_flags(_pendingFocus.Seat, 1, IntPtr.Zero, 0, 0,
                            _pendingFocus.Window, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                            IntPtr.Zero);
                        RiverLog.Write($"gave focus to window 0x{_pendingFocus.Window.ToString("x")}");
                    }
                }
                else if (_pendingFocus.ShellSurface != IntPtr.Zero
                         && _shellSurfaceRegistry.IsLive(_pendingFocus.ShellSurface))
                {
                    if (_pendingFocus.Window != IntPtr.Zero)
                    {
                        RiverLog.Write($"pending_focus: dropping stale window 0x{_pendingFocus.Window.ToString("x")}, delivering pending shell surface");
                    }
                    WaylandInterop.wl_proxy_marshal_flags(_pendingFocus.Seat, 2, IntPtr.Zero, 0, 0,
                        _pendingFocus.ShellSurface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                        IntPtr.Zero);
                    RiverLog.Write($"gave focus to shell surface 0x{_pendingFocus.ShellSurface.ToString("x")}");
                }
                else if (_pendingFocus.ShellSurface != IntPtr.Zero)
                {
                    // The shell surface proxy is no longer known to be live (the layer-shell client
                    // closed between shell_surface_interaction and this drain). Marshaling
                    // focus_shell_surface on the freed river_shell_surface proxy would segfault inside
                    // libwayland-client (the "segfault at 2c" crash). Drop it instead.
                    RiverLog.Write($"pending_focus: dropping stale shell surface 0x{_pendingFocus.ShellSurface.ToString("x")}");
                }
                else if (_pendingFocus.Window != IntPtr.Zero)
                {
                    RiverLog.Write($"pending_focus: dropping stale window 0x{_pendingFocus.Window.ToString("x")}");
                }

                if (consumed)
                {
                    _pendingFocus.Clear();
                }
            }

            if (_outputRegistry.Entries.IsEmpty)
            {
                var raw = new Rect(0, 0, 1920, 1080);
                var usable = StrutsCalculator.Apply(raw, _layoutController.Config?.Struts);
                _layoutProposer.ProposeForArea(IntPtr.Zero, null, raw, usable);
            }
            else
            {
                foreach (var outputKvp in _outputRegistry.Entries)
                {
                    OutputEntry oe = outputKvp.Value;
                    // Defensive: if the compositor has not yet reported this output's real
                    // dimensions (river_output_v1::dimensions still pending), do NOT lay windows
                    // out against a 1920x1080 guess — that stale geometry would be cached on each
                    // WindowEntry and the surface would keep its wrong first-open size. Skip the
                    // output and schedule another manage cycle; OutputEventHandler also schedules
                    // one once the dimensions arrive, so the retry is bounded.
                    if (oe.Width <= 0 || oe.Height <= 0)
                    {
                        RiverLog.Write(
                            $"manage: deferring layout for output 0x{outputKvp.Key.ToString("x")} (dimensions not ready)");
                        deferredManage = true;
                        continue;
                    }
                    var raw = new Rect(oe.X, oe.Y, oe.Width, oe.Height);
                    var usable = StrutsCalculator.Apply(raw, _layoutController.Config?.Struts);
                    usable = ApplyLayerShellUsable(outputKvp.Key, usable);
                    _layoutProposer.ProposeForArea(outputKvp.Key, null, raw, usable);
                }
            }

            _managerRequestSender.SendManagerRequest(2);
            finished = true;
        }
        catch (Exception ex)
        {
            RiverLog.Write("manage_start handler threw: " + ex);
        }
        finally
        {
            if (!finished)
            {
                _managerRequestSender.SendManagerRequest(2);
                RiverLog.Write("manage_start: forced manage_finish after exception");
            }

            _manageCycle.InsideManageSequence = false;
            _managerRequestSender.InsideManageSequence = false;

            // Now that we are no longer inside the manage sequence, a ScheduleManage() will actually
            // marshal manage_dirty. Retry any output whose dimensions were not yet ready; the
            // bounded OutputEventHandler path also reschedules once dimensions arrive, so this loop
            // cannot spin indefinitely.
            if (deferredManage)
            {
                _managerRequestSender.ScheduleManage();
            }
        }
    }

    private void HandleRenderStart()
    {
        RiverLog.Write("render_start");
        bool finished = false;
        try
        {
            var blurCfg = _layoutController.Config.Blur;
            var opacityCfg = _layoutController.Config.Opacity;
            IntPtr focused = _focusedWindowTracker.Current;
            var manager = _bindSiteState.Manager;
            if (manager != IntPtr.Zero)
            {
                if (!_hasSentManagerBlur
                    || _lastManagerBlurEnabled != blurCfg.Enabled
                    || _lastManagerBlurRadius != blurCfg.Radius
                    || _lastManagerBlurPasses != blurCfg.Passes)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        manager, 7, IntPtr.Zero, 0, 0,
                        (IntPtr)(blurCfg.Enabled ? 1u : 0u),
                        (IntPtr)blurCfg.Radius,
                        (IntPtr)blurCfg.Passes,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    _hasSentManagerBlur = true;
                    _lastManagerBlurEnabled = blurCfg.Enabled;
                    _lastManagerBlurRadius = blurCfg.Radius;
                    _lastManagerBlurPasses = blurCfg.Passes;
                }

                double globalOpacity = opacityCfg.Enabled ? opacityCfg.Value : 1.0;
                uint opacityEncoded = EncodeOpacity(globalOpacity);
                if (!_hasSentManagerOpacity || _lastManagerOpacityEncoded != opacityEncoded)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        manager, 8, IntPtr.Zero, 0, 0,
                        (IntPtr)opacityEncoded,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    _hasSentManagerOpacity = true;
                    _lastManagerOpacityEncoded = opacityEncoded;
                }

                var wsCfg = _layoutController.Config.WorkspaceTransition;
                // set_workspace_transition (opcode 9, since v9): enabled uint + rate as wl_fixed
                // (24.8 fixed-point). A non-positive rate keeps the compositor's built-in default.
                int wsRateFixed = wsCfg.Rate > 0.0 ? (int)Math.Round(wsCfg.Rate * 256.0) : 0;
                if (!_hasSentWorkspaceTransition
                    || _lastWorkspaceTransitionEnabled != wsCfg.Enabled
                    || _lastWorkspaceTransitionRateFixed != wsRateFixed)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        manager, 9, IntPtr.Zero, 0, 0,
                        (IntPtr)(wsCfg.Enabled ? 1u : 0u),
                        (IntPtr)wsRateFixed,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    _hasSentWorkspaceTransition = true;
                    _lastWorkspaceTransitionEnabled = wsCfg.Enabled;
                    _lastWorkspaceTransitionRateFixed = wsRateFixed;
                }
            }

            void EmitWindow(IntPtr key, WindowEntry we, bool emitPlaceTop)
            {
                if (!we.Visible)
                {
                    return;
                }

                // show (opcode 5): only on a real hidden→visible transition. Re-sending it every
                // render pass needlessly mutates the wlroots scene graph (visibility/damage recalc).
                if (!we.ShownVisible)
                {
                    WaylandInterop.wl_proxy_marshal_flags(key, 5, IntPtr.Zero, 0, 0, IntPtr.Zero, IntPtr.Zero,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    we.ShownVisible = true;
                }
                {
                    int bWidth = we.LastResolvedBorder.Width;
                    uint bColor = bWidth > 0
                        ? (key == focused ? we.LastResolvedBorder.Focused : we.LastResolvedBorder.Normal)
                        : 0u;
                    // set_borders (opcode 8): gate on the resolved width/colour so a focus change
                    // (which flips the active colour) still re-sends, but an unchanged window does not.
                    if (!we.BordersSent || we.LastBorderColor != bColor || we.LastBorderWidth != bWidth)
                    {
                        uint edges = bWidth > 0 ? 0xFu : 0u;
                        SplitArgb8888ToUint32Channels(bColor, out uint r, out uint g, out uint b, out uint a);
                        WaylandInterop.wl_proxy_marshal_flags(
                            key, 8, IntPtr.Zero, 0, 0,
                            (IntPtr)edges, (IntPtr)bWidth,
                            (IntPtr)r, (IntPtr)g, (IntPtr)b, (IntPtr)a);
                        we.BordersSent = true;
                        we.LastBorderColor = bColor;
                        we.LastBorderWidth = bWidth;
                    }
                }

                if (we.NodeProxy != IntPtr.Zero)
                {
                    // place_top (opcode 2): only when the overall stacking order actually changed
                    // this pass; otherwise the compositor's order_hash stays stable and the slide
                    // animation's z-order is left undisturbed.
                    if (emitPlaceTop)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(we.NodeProxy, 2, IntPtr.Zero, 0, 0, IntPtr.Zero,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    }
                    if (we.LastPosX != we.X || we.LastPosY != we.Y)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(we.NodeProxy, 1, IntPtr.Zero, 0, 0, (IntPtr)we.X,
                            (IntPtr)we.Y, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        we.LastPosX = we.X;
                        we.LastPosY = we.Y;
                    }
                }

                if (_manageCycle.ManagerVersion >= 2 && we.W > 0 && we.H > 0 &&
                    (we.LastClipW != we.W || we.LastClipH != we.H))
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        key, 21, IntPtr.Zero, 0, 0,
                        (IntPtr)0, (IntPtr)0, (IntPtr)we.W, (IntPtr)we.H,
                        IntPtr.Zero, IntPtr.Zero);
                    we.LastClipW = we.W;
                    we.LastClipH = we.H;
                }

                {
                    bool blurEnabled = we.Placement?.BlurOverride ?? blurCfg.Enabled;
                    // set_window_blur (opcode 25): gate so we don't re-run the optimized-blur
                    // backdrop recompute (setTreeBlurExcluded) every frame during a slide.
                    if (!we.WindowBlurSent || we.LastWindowBlurEnabled != blurEnabled)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(
                            key, 25, IntPtr.Zero, 0, 0,
                            (IntPtr)(blurEnabled ? 1u : 0u),
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        we.WindowBlurSent = true;
                        we.LastWindowBlurEnabled = blurEnabled;
                    }
                }

                {
                    double opacity = ResolveWindowOpacity(we, key, focused, opacityCfg);
                    // set_window_opacity (opcode 26): gate on the resolved value. Focus-sensitive
                    // opacity still re-sends when the focused/unfocused value flips, but a steady
                    // window no longer spams opacity every frame.
                    if (!we.WindowOpacitySent || we.LastWindowOpacity != opacity)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(
                            key, 26, IntPtr.Zero, 0, 0,
                            (IntPtr)EncodeOpacity(opacity),
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        we.WindowOpacitySent = true;
                        we.LastWindowOpacity = opacity;
                    }
                }
            }

            WindowState ClassifyState(IntPtr handle)
            {
                if (_windowStates.TryGetValue(handle, out var sd) && sd != null)
                {
                    return sd.State;
                }

                return WindowState.Tiled;
            }

            WindowState focusedState = focused != IntPtr.Zero
                ? ClassifyState(focused)
                : WindowState.Tiled;

            static bool Overlaps(WindowEntry a, WindowEntry b) =>
                a.W > 0 && a.H > 0 &&
                b.W > 0 && b.H > 0 &&
                a.X < b.X + b.W &&
                a.X + a.W > b.X &&
                a.Y < b.Y + b.H &&
                a.Y + a.H > b.Y;

            bool LayerHasVisibleOverlap(WindowState layer)
            {
                var visible = new List<WindowEntry>();
                foreach (var kvp in _windowRegistry.Entries)
                {
                    if (!kvp.Value.Visible || ClassifyState(kvp.Key) != layer)
                    {
                        continue;
                    }

                    visible.Add(kvp.Value);
                }

                for (int i = 0; i < visible.Count; i++)
                {
                    for (int j = i + 1; j < visible.Count; j++)
                    {
                        if (Overlaps(visible[i], visible[j]))
                        {
                            return true;
                        }
                    }
                }

                return false;
            }

            bool HasFocusedInLayer(WindowState layer) =>
                focused != IntPtr.Zero
                && _windowRegistry.Entries.ContainsKey(focused)
                && focusedState == layer
                && LayerHasVisibleOverlap(layer);

            // Collect the visible windows in their final stacking order rather than emitting them
            // inline. The order is hashed below so place_top is only re-marshalled when the stacking
            // actually changes (keeping the compositor's order_hash stable during slides).
            var emissionOrder = new List<IntPtr>();

            void CollectPass(Func<WindowState, bool> match, WindowState layer)
            {
                bool deferFocused = HasFocusedInLayer(layer);
                foreach (var kvp in _windowRegistry.Entries)
                {
                    var s = ClassifyState(kvp.Key);
                    if (!match(s)) continue;
                    if (deferFocused && kvp.Key == focused) continue;
                    if (kvp.Value.Visible) emissionOrder.Add(kvp.Key);
                }

                if (deferFocused
                    && _windowRegistry.Entries.TryGetValue(focused, out var fw)
                    && fw.Visible)
                {
                    emissionOrder.Add(focused);
                }
            }

            CollectPass(s => s == WindowState.Tiled, WindowState.Tiled);
            CollectPass(s => s == WindowState.Maximized, WindowState.Maximized);

            {
                bool deferFocused = focused != IntPtr.Zero
                                    && _windowRegistry.Entries.ContainsKey(focused)
                                    && (focusedState == WindowState.Floating
                                        || focusedState == WindowState.Scratchpad);
                foreach (var kvp in _windowRegistry.Entries)
                {
                    var s = ClassifyState(kvp.Key);
                    if (s != WindowState.Floating && s != WindowState.Scratchpad) continue;
                    if (deferFocused && kvp.Key == focused) continue;
                    if (kvp.Value.Visible) emissionOrder.Add(kvp.Key);
                }

                if (deferFocused
                    && _windowRegistry.Entries.TryGetValue(focused, out var fw)
                    && fw.Visible)
                {
                    emissionOrder.Add(focused);
                }
            }

            CollectPass(s => s == WindowState.Fullscreen, WindowState.Fullscreen);

            // FNV-1a over the emission order; place_top is re-sent for every window only when this
            // differs from the previous pass. An unchanged order leaves the compositor's
            // rendering_requested.list (and thus order_hash) untouched, so an in-flight slide's
            // z-order is not disturbed.
            ulong orderHash = 1469598103934665603UL;
            foreach (var key in emissionOrder)
            {
                ulong v = (ulong)key.ToInt64();
                for (int b = 0; b < 8; b++)
                {
                    orderHash ^= (v >> (b * 8)) & 0xFF;
                    orderHash *= 1099511628211UL;
                }
            }

            bool emitPlaceTop = orderHash != _lastEmissionOrderHash;
            _lastEmissionOrderHash = orderHash;

            foreach (var key in emissionOrder)
            {
                if (_windowRegistry.Entries.TryGetValue(key, out var we))
                {
                    EmitWindow(key, we, emitPlaceTop);
                }
            }

            _managerRequestSender.SendManagerRequest(4);
            finished = true;
        }
        catch (Exception ex)
        {
            RiverLog.Write("render_start handler threw: " + ex);
        }
        finally
        {
            if (!finished)
            {
                _managerRequestSender.SendManagerRequest(4);
                RiverLog.Write("render_start: forced render_finish after exception");
            }
        }
    }

    private void HandleWindowInformation(WlArgument* args)
    {
        IntPtr proxy = args[0].o;
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        // Update in place when this proxy is already known: river re-emits window_information on
        // every manage cycle, and reconstructing WindowEntry was leaving a dangling NodeProxy whose
        // wl_proxy libwayland tears down — the cached IntPtr then crashed at +0x2c when
        // LayoutProposer marshalled set_position on a second swap. NodeProxy is allocated only on
        // first sight; subsequent events leave the existing node proxy (and its bind-site tracking)
        // untouched so callers can safely reuse the handle across manage cycles.
        if (!_windowRegistry.Entries.TryGetValue(proxy, out var entry))
        {
            entry = new WindowEntry { Proxy = proxy };

            // Assign the freshly-mapped window to its group's active workspace so the layout
            // proposer's workspace filter can hide it once the user switches away. Without this the
            // Workspace field stays IntPtr.Zero ("visible everywhere"), the filter is a no-op, and a
            // window from another workspace keeps stealing a master/stack slot (the half-size bug).
            var group = _workspaceStore.GetCurrentGroup();
            if (group != null)
            {
                entry.Workspace = _workspaceStore.ActiveIn(group);
            }

            entry.NodeProxy = WaylandInterop.wl_proxy_marshal_flags(
                proxy, 2, (IntPtr)WlInterfaces.RiverNode, 1, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            _windowRegistry.Entries[proxy] = entry;
            _bindSiteState.TrackProxyInterface(proxy, "river_window_v1");
            _bindSiteState.TrackProxyInterface(entry.NodeProxy, "river_node_v1");
        }

        if (_primarySeat.Current != IntPtr.Zero && _windowRegistry.Entries.ContainsKey(proxy))
        {
            _focusService.RequestFocus(proxy);
        }
        else
        {
            RiverLog.Write(
                $"deferring focus on new window 0x{proxy.ToString("x")} (primarySeat={_primarySeat.Current != IntPtr.Zero}, tracked={_windowRegistry.Entries.ContainsKey(proxy)})");
        }

        WaylandInterop.wl_proxy_add_dispatcher(
            proxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch
                .NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);
        RiverLog.Write($"+ window 0x{proxy.ToString("x")}");

        _managerRequestSender.ScheduleManage();
    }

    private void HandleOutputInformation(WlArgument* args)
    {
        IntPtr proxy = args[0].o;
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        _outputRegistry.Entries[proxy] = new OutputEntry { Proxy = proxy };
        WaylandInterop.wl_proxy_add_dispatcher(
            proxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch
                .NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);
        _bindSiteState.TrackProxyInterface(proxy, "river_output_v1");
        RiverLog.Write($"+ output 0x{proxy.ToString("x")}");

        CreateLayerShellOutput(proxy);
    }

    /// <summary>
    /// Creates the per-output <c>river_layer_shell_output_v1</c> sub-object via
    /// <c>river_layer_shell_v1.get_output</c> (request opcode 1, signature "no") and installs a
    /// dispatcher so the <c>non_exclusive_area</c> event routes back to the WM. No-op when the
    /// layer-shell global was never bound, or when this output already has a sub-object.
    /// </summary>
    private void CreateLayerShellOutput(IntPtr output)
    {
        if (_bindSiteState.LayerShell == IntPtr.Zero || output == IntPtr.Zero)
        {
            return;
        }

        // The XML makes a second get_output for the same river_output_v1 a protocol error.
        if (_bindSiteState.LayerShellOutputByOutput.ContainsKey(output))
        {
            return;
        }

        IntPtr lsOutput = WaylandInterop.wl_proxy_marshal_flags(
            _bindSiteState.LayerShell,
            RiverProtocolOpcodes.LayerShell.GetOutput,
            (IntPtr)WlInterfaces.RiverLayerShellOutput,
            1,
            0,
            IntPtr.Zero, // new_id (filled by libwayland)
            output,      // the river_output_v1 object arg
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        if (lsOutput == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_add_dispatcher(
            lsOutput,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch
                .NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);
        _bindSiteState.TrackProxyInterface(lsOutput, "river_layer_shell_output_v1");
        _bindSiteState.LayerShellOutputByOutput[output] = lsOutput;
        _bindSiteState.OutputByLayerShellOutput[lsOutput] = output;
        RiverLog.Write($"+ layer_shell_output 0x{lsOutput:x} for output 0x{output:x}");
    }

    /// <summary>
    /// Creates the per-seat <c>river_layer_shell_seat_v1</c> sub-object via
    /// <c>river_layer_shell_v1.get_seat</c> (request opcode 2, signature "no") and installs a
    /// dispatcher so the <c>focus_exclusive</c>/<c>focus_non_exclusive</c>/<c>focus_none</c> events
    /// route back to the WM. No-op when the layer-shell global was never bound, or when this seat
    /// already has a sub-object.
    /// </summary>
    private void CreateLayerShellSeat(IntPtr seat)
    {
        if (_bindSiteState.LayerShell == IntPtr.Zero || seat == IntPtr.Zero)
        {
            return;
        }

        // The XML makes a second get_seat for the same river_seat_v1 a protocol error.
        if (_bindSiteState.LayerShellSeatBySeat.ContainsKey(seat))
        {
            return;
        }

        IntPtr lsSeat = WaylandInterop.wl_proxy_marshal_flags(
            _bindSiteState.LayerShell,
            RiverProtocolOpcodes.LayerShell.GetSeat,
            (IntPtr)WlInterfaces.RiverLayerShellSeat,
            1,
            0,
            IntPtr.Zero, // new_id (filled by libwayland)
            seat,        // the river_seat_v1 object arg
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        if (lsSeat == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_add_dispatcher(
            lsSeat,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch
                .NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);
        _bindSiteState.TrackProxyInterface(lsSeat, "river_layer_shell_seat_v1");
        _bindSiteState.LayerShellSeatBySeat[seat] = lsSeat;
        _bindSiteState.SeatByLayerShellSeat[lsSeat] = seat;
        RiverLog.Write($"+ layer_shell_seat 0x{lsSeat:x} for seat 0x{seat:x}");
    }

    private void HandleSeatInformation(WlArgument* args)
    {
        IntPtr proxy = args[0].o;
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        _seatRegistry.Entries[proxy] = new SeatEntry { Proxy = proxy };
        WaylandInterop.wl_proxy_add_dispatcher(
            proxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch
                .NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);
        _bindSiteState.TrackProxyInterface(proxy, "river_seat_v1");
        RiverLog.Write($"+ seat 0x{proxy.ToString("x")}");

        CreateLayerShellSeat(proxy);

        if (_primarySeat.Current == IntPtr.Zero)
        {
            _primarySeat.Current = proxy;
        }

        if (_focusedWindowTracker.Current == IntPtr.Zero && _pendingFocus.Window == IntPtr.Zero && _windowRegistry.Entries.Count > 0)
        {
            foreach (var wk in _windowRegistry.Entries.Keys)
            {
                _focusService.RequestFocus(wk);
                break;
            }
        }

        if (_bindSiteState.XkbBindings != IntPtr.Zero)
        {
            _keyBindingRegistrar.RegisterAllBindings(proxy);
        }

        bool firstPointerBindingForSeat = _pointerBindings.SeatsWithPointerBindings.Add(proxy);
        uint managerVersion = _manageCycle.ManagerVersion;
        if (firstPointerBindingForSeat && _pointerBindings.DragPointerBinding == IntPtr.Zero && managerVersion >= 4)
        {
            const uint BTN_LEFT = 0x110;
            uint modMask = Mods.PrimaryMask;
            _pointerBindings.DragPointerBinding = WaylandInterop.wl_proxy_marshal_flags(
                proxy, 6, (IntPtr)WlInterfaces.RiverPointerBinding, managerVersion, 0,
                IntPtr.Zero, (IntPtr)BTN_LEFT, (IntPtr)modMask,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            if (_pointerBindings.DragPointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(
                    _pointerBindings.DragPointerBinding,
                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch
                        .NativeCallbackEntry.Dispatch,
                    _keyBindingsRegistry.SelfHandlePtr,
                    IntPtr.Zero);
                _bindSiteState.TrackProxyInterface(_pointerBindings.DragPointerBinding, "river_pointer_binding_v1");
                _pointerBindings.DragPointerBindingNeedsEnable = true;
                RiverLog.Write(
                    $"registered {Mods.PrimaryName}+BTN_LEFT pointer binding for window drag (mask=0x{modMask:x}, v{managerVersion})");
            }
        }
        else if (_pointerBindings.DragPointerBinding == IntPtr.Zero && managerVersion < 4)
        {
            RiverLog.Write(
                $"skipping get_pointer_binding; river_window_manager_v1 v{managerVersion} < 4 (River 0.4.3 ships v3)");
        }

        if (firstPointerBindingForSeat && _pointerBindings.DragResizePointerBinding == IntPtr.Zero && managerVersion >= 4)
        {
            const uint BTN_RIGHT = 0x111;
            uint modMask = Mods.PrimaryMask;
            _pointerBindings.DragResizePointerBinding = WaylandInterop.wl_proxy_marshal_flags(
                proxy, 6, (IntPtr)WlInterfaces.RiverPointerBinding, managerVersion, 0,
                IntPtr.Zero, (IntPtr)BTN_RIGHT, (IntPtr)modMask,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            if (_pointerBindings.DragResizePointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(
                    _pointerBindings.DragResizePointerBinding,
                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch
                        .NativeCallbackEntry.Dispatch,
                    _keyBindingsRegistry.SelfHandlePtr,
                    IntPtr.Zero);
                _bindSiteState.TrackProxyInterface(_pointerBindings.DragResizePointerBinding, "river_pointer_binding_v1");
                _pointerBindings.DragResizePointerBindingNeedsEnable = true;
                RiverLog.Write(
                    $"registered {Mods.PrimaryName}+BTN_RIGHT pointer binding for window drag-resize (mask=0x{modMask:x}, v{managerVersion})");
            }
        }

    }
}
