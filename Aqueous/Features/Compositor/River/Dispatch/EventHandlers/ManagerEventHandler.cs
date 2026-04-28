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

// river_window_manager_v1 event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void OnManagerEvent(uint opcode, WlArgument* args)
    {
        // See RiverProtocolOpcodes.Manager for the full event table.
        switch (opcode)
        {
            case RiverProtocolOpcodes.Manager.Unavailable:
                Log("river_window_manager_v1.unavailable — another WM is active; giving up");
                _pump.Stop(0);
                break;
            case RiverProtocolOpcodes.Manager.Finished:
                Log("river_window_manager_v1.finished");
                _pump.Stop(0);
                break;
            case RiverProtocolOpcodes.Manager.ManageStart:
                _insideManageSequence = true;
                try
                {
                    Log($"manage_start (windows={_windows.Count} outputs={_outputs.Count} seats={_seats.Count})");

                    // Self-heal focus: if we think nothing is focused but windows exist, pick one.
                    // This catches the case where the previously focused window was destroyed
                    // between sequences and ensures the keyboard always has somewhere to go.
                    if (_focusedWindow == IntPtr.Zero && _pendingFocusWindow == IntPtr.Zero &&
                        _pendingFocusShellSurface == IntPtr.Zero && _windows.Count > 0)
                    {
                        foreach (var wk in _windows.Keys)
                        {
                            RequestFocus(wk);
                            break;
                        }
                    }

                    // Enable the pointer binding (must be issued inside a manage sequence).
                    if (_dragPointerBindingNeedsEnable && _dragPointerBinding != IntPtr.Zero)
                    {
                        // river_pointer_binding_v1::enable is opcode 1 (0=destroy, 1=enable, 2=disable)
                        WaylandInterop.wl_proxy_marshal_flags(
                            _dragPointerBinding, 1, IntPtr.Zero, 0, 0,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        _dragPointerBindingNeedsEnable = false;
                        Log("enabled Super+BTN_LEFT pointer binding");
                    }

                    if (_dragFinished)
                    {
                        // If the just-finalised drag was an interactive resize
                        // and we previously emitted inform_resize_start, send
                        // the matching inform_resize_end before tearing down
                        // drag state. Per protocol (river-window-management-v1
                        // lines 739-762) this request must live inside a manage
                        // sequence, which this branch already is.
                        if (_dragResizeInformed && _activeDragWindow != null)
                        {
                            // river_window_v1::inform_resize_end is request opcode 13.
                            WaylandInterop.wl_proxy_marshal_flags(
                                _activeDragWindow.Proxy, 13, IntPtr.Zero, 0, 0,
                                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            Log($"inform_resize_end on window 0x{_activeDragWindow.Proxy.ToString("x")}");
                        }

                        WaylandInterop.wl_proxy_marshal_flags(
                            _activeDragSeat, 5, IntPtr.Zero, 1, 0,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                        _activeDragWindow = null;
                        _activeDragSeat = IntPtr.Zero;
                        _dragFinished = false;
                        _dragStarted = false;
                        _dragEdges = 0;
                        _dragResizeInformed = false;
                    }

                    if (_activeDragSeat != IntPtr.Zero && _activeDragWindow != null && !_dragStarted)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(
                            _activeDragSeat, 4, IntPtr.Zero, 1, 0,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        _dragStarted = true;

                        // For interactive resize, also emit inform_resize_start
                        // so that toolkits like libdecor / GTK paint the live
                        // size affordance and actually commit the live
                        // propose_dimensions stream during the drag. Without
                        // this, the wire traffic is correct but the client
                        // appears unresponsive until release.
                        if (_dragEdges != 0 && !_dragResizeInformed)
                        {
                            // river_window_v1::inform_resize_start is request opcode 12.
                            WaylandInterop.wl_proxy_marshal_flags(
                                _activeDragWindow.Proxy, 12, IntPtr.Zero, 0, 0,
                                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            _dragResizeInformed = true;
                            Log($"inform_resize_start on window 0x{_activeDragWindow.Proxy.ToString("x")} edges={_dragEdges}");
                        }
                    }

                    if (_pendingFocusSeat != IntPtr.Zero)
                    {
                        if (_pendingFocusWindow != IntPtr.Zero)
                        {
                            WaylandInterop.wl_proxy_marshal_flags(_pendingFocusSeat, 1, IntPtr.Zero, 0, 0,
                                _pendingFocusWindow, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                                IntPtr.Zero);
                            Log($"gave focus to window 0x{_pendingFocusWindow.ToString("x")}");
                        }
                        else if (_pendingFocusShellSurface != IntPtr.Zero)
                        {
                            WaylandInterop.wl_proxy_marshal_flags(_pendingFocusSeat, 2, IntPtr.Zero, 0, 0,
                                _pendingFocusShellSurface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                                IntPtr.Zero);
                            Log($"gave focus to shell surface 0x{_pendingFocusShellSurface.ToString("x")}");
                        }

                        _pendingFocusSeat = IntPtr.Zero;
                        _pendingFocusWindow = IntPtr.Zero;
                        _pendingFocusShellSurface = IntPtr.Zero;
                    }

                    // ----------------------------------------------------------------
                    // Layout subsystem (Phase 1.1 / B1b).
                    //
                    // For every known output, ask the LayoutController to place the
                    // visible windows assigned to that output. The controller calls the
                    // resolved ILayoutEngine (tile / monocle / grid / float / scrolling)
                    // and clamps results to per-window min/max hints.
                    //
                    // Wayland-side, manage_start is the right phase for propose_dimensions
                    // — the per-frame set_position/show/place_top calls live in case 3
                    // (render_start) and are unchanged. We diff against the per-window
                    // LastHintW/H so we only re-propose when the engine actually picked a
                    // new size, preserving the bandwidth-saving behaviour the previous
                    // hard-coded 800x600 loop relied on.
                    // ----------------------------------------------------------------
                    if (_outputs.IsEmpty)
                    {
                        // Headless / no outputs reported yet: fall back to a single
                        // virtual 1920x1080 area so windows still get a reasonable
                        // initial proposal (matches old behaviour + tile layout).
                        ProposeForArea(IntPtr.Zero, null, new Rect(0, 0, 1920, 1080));
                    }
                    else
                    {
                        foreach (var outputKvp in _outputs)
                        {
                            var oe = outputKvp.Value;
                            int aw = oe.Width > 0 ? oe.Width : 1920;
                            int ah = oe.Height > 0 ? oe.Height : 1080;
                            ProposeForArea(outputKvp.Key, null, new Rect(oe.X, oe.Y, aw, ah));
                        }
                    }

                    SendManagerRequest(2); // manage_finish opcode = 2 (see WlInterfaces)
                }
                finally
                {
                    _insideManageSequence = false;
                }

                break;
            case RiverProtocolOpcodes.Manager.RenderStart:
                // NOTE: do NOT set _insideManageSequence here — render_start is the render
                // half of the loop, not a manage sequence. Setting the flag during render
                // would suppress legitimate manage_dirty calls scheduled from event
                // handlers dispatched just before render.
                Log("render_start");

                // River's render cycle (render_start -> per-window placement/show/decoration
                // -> render_finish) describes the contents of the NEXT frame. The scene
                // graph is not retained between cycles — anything not re-emitted in this
                // cycle will simply not be in the frame. Therefore show, borders, place_top
                // and node position (and set_clip_box) MUST be emitted every render cycle
                // for every visible window. Gating them with one-shot latches (ShowSent,
                // BordersSent, Placed, LastPosX/Y, LastClipW/H) causes windows to appear
                // on the first frame and then vanish on every subsequent render.
                // Fix #2: show / borders / place_top must be re-emitted every render
                // cycle (River does not retain these across cycles), but set_position
                // and set_clip_box do NOT need to be re-sent every frame. Re-sending
                // them at full render cadence multiplies bus traffic and, combined with
                // the former manage_dirty storm, starved client pings. Only re-emit
                // when the cached value has actually changed.
                // Phase B1e Pass C / C4: layered render emission.
                // The river scene graph is not retained between
                // render cycles, so the *last* place_top per node
                // wins for stacking. Emitting in four ordered passes
                // (tiled → maximized → floating → fullscreen) puts
                // FS on top of floats on top of maximized on top of
                // tiles, which is the documented Phase B1e
                // stacking order. Within a layer dictionary order is
                // accepted; focus-aware in-layer ordering is a
                // post-Pass-C polish item.
                void EmitWindow(IntPtr key, WindowEntry we)
                {
                    if (!we.Visible)
                    {
                        return;
                    }
                    // show (opcode 5) — every frame so the window is in this frame's scene.
                    WaylandInterop.wl_proxy_marshal_flags(key, 5, IntPtr.Zero, 0, 0, IntPtr.Zero, IntPtr.Zero,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    // set_borders (opcode 8) — zero-width, every frame.
                    // Note: per Pass C plan, fullscreen explicitly
                    // wants 0-width borders; tiled/floating get the
                    // same value today (Pass C does not introduce
                    // border colour/width — that's a polish item).
                    WaylandInterop.wl_proxy_marshal_flags(key, 8, IntPtr.Zero, 0, 0, (IntPtr)0, (IntPtr)0,
                        (IntPtr)0, (IntPtr)0, (IntPtr)0, (IntPtr)0);

                    if (we.NodeProxy != IntPtr.Zero)
                    {
                        // place_top (river_node_v1 opcode 2) — every frame (scene graph is not retained).
                        WaylandInterop.wl_proxy_marshal_flags(we.NodeProxy, 2, IntPtr.Zero, 0, 0, IntPtr.Zero,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        // set_position (river_node_v1 opcode 1) — only when changed.
                        if (we.LastPosX != we.X || we.LastPosY != we.Y)
                        {
                            WaylandInterop.wl_proxy_marshal_flags(we.NodeProxy, 1, IntPtr.Zero, 0, 0, (IntPtr)we.X,
                                (IntPtr)we.Y, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            we.LastPosX = we.X;
                            we.LastPosY = we.Y;
                        }
                    }

                    // set_clip_box (river_window_v1 opcode 21, since v2) — only when size changed.
                    if (_managerVersion >= 2 && we.W > 0 && we.H > 0 &&
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

                // Classify each window once, then emit in four
                // ordered passes. State==null is treated as Tiled
                // (windows that no chord has yet touched).
                WindowState ClassifyState(IntPtr handle)
                {
                    if (_windowStates.TryGetValue(handle, out var sd) && sd != null)
                    {
                        return sd.State;
                    }

                    return WindowState.Tiled;
                }

                // Bring-to-front on focus: within each layer pass, defer
                // the focused window so its EmitWindow (which internally
                // emits river_node_v1::place_top, opcode 2) runs LAST in
                // its layer. Because each pass's last place_top wins
                // stacking within that layer, this raises the focused
                // window above its peers without an extra post-pass
                // request (the previous post-pass call used opcode 1,
                // which is set_position(0,0) — that teleported the
                // focused window to the top-left every frame).
                WindowState focusedState = _focusedWindow != IntPtr.Zero
                    ? ClassifyState(_focusedWindow)
                    : WindowState.Tiled;
                bool HasFocusedInLayer(WindowState layer) =>
                    _focusedWindow != IntPtr.Zero
                    && _windows.ContainsKey(_focusedWindow)
                    && focusedState == layer;

                void EmitPass(Func<WindowState, bool> match, WindowState layer)
                {
                    bool deferFocused = HasFocusedInLayer(layer);
                    foreach (var kvp in _windows)
                    {
                        var s = ClassifyState(kvp.Key);
                        if (!match(s)) continue;
                        if (deferFocused && kvp.Key == _focusedWindow) continue;
                        EmitWindow(kvp.Key, kvp.Value);
                    }
                    if (deferFocused
                        && _windows.TryGetValue(_focusedWindow, out var fw))
                    {
                        EmitWindow(_focusedWindow, fw);
                    }
                }

                // Pass 1: tiled (and unknown).
                EmitPass(s => s == WindowState.Tiled, WindowState.Tiled);

                // Pass 2: maximized.
                EmitPass(s => s == WindowState.Maximized, WindowState.Maximized);

                // Pass 3: floating (and Scratchpad — visible scratchpads
                // are rendered as floating dropdown windows above tiles).
                // Scratchpad-focused windows are deferred under the
                // Scratchpad layer key; Floating-focused under Floating.
                {
                    bool deferFocused = _focusedWindow != IntPtr.Zero
                        && _windows.ContainsKey(_focusedWindow)
                        && (focusedState == WindowState.Floating
                            || focusedState == WindowState.Scratchpad);
                    foreach (var kvp in _windows)
                    {
                        var s = ClassifyState(kvp.Key);
                        if (s != WindowState.Floating && s != WindowState.Scratchpad) continue;
                        if (deferFocused && kvp.Key == _focusedWindow) continue;
                        EmitWindow(kvp.Key, kvp.Value);
                    }
                    if (deferFocused
                        && _windows.TryGetValue(_focusedWindow, out var fw))
                    {
                        EmitWindow(_focusedWindow, fw);
                    }
                }

                // Pass 4: fullscreen (last so its place_top wins).
                EmitPass(s => s == WindowState.Fullscreen, WindowState.Fullscreen);

                SendManagerRequest(4); // render_finish opcode = 4
                break;
            case RiverProtocolOpcodes.Manager.SessionLocked: Log("session_locked"); break;
            case RiverProtocolOpcodes.Manager.SessionUnlocked: Log("session_unlocked"); break;
            case RiverProtocolOpcodes.Manager.WindowInformation:
                {
                    IntPtr proxy = args[0].o;
                    if (proxy != IntPtr.Zero)
                    {
                        // Floating layer: do NOT seed a cascade (X,Y) here.
                        // Leaving HasFloatRect == false lets the floating
                        // branch in LayoutProposer.ProposeForArea (lines
                        // ~376-383) compute a centred initial rect against
                        // the *real* usableArea of the output the window
                        // ultimately binds to. The previous cascade put
                        // every new window at the top-left of the global
                        // compositor space. A user-provided initial rect
                        // (drag, dimensions_hint, or controller's
                        // FloatingGeom seed) sets HasFloatRect = true and
                        // is then preserved across manage cycles.
                        var entry = new WindowEntry { Proxy = proxy };
                        entry.NodeProxy = WaylandInterop.wl_proxy_marshal_flags(
                            proxy, 2, (IntPtr)WlInterfaces.RiverNode, 1, 0,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                        _windows[proxy] = entry;
                        WaylandInterop.wl_proxy_add_dispatcher(
                            proxy,
                            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                            GCHandle.ToIntPtr(_selfHandle),
                            IntPtr.Zero);
                        Log($"+ window 0x{proxy.ToString("x")}");

                        // Spawn-to-front: always focus the freshly mapped window.
                        // Previously this was guarded by `_focusedWindow == IntPtr.Zero`,
                        // but at the moment a new window event arrives focus is usually
                        // still on the start-menu / previously-focused window, so the
                        // guard would skip RequestFocus and the new window would map
                        // without keyboard/pointer focus ("no input" symptom).
                        RequestFocus(proxy);

                        // Flush pending focus + clip box / position on this cycle so the
                        // very first committed frame of the new client has a valid input
                        // region and is actually the focused surface.
                        ScheduleManage();
                    }

                    break;
                }
            case RiverProtocolOpcodes.Manager.OutputInformation:
                {
                    IntPtr proxy = args[0].o;
                    if (proxy != IntPtr.Zero)
                    {
                        _outputs[proxy] = new OutputEntry { Proxy = proxy };
                        WaylandInterop.wl_proxy_add_dispatcher(
                            proxy,
                            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                            GCHandle.ToIntPtr(_selfHandle),
                            IntPtr.Zero);
                        Log($"+ output 0x{proxy.ToString("x")}");
                    }

                    break;
                }
            case RiverProtocolOpcodes.Manager.SeatInformation:
                {
                    IntPtr proxy = args[0].o;
                    if (proxy != IntPtr.Zero)
                    {
                        _seats[proxy] = new SeatEntry { Proxy = proxy };
                        WaylandInterop.wl_proxy_add_dispatcher(
                            proxy,
                            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                            GCHandle.ToIntPtr(_selfHandle),
                            IntPtr.Zero);
                        Log($"+ seat 0x{proxy.ToString("x")}");

                        if (_primarySeat == IntPtr.Zero)
                        {
                            _primarySeat = proxy;
                        }

                        // Bug 1 fix: if windows already arrived before the seat, focus one now.
                        // Otherwise the initial RequestFocus short-circuited (seat == 0) and
                        // the first window never gets keyboard focus.
                        if (_focusedWindow == IntPtr.Zero && _pendingFocusWindow == IntPtr.Zero && _windows.Count > 0)
                        {
                            foreach (var wk in _windows.Keys)
                            {
                                RequestFocus(wk);
                                break;
                            }
                        }

                        // Register only modifier+keysym combinations so plain keys (letters,
                        // digits, arrows, Return, Backspace, etc.) fall through to the
                        // surface with keyboard focus. Binding the bare Super_L/Alt_L keysym
                        // would route every modifier press/release to the WM and prevent
                        // *any* modified keystroke from reaching the focused surface.
                        if (_xkbBindings != IntPtr.Zero && _keyBindings.Count == 0)
                        {
                            RegisterAllBindings(proxy);
                        }

                        // Register a compositor-level {Primary}+Left-Click pointer binding so that
                        // windows without client-side decorations (e.g. Alacritty) can still be
                        // dragged. BTN_LEFT = 0x110. The modifier (Super=64 / Alt=8) is selected
                        // via AQUEOUS_MOD so nested river (where the host eats Super) still works.
                        // Requires river_window_management_v1 version >= 4 (River 0.4.3 ships v3).
                        if (_dragPointerBinding == IntPtr.Zero && _managerVersion >= 4)
                        {
                            const uint BTN_LEFT = 0x110;
                            uint modMask = Mods.PrimaryMask;
                            // river_seat_v1::get_pointer_binding is opcode 6
                            // signature: new_id<river_pointer_binding_v1>, uint button, uint modifiers
                            // The child proxy version must match the parent seat's (manager's) version.
                            _dragPointerBinding = WaylandInterop.wl_proxy_marshal_flags(
                                proxy, 6, (IntPtr)WlInterfaces.RiverPointerBinding, _managerVersion, 0,
                                IntPtr.Zero, (IntPtr)BTN_LEFT, (IntPtr)modMask,
                                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                            if (_dragPointerBinding != IntPtr.Zero)
                            {
                                WaylandInterop.wl_proxy_add_dispatcher(
                                    _dragPointerBinding,
                                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                                    GCHandle.ToIntPtr(_selfHandle),
                                    IntPtr.Zero);
                                _dragPointerBindingNeedsEnable = true;
                                Log(
                                    $"registered {Mods.PrimaryName}+BTN_LEFT pointer binding for window drag (mask=0x{modMask:x}, v{_managerVersion})");
                            }
                        }
                        else if (_dragPointerBinding == IntPtr.Zero && _managerVersion < 4)
                        {
                            Log(
                                $"skipping get_pointer_binding; river_window_manager_v1 v{_managerVersion} < 4 (River 0.4.3 ships v3)");
                        }
                    }

                    break;
                }
        }
    }
}
