using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Compositor.River;

// river_window_v1 event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void OnWindowEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        if (!_windows.TryGetValue(proxy, out var w))
        {
            return;
        }
        // See RiverProtocolOpcodes.Window for the full event table.
        switch (opcode)
        {
            case RiverProtocolOpcodes.Window.Closed:
                Log($"window 0x{proxy.ToString("x")} closed");
                // Phase B1e Pass B: tear down per-window state so the
                // controller's invariants (single-FS slot, MRU stack,
                // scratchpad ownership) drop their references to the
                // dead proxy before _windows loses the entry.
                _windowState.OnWindowDestroyed(proxy);
                _windowStates.TryRemove(proxy, out _);
                foreach (var ofs in _outputFullscreen)
                {
                    if (ofs.Value == proxy)
                    {
                        _outputFullscreen.TryRemove(ofs.Key, out _);
                    }
                }

                _windows.TryRemove(proxy, out _);
                // Clean up all dangling references to the destroyed proxy so subsequent
                // manage_start sequences don't send requests against a dead object (which
                // would be a protocol error and terminate the WM).
                if (_activeDragWindow != null && _activeDragWindow.Proxy == proxy)
                {
                    _activeDragWindow = null;
                    _activeDragSeat = IntPtr.Zero;
                    _dragStarted = false;
                    _dragFinished = false;
                }

                if (_pendingFocusWindow == proxy)
                {
                    _pendingFocusWindow = IntPtr.Zero;
                }

                foreach (var k in _seatHoveredWindow.Keys)
                {
                    if (_seatHoveredWindow.TryGetValue(k, out var v) && v == proxy)
                    {
                        _seatHoveredWindow[k] = IntPtr.Zero;
                    }
                }

                // NOTE: do NOT send destroy (opcode 0) here. river_window_v1::closed
                // already implies the object is gone server-side, and calling destroy
                // from inside its own event handler can be a protocol error on some
                // River versions — which kills the WM connection and makes every
                // window on screen vanish. If cleanup of the client-side proxy is
                // needed, it must happen after the event dispatch returns.
                if (_focusedWindow == proxy)
                {
                    _focusedWindow = IntPtr.Zero;
                    FocusAnyOtherWindow(proxy);
                }

                break;
            case RiverProtocolOpcodes.Window.DimensionsHint:
                w.MinW = args[0].i;
                w.MinH = args[1].i;
                w.MaxW = args[2].i;
                w.MaxH = args[3].i;
                Log($"window 0x{proxy.ToString("x")} dimensions_hint min {w.MinW}x{w.MinH} max {w.MaxW}x{w.MaxH}");
                break;
            case RiverProtocolOpcodes.Window.Dimensions:
                w.W = args[0].i;
                w.H = args[1].i;
                Log($"window 0x{proxy.ToString("x")} dimensions {w.W}x{w.H}");
                // Fix #3: as soon as the client commits a real size, run a fresh
                // manage/render cycle so set_clip_box is emitted on the first frame
                // the size is known. Otherwise the initial frame ships without a
                // clip box and pointer/keyboard input falls outside the input region.
                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.AppId:
                w.AppId = MarshalUtf8(args[0].s);
                Log($"window 0x{proxy.ToString("x")} app_id={w.AppId}");
                break;
            case RiverProtocolOpcodes.Window.Title:
                w.Title = MarshalUtf8(args[0].s);
                Log($"window 0x{proxy.ToString("x")} title={w.Title}");
                break;
            case RiverProtocolOpcodes.Window.PointerMoveRequested:
                IntPtr seatProxy = args[0].o;
                Log($"window 0x{proxy.ToString("x")} requested pointer move on seat 0x{seatProxy.ToString("x")}");
                _activeDragWindow = w;
                _activeDragSeat = seatProxy;
                _dragStartX = w.X;
                _dragStartY = w.Y;
                break;
            case RiverProtocolOpcodes.Window.MaximizeRequested:
                if (!_windowStates.TryGetValue(proxy, out var sMax)
                    || sMax.State != WindowState.Maximized)
                {
                    _windowState.ToggleMaximize(proxy);
                }

                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.UnmaximizeRequested:
                if (_windowStates.TryGetValue(proxy, out var stateData)
                    && stateData.State == WindowState.Minimized)
                {
                    _windowState.ToggleMaximize(proxy);
                }

                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.FullscreenRequested:
                var outputProxy = args[0].o;
                _windowState.OnClientRequestedFullscreen(proxy,
                    outputProxy == IntPtr.Zero ? (IntPtr?)null : outputProxy);
                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.ExitFullscreenRequested:
                _windowState.OnClientRequestedUnfullscreen(proxy);
                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.MinimizeRequested:
                _windowState.ToggleMinimize(proxy);
                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.Identifier:
                Log($"window 0x{proxy.ToString("x")} identifier={MarshalUtf8(args[0].s)}"); break;
            default:
                Log($"window 0x{proxy.ToString("x")} event opcode={opcode}");
                break;
        }
    }
}
