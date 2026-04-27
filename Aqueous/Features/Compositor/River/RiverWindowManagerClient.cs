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
internal sealed unsafe partial class RiverWindowManagerClient : IDisposable, TagController.ITagHost
{
    // --- logging -------------------------------------------------------

    /// <summary>
    /// All protocol activity funnels through this action. By default logs
    /// to stderr; host code may replace it with a GLib-aware sink.
    /// </summary>
    public static Action<string> Log { get; set; } =
        msg => Console.Error.WriteLine("[river-wm] " + msg);

    // --- state tracked from events ------------------------------------
    // WindowEntry / OutputEntry / SeatEntry live in Model/*.cs.

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

    /// <summary>
    /// Owns the <c>wl_display*</c> lifetime; everything else in this
    /// file reaches the native display via <see cref="_display"/>, which
    /// proxies to <see cref="WaylandConnection.Display"/>.
    /// </summary>
    private readonly WaylandConnection _connection = new();

    /// <summary>
    /// Drives <c>wl_display_dispatch</c> on a background thread. Started
    /// from <see cref="StartPump"/>, stopped from <see cref="Dispose"/>.
    /// </summary>
    private readonly EventPump _pump;

    private IntPtr _display => _connection.Display;

    /// <summary>
    /// Owns the <c>wl_registry</c> proxy and converts raw
    /// <c>global</c>/<c>global_remove</c> events into the
    /// <see cref="OnGlobalDiscovered"/> handler below.
    /// </summary>
    private readonly RegistryBinder _registry = new();
    private IntPtr _manager;
    private IntPtr _layerShell;
    private IntPtr _xkbBindings;
    private IntPtr _superKeyBinding;

    // --- key bindings -------------------------------------------------

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
            ["view_tag_1"] = KeyBindingAction.ViewTag1,
            ["view_tag_2"] = KeyBindingAction.ViewTag2,
            ["view_tag_3"] = KeyBindingAction.ViewTag3,
            ["view_tag_4"] = KeyBindingAction.ViewTag4,
            ["view_tag_5"] = KeyBindingAction.ViewTag5,
            ["view_tag_6"] = KeyBindingAction.ViewTag6,
            ["view_tag_7"] = KeyBindingAction.ViewTag7,
            ["view_tag_8"] = KeyBindingAction.ViewTag8,
            ["view_tag_9"] = KeyBindingAction.ViewTag9,
            ["view_tag_all"] = KeyBindingAction.ViewTagAll,
            ["send_tag_1"] = KeyBindingAction.SendTag1,
            ["send_tag_2"] = KeyBindingAction.SendTag2,
            ["send_tag_3"] = KeyBindingAction.SendTag3,
            ["send_tag_4"] = KeyBindingAction.SendTag4,
            ["send_tag_5"] = KeyBindingAction.SendTag5,
            ["send_tag_6"] = KeyBindingAction.SendTag6,
            ["send_tag_7"] = KeyBindingAction.SendTag7,
            ["send_tag_8"] = KeyBindingAction.SendTag8,
            ["send_tag_9"] = KeyBindingAction.SendTag9,
            ["send_tag_all"] = KeyBindingAction.SendTagAll,
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
        _pump = new EventPump(_connection, msg => Log(msg));
        _seatInteractionService = new SeatInteractionService(this);
        _layoutRegistry = new LayoutRegistry();
        _layoutConfig = LayoutConfig.Load(GetDefaultConfigPath());
        _layoutController = new LayoutController(_layoutRegistry, _layoutConfig);
        _tagController = new TagController(this);
        _scratchpadRegistry = new ScratchpadRegistry();
        _windowState = new WindowStateController(
            new RiverWindowStateHost(this), _scratchpadRegistry);
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
        {
            return null;
        }

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
        if (!_connection.Connect())
        {
            Log("wl_display_connect returned null");
            return false;
        }

        WlInterfaces.EnsureBuilt();

        _selfHandle = GCHandle.Alloc(this, GCHandleType.Normal);
        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch;

        if (!_registry.Create(_display, dispatcher, GCHandle.ToIntPtr(_selfHandle)))
        {
            Log("get_registry failed");
            return false;
        }

        _registry.Discovered += OnGlobalDiscovered;

        // Flush globals; then a second roundtrip so any events the
        // compositor sends immediately on bind (for an existing window
        // list) are delivered before we return.
        _connection.Roundtrip();
        _connection.Roundtrip();

        return _manager != IntPtr.Zero;
    }

    private void StartPump() => _pump.Start();

    public void Dispose()
    {
        // river_window_manager_v1::stop (opcode 0) is intentionally NOT
        // sent here: it is not a destructor — we'd still have to wait
        // for the `finished` event and then call destroy. For the
        // skeleton we just disconnect the display; River treats a
        // disconnected WM the same way as a stopped one and cleans up.
        try
        {
            _pump.Stop();
            _connection.Disconnect();
        }
        catch
        {
            // Tear-down is best-effort; we never want Dispose to throw.
        }
        finally
        {
            if (_selfHandle.IsAllocated)
            {
                _selfHandle.Free();
            }
        }
    }


    // --- registry ------------------------------------------------------

    private void OnGlobalDiscovered(RegistryGlobal global)
    {
        // The set of interfaces this client cares about. Anything else
        // advertised by the compositor is intentionally ignored.
        if (global.Interface == "river_window_manager_v1" && _manager == IntPtr.Zero)
        {
            _managerVersion = Math.Min(global.Version, 4u);
            _manager = _registry.Bind(global.Name, WlInterfaces.RiverWindowManager, _managerVersion);
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
        else if (global.Interface == "river_layer_shell_v1")
        {
            _layerShell = _registry.Bind(global.Name, WlInterfaces.RiverLayerShell, 1);
            WaylandInterop.wl_proxy_add_dispatcher(
                _layerShell,
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                GCHandle.ToIntPtr(_selfHandle),
                IntPtr.Zero);
            Log("bound river_layer_shell_v1");
        }
        else if (global.Interface == "river_xkb_bindings_v1")
        {
            uint xkbVersion = Math.Min(global.Version, 2u);
            _xkbBindings = _registry.Bind(global.Name, WlInterfaces.RiverXkbBindings, xkbVersion);
            Log($"bound river_xkb_bindings_v1 (version {xkbVersion})");
        }
    }

    // --- river_window_manager_v1 events -------------------------------





    private void SendManagerRequest(uint opcode)
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }

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
        {
            outputVisibleTags = oeForTags.VisibleTags;
        }

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
                            if (inheritMask != 0u)
                            {
                                w.Tags = inheritMask;
                            }
                        }
                    }
                    else
                    {
                        continue;
                    }
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
                if (w.Output == IntPtr.Zero)
                {
                    w.Output = output;
                }

                bool treatAsFloating = floatIsActive && w.Floating;
                if (floatIsActive || treatAsFloating)
                {
                    floatingHandles.Add(kvp.Key);
                }
                else
                {
                    tiledSnapshot.Add(new WindowEntryView(
                        Handle: kvp.Key, MinW: w.MinW, MinH: w.MinH,
                        MaxW: w.MaxW, MaxH: w.MaxH,
                        Floating: false, Fullscreen: false, Tags: 0u));
                }
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
                if (!_windows.TryGetValue(p.Handle, out var w))
                {
                    continue;
                }

                int pw = p.Geometry.W;
                int ph = p.Geometry.H;
                if (pw <= 0 || ph <= 0)
                {
                    continue;
                }

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
            if (!_windows.TryGetValue(handle, out var w))
            {
                continue;
            }

            if (!w.HasFloatRect)
            {
                w.FloatX = initX;
                w.FloatY = initY;
                w.FloatW = initW;
                w.FloatH = initH;
                w.HasFloatRect = true;
            }

            int pw = w.FloatW, ph = w.FloatH;
            if (pw <= 0 || ph <= 0)
            {
                continue;
            }

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
            if (!_windows.TryGetValue(handle, out var w))
            {
                continue;
            }

            int tx = usableArea.X, ty = usableArea.Y;
            int pw = usableArea.W, ph = usableArea.H;
            if (pw <= 0 || ph <= 0)
            {
                continue;
            }

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
        {
            outputRect = new Rect(oeFull.X, oeFull.Y,
                oeFull.Width > 0 ? oeFull.Width : usableArea.W,
                oeFull.Height > 0 ? oeFull.Height : usableArea.H);
        }

        for (int i = 0; i < fullscreenHandles.Count; i++)
        {
            var handle = fullscreenHandles[i];
            if (!_windows.TryGetValue(handle, out var w))
            {
                continue;
            }

            int tx = outputRect.X, ty = outputRect.Y;
            int pw = outputRect.W, ph = outputRect.H;
            if (pw <= 0 || ph <= 0)
            {
                continue;
            }

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


    // --- river_output_v1 events ---------------------------------------


    // --- river_seat_v1 events -----------------------------------------


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


    /// <summary>
    /// Ask the compositor to start a new manage sequence so that any state we
    /// changed outside of one (pending focus from pointer-enter, Super+Tab,
    /// close-and-refocus, drag start) actually gets flushed promptly.
    /// river_window_manager_v1::manage_dirty is opcode 3.
    /// </summary>
    private void ScheduleManage()
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }
        // If we're already inside a manage/render sequence the compositor will flush
        // our pending state when the current handler returns; issuing manage_dirty now
        // would just guarantee an extra cycle (and a potential infinite loop).
        if (_insideManageSequence)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(_manager, 3, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        WaylandInterop.wl_display_flush(_display);
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
        {
            return kv.Value;
        }

        return null;
    }

    uint? TagController.ITagHost.GetFocusedOutputVisibleTags()
        => GetFocusedOutputEntry()?.VisibleTags;

    uint? TagController.ITagHost.GetFocusedOutputLastTagset()
        => GetFocusedOutputEntry()?.LastVisibleTags;

    bool TagController.ITagHost.SetFocusedOutputVisibleTags(uint mask)
    {
        var oe = GetFocusedOutputEntry();
        if (oe is null)
        {
            return false;
        }

        if (oe.VisibleTags == mask)
        {
            return false;
        }

        // Push prior value onto history (cap to 8) and remember it
        // separately as LastVisibleTags for fast back-and-forth.
        oe.LastVisibleTags = oe.VisibleTags;
        oe.TagHistory.Push(oe.VisibleTags);
        while (oe.TagHistory.Count > 8)
        {
            // Drop oldest by rebuilding (Stack<T> has no DequeueLast).
            var arr = oe.TagHistory.ToArray();
            oe.TagHistory.Clear();
            for (int i = arr.Length - 2; i >= 0; i--)
            {
                oe.TagHistory.Push(arr[i]);
            }

            break;
        }

        oe.VisibleTags = mask;
        Log($"tags: output 0x{oe.Proxy.ToString("x")} VisibleTags=0x{mask:x8} (was 0x{oe.LastVisibleTags:x8})");
        return true;
    }

    bool TagController.ITagHost.SetFocusedWindowTags(uint mask)
    {
        if (_focusedWindow == IntPtr.Zero)
        {
            return false;
        }

        if (!_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return false;
        }

        if (fw.Tags == mask)
        {
            return false;
        }

        fw.Tags = mask;
        Log($"tags: window 0x{_focusedWindow.ToString("x")} Tags=0x{mask:x8}");
        return true;
    }

    bool TagController.ITagHost.ToggleFocusedWindowTags(uint mask)
    {
        if (_focusedWindow == IntPtr.Zero)
        {
            return false;
        }

        if (!_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return false;
        }

        uint next = fw.Tags ^ mask;
        if (next == 0u)
        {
            return false; // never end up untagged
        }

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
            {
                mask = oe.VisibleTags;
            }

            if (TagState.IsVisible(fw.Tags, mask))
            {
                return; // still visible; keep focus.
            }
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
            if (focusedOutput != IntPtr.Zero && w.Output != focusedOutput)
            {
                continue;
            }

            if (!TagState.IsVisible(w.Tags, focusedMask))
            {
                continue;
            }

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

    private void HandleScrollViewport(int deltaColumns)
    {
        if (_focusedWindow == IntPtr.Zero || !_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return;
        }

        _layoutController.ScrollViewport(fw.Output, ResolveOutputName(fw.Output), deltaColumns);
        ScheduleManage();
    }

    private void HandleMoveColumn(FocusDirection dir)
    {
        if (_focusedWindow == IntPtr.Zero || !_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return;
        }

        if (_layoutController.MoveFocused(fw.Output, ResolveOutputName(fw.Output), _focusedWindow, dir))
        {
            ScheduleManage();
        }
    }

    /// <summary>Build a per-output WindowEntryView snapshot for navigation queries.</summary>
    private List<WindowEntryView> BuildSnapshotFor(IntPtr output)
    {
        var list = new List<WindowEntryView>(_windows.Count);
        foreach (var kvp in _windows)
        {
            var w = kvp.Value;
            if (output != IntPtr.Zero && w.Output != IntPtr.Zero && w.Output != output)
            {
                continue;
            }

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


    private static string? MarshalUtf8(IntPtr p)
        => p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
}
