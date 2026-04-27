using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

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
    internal sealed unsafe class RiverWindowManagerClient : IDisposable, TagController.ITagHost
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

            // Phase B1e (partial): per-window floating override + remembered
            // floating rect. Set when the user drags a window with
            // Super+BTN_LEFT; honoured by ProposeForArea so floating windows
            // bypass the active layout engine and keep their dragged
            // position across manage cycles.
            public bool Floating;
            public bool HasFloatRect;
            public int FloatX, FloatY, FloatW, FloatH;

            // Phase B1b scrolling fix: visibility comes from the layout
            // engine's WindowPlacement.Visible. Off-screen scrolling
            // columns must NOT be repositioned/clipped/place_top'd, and
            // must NOT receive propose_dimensions storms. Defaults to
            // true so windows mapped before the first manage cycle stay
            // visible.
            public bool Visible = true;

            // Output the window currently belongs to. Set by manage_start
            // when the window's position falls inside an output's area
            // (or to the first output as a fallback). Used by
            // ProposeForArea to filter the per-output snapshot so engines
            // like ScrollingLayout do not see windows from other outputs
            // in their per-output ScrollState.
            public IntPtr Output;

            // Phase B1c — Tags / Workspaces.
            //
            // 32-bit tag bitmask. A window is rendered iff
            // (Tags & Output.VisibleTags) != 0. Default is tag 1
            // (bit 0). At manage_start a freshly-mapped window is
            // re-tagged to whatever its assigned output currently views
            // (minus the reserved scratchpad bit). See TagState for
            // semantics.
            public uint Tags = Aqueous.Features.Tags.TagState.DefaultTag;

            // Latched "the compositor currently considers this window
            // shown" cache. Only flipped by the manage_start visibility
            // pass; render_start uses this together with the
            // engine-driven Visible flag to decide whether to emit
            // show/place_top/borders this frame.
            public bool TagVisible = true;

            // Latch so we only emit hide (opcode 4) once per
            // visibility transition; without this we would re-send hide
            // every manage cycle for every off-tag window.
            public bool HideSent;
        }

        private sealed class OutputEntry
        {
            public IntPtr Proxy;
            public uint WlOutputName;
            public int X, Y, Width, Height;

            // Phase B1c — Tags / Workspaces.
            //
            // 32-bit "currently visible tags" mask. Default is tag 1
            // (bit 0). Mutated by TagController in response to
            // Super+1..0 / Super+Ctrl+1..9 / Super+grave bindings.
            public uint VisibleTags = Aqueous.Features.Tags.TagState.DefaultTag;

            // Last-tagset stack for back-and-forth (Super+grave).
            // Capped to keep the structure small; a deque would be
            // cleaner but Stack<T> is sufficient at this size.
            public uint LastVisibleTags = Aqueous.Features.Tags.TagState.DefaultTag;
            public readonly System.Collections.Generic.Stack<uint> TagHistory = new();
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

        private enum KeyBindingAction
        {
            ToggleStartMenu,
            SpawnTerminal,
            CloseFocused,
            CycleFocus,
            FocusLeft,
            FocusRight,
            FocusDown,
            FocusUp,
            ScrollViewportLeft,
            ScrollViewportRight,
            MoveColumnLeft,
            MoveColumnRight,
            ReloadConfig,
            SetLayoutPrimary,
            SetLayoutSecondary,
            SetLayoutTertiary,
            SetLayoutQuaternary,

            // Phase B1c — Tag actions. Indexed by 0-based tag bit (0..9
            // for tag1..10) so the dispatcher can compute the mask via
            // 1u << (action - ViewTag1). Tag10 is bound to the digit
            // key '0' because keymaps order digits 1234567890.
            ViewTag1,
            ViewTag2,
            ViewTag3,
            ViewTag4,
            ViewTag5,
            ViewTag6,
            ViewTag7,
            ViewTag8,
            ViewTag9,
            ViewTagAll,
            SendTag1,
            SendTag2,
            SendTag3,
            SendTag4,
            SendTag5,
            SendTag6,
            SendTag7,
            SendTag8,
            SendTag9,
            SendTagAll,
            ToggleViewTag1,
            ToggleViewTag2,
            ToggleViewTag3,
            ToggleViewTag4,
            ToggleViewTag5,
            ToggleViewTag6,
            ToggleViewTag7,
            ToggleViewTag8,
            ToggleViewTag9,
            ToggleWindowTag1,
            ToggleWindowTag2,
            ToggleWindowTag3,
            ToggleWindowTag4,
            ToggleWindowTag5,
            ToggleWindowTag6,
            ToggleWindowTag7,
            ToggleWindowTag8,
            ToggleWindowTag9,
            SwapLastTagset,

            // Phase B1e — Window state ops (Pass B integration).
            ToggleFullscreen,
            ToggleMaximize,
            ToggleFloating,
            ToggleMinimize,
            UnminimizeLast,
            ToggleScratchpad,
            SendToScratchpad,
            Custom,
        }

        private readonly Dictionary<IntPtr, KeyBindingAction> _keyBindings = new();

        // For KeyBindingAction.Custom — chord proxy → free-form action verb.
        private readonly Dictionary<IntPtr, string> _customBindingActions = new();

        // action_name -> KeyBindingAction (for built-in chord overrides via [keybinds]).
        private static readonly Dictionary<string, KeyBindingAction> BuiltinActionMap =
            new(StringComparer.Ordinal)
            {
                ["toggle_start_menu"] = KeyBindingAction.ToggleStartMenu,
                ["spawn_terminal"] = KeyBindingAction.SpawnTerminal,
                ["close_focused"] = KeyBindingAction.CloseFocused,
                ["cycle_focus"] = KeyBindingAction.CycleFocus,
                ["focus_left"] = KeyBindingAction.FocusLeft,
                ["focus_right"] = KeyBindingAction.FocusRight,
                ["focus_up"] = KeyBindingAction.FocusUp,
                ["focus_down"] = KeyBindingAction.FocusDown,
                ["scroll_viewport_left"] = KeyBindingAction.ScrollViewportLeft,
                ["scroll_viewport_right"] = KeyBindingAction.ScrollViewportRight,
                ["move_column_left"] = KeyBindingAction.MoveColumnLeft,
                ["move_column_right"] = KeyBindingAction.MoveColumnRight,
                ["reload_config"] = KeyBindingAction.ReloadConfig,
                ["set_layout_primary"] = KeyBindingAction.SetLayoutPrimary,
                ["set_layout_secondary"] = KeyBindingAction.SetLayoutSecondary,
                ["set_layout_tertiary"] = KeyBindingAction.SetLayoutTertiary,
                ["set_layout_quaternary"] = KeyBindingAction.SetLayoutQuaternary,
                // Phase B1c — Tag actions exposed to [keybinds] config.
                ["view_tag_1"] = KeyBindingAction.ViewTag1, ["view_tag_2"] = KeyBindingAction.ViewTag2,
                ["view_tag_3"] = KeyBindingAction.ViewTag3, ["view_tag_4"] = KeyBindingAction.ViewTag4,
                ["view_tag_5"] = KeyBindingAction.ViewTag5, ["view_tag_6"] = KeyBindingAction.ViewTag6,
                ["view_tag_7"] = KeyBindingAction.ViewTag7, ["view_tag_8"] = KeyBindingAction.ViewTag8,
                ["view_tag_9"] = KeyBindingAction.ViewTag9, ["view_tag_all"] = KeyBindingAction.ViewTagAll,
                ["send_tag_1"] = KeyBindingAction.SendTag1, ["send_tag_2"] = KeyBindingAction.SendTag2,
                ["send_tag_3"] = KeyBindingAction.SendTag3, ["send_tag_4"] = KeyBindingAction.SendTag4,
                ["send_tag_5"] = KeyBindingAction.SendTag5, ["send_tag_6"] = KeyBindingAction.SendTag6,
                ["send_tag_7"] = KeyBindingAction.SendTag7, ["send_tag_8"] = KeyBindingAction.SendTag8,
                ["send_tag_9"] = KeyBindingAction.SendTag9, ["send_tag_all"] = KeyBindingAction.SendTagAll,
                ["toggle_view_tag_1"] = KeyBindingAction.ToggleViewTag1,
                ["toggle_view_tag_2"] = KeyBindingAction.ToggleViewTag2,
                ["toggle_view_tag_3"] = KeyBindingAction.ToggleViewTag3,
                ["toggle_view_tag_4"] = KeyBindingAction.ToggleViewTag4,
                ["toggle_view_tag_5"] = KeyBindingAction.ToggleViewTag5,
                ["toggle_view_tag_6"] = KeyBindingAction.ToggleViewTag6,
                ["toggle_view_tag_7"] = KeyBindingAction.ToggleViewTag7,
                ["toggle_view_tag_8"] = KeyBindingAction.ToggleViewTag8,
                ["toggle_view_tag_9"] = KeyBindingAction.ToggleViewTag9,
                ["toggle_window_tag_1"] = KeyBindingAction.ToggleWindowTag1,
                ["toggle_window_tag_2"] = KeyBindingAction.ToggleWindowTag2,
                ["toggle_window_tag_3"] = KeyBindingAction.ToggleWindowTag3,
                ["toggle_window_tag_4"] = KeyBindingAction.ToggleWindowTag4,
                ["toggle_window_tag_5"] = KeyBindingAction.ToggleWindowTag5,
                ["toggle_window_tag_6"] = KeyBindingAction.ToggleWindowTag6,
                ["toggle_window_tag_7"] = KeyBindingAction.ToggleWindowTag7,
                ["toggle_window_tag_8"] = KeyBindingAction.ToggleWindowTag8,
                ["toggle_window_tag_9"] = KeyBindingAction.ToggleWindowTag9,
                ["swap_last_tagset"] = KeyBindingAction.SwapLastTagset,
                // Phase B1e — Window state ops (Pass B integration).
                ["toggle_fullscreen"] = KeyBindingAction.ToggleFullscreen,
                ["toggle_maximize"] = KeyBindingAction.ToggleMaximize,
                ["toggle_floating"] = KeyBindingAction.ToggleFloating,
                ["toggle_minimize"] = KeyBindingAction.ToggleMinimize,
                ["unminimize_last"] = KeyBindingAction.UnminimizeLast,
                ["toggle_scratchpad"] = KeyBindingAction.ToggleScratchpad,
                ["send_to_scratchpad"] = KeyBindingAction.SendToScratchpad,
                // toggle_scratchpad_named / send_to_scratchpad_named are not
                // mapped here: they require a :arg suffix and are reachable
                // only via [keybinds.custom] -> RunCustomAction's builtin:
                // branch, which parses one trailing :name segment.
            };

        private IntPtr _primarySeat;
        private IntPtr _focusedWindow;
        private bool _insideManageSequence;
        private uint _managerVersion;
        private GCHandle _selfHandle;
        private Thread? _pumpThread;
        private volatile bool _running;

        // --- layout subsystem ----------------------------------------------
        // Pluggable layout engine (Phase 1.1 / B1b). The controller owns
        // per-output state and applies size hints; the engines themselves are
        // pure functions that never call into Wayland.
        private readonly LayoutRegistry _layoutRegistry;
        private LayoutController _layoutController;
        private LayoutConfig _layoutConfig;

        // --- tags subsystem (Phase B1c) -----------------------------------
        private readonly TagController _tagController;

        // --- window-state subsystem (Phase B1e — Pass B) ------------------
        // Per-window state projection (FS/Max/Float/Min/Scratchpad) used by
        // WindowStateController. Lazily populated when a chord first
        // touches a window; lifecycle-cleared on close / output removal.
        private readonly ConcurrentDictionary<IntPtr, WindowStateData> _windowStates = new();

        // Per-output single-FS slot (single-fullscreen-per-output rule).
        private readonly ConcurrentDictionary<IntPtr, IntPtr> _outputFullscreen = new();
        private readonly ScratchpadRegistry _scratchpadRegistry;
        private readonly WindowStateController _windowState;

        private RiverWindowManagerClient()
        {
            _seatInteractionService = new SeatInteractionService(this);
            _layoutRegistry = new LayoutRegistry();
            _layoutConfig = LayoutConfig.Load(GetDefaultConfigPath());
            _layoutController = new LayoutController(_layoutRegistry, _layoutConfig);
            _tagController = new TagController(this);
            _scratchpadRegistry = new ScratchpadRegistry();
            _windowState = new WindowStateController(
                new RiverWindowStateHost(this), _scratchpadRegistry);
        }

        // ------------------------------------------------------------------
        // IWindowStateHost adapter — bridges WindowStateController to the
        // river client's internal window/output dictionaries. Pass B keeps
        // this adapter conservative: every method either consults existing
        // state or asks the manage loop to re-run; it never directly emits
        // Wayland protocol ops. Render-path overrides (visibility, geometry,
        // z-order, borders) are deferred to a follow-up pass.
        // ------------------------------------------------------------------
        private sealed class RiverWindowStateHost : IWindowStateHost
        {
            private readonly RiverWindowManagerClient _c;

            public RiverWindowStateHost(RiverWindowManagerClient c)
            {
                _c = c;
            }

            public WindowStateData? Get(IntPtr window)
            {
                if (window == IntPtr.Zero) return null;
                if (!_c._windows.ContainsKey(window)) return null;
                return _c._windowStates.GetOrAdd(window, h => new WindowStateData { Handle = h });
            }

            public IntPtr FocusedWindow => _c._focusedWindow;

            public IntPtr FocusedOutput
            {
                get
                {
                    var oe = _c.GetFocusedOutputEntry();
                    return oe is null ? IntPtr.Zero : oe.Proxy;
                }
            }

            public Rect OutputRect(IntPtr output)
            {
                if (output != IntPtr.Zero && _c._outputs.TryGetValue(output, out var o))
                    return new Rect(o.X, o.Y, o.Width, o.Height);
                return new Rect(0, 0, 0, 0);
            }

            public Rect UsableArea(IntPtr output)
            {
                // Pass B simplification: layer-shell exclusive zones and
                // gaps are absorbed by the layout controller; treat the
                // raw output rect as usable for Maximize geometry. A
                // dedicated reservation pass can refine this later.
                return OutputRect(output);
            }

            public IntPtr GetFullscreenWindow(IntPtr output) =>
                _c._outputFullscreen.TryGetValue(output, out var w) ? w : IntPtr.Zero;

            public void SetFullscreenWindow(IntPtr output, IntPtr window)
            {
                if (output == IntPtr.Zero) return;
                if (window == IntPtr.Zero) _c._outputFullscreen.TryRemove(output, out _);
                else _c._outputFullscreen[output] = window;
            }

            public void Focus(IntPtr window)
            {
                if (window != IntPtr.Zero) _c.RequestFocus(window);
            }

            public void FocusNextOnOutput(IntPtr output) => _c.FocusAnyOtherWindow(_c._focusedWindow);

            public void RequestRender(IntPtr output) => _c.ScheduleManage();

            public void EmitForeignToplevelFullscreen(IntPtr window, IntPtr output)
            {
                // Pass B: foreign-toplevel sync deferred. See
                // none_of_the_new_keybinds_are_functional.md step 6.
            }

            public void EmitForeignToplevelUnfullscreen(IntPtr window)
            {
                // Pass B: foreign-toplevel sync deferred.
            }

            public void Spawn(string command)
            {
                if (string.IsNullOrEmpty(command)) return;
                try
                {
                    var psi = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "/bin/sh",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                    };
                    psi.ArgumentList.Add("-c");
                    psi.ArgumentList.Add($"setsid -f sh -c {EscapeSh(command)} >/dev/null 2>&1");
                    System.Diagnostics.Process.Start(psi);
                }
                catch (Exception ex)
                {
                    RiverWindowManagerClient.Log($"scratchpad spawn failed: {ex.Message}");
                }
            }

            public void Log(string message) => RiverWindowManagerClient.Log(message);

            public Rect CurrentGeometry(IntPtr window)
            {
                if (window != IntPtr.Zero && _c._windows.TryGetValue(window, out var w))
                    return new Rect(w.X, w.Y, w.W, w.H);
                return new Rect(0, 0, 0, 0);
            }
        }

        private static string GetDefaultConfigPath()
        {
            // ~/.config/aqueous/wm.toml — XDG base dir if set, otherwise HOME.
            var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
            var baseDir = !string.IsNullOrEmpty(xdg)
                ? xdg
                : System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".config");
            return System.IO.Path.Combine(baseDir, "aqueous", "wm.toml");
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
                if (!c.Connect())
                {
                    c.Dispose();
                    return null;
                }

                c.StartPump();
                Log($"attached as window manager (v{c._managerVersion})");
                return c;
            }
            catch (DllNotFoundException)
            {
                return null;
            }
            catch (Exception e)
            {
                Log("TryStart failed: " + e.Message);
                return null;
            }
        }

        private bool Connect()
        {
            _display = WaylandInterop.wl_display_connect(IntPtr.Zero);
            if (_display == IntPtr.Zero)
            {
                Log("wl_display_connect returned null");
                return false;
            }

            WlInterfaces.EnsureBuilt();

            // wl_display::get_registry is opcode 1.
            _registry = WaylandInterop.wl_proxy_marshal_flags(
                _display, 1, (IntPtr)WlInterfaces.WlRegistry, 1, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (_registry == IntPtr.Zero)
            {
                Log("get_registry failed");
                return false;
            }

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
                    if (r < 0)
                    {
                        Log("wl_display_dispatch returned < 0; pump exiting");
                        break;
                    }
                }
            }
            catch (Exception e)
            {
                Log("pump crashed: " + e.Message);
            }
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
            catch
            {
            }
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

                if (target == self._registry) self.OnRegistryEvent(opcode, a);
                else if (target == self._manager) self.OnManagerEvent(opcode, a);
                else if (target == self._layerShell) self.OnLayerShellEvent(opcode, a);
                else if (self._superKeyBinding != IntPtr.Zero && target == self._superKeyBinding)
                    self.OnSuperKeyBindingEvent(opcode, a);
                else if (self._keyBindings.ContainsKey(target)) self.OnKeyBindingEvent(target, opcode, a);
                else if (target == self._dragPointerBinding) self.OnDragPointerBindingEvent(opcode, a);
                else if (self._windows.ContainsKey(target)) self.OnWindowEvent(target, opcode, a);
                else if (self._outputs.ContainsKey(target)) self.OnOutputEvent(target, opcode, a);
                else if (self._seats.ContainsKey(target)) self.OnSeatEvent(target, opcode, a);
                else Log("unhandled dispatch: target=0x" + target.ToString("x") + " opcode=" + opcode);
            }
            catch (Exception e)
            {
                // NEVER unwind into native dispatch.
                try
                {
                    Log("dispatch exception: " + e.Message);
                }
                catch
                {
                }
            }

            return 0;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct WlArgument
        {
            [FieldOffset(0)] public int i;
            [FieldOffset(0)] public uint u;
            [FieldOffset(0)] public int fx;
            [FieldOffset(0)] public IntPtr s;
            [FieldOffset(0)] public IntPtr o;
            [FieldOffset(0)] public uint n;
            [FieldOffset(0)] public IntPtr a;
            [FieldOffset(0)] public int h;
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
                0, // opcode
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
                        Arguments =
                            "--session --type=method_call --dest=org.Aqueous /org/Aqueous org.Aqueous.ToggleStartMenu",
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
                        if (!we.Visible) return;
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
                            return sd.State;
                        return WindowState.Tiled;
                    }

                    // Pass 1: tiled (and unknown).
                    foreach (var kvp in _windows)
                    {
                        var s = ClassifyState(kvp.Key);
                        if (s == WindowState.Tiled) EmitWindow(kvp.Key, kvp.Value);
                    }

                    // Pass 2: maximized.
                    foreach (var kvp in _windows)
                    {
                        if (ClassifyState(kvp.Key) == WindowState.Maximized)
                            EmitWindow(kvp.Key, kvp.Value);
                    }

                    // Pass 3: floating (and Scratchpad — visible scratchpads
                    // are rendered as floating dropdown windows above tiles).
                    foreach (var kvp in _windows)
                    {
                        var s = ClassifyState(kvp.Key);
                        if (s == WindowState.Floating || s == WindowState.Scratchpad)
                            EmitWindow(kvp.Key, kvp.Value);
                    }

                    // Pass 4: fullscreen (last so its place_top wins).
                    foreach (var kvp in _windows)
                    {
                        if (ClassifyState(kvp.Key) == WindowState.Fullscreen)
                            EmitWindow(kvp.Key, kvp.Value);
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

        private void SendManagerRequest(uint opcode)
        {
            if (_manager == IntPtr.Zero) return;
            WaylandInterop.wl_proxy_marshal_flags(
                _manager, opcode, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            WaylandInterop.wl_display_flush(_display);
        }

        /// <summary>
        /// Drive the layout subsystem for one output (or, if
        /// <paramref name="output"/> is <see cref="IntPtr.Zero"/>, the
        /// virtual fallback area). Builds a snapshot of the visible
        /// windows, asks <see cref="LayoutController.Arrange"/> for
        /// placements, and emits <c>propose_dimensions</c> only when the
        /// engine's choice differs from <c>WindowEntry.LastHintW/H</c>.
        /// </summary>
        private void ProposeForArea(IntPtr output, string? outputName, Rect usableArea)
        {
            // Floating windows are a layer, not a layout: they bypass the
            // active engine entirely and use their remembered FloatRect (set
            // by the Super+BTN_LEFT drag handler). When the active engine is
            // "float", we additionally treat every window as floating so the
            // user can drag any of them — the engine itself is only used to
            // compute an initial centred rect for windows that don't have
            // one yet.
            string activeId = _layoutController.ResolveLayoutId(output, outputName);
            bool floatIsActive = activeId == "float";

            // Per-output filter: an engine like ScrollingLayout maintains
            // per-output state (ScrollState.Columns) and *must* only see
            // the windows that belong to this output, otherwise its
            // per-output state accumulates handles from other outputs
            // and KeyNotFoundException / cross-monitor placements ensue.
            // Assignment policy: a window belongs to `output` if its
            // tracked W.Output matches; else, if its (X,Y) falls inside
            // usableArea we adopt it onto this output; otherwise skip.
            // For the IntPtr.Zero fallback (no outputs), accept all.
            bool isFallback = output == IntPtr.Zero;

            // Phase B1c — Tags. Resolve the visible-tag mask for this
            // output (or AllTags for the IntPtr.Zero fallback) so we
            // can filter windows whose Tags do not intersect the
            // mask out of the layout snapshot before invoking the
            // engine. Off-tag windows additionally need a one-shot
            // hide(opcode 4) so the compositor stops drawing them;
            // see the transition pass below.
            uint outputVisibleTags = Aqueous.Features.Tags.TagState.AllTags;
            if (!isFallback && _outputs.TryGetValue(output, out var oeForTags))
                outputVisibleTags = oeForTags.VisibleTags;

            var tiledSnapshot = new List<WindowEntryView>(_windows.Count);
            var floatingHandles = new List<IntPtr>();
            // Phase B1e Pass C: per-window state overrides. Fullscreen
            // and Maximized bypass the layout engine and route directly
            // to short bespoke loops below; their target rects come from
            // the host adapter (OutputRect / UsableArea).
            var fullscreenHandles = new List<IntPtr>();
            var maximizedHandles = new List<IntPtr>();
            // Pass C / C2: hiddenThisCycle is the union of (a) tag-hidden,
            // (b) WindowState.Minimized, and (c) scratchpad windows that
            // are currently dismissed (state.Visible == false). All three
            // share the existing one-shot hide(opcode 4) + cache-invalidation
            // treatment further down.
            var hiddenThisCycle = new List<WindowEntry>();
            foreach (var kvp in _windows)
            {
                var w = kvp.Value;

                if (!isFallback)
                {
                    if (w.Output == IntPtr.Zero)
                    {
                        // Adopt onto an output: prefer one whose area
                        // contains the current (X,Y); else skip — another
                        // output's ProposeForArea call will adopt it.
                        bool inside =
                            w.X >= usableArea.X && w.X < usableArea.X + usableArea.W &&
                            w.Y >= usableArea.Y && w.Y < usableArea.Y + usableArea.H;
                        if (inside)
                        {
                            w.Output = output;
                            // Phase B1c: inherit the output's currently
                            // visible tags so a freshly-mapped window
                            // appears on whatever tag the user is on
                            // (minus the reserved scratchpad bit). Only
                            // touch a window still sitting on the
                            // default tag — anything else came from a
                            // deliberate SendFocusedToTags.
                            if (w.Tags == Aqueous.Features.Tags.TagState.DefaultTag)
                            {
                                uint inheritMask = outputVisibleTags &
                                                   ~Aqueous.Features.Tags.TagState.ScratchpadTag;
                                if (inheritMask != 0u) w.Tags = inheritMask;
                            }
                        }
                        else continue;
                    }
                    else if (w.Output != output)
                    {
                        continue;
                    }
                }

                // Tag visibility gate: a window present on this output
                // but whose Tags do not intersect VisibleTags must not
                // be passed to the layout engine and must be hidden
                // compositor-side.
                bool tagVisible = Aqueous.Features.Tags.TagState.IsVisible(
                    w.Tags, outputVisibleTags);
                if (!tagVisible)
                {
                    hiddenThisCycle.Add(w);
                    continue;
                }

                // Phase B1e Pass C / C2: window-state visibility filter.
                // Minimized windows and scratchpad-parked windows whose
                // visibility flag is currently false (pad dismissed) are
                // hidden the same way tag-hidden windows are: a one-shot
                // hide(opcode 4), placement caches invalidated, and
                // skipped from the layout snapshot entirely.
                _windowStates.TryGetValue(kvp.Key, out var wsState);
                if (wsState != null &&
                    (wsState.State == WindowState.Minimized ||
                     (wsState.InScratchpad && !wsState.Visible)))
                {
                    hiddenThisCycle.Add(w);
                    continue;
                }

                // Phase B1e Pass C / C3: state-driven geometry routing.
                // Fullscreen and Maximized bypass the active layout
                // engine; Floating uses the existing per-window FloatRect
                // path.  When the active engine is "float" we still treat
                // every window as floating so the user's drag handler
                // works as before.  Note that a window can only be
                // Fullscreen on the output it's pinned to: if a window
                // wandered onto a different output, demote it back to
                // its previous state for this cycle.
                if (wsState != null && wsState.State == WindowState.Fullscreen)
                {
                    // Single-FS-per-output: only the slot owner gets the
                    // FS rect. Defence-in-depth: if a stale FS flag
                    // somehow survives an output change, fall through to
                    // the Tiled bucket without emitting two FS rects.
                    var fsOwner = _outputFullscreen.TryGetValue(output, out var owner) ? owner : IntPtr.Zero;
                    if (fsOwner == IntPtr.Zero || fsOwner == kvp.Key)
                    {
                        fullscreenHandles.Add(kvp.Key);
                        continue;
                    }

                    Log($"FS slot conflict on output 0x{output.ToString("x")}: " +
                        $"window 0x{kvp.Key.ToString("x")} flagged FS but slot owner is 0x{fsOwner.ToString("x")}; demoting to tiled");
                }

                if (wsState != null && wsState.State == WindowState.Maximized)
                {
                    maximizedHandles.Add(kvp.Key);
                    continue;
                }

                if (wsState != null && wsState.State == WindowState.Floating)
                {
                    // Seed the WindowEntry's FloatRect from the controller's
                    // remembered FloatingGeom on the first cycle a window
                    // enters Floating, so the bespoke loop below has a rect
                    // to emit even if the user has never dragged it.
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

                // Floating is honoured only when the active layout is the
                // dedicated `float` engine. In tile/scrolling/monocle/grid the
                // per-window Floating override is suppressed so every window
                // goes through the active tiling engine.
                // When the float engine is active, every window goes onto
                // the floating layer. Otherwise the per-window Floating
                // override is suppressed so the tiling engine owns geometry.
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
                        Tags: w.Tags));
                }
            }

            // Visibility transition pass for tag-hidden windows.
            // Emit river_window_v1::hide (opcode 4) once per
            // hide transition, and clear placement caches so a
            // subsequent re-show re-issues propose_dimensions /
            // set_position. Hidden windows must not participate in
            // the per-frame render loop either, hence Visible=false.
            for (int hi = 0; hi < hiddenThisCycle.Count; hi++)
            {
                var w = hiddenThisCycle[hi];
                if (!w.HideSent)
                {
                    WaylandInterop.wl_proxy_marshal_flags(
                        w.Proxy, 4, IntPtr.Zero, 0, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    w.HideSent = true;
                    // Force re-propose / re-position on next show.
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

            // Adoption fallback: if we are the *only* output and no
            // window has been assigned yet (happens on first cycle
            // because windows start at cascade offsets that may sit
            // outside the reported usableArea), adopt every unassigned
            // window onto us so they are not silently dropped.
            if (!isFallback && tiledSnapshot.Count == 0 && floatingHandles.Count == 0 && _outputs.Count == 1)
            {
                foreach (var kvp in _windows)
                {
                    var w = kvp.Value;
                    if (w.Output == IntPtr.Zero) w.Output = output;
                    bool treatAsFloating = floatIsActive && w.Floating;
                    if (floatIsActive || treatAsFloating) floatingHandles.Add(kvp.Key);
                    else
                        tiledSnapshot.Add(new WindowEntryView(
                            Handle: kvp.Key, MinW: w.MinW, MinH: w.MinH,
                            MaxW: w.MaxW, MaxH: w.MaxH,
                            Floating: false, Fullscreen: false, Tags: 0u));
                }
            }

            // -------- Tiled windows: drive through the layout engine --------
            if (tiledSnapshot.Count > 0)
            {
                IReadOnlyList<WindowPlacement> placements;
                try
                {
                    placements = _layoutController.Arrange(
                        output, outputName, usableArea, tiledSnapshot, _focusedWindow);
                }
                catch (Exception ex)
                {
                    Log("layout engine threw, skipping arrange: " + ex.Message);
                    placements = Array.Empty<WindowPlacement>();
                }

                for (int i = 0; i < placements.Count; i++)
                {
                    var p = placements[i];
                    if (!_windows.TryGetValue(p.Handle, out var w)) continue;

                    int pw = p.Geometry.W;
                    int ph = p.Geometry.H;
                    if (pw <= 0 || ph <= 0) continue;

                    // Honor Visible: invisible (off-screen) placements
                    // must NOT trigger set_position with negative coords
                    // (render_start checks w.Visible) and must NOT spam
                    // propose_dimensions every manage cycle. Update size
                    // tracking only on real change so the next time the
                    // window scrolls back into view we don't re-propose.
                    if (!p.Visible)
                    {
                        w.Visible = false;
                        // Cache size for the off-screen column without
                        // any wire traffic; if the column width changes
                        // later we will propose only when it becomes
                        // visible again or when it actually changes.
                        if (pw != w.LastHintW || ph != w.LastHintH)
                        {
                            // Don't update LastHintW/H for invisible windows —
                            // we want the next visible cycle to fire propose
                            // exactly once if needed. Just skip silently.
                        }

                        continue;
                    }

                    w.Visible = true;
                    w.TagVisible = true;
                    w.HideSent = false;

                    if (pw == w.LastHintW && ph == w.LastHintH)
                    {
                        w.X = p.Geometry.X;
                        w.Y = p.Geometry.Y;
                        continue;
                    }

                    w.LastHintW = pw;
                    w.LastHintH = ph;
                    w.ProposedW = pw;
                    w.ProposedH = ph;
                    w.X = p.Geometry.X;
                    w.Y = p.Geometry.Y;

                    WaylandInterop.wl_proxy_marshal_flags(
                        p.Handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }

            // -------- Floating layer: use the remembered FloatRect ---------
            // Initial-rect math matches FloatingLayout.Arrange so the very
            // first frame of a never-dragged window in float-active mode is
            // identical to what the engine would have produced.
            int initW = Math.Min(800, (int)(usableArea.W * 0.6));
            int initH = Math.Min(600, (int)(usableArea.H * 0.6));
            int initX = usableArea.X + (usableArea.W - initW) / 2;
            int initY = usableArea.Y + (usableArea.H - initH) / 2;

            for (int i = 0; i < floatingHandles.Count; i++)
            {
                var handle = floatingHandles[i];
                if (!_windows.TryGetValue(handle, out var w)) continue;

                if (!w.HasFloatRect)
                {
                    w.FloatX = initX;
                    w.FloatY = initY;
                    w.FloatW = initW;
                    w.FloatH = initH;
                    w.HasFloatRect = true;
                }

                int pw = w.FloatW, ph = w.FloatH;
                if (pw <= 0 || ph <= 0) continue;

                // Position is what the user dragged to; never overwritten by
                // any engine call. Width/height only proposed when changed.
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
                    WaylandInterop.wl_proxy_marshal_flags(
                        handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }

            // -------- Phase B1e Pass C: Maximized layer --------------------
            // Maximized windows cover the usable area of their pinned
            // output (or this output, when not pinned). Geometry follows
            // exactly the same diff-gating discipline as the floating
            // loop above so we don't re-propose every cycle.
            for (int i = 0; i < maximizedHandles.Count; i++)
            {
                var handle = maximizedHandles[i];
                if (!_windows.TryGetValue(handle, out var w)) continue;

                int tx = usableArea.X, ty = usableArea.Y;
                int pw = usableArea.W, ph = usableArea.H;
                if (pw <= 0 || ph <= 0) continue;

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
                    WaylandInterop.wl_proxy_marshal_flags(
                        handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }

            // -------- Phase B1e Pass C: Fullscreen layer -------------------
            // Fullscreen windows cover the raw output rect (no struts,
            // no gaps). The single-FS-per-output invariant is enforced
            // up in the snapshot pass; here we trust the bucket.
            // Note: ProposeForArea is invoked once per output with
            // `usableArea` already equal to the OutputEntry rect (see
            // the `manage_start` caller around line 840), so for now we
            // use `usableArea` minus any reservation as the FS rect by
            // *adding back* the OutputEntry's full rect when one is
            // available. UsableArea reservation is a TODO(passC1)
            // pending real exclusive_zone tracking, so today
            // `OutputRect == UsableArea` and the two loops produce
            // identical geometry — which is the documented Pass C
            // behaviour without C1 reservations.
            Rect outputRect = usableArea;
            if (output != IntPtr.Zero && _outputs.TryGetValue(output, out var oeFull))
                outputRect = new Rect(oeFull.X, oeFull.Y,
                    oeFull.Width > 0 ? oeFull.Width : usableArea.W,
                    oeFull.Height > 0 ? oeFull.Height : usableArea.H);

            for (int i = 0; i < fullscreenHandles.Count; i++)
            {
                var handle = fullscreenHandles[i];
                if (!_windows.TryGetValue(handle, out var w)) continue;

                int tx = outputRect.X, ty = outputRect.Y;
                int pw = outputRect.W, ph = outputRect.H;
                if (pw <= 0 || ph <= 0) continue;

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
                    WaylandInterop.wl_proxy_marshal_flags(
                        handle, 3, IntPtr.Zero, 0, 0,
                        (IntPtr)pw, (IntPtr)ph,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
            }
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
                    // Phase B1e Pass B: tear down per-window state so the
                    // controller's invariants (single-FS slot, MRU stack,
                    // scratchpad ownership) drop their references to the
                    // dead proxy before _windows loses the entry.
                    _windowState.OnWindowDestroyed(proxy);
                    _windowStates.TryRemove(proxy, out _);
                    foreach (var ofs in _outputFullscreen)
                        if (ofs.Value == proxy)
                            _outputFullscreen.TryRemove(ofs.Key, out _);
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
                    w.MinW = args[0].i;
                    w.MinH = args[1].i;
                    w.MaxW = args[2].i;
                    w.MaxH = args[3].i;
                    Log($"window 0x{proxy.ToString("x")} dimensions_hint min {w.MinW}x{w.MinH} max {w.MaxW}x{w.MaxH}");
                    break;
                case 2:
                    w.W = args[0].i;
                    w.H = args[1].i;
                    Log($"window 0x{proxy.ToString("x")} dimensions {w.W}x{w.H}");
                    // Fix #3: as soon as the client commits a real size, run a fresh
                    // manage/render cycle so set_clip_box is emitted on the first frame
                    // the size is known. Otherwise the initial frame ships without a
                    // clip box and pointer/keyboard input falls outside the input region.
                    ScheduleManage();
                    break;
                case 3:
                    w.AppId = PtrToString(args[0].s);
                    Log($"window 0x{proxy.ToString("x")} app_id={w.AppId}");
                    break;
                case 4:
                    w.Title = PtrToString(args[0].s);
                    Log($"window 0x{proxy.ToString("x")} title={w.Title}");
                    break;
                case 7:
                    IntPtr seatProxy = args[0].o;
                    Log($"window 0x{proxy.ToString("x")} requested pointer move on seat 0x{seatProxy.ToString("x")}");
                    _activeDragWindow = w;
                    _activeDragSeat = seatProxy;
                    _dragStartX = w.X;
                    _dragStartY = w.Y;
                    break;
                case 10:
                    if (!_windowStates.TryGetValue(proxy, out var sMax)
                        || sMax.State != WindowState.Maximized)
                    {
                        _windowState.ToggleMaximize(proxy);
                    }

                    ScheduleManage();
                    break;
                case 11:
                    if (_windowStates.TryGetValue(proxy, out var stateData)
                        && stateData.State == WindowState.Minimized)
                    {
                        _windowState.ToggleMaximize(proxy);
                    }

                    ScheduleManage();
                    break;
                case 12:
                    var outputProxy = args[0].o;
                    _windowState.OnClientRequestedFullscreen(proxy,
                        outputProxy == IntPtr.Zero ? (IntPtr?)null : outputProxy);
                    ScheduleManage();
                    break;
                case 13:
                    _windowState.OnClientRequestedUnfullscreen(proxy);
                    ScheduleManage();
                    break;
                case 14:
                    _windowState.ToggleMinimize(proxy);
                    ScheduleManage();
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
                    // Phase B1e Pass B: forward the removal to the window
                    // state controller so it can demote any FS/Max windows
                    // pinned to this output before _outputs forgets it.
                {
                    var goneOutputWindows = new List<WindowStateData>();
                    foreach (var sk in _windowStates)
                        if (sk.Value.PinnedOutput == proxy)
                            goneOutputWindows.Add(sk.Value);
                    _windowState.OnOutputRemoved(proxy, goneOutputWindows);
                    _outputFullscreen.TryRemove(proxy, out _);
                }
                    _outputs.TryRemove(proxy, out _);
                    // Detach windows from the gone output so the next
                    // manage cycle re-adopts them onto a surviving one.
                    foreach (var wkvp in _windows)
                        if (wkvp.Value.Output == proxy)
                            wkvp.Value.Output = IntPtr.Zero;
                    break;
                case 1:
                    o.WlOutputName = args[0].u;
                    Log($"output 0x{proxy.ToString("x")} wl_output_name={o.WlOutputName}");
                    break;
                case 2:
                    o.X = args[0].i;
                    o.Y = args[1].i;
                    Log($"output 0x{proxy.ToString("x")} position={o.X},{o.Y}");
                    break;
                case 3:
                    o.Width = args[0].i;
                    o.Height = args[1].i;
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
                        var adw = _activeDragWindow;
                        adw.X = _dragStartX + dx;
                        adw.Y = _dragStartY + dy;
                        // Promote the dragged window to the floating layer and
                        // remember its rect so subsequent manage cycles do not
                        // overwrite the drag-derived position with the active
                        // layout engine's choice. Width/height come from the
                        // last known committed dimensions; if the client has
                        // not committed a size yet, fall back to the last
                        // proposed hint.
                        // Drag-to-float promotion is only meaningful when the
                        // active layout is the float engine; otherwise the tiling
                        // engine owns geometry and a per-window Floating override
                        // would be ignored anyway (see ProposeForArea).
                        if (IsFloatLayoutActive())
                            adw.Floating = true;
                        adw.HasFloatRect = true;
                        adw.FloatX = adw.X;
                        adw.FloatY = adw.Y;
                        adw.FloatW = adw.W > 0 ? adw.W : (adw.LastHintW > 0 ? adw.LastHintW : adw.ProposedW);
                        adw.FloatH = adw.H > 0 ? adw.H : (adw.LastHintH > 0 ? adw.LastHintH : adw.ProposedH);
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

        /// <summary>
        /// True iff the active layout (resolved against the focused window's
        /// output, or the first known output as a fallback) is the dedicated
        /// `float` engine. Drag-to-float promotion and the
        /// builtin:toggle_floating action consult this so per-window floating
        /// is inert in tile/scrolling/monocle/grid layouts.
        /// </summary>
        internal bool IsFloatLayoutActive()
        {
            IntPtr output = IntPtr.Zero;
            string? outputName = null;
            if (_focusedWindow != IntPtr.Zero &&
                _windows.TryGetValue(_focusedWindow, out var fw) &&
                fw.Output != IntPtr.Zero)
            {
                output = fw.Output;
            }
            else
            {
                foreach (var k in _outputs.Keys)
                {
                    output = k;
                    break;
                }
            }

            return _layoutController.ResolveLayoutId(output, outputName) == "float";
        }

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
            if (windowProxy == _focusedWindow && _pendingFocusWindow == IntPtr.Zero &&
                _pendingFocusShellSurface == IntPtr.Zero)
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
                foreach (var k in _seats.Keys)
                {
                    seat = k;
                    break;
                }
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
                foreach (var k in _seats.Keys)
                {
                    seat = k;
                    break;
                }
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
                foreach (var k in _windows.Keys)
                {
                    pick = k;
                    break;
                }
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
                if (takeNext)
                {
                    next = k;
                    takeNext = false;
                    break;
                }

                if (k == _focusedWindow) takeNext = true;
            }

            if (next != IntPtr.Zero) RequestFocus(next);
        }

        /// <summary>
        /// Register every keybind defined by the active <see cref="LayoutConfig.Keybinds"/>
        /// (built-in actions with config-overridable chords + custom chords with
        /// free-form action verbs). Falls back to <see cref="KeybindConfig.Defaults"/>
        /// for any built-in not explicitly listed in the config.
        /// </summary>
        private void RegisterAllBindings(IntPtr seatProxy)
        {
            var kb = _layoutConfig.Keybinds;
            foreach (var (action, builtin) in BuiltinActionMap)
            {
                foreach (var chordStr in kb.ChordsFor(action))
                {
                    var parsed = KeyChord.Parse(chordStr);
                    if (parsed is null)
                    {
                        Log($"keybind: invalid chord '{chordStr}' for action '{action}', ignored");
                        continue;
                    }

                    RegisterKeyBinding(seatProxy, parsed.Value.Keysym, parsed.Value.Modifiers, builtin);
                }
            }

            // Custom chord -> action verb (spawn:/set_layout:/builtin:).
            foreach (var (chordStr, verb) in kb.Custom)
            {
                var parsed = KeyChord.Parse(chordStr);
                if (parsed is null)
                {
                    Log($"keybind: invalid custom chord '{chordStr}', ignored");
                    continue;
                }

                RegisterCustomKeyBinding(seatProxy, parsed.Value.Keysym, parsed.Value.Modifiers, verb);
            }
        }

        private void RegisterCustomKeyBinding(IntPtr seatProxy, uint keysym, uint modifiers, string action)
        {
            if (_xkbBindings == IntPtr.Zero) return;
            IntPtr binding = WaylandInterop.wl_proxy_marshal_flags(
                _xkbBindings, 1, (IntPtr)WlInterfaces.RiverXkbBinding, 3, 0,
                seatProxy, IntPtr.Zero, (IntPtr)keysym, (IntPtr)modifiers, IntPtr.Zero, IntPtr.Zero);
            if (binding == IntPtr.Zero) return;
            _keyBindings[binding] = KeyBindingAction.Custom;
            _customBindingActions[binding] = action;
            WaylandInterop.wl_proxy_add_dispatcher(
                binding,
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                GCHandle.ToIntPtr(_selfHandle),
                IntPtr.Zero);
            WaylandInterop.wl_proxy_marshal_flags(binding, 2, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            Log($"registered custom key binding '{action}' (keysym 0x{keysym:x}, mods 0x{modifiers:x})");
        }

        /// <summary>
        /// Dispatch a custom action verb. Recognised forms:
        /// <list type="bullet">
        ///   <item><c>spawn:&lt;cmd&gt;</c> — fork/exec via <c>/bin/sh -c</c>.</item>
        ///   <item><c>set_layout:&lt;id-or-slot&gt;</c> — switch active layout.</item>
        ///   <item><c>builtin:&lt;action_name&gt;</c> — invoke a built-in.</item>
        /// </list>
        /// </summary>
        private void RunCustomAction(string action)
        {
            int colon = action.IndexOf(':');
            string verb = colon < 0 ? action : action.Substring(0, colon);
            string arg = colon < 0 ? "" : action.Substring(colon + 1).Trim();
            switch (verb)
            {
                case "spawn":
                    if (arg.Length == 0) return;
                    try
                    {
                        var psi = new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = "/bin/sh",
                            UseShellExecute = false,
                            CreateNoWindow = true,
                        };
                        psi.ArgumentList.Add("-c");
                        psi.ArgumentList.Add($"setsid -f sh -c {EscapeSh(arg)} >/dev/null 2>&1");
                        var wayland = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
                        var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
                        if (!string.IsNullOrEmpty(wayland)) psi.EnvironmentVariables["WAYLAND_DISPLAY"] = wayland;
                        if (!string.IsNullOrEmpty(runtime)) psi.EnvironmentVariables["XDG_RUNTIME_DIR"] = runtime;
                        psi.EnvironmentVariables.Remove("DISPLAY");
                        System.Diagnostics.Process.Start(psi);
                    }
                    catch (Exception ex)
                    {
                        Log($"spawn '{arg}' failed: {ex.Message}");
                    }

                    break;
                case "set_layout":
                    SetLayoutByIdOrSlot(arg);
                    break;
                case "builtin":
                {
                    // Phase B1e Pass B: split one optional trailing
                    // ":argument" segment so chords like
                    //   builtin:toggle_scratchpad_named:term
                    // can dispatch to the parameterised actions while
                    // preserving the existing parameterless
                    //   builtin:cycle_focus
                    // form.
                    string bname = arg;
                    string barg = string.Empty;
                    int sub = arg.IndexOf(':');
                    if (sub >= 0)
                    {
                        bname = arg.Substring(0, sub);
                        barg = arg.Substring(sub + 1).Trim();
                    }

                    switch (bname)
                    {
                        case "toggle_scratchpad_named":
                            if (barg.Length == 0)
                            {
                                Log("builtin:toggle_scratchpad_named requires :name");
                                break;
                            }

                            _windowState.ToggleScratchpad(barg);
                            break;
                        case "send_to_scratchpad_named":
                            if (barg.Length == 0)
                            {
                                Log("builtin:send_to_scratchpad_named requires :name");
                                break;
                            }

                            if (_focusedWindow != IntPtr.Zero)
                                _windowState.SendToScratchpad(_focusedWindow, barg);
                            else
                                Log("builtin:send_to_scratchpad_named: no focused window");
                            break;
                        default:
                            if (BuiltinActionMap.TryGetValue(bname, out var b))
                                InvokeBuiltin(b);
                            else
                                Log($"unknown builtin '{bname}'");
                            break;
                    }
                }
                    break;
                default:
                    Log($"unknown custom action verb '{verb}'");
                    break;
            }
        }

        private static string EscapeSh(string s) => "'" + s.Replace("'", "'\\''") + "'";

        /// <summary>Resolve <paramref name="idOrSlot"/> through slots first, then engines.</summary>
        private void SetLayoutByIdOrSlot(string idOrSlot)
        {
            if (string.IsNullOrEmpty(idOrSlot)) return;
            string id = idOrSlot;
            if (_layoutConfig.Slots.TryGetValue(idOrSlot, out var resolved))
                id = resolved;
            _layoutController.SetLayout(id);
            ScheduleManage();
        }

        private void InvokeBuiltin(KeyBindingAction action) => HandleKeyBindingAction(action);

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
            if (action == KeyBindingAction.Custom)
            {
                if (_customBindingActions.TryGetValue(proxy, out var verb))
                    RunCustomAction(verb);
                return;
            }

            HandleKeyBindingAction(action);
        }

        private void HandleKeyBindingAction(KeyBindingAction action)
        {
            switch (action)
            {
                case KeyBindingAction.ToggleStartMenu:
                    try
                    {
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = "dbus-send",
                            Arguments =
                                "--session --type=method_call --dest=org.Aqueous /org/Aqueous org.Aqueous.ToggleStartMenu",
                            UseShellExecute = false,
                            CreateNoWindow = true,
                        });
                    }
                    catch (Exception ex)
                    {
                        Log("failed to toggle start menu: " + ex.Message);
                    }

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
                    catch (Exception ex)
                    {
                        Log("failed to spawn terminal: " + ex.Message);
                    }

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
                    CycleFocus();
                    break;
                case KeyBindingAction.FocusLeft:
                    HandleDirectionalFocus(FocusDirection.Left);
                    break;
                case KeyBindingAction.FocusRight:
                    HandleDirectionalFocus(FocusDirection.Right);
                    break;
                case KeyBindingAction.FocusUp:
                    HandleDirectionalFocus(FocusDirection.Up);
                    break;
                case KeyBindingAction.FocusDown:
                    HandleDirectionalFocus(FocusDirection.Down);
                    break;
                case KeyBindingAction.ScrollViewportLeft:
                    HandleScrollViewport(-1);
                    break;
                case KeyBindingAction.ScrollViewportRight:
                    HandleScrollViewport(+1);
                    break;
                case KeyBindingAction.MoveColumnLeft:
                    HandleMoveColumn(FocusDirection.Left);
                    break;
                case KeyBindingAction.MoveColumnRight:
                    HandleMoveColumn(FocusDirection.Right);
                    break;
                case KeyBindingAction.ReloadConfig:
                    try
                    {
                        var fresh = LayoutConfig.Load(GetDefaultConfigPath());
                        _layoutConfig = fresh;
                        _layoutController.ReplaceConfig(fresh);
                        Log("config reloaded");
                        // Note: chord rebinding hot-swap is not done here —
                        // existing xkb bindings remain (River v3 has no
                        // unbind primitive); changes to [keybinds] take
                        // effect on next WM start.
                        ScheduleManage();
                    }
                    catch (Exception ex)
                    {
                        Log("config reload failed: " + ex.Message);
                    }

                    break;
                case KeyBindingAction.SetLayoutPrimary:
                    SetLayoutByIdOrSlot("primary");
                    break;
                case KeyBindingAction.SetLayoutSecondary:
                    SetLayoutByIdOrSlot("secondary");
                    break;
                case KeyBindingAction.SetLayoutTertiary:
                    SetLayoutByIdOrSlot("tertiary");
                    break;
                case KeyBindingAction.SetLayoutQuaternary:
                    SetLayoutByIdOrSlot("quaternary");
                    break;

                // Phase B1c — Tag actions. ViewTag1..9 / SendTag1..9 /
                // ToggleViewTag1..9 / ToggleWindowTag1..9 are arranged
                // contiguously in the enum; resolve the tag bit by
                // subtracting the action's group base. ViewTagAll /
                // SendTagAll fall through to AllTags.
                case KeyBindingAction.ViewTag1:
                case KeyBindingAction.ViewTag2:
                case KeyBindingAction.ViewTag3:
                case KeyBindingAction.ViewTag4:
                case KeyBindingAction.ViewTag5:
                case KeyBindingAction.ViewTag6:
                case KeyBindingAction.ViewTag7:
                case KeyBindingAction.ViewTag8:
                case KeyBindingAction.ViewTag9:
                    _tagController.ViewTags(TagState.Bit(action - KeyBindingAction.ViewTag1));
                    break;
                case KeyBindingAction.ViewTagAll:
                    _tagController.ViewAll();
                    break;
                case KeyBindingAction.SendTag1:
                case KeyBindingAction.SendTag2:
                case KeyBindingAction.SendTag3:
                case KeyBindingAction.SendTag4:
                case KeyBindingAction.SendTag5:
                case KeyBindingAction.SendTag6:
                case KeyBindingAction.SendTag7:
                case KeyBindingAction.SendTag8:
                case KeyBindingAction.SendTag9:
                    _tagController.SendFocusedToTags(TagState.Bit(action - KeyBindingAction.SendTag1));
                    break;
                case KeyBindingAction.SendTagAll:
                    _tagController.SendFocusedToTags(TagState.AllTags);
                    break;
                case KeyBindingAction.ToggleViewTag1:
                case KeyBindingAction.ToggleViewTag2:
                case KeyBindingAction.ToggleViewTag3:
                case KeyBindingAction.ToggleViewTag4:
                case KeyBindingAction.ToggleViewTag5:
                case KeyBindingAction.ToggleViewTag6:
                case KeyBindingAction.ToggleViewTag7:
                case KeyBindingAction.ToggleViewTag8:
                case KeyBindingAction.ToggleViewTag9:
                    _tagController.ToggleViewTag(TagState.Bit(action - KeyBindingAction.ToggleViewTag1));
                    break;
                case KeyBindingAction.ToggleWindowTag1:
                case KeyBindingAction.ToggleWindowTag2:
                case KeyBindingAction.ToggleWindowTag3:
                case KeyBindingAction.ToggleWindowTag4:
                case KeyBindingAction.ToggleWindowTag5:
                case KeyBindingAction.ToggleWindowTag6:
                case KeyBindingAction.ToggleWindowTag7:
                case KeyBindingAction.ToggleWindowTag8:
                case KeyBindingAction.ToggleWindowTag9:
                    _tagController.ToggleWindowTag(TagState.Bit(action - KeyBindingAction.ToggleWindowTag1));
                    break;
                case KeyBindingAction.SwapLastTagset:
                    _tagController.SwapLastTagset();
                    break;

                // ---- Phase B1e Pass B — Window state ops ---------------
                case KeyBindingAction.ToggleFullscreen:
                    if (_focusedWindow != IntPtr.Zero) _windowState.ToggleFullscreen(_focusedWindow);
                    else Log("toggle_fullscreen: no focused window");
                    break;
                case KeyBindingAction.ToggleMaximize:
                    if (_focusedWindow != IntPtr.Zero) _windowState.ToggleMaximize(_focusedWindow);
                    else Log("toggle_maximize: no focused window");
                    break;
                case KeyBindingAction.ToggleFloating:
                    if (_focusedWindow != IntPtr.Zero) _windowState.ToggleFloating(_focusedWindow);
                    else Log("toggle_floating: no focused window");
                    break;
                case KeyBindingAction.ToggleMinimize:
                    if (_focusedWindow != IntPtr.Zero) _windowState.ToggleMinimize(_focusedWindow);
                    else Log("toggle_minimize: no focused window");
                    break;
                case KeyBindingAction.UnminimizeLast:
                    _windowState.UnminimizeLast();
                    break;
                case KeyBindingAction.ToggleScratchpad:
                    _windowState.ToggleScratchpad(ScratchpadRegistry.DefaultPad);
                    break;
                case KeyBindingAction.SendToScratchpad:
                    if (_focusedWindow != IntPtr.Zero)
                        _windowState.SendToScratchpad(_focusedWindow, ScratchpadRegistry.DefaultPad);
                    else
                        Log("send_to_scratchpad: no focused window");
                    break;
            }
        }

        // ---- TagController.ITagHost (Phase B1c) --------------------------

        /// <summary>
        /// Returns the OutputEntry the keyboard focus currently lives on.
        /// Falls back to a pointer-hovered output, then to the first
        /// known output. <c>null</c> if no outputs are tracked yet
        /// (e.g. the headless fallback).
        /// </summary>
        private OutputEntry? GetFocusedOutputEntry()
        {
            // 1. Output of the focused window.
            if (_focusedWindow != IntPtr.Zero &&
                _windows.TryGetValue(_focusedWindow, out var fw) &&
                fw.Output != IntPtr.Zero &&
                _outputs.TryGetValue(fw.Output, out var oeFromFocus))
            {
                return oeFromFocus;
            }

            // 2. First output (deterministic enough for single-output;
            //    pointer-position output resolution can be added when
            //    SeatInteractionService exposes it).
            foreach (var kv in _outputs)
                return kv.Value;

            return null;
        }

        uint? TagController.ITagHost.GetFocusedOutputVisibleTags()
            => GetFocusedOutputEntry()?.VisibleTags;

        uint? TagController.ITagHost.GetFocusedOutputLastTagset()
            => GetFocusedOutputEntry()?.LastVisibleTags;

        bool TagController.ITagHost.SetFocusedOutputVisibleTags(uint mask)
        {
            var oe = GetFocusedOutputEntry();
            if (oe is null) return false;
            if (oe.VisibleTags == mask) return false;

            // Push prior value onto history (cap to 8) and remember it
            // separately as LastVisibleTags for fast back-and-forth.
            oe.LastVisibleTags = oe.VisibleTags;
            oe.TagHistory.Push(oe.VisibleTags);
            while (oe.TagHistory.Count > 8)
            {
                // Drop oldest by rebuilding (Stack<T> has no DequeueLast).
                var arr = oe.TagHistory.ToArray();
                oe.TagHistory.Clear();
                for (int i = arr.Length - 2; i >= 0; i--) oe.TagHistory.Push(arr[i]);
                break;
            }

            oe.VisibleTags = mask;
            Log($"tags: output 0x{oe.Proxy.ToString("x")} VisibleTags=0x{mask:x8} (was 0x{oe.LastVisibleTags:x8})");
            return true;
        }

        bool TagController.ITagHost.SetFocusedWindowTags(uint mask)
        {
            if (_focusedWindow == IntPtr.Zero) return false;
            if (!_windows.TryGetValue(_focusedWindow, out var fw)) return false;
            if (fw.Tags == mask) return false;
            fw.Tags = mask;
            Log($"tags: window 0x{_focusedWindow.ToString("x")} Tags=0x{mask:x8}");
            return true;
        }

        bool TagController.ITagHost.ToggleFocusedWindowTags(uint mask)
        {
            if (_focusedWindow == IntPtr.Zero) return false;
            if (!_windows.TryGetValue(_focusedWindow, out var fw)) return false;
            uint next = fw.Tags ^ mask;
            if (next == 0u) return false; // never end up untagged
            fw.Tags = next;
            Log($"tags: window 0x{_focusedWindow.ToString("x")} Tags=0x{next:x8} (toggled 0x{mask:x8})");
            return true;
        }

        void TagController.ITagHost.RequestRelayout() => ScheduleManage();

        /// <summary>
        /// Self-heal focus when the previously-focused window has just
        /// become invisible because of a tag change. Picks the first
        /// window on the focused output that intersects the new
        /// VisibleTags; clears focus if none.
        /// </summary>
        void TagController.ITagHost.RepairFocusAfterTagChange()
        {
            if (_focusedWindow != IntPtr.Zero &&
                _windows.TryGetValue(_focusedWindow, out var fw))
            {
                uint mask = TagState.AllTags;
                if (fw.Output != IntPtr.Zero && _outputs.TryGetValue(fw.Output, out var oe))
                    mask = oe.VisibleTags;
                if (TagState.IsVisible(fw.Tags, mask))
                    return; // still visible; keep focus.
            }

            // Replacement: first visible window on the focused output,
            // else any visible window, else clear focus.
            IntPtr replacement = IntPtr.Zero;
            var focusedOe = GetFocusedOutputEntry();
            uint focusedMask = focusedOe?.VisibleTags ?? TagState.AllTags;
            IntPtr focusedOutput = focusedOe?.Proxy ?? IntPtr.Zero;

            foreach (var kv in _windows)
            {
                var w = kv.Value;
                if (focusedOutput != IntPtr.Zero && w.Output != focusedOutput) continue;
                if (!TagState.IsVisible(w.Tags, focusedMask)) continue;
                replacement = kv.Key;
                break;
            }

            if (replacement == IntPtr.Zero)
            {
                ClearFocus();
            }
            else
            {
                RequestFocus(replacement);
            }
        }

        /// <summary>
        /// Optional sink consumed by the IPC bridge in Phase B1g.
        /// Settable from <c>Program.cs</c>; null by default so the
        /// hot path costs nothing.
        /// </summary>
        public Action<TagController.TagsChangedEvent>? TagsChanged { get; set; }

        Action<TagController.TagsChangedEvent>? TagController.ITagHost.TagsChanged => TagsChanged;

        /// <summary>
        /// Engine-aware directional focus. Asks the active layout engine for
        /// its preferred neighbour (e.g. scrolling's column ordering) and
        /// falls back to insertion-order CycleFocus when the engine has no
        /// opinion. After focus changes to a possibly off-screen window we
        /// schedule a manage cycle so the engine recentres its viewport
        /// (otherwise render_start would skip the new focused window
        /// because Visible=false).
        /// </summary>
        private void HandleDirectionalFocus(FocusDirection dir)
        {
            if (_focusedWindow == IntPtr.Zero || _windows.Count == 0)
            {
                CycleFocus();
                return;
            }

            if (!_windows.TryGetValue(_focusedWindow, out var fw))
            {
                CycleFocus();
                return;
            }

            IntPtr output = fw.Output;
            string? outputName = ResolveOutputName(output);
            var snapshot = BuildSnapshotFor(output);
            var target = _layoutController.FocusNeighbor(output, outputName, _focusedWindow, dir, snapshot);
            if (target is { } t && t != IntPtr.Zero && _windows.ContainsKey(t))
            {
                ScheduleManage(); // engine may need to recentre viewport
                RequestFocus(t);
                return;
            }

            CycleFocus();
        }

        private void HandleScrollViewport(int deltaColumns)
        {
            if (_focusedWindow == IntPtr.Zero || !_windows.TryGetValue(_focusedWindow, out var fw))
                return;
            _layoutController.ScrollViewport(fw.Output, ResolveOutputName(fw.Output), deltaColumns);
            ScheduleManage();
        }

        private void HandleMoveColumn(FocusDirection dir)
        {
            if (_focusedWindow == IntPtr.Zero || !_windows.TryGetValue(_focusedWindow, out var fw))
                return;
            if (_layoutController.MoveFocused(fw.Output, ResolveOutputName(fw.Output), _focusedWindow, dir))
                ScheduleManage();
        }

        /// <summary>Build a per-output WindowEntryView snapshot for navigation queries.</summary>
        private List<WindowEntryView> BuildSnapshotFor(IntPtr output)
        {
            var list = new List<WindowEntryView>(_windows.Count);
            foreach (var kvp in _windows)
            {
                var w = kvp.Value;
                if (output != IntPtr.Zero && w.Output != IntPtr.Zero && w.Output != output) continue;
                list.Add(new WindowEntryView(
                    Handle: kvp.Key,
                    MinW: w.MinW, MinH: w.MinH, MaxW: w.MaxW, MaxH: w.MaxH,
                    Floating: w.Floating, Fullscreen: false, Tags: 0u));
            }

            return list;
        }

        private string? ResolveOutputName(IntPtr output)
        {
            // OutputEntry does not currently surface a name field; per-output
            // config matching is handled separately. Returning null keeps the
            // controller's resolution path identical to ProposeForArea's.
            _ = output;
            return null;
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