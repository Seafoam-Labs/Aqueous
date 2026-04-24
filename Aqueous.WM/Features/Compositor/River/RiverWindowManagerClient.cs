using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Aqueous.Features.Compositor.River
{
    /// <summary>
    /// B1a "survive a session" skeleton that binds the River 0.4+
    /// <c>river_window_manager_v1</c> global and keeps the compositor alive by
    /// immediately acknowledging every <c>manage_start</c> / <c>render_start</c>
    /// event with the corresponding <c>manage_finish</c> / <c>render_finish</c>
    /// request.
    ///
    /// <para>
    /// <b>This is not a usable window manager.</b> It performs no layout, no
    /// focus policy, no keybinding registration, and no decoration placement.
    /// Windows will appear at whatever default dimensions River chooses and
    /// keyboard focus will behave however River's fallback does in the absence
    /// of a WM making focus decisions. The goal is solely to prove that the
    /// C# / AOT / hand-rolled protocol stack can bind the global, receive
    /// every event type declared in <see cref="WlInterfaces"/>, and keep
    /// River's manage/render loop progressing without tripping the
    /// <c>sequence_order</c> protocol error or the <c>unresponsive</c> watchdog.
    /// </para>
    ///
    /// <para>
    /// Gated on the <c>AQUEOUS_RIVER_WM</c> environment variable so that the
    /// default Aqueous bar build is unaffected. Set <c>AQUEOUS_RIVER_WM=1</c>
    /// to opt in when launching under River as the sole window-management
    /// client.
    /// </para>
    ///
    /// <para>
    /// <b>Safety:</b> A misbehaving window manager can deadlock River (the
    /// compositor refuses to render until <c>render_finish</c> is received)
    /// and can crash it via protocol errors. This implementation therefore
    /// never sends any window-management-state-modifying requests — only the
    /// two lifecycle acks required to advance the sequence loop.
    /// </para>
    /// </summary>
    internal sealed unsafe class RiverWindowManagerClient : IDisposable
    {
        // --- logging -------------------------------------------------------

        /// <summary>
        /// All protocol activity funnels through this action. By default logs
        /// to stderr; host code may replace it with a GLib-aware sink.
        /// </summary>
        public static Action<string> Log { get; set; } =
            msg => Console.Error.WriteLine("[river-wm] " + msg);

        // --- state tracked from events ------------------------------------

        private sealed class WindowEntry
        {
            public IntPtr Proxy;
            public IntPtr NodeProxy;
            public string? Title;
            public string? AppId;
            public int WidthHint, HeightHint;
            public int W, H;
            public int X, Y;
            public bool Placed;
            public int ProposedW, ProposedH;
            public int LastHintW, LastHintH;
            public int MinW, MinH, MaxW, MaxH;
            public int LastPosX = int.MinValue, LastPosY = int.MinValue;
            public int LastClipW, LastClipH;
            public bool BordersSent;
            public bool ShowSent;
        }

        private sealed class OutputEntry
        {
            public IntPtr Proxy;
            public uint WlOutputName;
            public int X, Y, Width, Height;
        }

        private sealed class SeatEntry
        {
            public IntPtr Proxy;
            public uint WlSeatName;
        }

        private readonly ConcurrentDictionary<IntPtr, WindowEntry> _windows = new();
        private readonly ConcurrentDictionary<IntPtr, OutputEntry> _outputs = new();
        private readonly ConcurrentDictionary<IntPtr, SeatEntry> _seats = new();

        // --- interaction service -------------------------------------------

        private readonly SeatInteractionService _seatInteractionService;

        private IntPtr _pendingFocusWindow;
        private IntPtr _pendingFocusShellSurface;
        private IntPtr _pendingFocusSeat;

        private WindowEntry? _activeDragWindow;
        private IntPtr _activeDragSeat;
        private bool _dragFinished;
        private bool _dragStarted;
        private int _dragStartX;
        private int _dragStartY;
        private IntPtr _dragPointerBinding;
        private bool _dragPointerBindingNeedsEnable;
        private readonly ConcurrentDictionary<IntPtr, IntPtr> _seatHoveredWindow = new(); // seat -> window

        // --- wayland state -------------------------------------------------

        private IntPtr _display;
        private IntPtr _registry;
        private IntPtr _manager;
        private IntPtr _layerShell;
        private IntPtr _xkbBindings;
        private IntPtr _superKeyBinding;

        // --- key bindings -------------------------------------------------

        private enum KeyBindingAction { ToggleStartMenu, SpawnTerminal, CloseFocused, CycleFocus, FocusLeft, FocusRight, FocusDown, FocusUp }
        private readonly Dictionary<IntPtr, KeyBindingAction> _keyBindings = new();
        private IntPtr _primarySeat;
        private IntPtr _focusedWindow;
        private bool _insideManageSequence;
        private uint _managerVersion;
        private GCHandle _selfHandle;
        private Thread? _pumpThread;
        private volatile bool _running;

        private RiverWindowManagerClient()
        {
            _seatInteractionService = new SeatInteractionService(this);
        }

        // --- lifecycle -----------------------------------------------------

        /// <summary>
        /// Starts the client if <c>AQUEOUS_RIVER_WM=1</c> and the WM global is
        /// advertised to us. Returns <c>null</c> silently in every other case
        /// — the Aqueous bar never wants a failure here to abort startup.
        /// </summary>
        public static RiverWindowManagerClient? TryStart()
        {
            if (Environment.GetEnvironmentVariable("AQUEOUS_RIVER_WM") != "1")
                return null;
            try
            {
                var c = new RiverWindowManagerClient();
                if (!c.Connect()) { c.Dispose(); return null; }
                c.StartPump();
                Log($"attached as window manager (v{c._managerVersion})");
                return c;
            }
            catch (DllNotFoundException) { return null; }
            catch (Exception e) { Log("TryStart failed: " + e.Message); return null; }
        }

        private bool Connect()
        {
            _display = WaylandInterop.wl_display_connect(IntPtr.Zero);
            if (_display == IntPtr.Zero) { Log("wl_display_connect returned null"); return false; }

            WlInterfaces.EnsureBuilt();

            // wl_display::get_registry is opcode 1.
            _registry = WaylandInterop.wl_proxy_marshal_flags(
                _display, 1, (IntPtr)WlInterfaces.WlRegistry, 1, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (_registry == IntPtr.Zero) { Log("get_registry failed"); return false; }

            _selfHandle = GCHandle.Alloc(this, GCHandleType.Normal);
            WaylandInterop.wl_proxy_add_dispatcher(
                _registry,
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                GCHandle.ToIntPtr(_selfHandle), IntPtr.Zero);

            // Flush globals; then a second roundtrip so any events the
            // compositor sends immediately on bind (for an existing window
            // list) are delivered before we return.
            WaylandInterop.wl_display_roundtrip(_display);
            WaylandInterop.wl_display_roundtrip(_display);

            return _manager != IntPtr.Zero;
        }

        private void StartPump()
        {
            _running = true;
            _pumpThread = new Thread(PumpLoop)
            {
                IsBackground = true,
                Name = "Aqueous.RiverWindowManager",
            };
            _pumpThread.Start();
        }

        private void PumpLoop()
        {
            try
            {
                while (_running)
                {
                    int r = WaylandInterop.wl_display_dispatch(_display);
                    if (r < 0) { Log("wl_display_dispatch returned < 0; pump exiting"); break; }
                }
            }
            catch (Exception e) { Log("pump crashed: " + e.Message); }
        }

        public void Dispose()
        {
            _running = false;
            try
            {
                if (_manager != IntPtr.Zero)
                {
                    // river_window_manager_v1::stop (opcode 0). NOT a destructor
                    // — we still have to wait for the `finished` event and
                    // then call destroy. For the skeleton we just disconnect
                    // the display; River treats a disconnected WM the same
                    // way as a stopped one and cleans up.
                }

                if (_display != IntPtr.Zero)
                {
                    WaylandInterop.wl_display_disconnect(_display);
                    _display = IntPtr.Zero;
                }

                _pumpThread?.Join(500);
            }
            catch { }
            finally
            {
                if (_selfHandle.IsAllocated) _selfHandle.Free();
            }
        }

        // --- dispatcher ----------------------------------------------------

        [UnmanagedCallersOnly]
        private static int Dispatch(IntPtr implementation, IntPtr target, uint opcode, IntPtr msg, IntPtr args)
        {
            try
            {
                var gch = GCHandle.FromIntPtr(implementation);
                var self = gch.Target as RiverWindowManagerClient;
                if (self == null) return 0;
                var a = (WlArgument*)args;

                if (target == self._registry)      self.OnRegistryEvent(opcode, a);
                else if (target == self._manager)  self.OnManagerEvent(opcode, a);
                else if (target == self._layerShell) self.OnLayerShellEvent(opcode, a);
                else if (self._superKeyBinding != IntPtr.Zero && target == self._superKeyBinding) self.OnSuperKeyBindingEvent(opcode, a);
                else if (self._keyBindings.ContainsKey(target)) self.OnKeyBindingEvent(target, opcode, a);
                else if (target == self._dragPointerBinding) self.OnDragPointerBindingEvent(opcode, a);
                else if (self._windows.ContainsKey(target)) self.OnWindowEvent(target, opcode, a);
                else if (self._outputs.ContainsKey(target)) self.OnOutputEvent(target, opcode, a);
                else if (self._seats.ContainsKey(target))   self.OnSeatEvent(target, opcode, a);
                else Log("unhandled dispatch: target=0x" + target.ToString("x") + " opcode=" + opcode);
            }
            catch (Exception e)
            {
                // NEVER unwind into native dispatch.
                try { Log("dispatch exception: " + e.Message); } catch { }
            }
            return 0;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct WlArgument
        {
            [FieldOffset(0)] public int   i;
            [FieldOffset(0)] public uint  u;
            [FieldOffset(0)] public int   fx;
            [FieldOffset(0)] public IntPtr s;
            [FieldOffset(0)] public IntPtr o;
            [FieldOffset(0)] public uint  n;
            [FieldOffset(0)] public IntPtr a;
            [FieldOffset(0)] public int   h;
        }

        // --- registry ------------------------------------------------------

        private void OnRegistryEvent(uint opcode, WlArgument* args)
        {
            // wl_registry events:
            //   0  global(name, interface, version)
            //   1  global_remove(name)
            if (opcode != 0) return;
            uint name = args[0].u;
            string? iface = PtrToString(args[1].s);
            uint version = args[2].u;
            if (iface == null) return;

            if (iface == "river_window_manager_v1" && _manager == IntPtr.Zero)
            {
                _managerVersion = Math.Min(version, 4u);
                _manager = Bind(name, WlInterfaces.RiverWindowManager, _managerVersion);
                if (_manager != IntPtr.Zero)
                {
                    WaylandInterop.wl_proxy_add_dispatcher(
                        _manager,
                        (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                        GCHandle.ToIntPtr(_selfHandle),
                        IntPtr.Zero);
                    Log($"bound river_window_manager_v1 (version {_managerVersion})");
                }
            }
            else if (iface == "river_layer_shell_v1")
            {
                _layerShell = Bind(name, WlInterfaces.RiverLayerShell, 1);
                WaylandInterop.wl_proxy_add_dispatcher(
                    _layerShell,
                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                    GCHandle.ToIntPtr(_selfHandle),
                    IntPtr.Zero);
                Log("bound river_layer_shell_v1");
            }
            else if (iface == "river_xkb_bindings_v1")
            {
                uint xkbVersion = Math.Min(version, 2u);
                _xkbBindings = Bind(name, WlInterfaces.RiverXkbBindings, xkbVersion);
                Log($"bound river_xkb_bindings_v1 (version {xkbVersion})");
            }
        }

        private IntPtr Bind(uint name, WaylandInterop.WlInterface* iface, uint version)
        {
            // wl_registry::bind(name: uint, new_id: untyped)
            // libwayland takes (name, iface_name, iface_version, new_id-placeholder)
            // on the wire; wl_proxy_marshal_flags fills the new_id implicitly.
            return WaylandInterop.wl_proxy_marshal_flags(
                _registry,
                0,                                 // opcode
                (IntPtr)iface,
                version,
                0,
                (IntPtr)name,
                (IntPtr)iface->name,
                (IntPtr)version,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        }

        // --- river_window_manager_v1 events -------------------------------

        private void OnDragPointerBindingEvent(uint opcode, WlArgument* args)
        {
            // 0 pressed, 1 released
            if (opcode == 0)
            {
                // Find a seat that has a currently-hovered window and start a drag for it.
                foreach (var kvp in _seatHoveredWindow)
                {
                    IntPtr seat = kvp.Key;
                    IntPtr hovered = kvp.Value;
                    if (hovered == IntPtr.Zero) continue;
                    if (!_windows.TryGetValue(hovered, out var w)) continue;

                    _activeDragWindow = w;
                    _activeDragSeat = seat;
                    _dragStartX = w.X;
                    _dragStartY = w.Y;
                    Log($"super+click drag start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")}");
                    break;
                }
            }
            else if (opcode == 1)
            {
                Log("super+click pointer binding released");
                // The matching op_release from the seat will set _dragFinished; nothing else to do here.
            }
        }

        private void OnSuperKeyBindingEvent(uint opcode, WlArgument* args)
        {
            // 0: pressed
            // 1: released
            if (opcode == 0)
            {
                Log("super key pressed, toggling Aqueous Start Menu via shell script/command");
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "dbus-send",
                        Arguments = "--session --type=method_call --dest=org.Aqueous /org/Aqueous org.Aqueous.ToggleStartMenu",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true
                    });
                }
                catch (Exception ex)
                {
                    Log("failed to launch start menu dbus command: " + ex.Message);
                }
            }
            else if (opcode == 1)
            {
                Log("super key released");
            }
        }

        private void OnLayerShellEvent(uint opcode, WlArgument* args)
        {
            if (opcode == 0) // layer_surface(new_id<river_layer_surface_v1>)
            {
                IntPtr layerSurface = args[0].o;
                if (layerSurface != IntPtr.Zero)
                {
                    IntPtr node = WaylandInterop.wl_proxy_marshal_flags(
                        layerSurface, 0, (IntPtr)WlInterfaces.RiverNode, 1, 0, 
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    if (node != IntPtr.Zero)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(node, 2, IntPtr.Zero, 1, 0, 
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        Log("mapped layer_surface to top");
                    }
                }
            }
        }

        private void OnManagerEvent(uint opcode, WlArgument* args)
        {
            // events, per XML order:
            //  0 unavailable
            //  1 finished
            //  2 manage_start
            //  3 render_start
            //  4 session_locked
            //  5 session_unlocked
            //  6 window(new_id<river_window_v1>)
            //  7 output(new_id<river_output_v1>)
            //  8 seat(new_id<river_seat_v1>)
            switch (opcode)
            {
                case 0: // unavailable
                    Log("river_window_manager_v1.unavailable — another WM is active; giving up");
                    _running = false;
                    break;
                case 1: // finished
                    Log("river_window_manager_v1.finished");
                    _running = false;
                    break;
                case 2: // manage_start
                    _insideManageSequence = true;
                    try {
                    Log($"manage_start (windows={_windows.Count} outputs={_outputs.Count} seats={_seats.Count})");

                    // Self-heal focus: if we think nothing is focused but windows exist, pick one.
                    // This catches the case where the previously focused window was destroyed
                    // between sequences and ensures the keyboard always has somewhere to go.
                    if (_focusedWindow == IntPtr.Zero && _pendingFocusWindow == IntPtr.Zero && _pendingFocusShellSurface == IntPtr.Zero && _windows.Count > 0)
                    {
                        foreach (var wk in _windows.Keys) { RequestFocus(wk); break; }
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
                        WaylandInterop.wl_proxy_marshal_flags(
                            _activeDragSeat, 5, IntPtr.Zero, 1, 0,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            
                        _activeDragWindow = null;
                        _activeDragSeat = IntPtr.Zero;
                        _dragFinished = false;
                        _dragStarted = false;
                    }

                    if (_activeDragSeat != IntPtr.Zero && _activeDragWindow != null && !_dragStarted)
                    {
                        WaylandInterop.wl_proxy_marshal_flags(
                            _activeDragSeat, 4, IntPtr.Zero, 1, 0,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        _dragStarted = true;
                    }
                    
                    if (_pendingFocusSeat != IntPtr.Zero)
                    {
                        if (_pendingFocusWindow != IntPtr.Zero)
                        {
                            WaylandInterop.wl_proxy_marshal_flags(_pendingFocusSeat, 1, IntPtr.Zero, 0, 0, _pendingFocusWindow, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            Log($"gave focus to window 0x{_pendingFocusWindow.ToString("x")}");
                        }
                        else if (_pendingFocusShellSurface != IntPtr.Zero)
                        {
                            WaylandInterop.wl_proxy_marshal_flags(_pendingFocusSeat, 2, IntPtr.Zero, 0, 0, _pendingFocusShellSurface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            Log($"gave focus to shell surface 0x{_pendingFocusShellSurface.ToString("x")}");
                        }
                        _pendingFocusSeat = IntPtr.Zero;
                        _pendingFocusWindow = IntPtr.Zero;
                        _pendingFocusShellSurface = IntPtr.Zero;
                    }

                    foreach (var kvp in _windows) {
                        // Only propose when the hint itself changed. Whatever the client commits
                        // in response (via the dimensions event) is final; we do not re-propose
                        // just because the client rounded to cell size.
                        var w = kvp.Value;
                        int pw = 800, ph = 600;
                        if (w.MaxW > 0) pw = Math.Min(pw, w.MaxW);
                        if (w.MaxH > 0) ph = Math.Min(ph, w.MaxH);
                        if (w.MinW > 0) pw = Math.Max(pw, w.MinW);
                        if (w.MinH > 0) ph = Math.Max(ph, w.MinH);
                        if (pw == w.LastHintW && ph == w.LastHintH) continue;
                        w.LastHintW = pw; w.LastHintH = ph;
                        w.ProposedW = pw; w.ProposedH = ph;
                        WaylandInterop.wl_proxy_marshal_flags(kvp.Key, 3, IntPtr.Zero, 0, 0, (IntPtr)pw, (IntPtr)ph, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    }
                    SendManagerRequest(2); // manage_finish opcode = 2 (see WlInterfaces)
                    } finally { _insideManageSequence = false; }
                    break;
                case 3: // render_start
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
                    foreach (var kvp in _windows) {
                        var we = kvp.Value;
                        // show (opcode 5) — every frame so the window is in this frame's scene.
                        WaylandInterop.wl_proxy_marshal_flags(kvp.Key, 5, IntPtr.Zero, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        // set_borders (opcode 8) — zero-width, every frame.
                        WaylandInterop.wl_proxy_marshal_flags(kvp.Key, 8, IntPtr.Zero, 0, 0, (IntPtr)0, (IntPtr)0, (IntPtr)0, (IntPtr)0, (IntPtr)0, (IntPtr)0);

                        if (we.NodeProxy != IntPtr.Zero)
                        {
                            // place_top (river_node_v1 opcode 2) — every frame (scene graph is not retained).
                            WaylandInterop.wl_proxy_marshal_flags(we.NodeProxy, 2, IntPtr.Zero, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            // set_position (river_node_v1 opcode 1) — only when changed.
                            if (we.LastPosX != we.X || we.LastPosY != we.Y)
                            {
                                WaylandInterop.wl_proxy_marshal_flags(we.NodeProxy, 1, IntPtr.Zero, 0, 0, (IntPtr)we.X, (IntPtr)we.Y, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                                we.LastPosX = we.X; we.LastPosY = we.Y;
                            }
                        }

                        // set_clip_box (river_window_v1 opcode 21, since v2) — only when size changed.
                        if (_managerVersion >= 2 && we.W > 0 && we.H > 0 &&
                            (we.LastClipW != we.W || we.LastClipH != we.H))
                        {
                            WaylandInterop.wl_proxy_marshal_flags(
                                kvp.Key, 21, IntPtr.Zero, 0, 0,
                                (IntPtr)0, (IntPtr)0, (IntPtr)we.W, (IntPtr)we.H,
                                IntPtr.Zero, IntPtr.Zero);
                            we.LastClipW = we.W; we.LastClipH = we.H;
                        }
                    }
                    SendManagerRequest(4); // render_finish opcode = 4
                    break;
                case 4: Log("session_locked"); break;
                case 5: Log("session_unlocked"); break;
                case 6: // window(new_id)
                {
                    IntPtr proxy = args[0].o;
                    if (proxy != IntPtr.Zero)
                    {
                        // Bug 3 fix: cascade new windows so two windows do not sit stacked at
                        // (0,0) shadowing each other's input region.
                        int cascadeIndex = _windows.Count;
                        var entry = new WindowEntry { Proxy = proxy, X = cascadeIndex * 40, Y = cascadeIndex * 40 };
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
                case 7: // output(new_id)
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
                case 8: // seat(new_id)
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

                        if (_primarySeat == IntPtr.Zero) _primarySeat = proxy;

                        // Bug 1 fix: if windows already arrived before the seat, focus one now.
                        // Otherwise the initial RequestFocus short-circuited (seat == 0) and
                        // the first window never gets keyboard focus.
                        if (_focusedWindow == IntPtr.Zero && _pendingFocusWindow == IntPtr.Zero && _windows.Count > 0)
                        {
                            foreach (var wk in _windows.Keys) { RequestFocus(wk); break; }
                        }

                        // Register only modifier+keysym combinations so plain keys (letters,
                        // digits, arrows, Return, Backspace, etc.) fall through to the
                        // surface with keyboard focus. Binding the bare Super_L/Alt_L keysym
                        // would route every modifier press/release to the WM and prevent
                        // *any* modified keystroke from reaching the focused surface.
                        if (_xkbBindings != IntPtr.Zero && _keyBindings.Count == 0)
                        {
                            uint mod = Mods.PrimaryMask;
                            RegisterKeyBinding(proxy, 0x0020, mod, KeyBindingAction.ToggleStartMenu); // space
                            RegisterKeyBinding(proxy, 0xff0d, mod, KeyBindingAction.SpawnTerminal);   // Return
                            RegisterKeyBinding(proxy, 0x0071, mod, KeyBindingAction.CloseFocused);    // q
                            RegisterKeyBinding(proxy, 0xff09, mod, KeyBindingAction.CycleFocus);      // Tab
                            RegisterKeyBinding(proxy, 0x0068, mod, KeyBindingAction.FocusLeft);       // h
                            RegisterKeyBinding(proxy, 0x006a, mod, KeyBindingAction.FocusDown);       // j
                            RegisterKeyBinding(proxy, 0x006b, mod, KeyBindingAction.FocusUp);         // k
                            RegisterKeyBinding(proxy, 0x006c, mod, KeyBindingAction.FocusRight);      // l
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
                                Log($"registered {Mods.PrimaryName}+BTN_LEFT pointer binding for window drag (mask=0x{modMask:x}, v{_managerVersion})");
                            }
                        }
                        else if (_dragPointerBinding == IntPtr.Zero && _managerVersion < 4)
                        {
                            Log($"skipping get_pointer_binding; river_window_manager_v1 v{_managerVersion} < 4 (River 0.4.3 ships v3)");
                        }
                    }
                    break;
                }
            }
        }

        private void SendManagerRequest(uint opcode)
        {
            if (_manager == IntPtr.Zero) return;
            WaylandInterop.wl_proxy_marshal_flags(
                _manager, opcode, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            WaylandInterop.wl_display_flush(_display);
        }

        // --- river_window_v1 events ---------------------------------------

        private void OnWindowEvent(IntPtr proxy, uint opcode, WlArgument* args)
        {
            if (!_windows.TryGetValue(proxy, out var w)) return;
            //  0 closed
            //  1 dimensions_hint(iiii)  -> min_w,min_h,max_w,max_h
            //  2 dimensions(ii)
            //  3 app_id(?s)
            //  4 title(?s)
            //  5 parent(?o)
            //  6 decoration_hint(u)
            //  7 pointer_move_requested(o)
            //  8 pointer_resize_requested(o u)
            //  9 show_window_menu_requested(ii)
            // 10 maximize_requested
            // 11 unmaximize_requested
            // 12 fullscreen_requested(?o)
            // 13 exit_fullscreen_requested
            // 14 minimize_requested
            // 15 unreliable_pid(i)
            // 16 presentation_hint(u)
            // 17 identifier(s)
            switch (opcode)
            {
                case 0:
                    Log($"window 0x{proxy.ToString("x")} closed");
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
                    if (_pendingFocusWindow == proxy) _pendingFocusWindow = IntPtr.Zero;
                    foreach (var k in _seatHoveredWindow.Keys)
                    {
                        if (_seatHoveredWindow.TryGetValue(k, out var v) && v == proxy)
                            _seatHoveredWindow[k] = IntPtr.Zero;
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
                case 1:
                    w.MinW = args[0].i; w.MinH = args[1].i; w.MaxW = args[2].i; w.MaxH = args[3].i;
                    Log($"window 0x{proxy.ToString("x")} dimensions_hint min {w.MinW}x{w.MinH} max {w.MaxW}x{w.MaxH}");
                    break;
                case 2:
                    w.W = args[0].i; w.H = args[1].i;
                    Log($"window 0x{proxy.ToString("x")} dimensions {w.W}x{w.H}");
                    // Fix #3: as soon as the client commits a real size, run a fresh
                    // manage/render cycle so set_clip_box is emitted on the first frame
                    // the size is known. Otherwise the initial frame ships without a
                    // clip box and pointer/keyboard input falls outside the input region.
                    ScheduleManage();
                    break;
                case 3: w.AppId = PtrToString(args[0].s); Log($"window 0x{proxy.ToString("x")} app_id={w.AppId}"); break;
                case 4: w.Title = PtrToString(args[0].s); Log($"window 0x{proxy.ToString("x")} title={w.Title}"); break;
                case 7:
                    IntPtr seatProxy = args[0].o;
                    Log($"window 0x{proxy.ToString("x")} requested pointer move on seat 0x{seatProxy.ToString("x")}");
                    _activeDragWindow = w;
                    _activeDragSeat = seatProxy;
                    _dragStartX = w.X;
                    _dragStartY = w.Y;
                    break;
                case 17: Log($"window 0x{proxy.ToString("x")} identifier={PtrToString(args[0].s)}"); break;
                default:
                    Log($"window 0x{proxy.ToString("x")} event opcode={opcode}");
                    break;
            }
        }

        // --- river_output_v1 events ---------------------------------------

        private void OnOutputEvent(IntPtr proxy, uint opcode, WlArgument* args)
        {
            if (!_outputs.TryGetValue(proxy, out var o)) return;
            // 0 removed
            // 1 wl_output(u)
            // 2 position(ii)
            // 3 dimensions(ii)
            switch (opcode)
            {
                case 0:
                    Log($"output 0x{proxy.ToString("x")} removed");
                    _outputs.TryRemove(proxy, out _);
                    break;
                case 1:
                    o.WlOutputName = args[0].u;
                    Log($"output 0x{proxy.ToString("x")} wl_output_name={o.WlOutputName}");
                    break;
                case 2:
                    o.X = args[0].i; o.Y = args[1].i;
                    Log($"output 0x{proxy.ToString("x")} position={o.X},{o.Y}");
                    break;
                case 3:
                    o.Width = args[0].i; o.Height = args[1].i;
                    Log($"output 0x{proxy.ToString("x")} dimensions={o.Width}x{o.Height}");
                    break;
            }
        }

        // --- river_seat_v1 events -----------------------------------------

        private void OnSeatEvent(IntPtr proxy, uint opcode, WlArgument* args)
        {
            if (!_seats.TryGetValue(proxy, out var s)) return;
            // 0 removed
            // 1 wl_seat(u)
            // 2 pointer_enter(o)
            // 3 pointer_leave
            // 4 window_interaction(o)
            // 5 shell_surface_interaction(o)
            // 6 op_delta(ii)
            // 7 op_release
            // 8 pointer_position(ii)  [since 2]
            switch (opcode)
            {
                case 0:
                    Log($"seat 0x{proxy.ToString("x")} removed");
                    _seats.TryRemove(proxy, out _);
                    break;
                case 1:
                    s.WlSeatName = args[0].u;
                    Log($"seat 0x{proxy.ToString("x")} wl_seat_name={s.WlSeatName}");
                    break;
                case 2: // pointer_enter(window)
                {
                    IntPtr hovered = args[0].o;
                    // Gate: only log / follow focus when the hovered window actually changed.
                    // River can re-send pointer_enter during normal motion; treating each
                    // as a focus change triggers the manage_dirty storm (see Fix #1).
                    if (_seatHoveredWindow.TryGetValue(proxy, out var prevHover) && prevHover == hovered)
                        break;
                    _seatHoveredWindow[proxy] = hovered;
                    Log($"seat 0x{proxy.ToString("x")} pointer_enter window 0x{hovered.ToString("x")}");
                    // Sloppy focus: follow the pointer so keystrokes go where the user is looking.
                    if (hovered != IntPtr.Zero && _windows.ContainsKey(hovered) && hovered != _focusedWindow)
                    {
                        SetFocusedWindow(hovered, proxy);
                    }
                    break;
                }
                case 3: // pointer_leave
                    _seatHoveredWindow.TryRemove(proxy, out _);
                    Log($"seat 0x{proxy.ToString("x")} pointer_leave");
                    break;
                case 4:
                    Log($"seat 0x{proxy.ToString("x")} window_interaction 0x{args[0].o.ToString("x")}");
                    _seatInteractionService.HandleWindowInteraction(args[0].o, proxy);
                    break;
                case 5:
                    Log($"seat 0x{proxy.ToString("x")} shell_surface_interaction 0x{args[0].o.ToString("x")}");
                    _seatInteractionService.HandleShellSurfaceInteraction(args[0].o, proxy);
                    break;
                case 6:
                    int dx = args[0].i;
                    int dy = args[1].i;
                    if (_activeDragWindow != null)
                    {
                        _activeDragWindow.X = _dragStartX + dx;
                        _activeDragWindow.Y = _dragStartY + dy;
                    }
                    break;
                case 7:
                    Log($"seat 0x{proxy.ToString("x")} pointer operation released");
                    _dragFinished = true;
                    break;
                default:
                    Log($"seat 0x{proxy.ToString("x")} event opcode={opcode}");
                    break;
            }
        }

        // --- utility -------------------------------------------------------

        public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy)
        {
            // Fix #1: skip no-op focus changes. SetFocusedWindow is called from
            // pointer_enter on every mouse crossing; without a correct guard each
            // enter event would issue manage_dirty, creating a manage/render storm
            // that starves other clients' wl_display pings (they die after ~60s).
            // The previous guard only fired when both pending fields were zero,
            // but _pendingFocusWindow stays non-zero between manage_start cycles,
            // so the guard never tripped again during pointer motion.
            if (windowProxy == _focusedWindow && _pendingFocusWindow == windowProxy)
                return; // same focus already pending
            if (windowProxy == _focusedWindow && _pendingFocusWindow == IntPtr.Zero && _pendingFocusShellSurface == IntPtr.Zero)
                return; // already focused and applied
            _pendingFocusWindow = windowProxy;
            _pendingFocusShellSurface = IntPtr.Zero;
            _pendingFocusSeat = seatProxy;
            _focusedWindow = windowProxy;
            ScheduleManage();
        }

        /// <summary>
        /// Ask the compositor to start a new manage sequence so that any state we
        /// changed outside of one (pending focus from pointer-enter, Super+Tab,
        /// close-and-refocus, drag start) actually gets flushed promptly.
        /// river_window_manager_v1::manage_dirty is opcode 3.
        /// </summary>
        private void ScheduleManage()
        {
            if (_manager == IntPtr.Zero) return;
            // If we're already inside a manage/render sequence the compositor will flush
            // our pending state when the current handler returns; issuing manage_dirty now
            // would just guarantee an extra cycle (and a potential infinite loop).
            if (_insideManageSequence) return;
            WaylandInterop.wl_proxy_marshal_flags(_manager, 3, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            WaylandInterop.wl_display_flush(_display);
        }

        /// <summary>
        /// Request focus for the given window. Uses the primary seat when no seat is provided.
        /// The focus request is stashed and flushed during the next manage_start.
        /// </summary>
        private void RequestFocus(IntPtr windowProxy)
        {
            IntPtr seat = _primarySeat;
            if (seat == IntPtr.Zero)
            {
                foreach (var k in _seats.Keys) { seat = k; break; }
            }
            if (seat == IntPtr.Zero) return;
            SetFocusedWindow(windowProxy, seat);
        }

        /// <summary>Clear focus on the primary seat (river_seat_v1::clear_focus, opcode 3).</summary>
        private void ClearFocus()
        {
            IntPtr seat = _primarySeat;
            if (seat == IntPtr.Zero)
            {
                foreach (var k in _seats.Keys) { seat = k; break; }
            }
            _pendingFocusWindow = IntPtr.Zero;
            _pendingFocusShellSurface = IntPtr.Zero;
            _pendingFocusSeat = IntPtr.Zero;
            _focusedWindow = IntPtr.Zero;
            if (seat != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_marshal_flags(seat, 3, IntPtr.Zero, 0, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                Log($"clear_focus on seat 0x{seat.ToString("x")}");
            }
            ScheduleManage();
        }

        /// <summary>Pick any window (prefer not-currently-focused) and focus it. No-op if empty.</summary>
        private void FocusAnyOtherWindow(IntPtr avoid)
        {
            IntPtr pick = IntPtr.Zero;
            foreach (var k in _windows.Keys)
            {
                if (k == avoid) continue;
                pick = k;
                break;
            }
            if (pick == IntPtr.Zero)
            {
                foreach (var k in _windows.Keys) { pick = k; break; }
            }
            if (pick != IntPtr.Zero) RequestFocus(pick);
            else ClearFocus();
        }

        /// <summary>Advance keyboard focus to the next window in _windows iteration order.</summary>
        private void CycleFocus()
        {
            if (_windows.Count == 0) return;
            IntPtr next = IntPtr.Zero;
            bool takeNext = false;
            foreach (var k in _windows.Keys)
            {
                if (next == IntPtr.Zero) next = k; // fallback to first
                if (takeNext) { next = k; takeNext = false; break; }
                if (k == _focusedWindow) takeNext = true;
            }
            if (next != IntPtr.Zero) RequestFocus(next);
        }

        private void RegisterKeyBinding(IntPtr seatProxy, uint keysym, uint modifiers, KeyBindingAction action)
        {
            if (_xkbBindings == IntPtr.Zero) return;
            // river_xkb_bindings_v1::get_xkb_binding opcode=1
            // args: seat(o), id(new_id), keysym(u), modifiers(u)
            IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
                _xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, 3, 0,
                seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
            if (binding == IntPtr.Zero) return;
            _keyBindings[binding] = action;
            WaylandInterop.wl_proxy_add_dispatcher(
                binding,
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                GCHandle.ToIntPtr(_selfHandle),
                IntPtr.Zero);
            // river_xkb_binding_v1::enable opcode=2
            WaylandInterop.wl_proxy_marshal_flags(binding, 2, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            Log($"registered key binding {action} (keysym 0x{keysym:x}, mods 0x{modifiers:x})");
        }

        private void OnKeyBindingEvent(IntPtr proxy, uint opcode, WlArgument* args)
        {
            // 0: pressed, 1: released
            if (opcode != 0) return;
            if (!_keyBindings.TryGetValue(proxy, out var action)) return;
            Log($"key binding pressed: {action}");
            switch (action)
            {
                case KeyBindingAction.ToggleStartMenu:
                    try
                    {
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = "dbus-send",
                            Arguments = "--session --type=method_call --dest=org.Aqueous /org/Aqueous org.Aqueous.ToggleStartMenu",
                            UseShellExecute = false,
                            CreateNoWindow = true,
                        });
                    }
                    catch (Exception ex) { Log("failed to toggle start menu: " + ex.Message); }
                    break;
                case KeyBindingAction.SpawnTerminal:
                    try
                    {
                        var term = Environment.GetEnvironmentVariable("TERMINAL") ?? "alacritty";
                        // Hardened spawn: detach via setsid (so the child survives WM
                        // restarts / manage storms), explicitly export the WM's
                        // WAYLAND_DISPLAY / XDG_RUNTIME_DIR, and clear DISPLAY to
                        // prevent silent Xwayland fallback (an X11 client would never
                        // register as a river_window_v1 and therefore never receive
                        // focus / input through this code path).
                        var psi = new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = "/bin/sh",
                            UseShellExecute = false,
                            CreateNoWindow = true,
                        };
                        psi.ArgumentList.Add("-c");
                        psi.ArgumentList.Add($"setsid -f {term} >/dev/null 2>&1");

                        var wayland = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
                        var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
                        if (!string.IsNullOrEmpty(wayland))
                            psi.EnvironmentVariables["WAYLAND_DISPLAY"] = wayland;
                        if (!string.IsNullOrEmpty(runtime))
                            psi.EnvironmentVariables["XDG_RUNTIME_DIR"] = runtime;
                        psi.EnvironmentVariables["XDG_SESSION_TYPE"] = "wayland";
                        psi.EnvironmentVariables["XDG_CURRENT_DESKTOP"] = "Aqueous";
                        psi.EnvironmentVariables.Remove("DISPLAY");

                        System.Diagnostics.Process.Start(psi);
                    }
                    catch (Exception ex) { Log("failed to spawn terminal: " + ex.Message); }
                    break;
                case KeyBindingAction.CloseFocused:
                    if (_focusedWindow != IntPtr.Zero)
                    {
                        // river_window_v1::close opcode=1 (0 is destroy)
                        WaylandInterop.wl_proxy_marshal_flags(_focusedWindow, 1, IntPtr.Zero, 0, 0,
                            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    }
                    break;
                case KeyBindingAction.CycleFocus:
                case KeyBindingAction.FocusLeft:
                case KeyBindingAction.FocusRight:
                case KeyBindingAction.FocusUp:
                case KeyBindingAction.FocusDown:
                    CycleFocus();
                    break;
            }
        }

        public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
        {
            _pendingFocusShellSurface = shellSurfaceProxy;
            _pendingFocusWindow = IntPtr.Zero;
            _pendingFocusSeat = seatProxy;
            // Parity with SetFocusedWindow / ClearFocus: ensure the pending focus
            // is actually flushed on the next manage cycle. Without this, if a
            // layer-shell surface (e.g. the start menu) grabs focus just before a
            // new window maps, the pending focus never ships and the new window
            // can't grab keyboard focus either.
            ScheduleManage();
        }

        private static string? PtrToString(IntPtr p)
            => p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
    }
}
