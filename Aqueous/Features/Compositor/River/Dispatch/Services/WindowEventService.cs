using System;
using System.Runtime.InteropServices;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River.Dispatch.Services;

/// <summary>
/// Handles river_window_v1 events.
/// <para>
/// The service no longer references <see cref="RiverWindowManagerClient"/>. All
/// state.</description>
/// </item>
/// <item>
/// <description><see cref="WindowStateStore"/>, <see cref="OutputFullscreenMap"/>, <see
/// cref="PrevFullscreenStore"/> — per-window/output state buckets cleared on Closed and queried by
/// the Maximize/Fullscreen/Minimize cases.</description>
/// </item>
/// <item>
/// <description><see cref="DragStateStore"/> — drag-lifecycle
/// coords/edges/started/finished/seat-hovered map.
internal sealed unsafe class WindowEventService
{
    private readonly IWindowRegistry _windowRegistry;
    private readonly WindowStateStore _windowStates;
    private readonly OutputFullscreenMap _outputFullscreen;
    private readonly PrevFullscreenStore _prevFullscreenStore;
    private readonly DragStateStore _dragState;
    private readonly PendingFocusStore _pendingFocus;
    private readonly IFocusService _focusService;
    private readonly FocusedWindowTracker _focusedWindowTracker;
    private readonly WindowStateController _windowStateController;
    private readonly ILayoutProposer _layoutProposer;
    private readonly IManagerRequestSender _managerRequestSender;

    public WindowEventService(
        IWindowRegistry windowRegistry,
        WindowStateStore windowStates,
        OutputFullscreenMap outputFullscreen,
        PrevFullscreenStore prevFullscreenStore,
        DragStateStore dragState,
        PendingFocusStore pendingFocus,
        IFocusService focusService,
        FocusedWindowTracker focusedWindowTracker,
        WindowStateController windowStateController,
        ILayoutProposer layoutProposer,
        IManagerRequestSender managerRequestSender)
    {
        _windowRegistry        = windowRegistry        ?? throw new ArgumentNullException(nameof(windowRegistry));
        _windowStates          = windowStates          ?? throw new ArgumentNullException(nameof(windowStates));
        _outputFullscreen      = outputFullscreen      ?? throw new ArgumentNullException(nameof(outputFullscreen));
        _prevFullscreenStore   = prevFullscreenStore   ?? throw new ArgumentNullException(nameof(prevFullscreenStore));
        _dragState             = dragState             ?? throw new ArgumentNullException(nameof(dragState));
        _pendingFocus          = pendingFocus          ?? throw new ArgumentNullException(nameof(pendingFocus));
        _focusService          = focusService          ?? throw new ArgumentNullException(nameof(focusService));
        _focusedWindowTracker  = focusedWindowTracker  ?? throw new ArgumentNullException(nameof(focusedWindowTracker));
        _windowStateController = windowStateController ?? throw new ArgumentNullException(nameof(windowStateController));
        _layoutProposer        = layoutProposer        ?? throw new ArgumentNullException(nameof(layoutProposer));
        _managerRequestSender  = managerRequestSender  ?? throw new ArgumentNullException(nameof(managerRequestSender));
    }

    private static string? MarshalUtf8(IntPtr p) =>
        p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);

    public void HandleEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        if (!_windowRegistry.Entries.TryGetValue(proxy, out var w))
        {
            return;
        }

        switch (opcode)
        {
            case RiverProtocolOpcodes.Window.Closed:
                RiverLog.Write($"window 0x{proxy.ToString("x")} closed");
                _windowStateController.OnWindowDestroyed(new WindowProxy(proxy));
                _windowStates.TryRemove(proxy, out _);
                foreach (var ofs in _outputFullscreen)
                {
                    if (ofs.Value == proxy)
                    {
                        _outputFullscreen.TryRemove(ofs.Key, out _);
                    }
                }
                _prevFullscreenStore.Handles.Remove(proxy);

                _windowRegistry.Entries.TryRemove(proxy, out _);

                if (_dragState.ActiveDragWindow != null && _dragState.ActiveDragWindow.Proxy == proxy)
                {
                    _dragState.ActiveDragWindow = null;
                    _dragState.ActiveDragSeat = IntPtr.Zero;
                    _dragState.DragStarted = false;
                    _dragState.DragFinished = false;
                    _dragState.DragEdges = 0;
                    _dragState.DragResizeInformed = false;
                }

                if (_pendingFocus.Window == proxy)
                {
                    _pendingFocus.Window = IntPtr.Zero;
                }

                foreach (var k in _dragState.SeatHoveredWindow.Keys)
                {
                    if (_dragState.SeatHoveredWindow.TryGetValue(k, out var v) && v == proxy)
                    {
                        _dragState.SeatHoveredWindow[k] = IntPtr.Zero;
                    }
                }

                if (_focusedWindowTracker.Current == proxy)
                {
                    _focusService.ClearFocusedHandle();
                    _focusService.FocusAnyOtherWindow(proxy);
                }
                break;

            case RiverProtocolOpcodes.Window.DimensionsHint:
                w.MinW = args[0].i;
                w.MinH = args[1].i;
                w.MaxW = args[2].i;
                w.MaxH = args[3].i;
                RiverLog.Write($"window 0x{proxy.ToString("x")} dimensions_hint min {w.MinW}x{w.MinH} max {w.MaxW}x{w.MaxH}");
                break;

            case RiverProtocolOpcodes.Window.Dimensions:
                w.W = args[0].i;
                w.H = args[1].i;
                RiverLog.Write($"window 0x{proxy.ToString("x")} dimensions {w.W}x{w.H}");
                _managerRequestSender.ScheduleManage();
                break;

            case RiverProtocolOpcodes.Window.AppId:
                w.AppId = MarshalUtf8(args[0].s) ?? string.Empty;
                RiverLog.Write($"window 0x{proxy.ToString("x")} app_id={w.AppId}");
                break;

            case RiverProtocolOpcodes.Window.Title:
                w.Title = MarshalUtf8(args[0].s) ?? string.Empty;
                RiverLog.Write($"window 0x{proxy.ToString("x")} title={w.Title}");
                break;

            case RiverProtocolOpcodes.Window.PointerMoveRequested:
            {
                IntPtr seatProxy = args[0].o;
                RiverLog.Write($"window 0x{proxy.ToString("x")} requested pointer move on seat 0x{seatProxy.ToString("x")}");
                if (!_layoutProposer.IsFloatLayoutActive(w.Output))
                {
                    break;
                }

                _dragState.ActiveDragWindow = w;
                _dragState.ActiveDragSeat = seatProxy;
                _dragState.DragStartX = w.X;
                _dragState.DragStartY = w.Y;
                if (_dragState.SeatPointerPos.TryGetValue(seatProxy, out var pmrP0))
                {
                    _dragState.DragStartPointerX = pmrP0.X;
                    _dragState.DragStartPointerY = pmrP0.Y;
                }
                else
                {
                    _dragState.DragStartPointerX = w.X;
                    _dragState.DragStartPointerY = w.Y;
                }

                _dragState.DragEdges = 0;
                _dragState.DragStarted = false;
                _dragState.DragFinished = false;
                break;
            }

            case RiverProtocolOpcodes.Window.PointerResizeRequested:
            {
                IntPtr resizeSeatProxy = args[0].o;
                uint edges = args[1].u;
                RiverLog.Write($"window 0x{proxy.ToString("x")} requested pointer resize on seat 0x{resizeSeatProxy.ToString("x")} edges={edges}");
                if (edges == 0 || w.Output == IntPtr.Zero || !_layoutProposer.IsFloatLayoutActive(w.Output))
                {
                    RiverLog.Write($"pointer_resize_requested ignored (edges={edges}, output=0x{w.Output.ToString("x")})");
                    break;
                }

                if (!_dragState.SeatPointerPos.TryGetValue(resizeSeatProxy, out var prrP0))
                {
                    // No cached pointer pos => we cannot compute deltas, so do NOT start a drag.
                    RiverLog.Write("pointer_resize_requested ignored: no cached seat pointer pos");
                    break;
                }

                _dragState.ActiveDragWindow = w;
                _dragState.ActiveDragSeat = resizeSeatProxy;
                _dragState.DragStartX = w.X;
                _dragState.DragStartY = w.Y;
                _dragState.DragStartPointerX = prrP0.X;
                _dragState.DragStartPointerY = prrP0.Y;

                int startW = w.W > 0 ? w.W
                            : w.FloatW > 0 ? w.FloatW
                            : w.LastHintW > 0 ? w.LastHintW
                            : w.ProposedW > 0 ? w.ProposedW
                            : 800;
                int startH = w.H > 0 ? w.H
                            : w.FloatH > 0 ? w.FloatH
                            : w.LastHintH > 0 ? w.LastHintH
                            : w.ProposedH > 0 ? w.ProposedH
                            : 600;
                _dragState.DragStartW = startW;
                _dragState.DragStartH = startH;
                _dragState.DragEdges = edges;
                _dragState.DragStarted = false;
                _dragState.DragFinished = false;
                _dragState.DragResizeInformed = false;
                break;
            }

            case RiverProtocolOpcodes.Window.MaximizeRequested:
                if (!_windowStates.TryGetValue(proxy, out WindowStateData? sMax)
                    || sMax.State != WindowState.Maximized)
                {
                    _windowStateController.ToggleMaximize(new WindowProxy(proxy));
                }
                _managerRequestSender.ScheduleManage();
                break;

            case RiverProtocolOpcodes.Window.UnmaximizeRequested:
                if (_windowStates.TryGetValue(proxy, out WindowStateData? stateData)
                    && stateData.State == WindowState.Maximized)
                {
                    _windowStateController.ToggleMaximize(new WindowProxy(proxy));
                }
                _managerRequestSender.ScheduleManage();
                break;

            case RiverProtocolOpcodes.Window.FullscreenRequested:
            {
                var outputProxy = args[0].o;
                _windowStateController.OnClientRequestedFullscreen(new WindowProxy(proxy),
                    outputProxy == IntPtr.Zero ? null : new OutputProxy(outputProxy));
                _managerRequestSender.ScheduleManage();
                break;
            }

            case RiverProtocolOpcodes.Window.ExitFullscreenRequested:
                _windowStateController.OnClientRequestedUnfullscreen(new WindowProxy(proxy));
                _managerRequestSender.ScheduleManage();
                break;

            case RiverProtocolOpcodes.Window.MinimizeRequested:
                RiverLog.Write($"window 0x{proxy.ToString("x")} minimize_requested");
                if (!_windowStates.TryGetValue(proxy, out WindowStateData? minState)
                    || minState.State != WindowState.Minimized)
                {
                    _windowStateController.ToggleMinimize(new WindowProxy(proxy));
                }
                _managerRequestSender.ScheduleManage();
                break;

            case RiverProtocolOpcodes.Window.ActivateRequested:
                RiverLog.Write($"window 0x{proxy.ToString("x")} activate_requested");
                if (_windowStates.TryGetValue(proxy, out WindowStateData? actState)
                    && actState.State == WindowState.Minimized)
                {
                    _windowStateController.ToggleMinimize(new WindowProxy(proxy));
                }
                _focusService.RequestFocus(proxy);
                _managerRequestSender.ScheduleManage();
                break;

            case RiverProtocolOpcodes.Window.UnminimizeRequested:
                RiverLog.Write($"window 0x{proxy.ToString("x")} unminimize_requested");
                if (_windowStates.TryGetValue(proxy, out WindowStateData? unminState)
                    && unminState.State == WindowState.Minimized)
                {
                    _windowStateController.ToggleMinimize(new WindowProxy(proxy));
                    _focusService.RequestFocus(proxy);
                }
                _managerRequestSender.ScheduleManage();
                break;

            case RiverProtocolOpcodes.Window.Identifier:
                RiverLog.Write($"window 0x{proxy.ToString("x")} identifier={MarshalUtf8(args[0].s)}");
                break;

            default:
                RiverLog.Write($"window 0x{proxy.ToString("x")} event opcode={opcode}");
                break;
        }
    }
}
