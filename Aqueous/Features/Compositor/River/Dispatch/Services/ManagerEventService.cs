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
        IWindowStateHost windowStateHost)
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
    }

    public void HandleEvent(uint opcode, WlArgument* args)
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

    private void HandleManageStart()
    {
        _manageCycle.InsideManageSequence = true;
        _managerRequestSender.InsideManageSequence = true;
        try
        {
            RiverLog.Write(
                $"manage_start (windows={_windowRegistry.Entries.Count} outputs={_outputRegistry.Entries.Count} seats={_seatRegistry.Entries.Count})");

            // Self-heal focus.
            if (_focusedWindowTracker.Current == IntPtr.Zero
                && _pendingFocus.Window == IntPtr.Zero
                && _pendingFocus.ShellSurface == IntPtr.Zero
                && _windowRegistry.Entries.Count > 0)
            {
                foreach (var wk in _windowRegistry.Entries.Keys)
                {
                    _focusService.RequestFocus(wk);
                    break;
                }
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
            // bucket state (TagVisible && !HideSent) is the authoritative readiness signal. Running
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
                         && _pendingFocus.IsShellSurfaceLive(_pendingFocus.ShellSurface))
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
                    var aw = oe.Width > 0 ? oe.Width : 1920;
                    var ah = oe.Height > 0 ? oe.Height : 1080;
                    var raw = new Rect(oe.X, oe.Y, aw, ah);
                    var usable = StrutsCalculator.Apply(raw, _layoutController.Config?.Struts);
                    _layoutProposer.ProposeForArea(outputKvp.Key, null, raw, usable);
                }
            }

            _managerRequestSender.SendManagerRequest(2); // manage_finish
        }
        finally
        {
            _manageCycle.InsideManageSequence = false;
            _managerRequestSender.InsideManageSequence = false;
        }
    }

    private void HandleRenderStart()
    {
        RiverLog.Write("render_start");

        void EmitWindow(IntPtr key, WindowEntry we)
        {
            if (!we.Visible)
            {
                return;
            }

            WaylandInterop.wl_proxy_marshal_flags(key, 5, IntPtr.Zero, 0, 0, IntPtr.Zero, IntPtr.Zero,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            WaylandInterop.wl_proxy_marshal_flags(key, 8, IntPtr.Zero, 0, 0, (IntPtr)0, (IntPtr)0,
                (IntPtr)0, (IntPtr)0, (IntPtr)0, (IntPtr)0);

            if (we.NodeProxy != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_marshal_flags(we.NodeProxy, 2, IntPtr.Zero, 0, 0, IntPtr.Zero,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
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
        }

        WindowState ClassifyState(IntPtr handle)
        {
            if (_windowStates.TryGetValue(handle, out var sd) && sd != null)
            {
                return sd.State;
            }

            return WindowState.Tiled;
        }

        IntPtr focused = _focusedWindowTracker.Current;
        WindowState focusedState = focused != IntPtr.Zero
            ? ClassifyState(focused)
            : WindowState.Tiled;

        bool HasFocusedInLayer(WindowState layer) =>
            focused != IntPtr.Zero
            && _windowRegistry.Entries.ContainsKey(focused)
            && focusedState == layer;

        void EmitPass(Func<WindowState, bool> match, WindowState layer)
        {
            bool deferFocused = HasFocusedInLayer(layer);
            foreach (var kvp in _windowRegistry.Entries)
            {
                var s = ClassifyState(kvp.Key);
                if (!match(s)) continue;
                if (deferFocused && kvp.Key == focused) continue;
                EmitWindow(kvp.Key, kvp.Value);
            }

            if (deferFocused
                && _windowRegistry.Entries.TryGetValue(focused, out var fw))
            {
                EmitWindow(focused, fw);
            }
        }

        EmitPass(s => s == WindowState.Tiled, WindowState.Tiled);
        EmitPass(s => s == WindowState.Maximized, WindowState.Maximized);

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
                EmitWindow(kvp.Key, kvp.Value);
            }

            if (deferFocused
                && _windowRegistry.Entries.TryGetValue(focused, out var fw))
            {
                EmitWindow(focused, fw);
            }
        }

        EmitPass(s => s == WindowState.Fullscreen, WindowState.Fullscreen);

        _managerRequestSender.SendManagerRequest(4); // render_finish
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
