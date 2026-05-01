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
// Phase 2 readability refactor.
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
                // tear down per-window state so the
                // controller's invariants (single-FS slot, MRU stack,
                // scratchpad ownership) drop their references to the
                // dead proxy before _windows loses the entry.
                _windowState.OnWindowDestroyed(new WindowProxy(proxy));
                _windowStates.TryRemove(proxy, out _);
                // clear *all* tracking that points at this proxy
                // BEFORE removing it from _windows. The layout pass uses
                // _windows.TryGetValue as its only "is this handle alive?"
                // check before marshalling opcode 3 onto the proxy. If we
                // remove from _windows first, a concurrent ProposeForArea
                // can still find the dead handle in _outputFullscreen /
                // _prevFullscreenHandles, fall into the FS bucket, and
                // (because the new ContainsKey guard fires AFTER the
                // bucketing pass had already captured the handle) marshal
                // a propose_dimensions on a freed proxy — protocol error,
                // River drops our connection.
                foreach (var ofs in _outputFullscreen)
                {
                    if (ofs.Value == proxy)
                    {
                        _outputFullscreen.TryRemove(ofs.Key, out _);
                    }
                }
                _prevFullscreenHandles.Remove(proxy);

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
                    _dragEdges = 0;
                    // The window is gone, so we cannot — and must not — send
                    // inform_resize_end on a destroyed proxy. Just clear the
                    // flag; no balancing request is required because the
                    // server tears the resize down implicitly with the
                    // closed event.
                    _dragResizeInformed = false;
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
                // as soon as the client commits a real size, run a fresh
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
                // Per the intended UX, interactive move is only honoured while the
                // float layout is active. In tile/scrolling/monocle/grid the per-
                // window Floating override is suppressed by the bucketing pass
                // (see LayoutProposer ~lines 200-220), so any FloatX/Y written
                // during the drag would be silently overwritten on the next
                // manage cycle. Ignoring the request here keeps the WM out of a
                // half-armed drag state instead of pretending to move the window.
                // gate on the dragged window's output, not the focused
                // window's, so a resize/move gesture that landed before the
                // CSD-driven focus update isn't silently dropped because focus
                // happens to live on another output running a tiling layout.
                if (!IsFloatLayoutActive(w.Output))
                {
                    break;
                }

                _activeDragWindow = w;
                _activeDragSeat = seatProxy;
                _dragStartX = w.X;
                _dragStartY = w.Y;
                _dragEdges = 0;
                // Reset the drag lifecycle flags so ManagerEventHandler will
                // actually issue op_start_pointer on the next manage cycle.
                // If a previous drag's release path didn't clear _dragStarted
                // (e.g. a focus-change race), the new gesture would otherwise
                // never produce an op_delta stream.
                _dragStarted = false;
                _dragFinished = false;
                break;
            case RiverProtocolOpcodes.Window.PointerResizeRequested:
            {
                IntPtr resizeSeatProxy = args[0].o;
                uint edges = args[1].u;
                Log($"window 0x{proxy.ToString("x")} requested pointer resize on seat 0x{resizeSeatProxy.ToString("x")} edges={edges}");
                // Intended UX: interactive resize is only allowed while the
                // float layout is active. Outside float, the per-window
                // Floating override is suppressed by LayoutProposer bucketing
                // and any FloatW/FloatH written during op_delta would be
                // overwritten by the tiling engine on the next manage cycle.
                // The protocol explicitly permits the WM to ignore this
                // event entirely, so simply do nothing.
                if (edges == 0 || !IsFloatLayoutActive(w.Output))
                {
                    break;
                }

                _activeDragWindow = w;
                _activeDragSeat = resizeSeatProxy;
                _dragStartX = w.X;
                _dragStartY = w.Y;
                _dragStartW = w.W > 0 ? w.W
                            : w.FloatW > 0 ? w.FloatW
                            : w.LastHintW > 0 ? w.LastHintW
                            : w.ProposedW > 0 ? w.ProposedW
                            : 800;
                _dragStartH = w.H > 0 ? w.H
                            : w.FloatH > 0 ? w.FloatH
                            : w.LastHintH > 0 ? w.LastHintH
                            : w.ProposedH > 0 ? w.ProposedH
                            : 600;
                _dragEdges = edges;
                // Same _dragStarted/_dragFinished reset as the move arm: a
                // sticky flag from a prior gesture would otherwise prevent
                // ManagerEventHandler from emitting op_start_pointer for the
                // new resize, leaving the delta stream dead-on-arrival.
                _dragStarted = false;
                _dragFinished = false;
                break;
            }
            case RiverProtocolOpcodes.Window.MaximizeRequested:
                if (!_windowStates.TryGetValue(proxy, out var sMax)
                    || sMax.State != WindowState.Maximized)
                {
                    _windowState.ToggleMaximize(new WindowProxy(proxy));
                }

                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.UnmaximizeRequested:
                if (_windowStates.TryGetValue(proxy, out var stateData)
                    && stateData.State == WindowState.Maximized)
                {
                    _windowState.ToggleMaximize(new WindowProxy(proxy));
                }

                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.FullscreenRequested:
                var outputProxy = args[0].o;
                _windowState.OnClientRequestedFullscreen(new WindowProxy(proxy),
                    outputProxy == IntPtr.Zero ? null : new OutputProxy(outputProxy));
                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.ExitFullscreenRequested:
                _windowState.OnClientRequestedUnfullscreen(new WindowProxy(proxy));
                ScheduleManage();
                break;
            case RiverProtocolOpcodes.Window.MinimizeRequested:
                _windowState.ToggleMinimize(new WindowProxy(proxy));
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
