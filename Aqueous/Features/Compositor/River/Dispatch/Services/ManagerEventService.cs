using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Diagnostics;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River.Dispatch.Services;

/// <summary>
/// PR 9.12 §2.13 — handles river_window_manager_v1 events
/// (manage_start / render_start / *_information / session_*). Lifted
/// from the deleted partial-class file
/// <c>ManagerEventHandler.cs</c> into a standalone service. State the
/// service mutates still lives on <see cref="RiverWindowManagerClient"/>
/// (registries, pending-focus, drag state, pointer-binding caches,
/// pump). Each is consumed via internal accessors and retires together
/// with the god class.
/// </summary>
internal sealed unsafe class ManagerEventService
{
    private readonly RiverWindowManagerClient _client;

    public ManagerEventService(RiverWindowManagerClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    public void HandleEvent(uint opcode, WlArgument* args)
    {
        switch (opcode)
        {
            case RiverProtocolOpcodes.Manager.Unavailable:
                RiverLog.Write("river_window_manager_v1.unavailable — another WM is active; giving up");
                _client.Pump.Stop(TimeSpan.Zero);
                break;
            case RiverProtocolOpcodes.Manager.Finished:
                RiverLog.Write("river_window_manager_v1.finished");
                _client.Pump.Stop(TimeSpan.Zero);
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
        _client.InsideManageSequenceFlag = true;
        try
        {
            RiverLog.Write($"manage_start (windows={_client.WindowRegistry.Entries.Count} outputs={_client.OutputRegistry.Entries.Count} seats={_client.SeatRegistry.Entries.Count})");

            // Self-heal focus.
            if (_client.FocusedWindowHandle == IntPtr.Zero
                && _client.PendingFocusWindow == IntPtr.Zero
                && _client.PendingFocusShellSurface == IntPtr.Zero
                && _client.WindowRegistry.Entries.Count > 0)
            {
                foreach (var wk in _client.WindowRegistry.Entries.Keys)
                {
                    _client.RequestFocusExternal(wk);
                    break;
                }
            }

            // Enable the pointer binding (must be issued inside a manage sequence).
            if (_client.DragPointerBindingNeedsEnable && _client.DragPointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    _client.DragPointerBinding, 1, IntPtr.Zero, 0, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _client.DragPointerBindingNeedsEnable = false;
                RiverLog.Write("enabled Super+BTN_LEFT pointer binding");
            }

            if (_client.DragResizePointerBindingNeedsEnable && _client.DragResizePointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    _client.DragResizePointerBinding, 1, IntPtr.Zero, 0, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _client.DragResizePointerBindingNeedsEnable = false;
                RiverLog.Write("enabled Super+BTN_RIGHT pointer binding");
            }

            if (_client.SnapActivatorBindingNeedsEnable.Count > 0)
            {
                foreach (var pb in new List<IntPtr>(_client.SnapActivatorBindingNeedsEnable.Keys))
                {
                    if (!_client.SnapActivatorBindingNeedsEnable[pb])
                    {
                        continue;
                    }

                    WaylandInterop.wl_proxy_marshal_flags(
                        pb, 1, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    _client.SnapActivatorBindingNeedsEnable[pb] = false;
                    if (_client.SnapActivatorBindings.TryGetValue(pb, out var act))
                    {
                        RiverLog.Write($"enabled Super+{act}+BTN_LEFT snap-activator pointer binding");
                    }
                }
            }

            // Drag finish path.
            if (_client.DragFinishedFlag)
            {
                if (_client.DragResizeInformed && _client.ActiveDragWindow != null)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        _client.ActiveDragWindow.Proxy, 13, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    RiverLog.Write($"inform_resize_end on window 0x{_client.ActiveDragWindow.Proxy.ToString("x")}");
                }

                WaylandInterop.wl_proxy_marshal_flags(
                    _client.ActiveDragSeatHandle, 5, IntPtr.Zero, 1, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                _client.SetActiveDragWindow(null);
                _client.SetActiveDragSeat(IntPtr.Zero);
                _client.SetActiveDragActivator(Aqueous.Features.SnapZones.SnapActivator.Always);
                _client.SetDragFinished(false);
                _client.SetDragStarted(false);
                _client.SetDragEdges(0);
                _client.DragResizeInformed = false;
            }

            if (_client.ActiveDragSeatHandle != IntPtr.Zero && _client.ActiveDragWindow != null && !_client.DragStartedFlag)
            {
                WaylandInterop.wl_proxy_marshal_flags(
                    _client.ActiveDragSeatHandle, 4, IntPtr.Zero, 1, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _client.SetDragStarted(true);

                if (_client.DragEdgesValue != 0 && !_client.DragResizeInformed)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        _client.ActiveDragWindow.Proxy, 12, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    _client.DragResizeInformed = true;
                    uint edges = _client.DragEdgesValue;
                    RiverLog.Write($"inform_resize_start on window 0x{_client.ActiveDragWindow.Proxy.ToString("x")} edges={edges}");
                }
            }

            if (_client.PendingFocusSeatField != IntPtr.Zero)
            {
                if (_client.PendingFocusWindow != IntPtr.Zero)
                {
                    WaylandInterop.wl_proxy_marshal_flags(_client.PendingFocusSeatField, 1, IntPtr.Zero, 0, 0,
                        _client.PendingFocusWindow, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                        IntPtr.Zero);
                    RiverLog.Write($"gave focus to window 0x{_client.PendingFocusWindow.ToString("x")}");
                }
                else if (_client.PendingFocusShellSurface != IntPtr.Zero)
                {
                    WaylandInterop.wl_proxy_marshal_flags(_client.PendingFocusSeatField, 2, IntPtr.Zero, 0, 0,
                        _client.PendingFocusShellSurface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                        IntPtr.Zero);
                    RiverLog.Write($"gave focus to shell surface 0x{_client.PendingFocusShellSurface.ToString("x")}");
                }

                _client.PendingFocusSeatField = IntPtr.Zero;
                _client.PendingFocusWindowMutable = IntPtr.Zero;
                _client.PendingFocusShellSurfaceMutable = IntPtr.Zero;
            }

            if (_client.OutputRegistry.Entries.IsEmpty)
            {
                Rect rect = StrutsCalculator.Apply(new Rect(0, 0, 1920, 1080), _client.LayoutConfig?.Struts);
                _client.ProposeForArea(IntPtr.Zero, null, rect);
            }
            else
            {
                foreach (var outputKvp in _client.OutputRegistry.Entries)
                {
                    OutputEntry oe = outputKvp.Value;
                    var aw = oe.Width > 0 ? oe.Width : 1920;
                    var ah = oe.Height > 0 ? oe.Height : 1080;
                    Rect rect = StrutsCalculator.Apply(new Rect(oe.X, oe.Y, aw, ah), _client.LayoutConfig?.Struts);
                    _client.ProposeForArea(outputKvp.Key, null, rect);
                }
            }

            _client.SendManagerRequestExternal(2); // manage_finish
        }
        finally
        {
            _client.InsideManageSequenceFlag = false;
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

            if (_client.ManagerVersion >= 2 && we.W > 0 && we.H > 0 &&
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
            if (_client.WindowStates.TryGetValue(handle, out var sd) && sd != null)
            {
                return sd.State;
            }

            return WindowState.Tiled;
        }

        IntPtr focused = _client.FocusedWindowHandle;
        WindowState focusedState = focused != IntPtr.Zero
            ? ClassifyState(focused)
            : WindowState.Tiled;
        bool HasFocusedInLayer(WindowState layer) =>
            focused != IntPtr.Zero
            && _client.WindowRegistry.Entries.ContainsKey(focused)
            && focusedState == layer;

        void EmitPass(Func<WindowState, bool> match, WindowState layer)
        {
            bool deferFocused = HasFocusedInLayer(layer);
            foreach (var kvp in _client.WindowRegistry.Entries)
            {
                var s = ClassifyState(kvp.Key);
                if (!match(s)) continue;
                if (deferFocused && kvp.Key == focused) continue;
                EmitWindow(kvp.Key, kvp.Value);
            }
            if (deferFocused
                && _client.WindowRegistry.Entries.TryGetValue(focused, out var fw))
            {
                EmitWindow(focused, fw);
            }
        }

        EmitPass(s => s == WindowState.Tiled, WindowState.Tiled);
        EmitPass(s => s == WindowState.Maximized, WindowState.Maximized);

        {
            bool deferFocused = focused != IntPtr.Zero
                && _client.WindowRegistry.Entries.ContainsKey(focused)
                && (focusedState == WindowState.Floating
                    || focusedState == WindowState.Scratchpad);
            foreach (var kvp in _client.WindowRegistry.Entries)
            {
                var s = ClassifyState(kvp.Key);
                if (s != WindowState.Floating && s != WindowState.Scratchpad) continue;
                if (deferFocused && kvp.Key == focused) continue;
                EmitWindow(kvp.Key, kvp.Value);
            }
            if (deferFocused
                && _client.WindowRegistry.Entries.TryGetValue(focused, out var fw))
            {
                EmitWindow(focused, fw);
            }
        }

        EmitPass(s => s == WindowState.Fullscreen, WindowState.Fullscreen);

        _client.SendManagerRequestExternal(4); // render_finish
    }

    private void HandleWindowInformation(WlArgument* args)
    {
        IntPtr proxy = args[0].o;
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        var entry = new WindowEntry { Proxy = proxy };
        entry.NodeProxy = WaylandInterop.wl_proxy_marshal_flags(
            proxy, 2, (IntPtr)WlInterfaces.RiverNode, 1, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        _client.WindowRegistry.Entries[proxy] = entry;
        _client.TrackProxyInterface(proxy, "river_window_v1");
        _client.TrackProxyInterface(entry.NodeProxy, "river_node_v1");

        if (_client.PrimarySeat != IntPtr.Zero && _client.WindowRegistry.Entries.ContainsKey(proxy))
        {
            _client.RequestFocusExternal(proxy);
        }
        else
        {
            RiverLog.Write($"deferring focus on new window 0x{proxy.ToString("x")} (primarySeat={_client.PrimarySeat != IntPtr.Zero}, tracked={_client.WindowRegistry.Entries.ContainsKey(proxy)})");
        }

        WaylandInterop.wl_proxy_add_dispatcher(
            proxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
            _client.SelfHandlePtr,
            IntPtr.Zero);
        RiverLog.Write($"+ window 0x{proxy.ToString("x")}");

        _client.ScheduleManageExternal();
    }

    private void HandleOutputInformation(WlArgument* args)
    {
        IntPtr proxy = args[0].o;
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        _client.OutputRegistry.Entries[proxy] = new OutputEntry { Proxy = proxy };
        WaylandInterop.wl_proxy_add_dispatcher(
            proxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
            _client.SelfHandlePtr,
            IntPtr.Zero);
        _client.TrackProxyInterface(proxy, "river_output_v1");
        RiverLog.Write($"+ output 0x{proxy.ToString("x")}");
    }

    private void HandleSeatInformation(WlArgument* args)
    {
        IntPtr proxy = args[0].o;
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        _client.SeatRegistry.Entries[proxy] = new SeatEntry { Proxy = proxy };
        WaylandInterop.wl_proxy_add_dispatcher(
            proxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
            _client.SelfHandlePtr,
            IntPtr.Zero);
        _client.TrackProxyInterface(proxy, "river_seat_v1");
        RiverLog.Write($"+ seat 0x{proxy.ToString("x")}");

        if (_client.PrimarySeat == IntPtr.Zero)
        {
            _client.PrimarySeatMutable = proxy;
        }

        if (_client.FocusedWindowHandle == IntPtr.Zero && _client.PendingFocusWindow == IntPtr.Zero && _client.WindowRegistry.Entries.Count > 0)
        {
            foreach (var wk in _client.WindowRegistry.Entries.Keys)
            {
                _client.RequestFocusExternal(wk);
                break;
            }
        }

        if (_client.XkbBindings != IntPtr.Zero)
        {
            _client.KeyBindingRegistrar.RegisterAllBindings(proxy);
        }

        bool firstPointerBindingForSeat = _client.SeatsWithPointerBindings.Add(proxy);
        if (firstPointerBindingForSeat && _client.DragPointerBinding == IntPtr.Zero && _client.ManagerVersion >= 4)
        {
            const uint BTN_LEFT = 0x110;
            uint modMask = Mods.PrimaryMask;
            _client.DragPointerBinding = WaylandInterop.wl_proxy_marshal_flags(
                proxy, 6, (IntPtr)WlInterfaces.RiverPointerBinding, _client.ManagerVersion, 0,
                IntPtr.Zero, (IntPtr)BTN_LEFT, (IntPtr)modMask,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            if (_client.DragPointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(
                    _client.DragPointerBinding,
                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
                    _client.SelfHandlePtr,
                    IntPtr.Zero);
                _client.TrackProxyInterface(_client.DragPointerBinding, "river_pointer_binding_v1");
                _client.DragPointerBindingNeedsEnable = true;
                RiverLog.Write(
                    $"registered {Mods.PrimaryName}+BTN_LEFT pointer binding for window drag (mask=0x{modMask:x}, v{_client.ManagerVersion})");
            }
        }
        else if (_client.DragPointerBinding == IntPtr.Zero && _client.ManagerVersion < 4)
        {
            RiverLog.Write(
                $"skipping get_pointer_binding; river_window_manager_v1 v{_client.ManagerVersion} < 4 (River 0.4.3 ships v3)");
        }

        if (firstPointerBindingForSeat && _client.DragResizePointerBinding == IntPtr.Zero && _client.ManagerVersion >= 4)
        {
            const uint BTN_RIGHT = 0x111;
            uint modMask = Mods.PrimaryMask;
            _client.DragResizePointerBindingMutable = WaylandInterop.wl_proxy_marshal_flags(
                proxy, 6, (IntPtr)WlInterfaces.RiverPointerBinding, _client.ManagerVersion, 0,
                IntPtr.Zero, (IntPtr)BTN_RIGHT, (IntPtr)modMask,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            if (_client.DragResizePointerBinding != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(
                    _client.DragResizePointerBinding,
                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
                    _client.SelfHandlePtr,
                    IntPtr.Zero);
                _client.TrackProxyInterface(_client.DragResizePointerBinding, "river_pointer_binding_v1");
                _client.DragResizePointerBindingNeedsEnable = true;
                RiverLog.Write(
                    $"registered {Mods.PrimaryName}+BTN_RIGHT pointer binding for window drag-resize (mask=0x{modMask:x}, v{_client.ManagerVersion})");
            }
        }

        if (_client.ManagerVersion >= 4 && _client.SnapActivatorBindings.Count == 0)
        {
            const uint BTN_LEFT = 0x110;
            var seenActivators = new HashSet<Aqueous.Features.SnapZones.SnapActivator>();
            foreach (var layoutList in _client.SnapZoneService.CollectAllSnapLayouts())
            {
                foreach (var l in layoutList)
                {
                    if (l.Activator == Aqueous.Features.SnapZones.SnapActivator.Always)
                    {
                        continue;
                    }

                    if (!seenActivators.Add(l.Activator))
                    {
                        continue;
                    }

                    uint extraMask = _client.SnapZoneService.ActivatorToMask(l.Activator);
                    if (extraMask == 0)
                    {
                        continue;
                    }

                    uint combinedMask = Mods.PrimaryMask | extraMask;
                    var pb = WaylandInterop.wl_proxy_marshal_flags(
                        proxy, 6, (IntPtr)WlInterfaces.RiverPointerBinding, _client.ManagerVersion, 0,
                        IntPtr.Zero, (IntPtr)BTN_LEFT, (IntPtr)combinedMask,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    if (pb == IntPtr.Zero)
                    {
                        continue;
                    }

                    _client.SnapActivatorBindingsMutable[pb] = l.Activator;
                    _client.SnapActivatorBindingNeedsEnable[pb] = true;
                    WaylandInterop.wl_proxy_add_dispatcher(
                        pb,
                        (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
                        _client.SelfHandlePtr,
                        IntPtr.Zero);
                    _client.TrackProxyInterface(pb, "river_pointer_binding_v1");
                    string maskHex = combinedMask.ToString("x");
                    RiverLog.Write($"registered {Mods.PrimaryName}+{l.Activator.ToString()}+BTN_LEFT snap-activator pointer binding (mask=0x{maskHex})");
                }
            }
        }
    }
}
