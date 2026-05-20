using System;
using System.Runtime.InteropServices;
using Aqueous.Diagnostics;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River.Dispatch.Services;

/// <summary>
/// PR 9.12 §2.13 — handles river_window_v1 events. Lifted from the
/// deleted partial-class file <c>WindowEventHandler.cs</c> into a
/// standalone service. State the service mutates still lives on
/// <see cref="RiverWindowManagerClient"/> (window registry, window
/// states, fullscreen map, drag state, focus state, seat-hover map).
/// Each is consumed via internal accessors and retires together with
/// the god class.
/// </summary>
internal sealed unsafe class WindowEventService
{
    private readonly RiverWindowManagerClient _client;

    public WindowEventService(RiverWindowManagerClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    private static string? MarshalUtf8(IntPtr p) =>
        p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);

    public void HandleEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        if (!_client.WindowRegistry.Entries.TryGetValue(proxy, out var w))
        {
            return;
        }

        switch (opcode)
        {
            case RiverProtocolOpcodes.Window.Closed:
                RiverLog.Write($"window 0x{proxy.ToString("x")} closed");
                _client.WindowStateController.OnWindowDestroyed(new WindowProxy(proxy));
                _client.WindowStates.TryRemove(proxy, out _);
                foreach (var ofs in _client.OutputFullscreen)
                {
                    if (ofs.Value == proxy)
                    {
                        _client.OutputFullscreen.TryRemove(ofs.Key, out _);
                    }
                }
                _client.PrevFullscreenHandles.Remove(proxy);

                _client.WindowRegistry.Entries.TryRemove(proxy, out _);

                if (_client.ActiveDragWindow != null && _client.ActiveDragWindow.Proxy == proxy)
                {
                    _client.SetActiveDragWindow(null);
                    _client.SetActiveDragSeat(IntPtr.Zero);
                    _client.SetDragStarted(false);
                    _client.SetDragFinished(false);
                    _client.SetDragEdges(0);
                    _client.DragResizeInformed = false;
                }

                if (_client.PendingFocusWindow == proxy)
                {
                    _client.PendingFocusWindowMutable = IntPtr.Zero;
                }

                foreach (var k in _client.SeatHoveredWindow.Keys)
                {
                    if (_client.SeatHoveredWindow.TryGetValue(k, out var v) && v == proxy)
                    {
                        _client.SeatHoveredWindow[k] = IntPtr.Zero;
                    }
                }

                if (_client.FocusedWindow == proxy)
                {
                    _client.FocusedWindow = IntPtr.Zero;
                    _client.FocusAnyOtherWindowExternal(proxy);
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
                _client.ScheduleManageExternal();
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
                if (!_client.IsFloatLayoutActive(w.Output))
                {
                    break;
                }

                _client.SetActiveDragWindow(w);
                _client.SetActiveDragSeat(seatProxy);
                _client.SetDragStartX(w.X);
                _client.SetDragStartY(w.Y);
                if (_client.SeatPointerPos.TryGetValue(seatProxy, out var pmrP0))
                {
                    _client.SetDragStartPointerX(pmrP0.X);
                    _client.SetDragStartPointerY(pmrP0.Y);
                }
                else
                {
                    _client.SetDragStartPointerX(w.X);
                    _client.SetDragStartPointerY(w.Y);
                }

                _client.SetDragEdges(0);
                _client.SetDragStarted(false);
                _client.SetDragFinished(false);
                break;
            }

            case RiverProtocolOpcodes.Window.PointerResizeRequested:
            {
                IntPtr resizeSeatProxy = args[0].o;
                uint edges = args[1].u;
                RiverLog.Write($"window 0x{proxy.ToString("x")} requested pointer resize on seat 0x{resizeSeatProxy.ToString("x")} edges={edges}");
                if (edges == 0 || !_client.IsFloatLayoutActive(w.Output))
                {
                    break;
                }

                _client.SetActiveDragWindow(w);
                _client.SetActiveDragSeat(resizeSeatProxy);
                _client.SetDragStartX(w.X);
                _client.SetDragStartY(w.Y);
                if (_client.SeatPointerPos.TryGetValue(resizeSeatProxy, out var prrP0))
                {
                    _client.SetDragStartPointerX(prrP0.X);
                    _client.SetDragStartPointerY(prrP0.Y);
                }
                else
                {
                    _client.SetDragStartPointerX(w.X);
                    _client.SetDragStartPointerY(w.Y);
                }

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
                _client.SetDragStartW(startW);
                _client.SetDragStartH(startH);
                _client.SetDragEdges(edges);
                _client.SetDragStarted(false);
                _client.SetDragFinished(false);
                break;
            }

            case RiverProtocolOpcodes.Window.MaximizeRequested:
                if (!_client.WindowStates.TryGetValue(proxy, out WindowStateData? sMax)
                    || sMax.State != WindowState.Maximized)
                {
                    _client.WindowStateController.ToggleMaximize(new WindowProxy(proxy));
                }
                _client.ScheduleManageExternal();
                break;

            case RiverProtocolOpcodes.Window.UnmaximizeRequested:
                if (_client.WindowStates.TryGetValue(proxy, out WindowStateData? stateData)
                    && stateData.State == WindowState.Maximized)
                {
                    _client.WindowStateController.ToggleMaximize(new WindowProxy(proxy));
                }
                _client.ScheduleManageExternal();
                break;

            case RiverProtocolOpcodes.Window.FullscreenRequested:
            {
                var outputProxy = args[0].o;
                _client.WindowStateController.OnClientRequestedFullscreen(new WindowProxy(proxy),
                    outputProxy == IntPtr.Zero ? null : new OutputProxy(outputProxy));
                _client.ScheduleManageExternal();
                break;
            }

            case RiverProtocolOpcodes.Window.ExitFullscreenRequested:
                _client.WindowStateController.OnClientRequestedUnfullscreen(new WindowProxy(proxy));
                _client.ScheduleManageExternal();
                break;

            case RiverProtocolOpcodes.Window.MinimizeRequested:
                RiverLog.Write($"window 0x{proxy.ToString("x")} minimize_requested");
                if (!_client.WindowStates.TryGetValue(proxy, out WindowStateData? minState)
                    || minState.State != WindowState.Minimized)
                {
                    _client.WindowStateController.ToggleMinimize(new WindowProxy(proxy));
                }
                _client.ScheduleManageExternal();
                break;

            case RiverProtocolOpcodes.Window.ActivateRequested:
                RiverLog.Write($"window 0x{proxy.ToString("x")} activate_requested");
                if (_client.WindowStates.TryGetValue(proxy, out WindowStateData? actState)
                    && actState.State == WindowState.Minimized)
                {
                    _client.WindowStateController.ToggleMinimize(new WindowProxy(proxy));
                }
                _client.RequestFocusExternal(proxy);
                _client.ScheduleManageExternal();
                break;

            case RiverProtocolOpcodes.Window.UnminimizeRequested:
                RiverLog.Write($"window 0x{proxy.ToString("x")} unminimize_requested");
                if (_client.WindowStates.TryGetValue(proxy, out WindowStateData? unminState)
                    && unminState.State == WindowState.Minimized)
                {
                    _client.WindowStateController.ToggleMinimize(new WindowProxy(proxy));
                    _client.RequestFocusExternal(proxy);
                }
                _client.ScheduleManageExternal();
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
